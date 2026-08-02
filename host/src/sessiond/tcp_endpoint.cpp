// =============================================================================
// tcp_endpoint.cpp — BSD-socket implementation of the host-owned connection
// -----------------------------------------------------------------------------
// No exceptions. Every failure is a SessionError. See tcp_endpoint.hpp for the
// host/fabric split this implements and for why seqSnapshot() refuses to guess.
// =============================================================================
#include "trading/sessiond/tcp_endpoint.hpp"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace trading::sessiond {
namespace {

[[nodiscard]] bool setNonBlocking(int fd) noexcept {
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return false;
    }
    return ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

}  // namespace

PosixTcpEndpoint::~PosixTcpEndpoint() {
    close();
}

trading::expected<void, SessionError> PosixTcpEndpoint::connect(const SessionConfig& cfg) {
    close();

    std::uint32_t remote_ip = 0;
    std::uint32_t local_ip  = 0;
    if (!parseIpv4(cfg.venue_host, remote_ip) || !parseIpv4(cfg.local_bind_ip, local_ip)) {
        return trading::fail(SessionError::InvalidConfig);
    }

    fd_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }

    int one = 1;
    (void)::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    // ⚠️ Nagle OFF. An order session must never coalesce. Delayed ACK is
    //    disabled where the platform allows it (Linux); on platforms that do not
    //    expose TCP_QUICKACK the fabric's mandatory PSH flag carries the load.
    //    manuals/02-networking/02-ip-udp-tcp-in-hardware.md §8 rule 10.
    if (::setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) != 0) {
        close();
        return trading::fail(SessionError::SocketError);
    }
#ifdef TCP_QUICKACK
    (void)::setsockopt(fd_, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
#endif

    // Bind the source address explicitly: the frame template must carry the same
    // source IP and port the kernel used, and an ephemeral bind chosen by the
    // stack is fine as long as we read it back afterwards (see tuple()).
    sockaddr_in local{};
    local.sin_family      = AF_INET;
    local.sin_addr.s_addr = htonl(local_ip);
    local.sin_port        = htons(cfg.local_bind_port);
    if (::bind(fd_, reinterpret_cast<const sockaddr*>(&local), sizeof(local)) != 0) {
        close();
        return trading::fail(SessionError::SocketError);
    }

    if (!setNonBlocking(fd_)) {
        close();
        return trading::fail(SessionError::SocketError);
    }

    sockaddr_in remote{};
    remote.sin_family      = AF_INET;
    remote.sin_addr.s_addr = htonl(remote_ip);
    remote.sin_port        = htons(cfg.venue_port);

    int rc = ::connect(fd_, reinterpret_cast<const sockaddr*>(&remote), sizeof(remote));
    if (rc != 0 && errno != EINPROGRESS) {
        close();
        return trading::fail(SessionError::SocketError);
    }

    if (rc != 0) {
        pollfd pfd{};
        pfd.fd     = fd_;
        pfd.events = POLLOUT;
        const int timeout_ms = static_cast<int>(cfg.connect_timeout.count());
        const int pr = ::poll(&pfd, 1, timeout_ms);
        if (pr == 0) {
            close();
            return trading::fail(SessionError::ConnectTimeout);
        }
        if (pr < 0) {
            close();
            return trading::fail(SessionError::SocketError);
        }
        int       so_err = 0;
        socklen_t len    = sizeof(so_err);
        if (::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &so_err, &len) != 0 || so_err != 0) {
            close();
            return trading::fail(SessionError::SocketError);
        }
    }

    send_locked_ = false;
    return {};
}

trading::expected<std::size_t, SessionError> PosixTcpEndpoint::send(
        std::span<const std::uint8_t> data) {
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }
    // ⚠️ Hazard 1. While the fabric owns the send side, the host writing even
    //    one byte here corrupts the TCP sequence space irrecoverably. This is a
    //    hard refusal, not a warning.
    if (send_locked_) {
        return trading::fail(SessionError::SendOwnerViolation);
    }
    if (data.empty()) {
        return std::size_t{0};
    }
#ifdef MSG_NOSIGNAL
    const int flags = MSG_NOSIGNAL;
#else
    const int flags = 0;
#endif
    const ssize_t n = ::send(fd_, data.data(), data.size(), flags);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return std::size_t{0};
        }
        if (errno == EPIPE || errno == ECONNRESET) {
            return trading::fail(SessionError::PeerClosed);
        }
        return trading::fail(SessionError::SocketError);
    }
    return static_cast<std::size_t>(n);
}

trading::expected<std::size_t, SessionError> PosixTcpEndpoint::recv(std::span<std::uint8_t> buf) {
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }
    if (buf.empty()) {
        return std::size_t{0};
    }
    const ssize_t n = ::recv(fd_, buf.data(), buf.size(), 0);
    if (n == 0) {
        return trading::fail(SessionError::PeerClosed);
    }
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return std::size_t{0};
        }
        if (errno == ECONNRESET) {
            return trading::fail(SessionError::PeerClosed);
        }
        return trading::fail(SessionError::SocketError);
    }
    return static_cast<std::size_t>(n);
}

trading::expected<void, SessionError> PosixTcpEndpoint::shutdownWrite() {
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }
    if (send_locked_) {
        return trading::fail(SessionError::SendOwnerViolation);
    }
    if (::shutdown(fd_, SHUT_WR) != 0 && errno != ENOTCONN) {
        return trading::fail(SessionError::SocketError);
    }
    return {};
}

void PosixTcpEndpoint::close() noexcept {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    send_locked_ = false;
}

bool PosixTcpEndpoint::connected() const noexcept {
    return fd_ >= 0;
}

trading::expected<ConnectionTuple, SessionError> PosixTcpEndpoint::tuple() const {
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }
    sockaddr_in local{};
    sockaddr_in remote{};
    socklen_t   ll = sizeof(local);
    socklen_t   rl = sizeof(remote);
    if (::getsockname(fd_, reinterpret_cast<sockaddr*>(&local), &ll) != 0 ||
        ::getpeername(fd_, reinterpret_cast<sockaddr*>(&remote), &rl) != 0) {
        return trading::fail(SessionError::SocketError);
    }
    ConnectionTuple t{};
    t.local_ip    = ntohl(local.sin_addr.s_addr);
    t.remote_ip   = ntohl(remote.sin_addr.s_addr);
    t.local_port  = ntohs(local.sin_port);
    t.remote_port = ntohs(remote.sin_port);
    return t;
}

trading::expected<TcpSeqSnapshot, SessionError> PosixTcpEndpoint::seqSnapshot() const {
    if (fd_ < 0) {
        return trading::fail(SessionError::SocketError);
    }
    // ⚠️ No provider means we do not know snd_nxt. We do NOT guess, and we do
    //    NOT fall back to something plausible: a wrong sequence number produces
    //    a segment the venue silently discards. sessiond turns this into a
    //    refusal to write the template, which is a refusal to trade.
    if (seq_provider_ == nullptr) {
        return trading::fail(SessionError::SeqStateUnavailable);
    }
    return seq_provider_(fd_, seq_ctx_);
}

}  // namespace trading::sessiond
