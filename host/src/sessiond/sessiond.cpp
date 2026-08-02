// =============================================================================
// sessiond.cpp — venue session lifecycle, heartbeats, sequencing, recovery
// -----------------------------------------------------------------------------
// See sessiond.hpp for the send-ownership interlock, the "no software path emits
// an order" rule, and the ordered recovery contract this file implements.
//
// No exceptions. No allocation after construction. No floating point anywhere
// near a sequence number.
// =============================================================================
#include "trading/sessiond/sessiond.hpp"

#include <algorithm>
#include <cstring>

namespace trading::sessiond {
namespace {

// How often the host re-reads the fabric's own view (SESS_STATE, SESS_SEQ_RX,
// SESS_LINK_UP) and compares it with its own. Slow on purpose: this is a
// consistency check, not a control loop, and the register interface is shared.
constexpr std::chrono::milliseconds kCrossCheckPeriod{1000};

// Bounded retry for a short non-blocking write. Every packet the host sends is
// <= 49 bytes, so a partial write is close to impossible — but "close to" is not
// a design, and a silent truncation of a Login Request is a session that never
// comes up for reasons nobody can see.
constexpr int kSendAttempts = 1024;

}  // namespace

SessionDaemon::SessionDaemon(SessionConfig cfg,
                             Device& dev,
                             ControlPlane& control,
                             TcpEndpoint& tcp,
                             Clock& clock) noexcept
    : cfg_(std::move(cfg)),
      regs_(dev),
      control_(control),
      tcp_(tcp),
      clock_(clock) {
    last_rx_          = clock_.now();
    last_tx_          = last_rx_;
    last_cross_check_ = last_rx_;
}

// -----------------------------------------------------------------------------
// State transitions
// -----------------------------------------------------------------------------
void SessionDaemon::transition(SessionState next) noexcept {
    if (state_ == next) {
        return;
    }
    state_ = next;
    // Best-effort publish to the fabric so SESS_STATE and the host agree. A
    // failure here is not fatal to the transition itself — but it is counted,
    // and crossCheckFabric() will notice the divergence.
    auto w = regs_.writeField(SessionField::HostState, static_cast<std::uint32_t>(next));
    if (!w.has_value()) {
        ++stats_.fabric_state_mismatch;
    }
}

void SessionDaemon::fault(SessionError e) noexcept {
    last_error_ = e;
    template_verified_ = false;
    transition(SessionState::Fault);
}

// -----------------------------------------------------------------------------
// Bring-up steps
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::ensureFabricCannotEmit() {
    // ⚠️ Request AND verify. "Ask ctrld to disarm and assume it worked" is the
    //    failure mode this whole function exists to prevent.
    auto d = control_.disarmOrderPath();
    if (!d.has_value()) {
        return trading::fail(d.error());
    }
    auto blocked = control_.emissionBlocked();
    if (!blocked.has_value()) {
        return trading::fail(blocked.error());
    }
    if (!*blocked) {
        return trading::fail(SessionError::ControlPlaneRefused);
    }
    // Belt and braces: take the send side back at the session layer too, so the
    // fabric's TX path has no valid epoch even if the disarm were reverted.
    auto t = takeSendSideFromFabric();
    if (!t.has_value()) {
        return trading::fail(t.error());
    }
    return {};
}

trading::expected<void, SessionError> SessionDaemon::checkLink() {
    auto link = regs_.readLinkStatus();
    if (!link.has_value()) {
        return trading::fail(link.error());
    }
    if (!link->order_entry) {
        // No point completing a TCP handshake through a dark link.
        return trading::fail(SessionError::LinkDown);
    }
    return {};
}

trading::expected<void, SessionError> SessionDaemon::connectTcp() {
    ++stats_.connects_attempted;
    transition(SessionState::Connecting);

    auto c = tcp_.connect(cfg_);
    if (!c.has_value()) {
        fault(c.error());
        return trading::fail(c.error());
    }
    ++stats_.connects_succeeded;
    rx_len_  = 0;
    last_rx_ = clock_.now();
    last_tx_ = last_rx_;
    return {};
}

std::uint64_t SessionDaemon::computeRequestedSequence() const noexcept {
    if (seq_.baseline_established) {
        // ⚠️ On every re-login this is the ONLY correct value: the next message
        //    we have not yet seen. Asking for anything else either replays what
        //    we already processed (harmless, handled) or skips messages we never
        //    saw (an unrecoverable hole in our order state).
        return seq_.next_expected;
    }
    switch (cfg_.start_policy) {
        case StartSequencePolicy::CurrentEnd:
            return soup::kSequenceCurrentEnd;   // 0 = only what happens from now on
        case StartSequencePolicy::ReplayAll:
            return 1;                            // the first message of the session
        case StartSequencePolicy::Explicit:
            return cfg_.explicit_start;
    }
    return 1;
}

trading::expected<void, SessionError> SessionDaemon::performLogin() {
    // The host owns the send side for the whole login exchange.
    if (send_owner_ != SendOwner::Host) {
        ++stats_.send_owner_violations;
        return trading::fail(SessionError::SendOwnerViolation);
    }

    const std::uint64_t requested = computeRequestedSequence();
    seq_.last_requested = requested;

    std::array<std::uint8_t, sizeof(soup::LoginRequestPacket)> buf{};
    const soup::LoginCredentials cred{
            .username          = cfg_.username,
            .password          = cfg_.password,   // ⚠️ never logged, never copied elsewhere
            .requested_session = cfg_.requested_session,
    };
    const std::size_t n = soup::encodeLoginRequest(buf, cred, requested);
    if (n == 0) {
        return trading::fail(SessionError::InvalidConfig);
    }

    transition(SessionState::LoginSent);
    auto s = sendAll(std::span<const std::uint8_t>(buf.data(), n));
    if (!s.has_value()) {
        fault(s.error());
        return trading::fail(s.error());
    }
    ++stats_.logins_sent;

    // ── Wait for Login Accepted / Login Rejected ─────────────────────────────
    const auto deadline = clock_.now() + cfg_.login_timeout;
    while (clock_.now() < deadline) {
        auto d = drainSocket();
        if (!d.has_value()) {
            fault(d.error());
            return trading::fail(d.error());
        }

        soup::Packet pkt{};
        while (true) {
            const auto st = soup::nextPacket(
                    std::span<const std::uint8_t>(rx_buf_.data(), rx_len_), pkt);
            if (st == soup::FrameStatus::Incomplete) {
                break;
            }
            if (st == soup::FrameStatus::Malformed) {
                ++stats_.malformed_packets;
                fault(SessionError::MalformedPacket);
                return trading::fail(SessionError::MalformedPacket);
            }

            auto handled = dispatch(pkt);
            const std::size_t consumed = pkt.frame_bytes;
            std::memmove(rx_buf_.data(), rx_buf_.data() + consumed, rx_len_ - consumed);
            rx_len_ -= consumed;

            if (!handled.has_value()) {
                fault(handled.error());
                return trading::fail(handled.error());
            }
            if (state_ == SessionState::Up) {
                return {};   // Login Accepted, sequence reconciled
            }
        }
    }

    // ⚠️ A login that neither succeeds nor is rejected is its own failure mode:
    //    the venue may be up but not answering this port.
    fault(SessionError::LoginTimeout);
    return trading::fail(SessionError::LoginTimeout);
}

trading::expected<void, SessionError> SessionDaemon::reconcileSequence(
        const soup::LoginAccepted& accepted) {
    seq_.last_accepted = accepted.next_sequence;

    if (!seq_.baseline_established) {
        // First login of this session. Whatever the venue says is our baseline —
        // including the "current end" case, where we asked for 0 and it tells us
        // where "now" is.
        seq_.next_expected        = accepted.next_sequence;
        seq_.highest_delivered    = (accepted.next_sequence > 0) ? accepted.next_sequence - 1 : 0;
        seq_.baseline_established = true;
        return {};
    }

    if (accepted.next_sequence > seq_.last_requested) {
        // ⚠️ UNRECOVERABLE. We asked to resume at N and the venue will start at
        //    M > N: the messages in [N, M) are gone. Those messages are the only
        //    authoritative record of what happened to our orders while we were
        //    away — fills we do not know about, cancels we think are live. There
        //    is no protocol mechanism to get them back.
        //    This is trading_pkg::kill_src_e KILL_SEQ_FAULT, and it is a
        //    stop-and-reconcile-by-hand event, not a retry.
        ++stats_.sequence_gaps;
        ++stats_.sequence_faults;
        return trading::fail(SessionError::SequenceFault);
    }

    if (accepted.next_sequence < seq_.last_requested) {
        // The venue will replay messages we have already processed. Benign: we
        // count them and drop them as they arrive rather than double-applying.
        seq_.next_expected = accepted.next_sequence;
        return {};
    }

    seq_.next_expected = accepted.next_sequence;
    return {};
}

trading::expected<void, SessionError> SessionDaemon::writeTemplateAndVerify() {
    template_verified_ = false;

    auto tuple = tcp_.tuple();
    if (!tuple.has_value()) {
        return trading::fail(tuple.error());
    }
    // ⚠️ No guessing. If the stack cannot tell us where its send sequence is,
    //    we do not write a template — a wrong snd_nxt produces segments the
    //    venue silently discards, which looks exactly like a market with no
    //    fills. See TcpEndpoint::seqSnapshot().
    auto seqs = tcp_.seqSnapshot();
    if (!seqs.has_value()) {
        return trading::fail(seqs.error());
    }
    if (!seqs->valid) {
        return trading::fail(SessionError::SeqStateUnavailable);
    }

    FrameTemplateParams p{};
    p.src_mac       = cfg_.src_mac;
    p.dst_mac       = cfg_.dst_mac;
    p.src_ip        = tuple->local_ip;
    p.dst_ip        = tuple->remote_ip;
    p.src_port      = tuple->local_port;
    p.dst_port      = tuple->remote_port;
    p.ip_ttl        = cfg_.ip_ttl;
    p.ip_dscp       = cfg_.ip_dscp;
    p.tcp_window    = cfg_.tcp_window;
    p.session_epoch = epoch_;

    auto built = FrameTemplate::build(p);
    if (!built.has_value()) {
        return trading::fail(built.error());
    }
    frame_template_ = *built;

    ++stats_.template_writes;
    auto w = regs_.writeFrameTemplate(frame_template_);
    if (!w.has_value()) {
        if (w.error() == SessionError::TemplateVerifyMismatch) {
            ++stats_.template_verify_fails;
        } else if (w.error() == SessionError::TemplateCrcMismatch) {
            ++stats_.template_crc_fails;
        }
        return trading::fail(w.error());
    }

    // Hand over the pieces of TCP state that live outside the template image.
    auto f = regs_.writeField(SessionField::TcpRcvNxt, seqs->rcv_nxt);
    if (!f.has_value()) {
        return trading::fail(f.error());
    }
    f = regs_.writeField(SessionField::TcpSndWnd, seqs->snd_wnd);
    if (!f.has_value()) {
        return trading::fail(f.error());
    }
    f = regs_.writeField(SessionField::IpIdBase, cfg_.ip_id_base);
    if (!f.has_value()) {
        return trading::fail(f.error());
    }
    // ⚠️ The epoch is written AFTER the template it describes. The fabric
    //    refuses to fire unless the two match, so this ordering makes a
    //    half-configured session physically unable to emit.
    f = regs_.writeField(SessionField::Epoch, epoch_);
    if (!f.has_value()) {
        return trading::fail(f.error());
    }

    // Publish the TCP send sequence the fabric must continue from.
    auto ps = regs_.publishTxSequence(static_cast<std::uint64_t>(seqs->snd_nxt));
    if (!ps.has_value()) {
        return trading::fail(ps.error());
    }

    template_verified_ = true;
    return {};
}

trading::expected<void, SessionError> SessionDaemon::publishSequenceState() {
    auto f = regs_.writeField(SessionField::SoupRxSeqLo,
                              static_cast<std::uint32_t>(seq_.next_expected));
    if (!f.has_value()) {
        return trading::fail(f.error());
    }
    return regs_.writeField(SessionField::SoupRxSeqHi,
                            static_cast<std::uint32_t>(seq_.next_expected >> 32));
}

trading::expected<void, SessionError> SessionDaemon::handSendSideToFabric() {
    // Order matters: lock the host socket FIRST, then tell the fabric it owns
    // the send side. If the two overlapped in the other order there would be an
    // instant with two writers, which is the one thing that must never happen.
    tcp_.lockSend(true);
    auto f = regs_.writeField(SessionField::TxArm, 1);
    if (!f.has_value()) {
        tcp_.lockSend(false);
        return trading::fail(f.error());
    }
    send_owner_ = SendOwner::Fabric;
    return {};
}

trading::expected<void, SessionError> SessionDaemon::takeSendSideFromFabric() {
    // Mirror image: disarm the fabric's TX first, then unlock the socket.
    auto f = regs_.writeField(SessionField::TxArm, 0);
    if (!f.has_value()) {
        return trading::fail(f.error());
    }
    send_owner_ = SendOwner::Host;
    tcp_.lockSend(false);
    return {};
}

// -----------------------------------------------------------------------------
// start()
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::start() {
    const SessionError cfg_err = cfg_.validate();
    if (cfg_err != SessionError::None) {
        fault(cfg_err);
        return trading::fail(cfg_err);
    }

    // The fabric must be quiescent before we touch the session at all.
    auto q = ensureFabricCannotEmit();
    if (!q.has_value()) {
        fault(q.error());
        return trading::fail(q.error());
    }

    auto l = checkLink();
    if (!l.has_value()) {
        fault(l.error());
        return trading::fail(l.error());
    }

    auto c = connectTcp();
    if (!c.has_value()) {
        return trading::fail(c.error());
    }

    ++epoch_;   // every login gets its own epoch, first one included

    auto li = performLogin();
    if (!li.has_value()) {
        return trading::fail(li.error());
    }

    auto t = writeTemplateAndVerify();
    if (!t.has_value()) {
        fault(t.error());
        return trading::fail(t.error());
    }

    auto ps = publishSequenceState();
    if (!ps.has_value()) {
        fault(ps.error());
        return trading::fail(ps.error());
    }

    auto h = handSendSideToFabric();
    if (!h.has_value()) {
        fault(h.error());
        return trading::fail(h.error());
    }

    // ⚠️ Deliberately NOT armed. Enabling trading is ctrld's two-step arm
    //    (startup sequence steps 7-8) and stays human-gated.
    return {};
}

// -----------------------------------------------------------------------------
// poll()
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::poll() {
    if (state_ != SessionState::Up && state_ != SessionState::LoginSent) {
        return {};   // nothing to service; the caller drives recovery
    }

    auto d = drainSocket();
    if (!d.has_value()) {
        if (d.error() == SessionError::PeerClosed) {
            ++stats_.peer_closes;
        }
        fault(d.error());
        return trading::fail(d.error());
    }

    // Frame and dispatch everything currently buffered.
    while (true) {
        soup::Packet pkt{};
        const auto st = soup::nextPacket(
                std::span<const std::uint8_t>(rx_buf_.data(), rx_len_), pkt);
        if (st == soup::FrameStatus::Incomplete) {
            break;
        }
        if (st == soup::FrameStatus::Malformed) {
            ++stats_.malformed_packets;
            fault(SessionError::MalformedPacket);
            return trading::fail(SessionError::MalformedPacket);
        }
        auto handled = dispatch(pkt);
        const std::size_t consumed = pkt.frame_bytes;
        std::memmove(rx_buf_.data(), rx_buf_.data() + consumed, rx_len_ - consumed);
        rx_len_ -= consumed;
        if (!handled.has_value()) {
            fault(handled.error());
            return trading::fail(handled.error());
        }
    }

    const auto now = clock_.now();

    // ── Receive timeout ──────────────────────────────────────────────────────
    // ⚠️ Nothing at all — not even a Server Heartbeat — for rx_timeout means the
    //    session is dead whether or not the socket says so. TCP can take minutes
    //    to notice a black hole; we take 15 seconds.
    if (now - last_rx_ > cfg_.rx_timeout) {
        ++stats_.rx_timeouts;
        fault(SessionError::ReceiveTimeout);
        return trading::fail(SessionError::ReceiveTimeout);
    }

    // ── Client heartbeat ─────────────────────────────────────────────────────
    // Only while the HOST owns the send side. Once the fabric owns it, the
    // fabric emits the heartbeat on its own timer (rtl/order/soupbin_tx.sv) so a
    // quiet market cannot kill the session while the host is busy — and so that
    // there is never a second writer on this TCP stream.
    if (send_owner_ == SendOwner::Host && state_ == SessionState::Up &&
        (now - last_tx_) >= cfg_.heartbeat_interval) {
        auto hb = sendClientHeartbeat();
        if (!hb.has_value()) {
            fault(hb.error());
            return trading::fail(hb.error());
        }
    }

    // ── Periodic agreement check with the fabric ─────────────────────────────
    if (now - last_cross_check_ >= kCrossCheckPeriod) {
        last_cross_check_ = now;
        auto x = crossCheckFabric();
        if (!x.has_value()) {
            fault(x.error());
            return trading::fail(x.error());
        }
        // Push any credit the host has accounted for. Bounded per call.
        auto fl = credits_.flush(control_);
        if (fl.has_value()) {
            stats_.credits_returned += *fl;
        } else {
            ++stats_.credit_return_errors;
        }
    }

    return {};
}

// -----------------------------------------------------------------------------
// Packet dispatch
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::dispatch(const soup::Packet& pkt) {
    switch (pkt.type) {
        case soup::PacketType::SequencedData: {
            if (state_ != SessionState::Up) {
                ++stats_.unexpected_packets;
                return trading::fail(SessionError::UnexpectedPacket);
            }
            ++stats_.seq_data_rx;
            const std::uint64_t this_seq = seq_.next_expected;
            // ⚠️ Only Sequenced Data advances the sequence. Heartbeats and Debug
            //    do not — see soup::advancesSequence().
            seq_.next_expected = this_seq + 1;

            if (this_seq <= seq_.highest_delivered && seq_.highest_delivered != 0) {
                // A replay of something we already applied. Count it and drop it;
                // re-delivering would double-count a fill.
                ++stats_.replay_duplicates;
                return {};
            }
            seq_.highest_delivered = this_seq;
            if (on_seq_data_ != nullptr && !pkt.payload.empty()) {
                on_seq_data_(this_seq, pkt.payload, on_seq_data_ctx_);
            }
            return {};
        }

        case soup::PacketType::ServerHeartbeat:
            ++stats_.server_heartbeats_rx;
            return {};

        case soup::PacketType::LoginAccepted: {
            if (state_ != SessionState::LoginSent) {
                ++stats_.unexpected_packets;
                return trading::fail(SessionError::UnexpectedPacket);
            }
            soup::LoginAccepted acc{};
            if (!soup::decodeLoginAccepted(pkt.payload, acc)) {
                ++stats_.malformed_packets;
                return trading::fail(SessionError::MalformedPacket);
            }
            ++stats_.logins_accepted;
            auto rec = reconcileSequence(acc);
            if (!rec.has_value()) {
                return trading::fail(rec.error());
            }
            transition(SessionState::Up);
            return {};
        }

        case soup::PacketType::LoginRejected: {
            if (pkt.payload.size() != sizeof(soup::LoginRejectedPayload)) {
                ++stats_.malformed_packets;
                return trading::fail(SessionError::MalformedPacket);
            }
            const auto reason =
                    soup::decodeRejectReason(static_cast<char>(pkt.payload[0]));
            switch (reason) {
                case soup::LoginRejectReason::NotAuthorized:
                    // ⚠️ Credentials or entitlement. Retrying burns login
                    //    attempts and can lock the account. Operator action.
                    ++stats_.logins_rejected_auth;
                    return trading::fail(SessionError::LoginRejectedAuth);
                case soup::LoginRejectReason::SessionNotAvailable:
                    // ⚠️ A completely different problem: the credentials are
                    //    fine, the requested session id is not available
                    //    (typically a stale, previous-day session). Retrying the
                    //    same id will never succeed; retrying with the "current
                    //    session" (empty) may, and that is a policy decision the
                    //    operator makes, not a loop.
                    ++stats_.logins_rejected_sess;
                    return trading::fail(SessionError::LoginRejectedSession);
                case soup::LoginRejectReason::Unknown:
                    break;
            }
            return trading::fail(SessionError::LoginRejectedUnknown);
        }

        case soup::PacketType::EndOfSession:
            // Orderly: the venue has ended the session. Not an error — but not a
            // state we may trade in, and NOT something to auto-reconnect out of.
            // Reconnecting into an ended session just produces another 'Z'.
            ++stats_.end_of_session_rx;
            return trading::fail(SessionError::EndOfSession);

        case soup::PacketType::Debug:
            ++stats_.debug_rx;
            return {};

        case soup::PacketType::UnsequencedData:
            // ⚠️ We are the client. Unsequenced data is ours to send, never to
            //    receive. Seeing one means we are talking to something that is
            //    not the venue's order-entry port.
            ++stats_.unseq_data_rx;
            return trading::fail(SessionError::UnexpectedPacket);

        case soup::PacketType::LoginRequest:
        case soup::PacketType::ClientHeartbeat:
        case soup::PacketType::LogoutRequest:
            ++stats_.unexpected_packets;
            return trading::fail(SessionError::UnexpectedPacket);
    }
    ++stats_.unexpected_packets;
    return trading::fail(SessionError::UnexpectedPacket);
}

trading::expected<void, SessionError> SessionDaemon::drainSocket() {
    while (true) {
        if (rx_len_ >= rx_buf_.size()) {
            // Full buffer with no complete packet extracted means the length
            // framing is wrong. SoupBinTCP has no resynchronisation marker, so
            // there is nothing to recover to: tear the session down.
            return trading::fail(SessionError::BufferOverflow);
        }
        auto n = tcp_.recv(std::span<std::uint8_t>(rx_buf_.data() + rx_len_,
                                                   rx_buf_.size() - rx_len_));
        if (!n.has_value()) {
            return trading::fail(n.error());
        }
        if (*n == 0) {
            return {};   // drained
        }
        rx_len_ += *n;
        last_rx_ = clock_.now();
    }
}

trading::expected<void, SessionError> SessionDaemon::sendAll(std::span<const std::uint8_t> data) {
    std::size_t sent = 0;
    for (int attempt = 0; attempt < kSendAttempts && sent < data.size(); ++attempt) {
        auto n = tcp_.send(data.subspan(sent));
        if (!n.has_value()) {
            if (n.error() == SessionError::SendOwnerViolation) {
                ++stats_.send_owner_violations;
            }
            return trading::fail(n.error());
        }
        sent += *n;
    }
    if (sent != data.size()) {
        return trading::fail(SessionError::SocketError);
    }
    last_tx_ = clock_.now();
    return {};
}

trading::expected<void, SessionError> SessionDaemon::sendClientHeartbeat() {
    std::array<std::uint8_t, soup::kHeaderBytes> buf{};
    const std::size_t n = soup::encodeEmptyPacket(buf, soup::PacketType::ClientHeartbeat);
    if (n == 0) {
        return trading::fail(SessionError::MalformedPacket);
    }
    auto s = sendAll(std::span<const std::uint8_t>(buf.data(), n));
    if (!s.has_value()) {
        return trading::fail(s.error());
    }
    ++stats_.client_heartbeats_tx;
    return {};
}

// -----------------------------------------------------------------------------
// Fabric agreement
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::crossCheckFabric() {
    auto link = regs_.readLinkStatus();
    if (!link.has_value()) {
        return trading::fail(link.error());
    }
    if (!link->order_entry) {
        // ⚠️ The order-entry link dropped underneath an established session.
        //    Whatever the socket thinks, no order can reach the venue.
        return trading::fail(SessionError::LinkDown);
    }

    auto fabric_state = regs_.readState();
    if (!fabric_state.has_value()) {
        return trading::fail(fabric_state.error());
    }
    if (*fabric_state != state_) {
        // Counted, not fatal: the fabric's own state machine may lag ours by a
        // poll. A persistent divergence is what the alert threshold is for.
        ++stats_.fabric_state_mismatch;
    }

    auto fabric_rx = regs_.readRxSequence();
    if (!fabric_rx.has_value()) {
        return trading::fail(fabric_rx.error());
    }
    // The fabric counts sequenced-data packets it has seen; the host counts the
    // ones it has processed. The fabric can be ahead by the packets still in our
    // buffer, but it must never be BEHIND — that would mean it missed inbound
    // messages, and its fill and credit view is not ours.
    if (*fabric_rx + 1 < seq_.next_expected) {
        ++stats_.sequence_gaps;
        return trading::fail(SessionError::SequenceGap);
    }
    return {};
}

// -----------------------------------------------------------------------------
// resynchronize() — the ordered recovery
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::resynchronize(ResyncReason reason) {
    ++stats_.resyncs_started;

    // ── (a) The fabric must not be able to emit. Verified, not hoped. ────────
    if (reason == ResyncReason::SequenceFault) {
        // ⚠️ An unrecoverable sequence fault is not a disarm, it is a KILL. Our
        //    view of our own orders is wrong; latch it in hardware with the
        //    right provenance so the post-incident record says why.
        //    trading_pkg::kill_src_e KILL_SEQ_FAULT = 7.
        auto k = control_.requestKill(KillSrc::SeqFault);
        if (!k.has_value()) {
            ++stats_.resyncs_failed;
            fault(k.error());
            return trading::fail(k.error());
        }
    }
    auto q = ensureFabricCannotEmit();
    if (!q.has_value()) {
        ++stats_.resyncs_failed;
        fault(q.error());
        return trading::fail(q.error());
    }
    template_verified_ = false;

    // A sequence fault is terminal for automated recovery. We have stopped the
    // fabric and latched the kill; a human reconciles from the venue's record
    // before anything else happens.
    if (reason == ResyncReason::SequenceFault) {
        fault(SessionError::SequenceFault);
        ++stats_.resyncs_failed;
        return trading::fail(SessionError::SequenceFault);
    }

    // ── (b) Tear down and reconnect ──────────────────────────────────────────
    tcp_.close();
    rx_len_ = 0;
    transition(SessionState::Down);

    auto l = checkLink();
    if (!l.has_value()) {
        ++stats_.resyncs_failed;
        fault(l.error());
        return trading::fail(l.error());
    }

    auto c = connectTcp();
    if (!c.has_value()) {
        ++stats_.resyncs_failed;
        return trading::fail(c.error());
    }

    // ── (c) Re-login and reconcile the sequence number ───────────────────────
    // ⚠️ New connection, new sequence space, new source port: a new epoch. The
    //    fabric refuses to fire on a template whose epoch does not match, so the
    //    old template is now inert even if something tried to use it.
    ++epoch_;

    auto li = performLogin();
    if (!li.has_value()) {
        ++stats_.resyncs_failed;
        if (li.error() == SessionError::SequenceFault) {
            // Escalate: the venue cannot replay what we need.
            auto k = control_.requestKill(KillSrc::SeqFault);
            (void)k;   // already faulted; the kill is best-effort at this point
        }
        return trading::fail(li.error());
    }

    // ── (d) Rewrite and re-verify the template ───────────────────────────────
    auto t = writeTemplateAndVerify();
    if (!t.has_value()) {
        ++stats_.resyncs_failed;
        fault(t.error());
        return trading::fail(t.error());
    }
    auto ps = publishSequenceState();
    if (!ps.has_value()) {
        ++stats_.resyncs_failed;
        fault(ps.error());
        return trading::fail(ps.error());
    }

    // ── Credit is meaningless across a session boundary ──────────────────────
    // Every order that was in flight is now in an unknown state until the replay
    // says otherwise. Start from "nothing outstanding" and let the reconciler
    // correct it from the authoritative sequenced stream.
    credits_.resync(0);

    auto h = handSendSideToFabric();
    if (!h.has_value()) {
        ++stats_.resyncs_failed;
        fault(h.error());
        return trading::fail(h.error());
    }

    // ── (e) Only now may trading be permitted again ──────────────────────────
    if (was_armed_) {
        auto a = control_.armOrderPath();
        if (!a.has_value()) {
            ++stats_.resyncs_failed;
            fault(a.error());
            return trading::fail(a.error());
        }
    }

    ++stats_.resyncs_completed;
    last_error_ = SessionError::None;
    return {};
}

// -----------------------------------------------------------------------------
// shutdown()
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionDaemon::shutdown() {
    // ⚠️ Disable emission BEFORE anything else. The reverse of bring-up.
    auto q = ensureFabricCannotEmit();
    if (!q.has_value()) {
        fault(q.error());
        return trading::fail(q.error());
    }

    if (tcp_.connected() && state_ == SessionState::Up) {
        std::array<std::uint8_t, soup::kHeaderBytes> buf{};
        const std::size_t n = soup::encodeEmptyPacket(buf, soup::PacketType::LogoutRequest);
        if (n > 0) {
            auto s = sendAll(std::span<const std::uint8_t>(buf.data(), n));
            if (s.has_value()) {
                ++stats_.logouts_sent;
            }
            // A failed logout is logged and ignored: we are closing the socket
            // regardless, and the venue treats a dropped connection as a logout.
        }
        (void)tcp_.shutdownWrite();
    }

    tcp_.close();
    rx_len_            = 0;
    template_verified_ = false;
    was_armed_         = false;
    transition(SessionState::Down);
    return {};
}

}  // namespace trading::sessiond
