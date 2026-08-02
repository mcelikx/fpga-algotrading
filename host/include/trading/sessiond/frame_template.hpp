// =============================================================================
// frame_template.hpp — the byte-exact frame the fabric splices orders into
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond
// Mirrors : rtl/order/ouch_pkg.sv §11 (ETH_/IP_/TCP_ offsets, FRAME_HDR_LEN)
//           rtl/order/ouch_pkg.sv §1  (SOUP_ header geometry)
// Governs : manuals/02-networking/02-ip-udp-tcp-in-hardware.md §4, §6
//           manuals/08-nasdaq/05-ouch-5.0-order-entry.md §7
//
// =============================================================================
// WHAT THIS IS
// -----------------------------------------------------------------------------
// The host establishes the TCP connection and logs in. It then writes into the
// fabric a complete byte image of the outbound frame with every constant field
// filled in, and the fabric splices order payloads into it:
//
//   byte 0        14           34            54     57
//   ┌─────────────┬────────────┬─────────────┬──────┬──────────────────────┐
//   │ Ethernet 14 │  IPv4 20   │   TCP 20    │Soup 3│  OUCH message (N)    │
//   └─────────────┴────────────┴─────────────┴──────┴──────────────────────┘
//                      ▲              ▲          ▲          ▲
//                      │              │          │          └ ouch_encoder.sv
//                      │              │          │            (per-symbol BRAM)
//                      │              │          └ length patched, type 'U' fixed
//                      │              └ seq / ack / checksum patched
//                      └ total length / identification / checksum patched
//
// PATCHED PER ORDER BY THE FABRIC (and therefore stored as ZERO here, so the
// stored partial checksum never needs a subtraction — see §4 of the networking
// manual, and the RFC 1624 warning: we never subtract, so the erratum cannot
// bite us):
//     IPv4 total length      2 B   @ 16
//     IPv4 identification    2 B   @ 18
//     IPv4 header checksum   2 B   @ 24
//     TCP  sequence number   4 B   @ 38
//     TCP  acknowledgement   4 B   @ 42
//     TCP  checksum          2 B   @ 50
//     Soup packet length     2 B   @ 54
//     (plus the OUCH body, which is ouch_encoder.sv's template, not ours)
//
// FIXED FOR THE LIFE OF THE SESSION EPOCH:
//     dst MAC, src MAC, EtherType
//     ver/IHL, DSCP, flags(DF), TTL, protocol, src IP, dst IP
//     src port, dst port, data offset, flags(PSH|ACK), window, urgent pointer
//     Soup packet type 'U'
//
// ⚠️ THE WINDOW FIELD IS A HAZARD. Every segment the fabric emits advertises
//    the window baked in here, while the host's real receive window moves. It
//    must be configured at or below the smallest window the host stack will
//    ever advertise (SessionConfig::tcp_window). Advertising more than we can
//    hold invites the venue to send data we will drop.
//
// ⚠️ A wrong byte here is the worst failure mode in the system: the venue's
//    stack silently discards a segment with a bad checksum. No reject, no
//    error, no fill — the order simply never happened. Hence: write, READ BACK,
//    verify word by word, and cross-check a host-computed CRC32 against
//    SESS_TMPL_CRC before anything is armed.
// =============================================================================
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include "trading/expected.hpp"
#include <span>
#include <string>

#include "trading/sessiond/config.hpp"
#include "trading/sessiond/session_state.hpp"
#include "trading/sessiond/soupbin.hpp"

namespace trading::sessiond {

// =============================================================================
// 1. Geometry — MUST match rtl/order/ouch_pkg.sv §11 exactly
// =============================================================================
inline constexpr std::size_t kEthHdrLen   = 14;
inline constexpr std::size_t kIp4HdrLen   = 20;   // IHL=5, no options. Ever.
inline constexpr std::size_t kTcpHdrLen   = 20;   // data offset 5, no options
inline constexpr std::size_t kL2L4HdrLen  = kEthHdrLen + kIp4HdrLen + kTcpHdrLen;  // 54
inline constexpr std::size_t kFrameHdrLen = kL2L4HdrLen + soup::kHeaderBytes;      // 57

static_assert(kL2L4HdrLen == 54, "mirrors ouch_pkg::FRAME_HDR_LEN");

// Ethernet
inline constexpr std::size_t   kOffEthDmac   = 0;
inline constexpr std::size_t   kOffEthSmac   = 6;
inline constexpr std::size_t   kOffEthType   = 12;
inline constexpr std::uint16_t kEtherTypeIpv4 = 0x0800;

// IPv4 (base 14)
inline constexpr std::size_t   kOffIpVerIhl  = 14;
inline constexpr std::size_t   kOffIpDscp    = 15;
inline constexpr std::size_t   kOffIpTotLen  = 16;   // PATCHED
inline constexpr std::size_t   kOffIpId      = 18;   // PATCHED
inline constexpr std::size_t   kOffIpFlags   = 20;
inline constexpr std::size_t   kOffIpTtl     = 22;
inline constexpr std::size_t   kOffIpProto   = 23;
inline constexpr std::size_t   kOffIpCsum    = 24;   // PATCHED
inline constexpr std::size_t   kOffIpSrc     = 26;
inline constexpr std::size_t   kOffIpDst     = 30;
inline constexpr std::uint8_t  kIpVerIhlV4   = 0x45;
inline constexpr std::uint16_t kIpFlagsDf    = 0x4000;
inline constexpr std::uint8_t  kIpProtoTcp   = 6;

// TCP (base 34)
inline constexpr std::size_t   kOffTcpSport  = 34;
inline constexpr std::size_t   kOffTcpDport  = 36;
inline constexpr std::size_t   kOffTcpSeq    = 38;   // PATCHED
inline constexpr std::size_t   kOffTcpAck    = 42;   // PATCHED
inline constexpr std::size_t   kOffTcpOffRsv = 46;
inline constexpr std::size_t   kOffTcpFlags  = 47;
inline constexpr std::size_t   kOffTcpWin    = 48;
inline constexpr std::size_t   kOffTcpCsum   = 50;   // PATCHED
inline constexpr std::size_t   kOffTcpUrg    = 52;
inline constexpr std::uint8_t  kTcpOffRsv5   = 0x50;
inline constexpr std::uint8_t  kTcpFlagsPshAck = 0x18;   // PSH is mandatory

// SoupBinTCP (base 54)
inline constexpr std::size_t kOffSoupLen  = 54;   // PATCHED
inline constexpr std::size_t kOffSoupType = 56;

// ⚠️ Every 16-bit field of the checksummed region must start at an EVEN offset,
//    or the one's-complement byte parity in the fabric is inverted and every
//    checksum is wrong. These asserts are the cheapest possible guard.
static_assert(kOffIpSrc  % 2 == 0, "pseudo-header parity");
static_assert(kOffTcpSport % 2 == 0, "TCP header parity");
static_assert(kOffSoupLen % 2 == 0, "TCP payload parity");
static_assert(kOffSoupType % 2 == 0, "Soup type byte lands in the HIGH half");

// =============================================================================
// 2. The word image handed to the fabric
// -----------------------------------------------------------------------------
// 32-bit words, LITTLE-ENDIAN packing of the BIG-ENDIAN wire, i.e. word[i] bits
// [7:0] hold frame byte 4i — the byte transmitted FIRST. This matches the host
// contract at the top of rtl/order/ouch_encoder.sv verbatim; if that contract
// changes, this changes with it and both static_asserts below must be revisited.
// =============================================================================
inline constexpr std::size_t kFrameHdrWords = 15;   // 60 bytes: 57 used, 3 pad
inline constexpr std::size_t kMetaWords     = 5;
inline constexpr std::size_t kTemplateWords = kFrameHdrWords + kMetaWords;   // 20

static_assert(kFrameHdrWords * 4 >= kFrameHdrLen, "header does not fit in the word image");
static_assert(kTemplateWords == 20,
              "matches ouch_encoder.sv TMPL_WORDS so both template kinds share a "
              "20-word row stride");

// Meta word indices, relative to the start of the template row.
// TODO(rtl-contract): rtl/order/tcp_tx_lite.sv does not exist yet. This meta
//   block is the host's proposal; reconcile with that module when it lands and
//   with rtl/ctrl/csr_regfile.sv.
inline constexpr std::size_t kMetaTcpCsum = kFrameHdrWords + 0;  // [15:0] partial one's-comp sum
inline constexpr std::size_t kMetaIpCsum  = kFrameHdrWords + 1;  // [15:0] partial one's-comp sum
inline constexpr std::size_t kMetaEpoch   = kFrameHdrWords + 2;  // [15:0] session epoch
inline constexpr std::size_t kMetaFlags   = kFrameHdrWords + 3;  // [0] valid
inline constexpr std::size_t kMetaRsvd    = kFrameHdrWords + 4;

inline constexpr std::uint32_t kMetaFlagValid = 0x1U;

// =============================================================================
// 3. One's-complement checksum arithmetic (RFC 1071)
// -----------------------------------------------------------------------------
// Mirrors rtl/order/ouch_pkg.sv §9. We accumulate UNFOLDED and fold exactly
// once, at the end — folding early repeatedly hits the 0x0000 / 0xFFFF
// equivalence and invites precisely the off-by-one the RFC 1624 erratum is
// about. We never subtract, so that erratum cannot apply to this code at all.
// =============================================================================

// Sum `bytes` into a 32-bit accumulator. `start_parity` is the parity of the
// FIRST byte's offset within the checksummed region: 0 = the byte is the HIGH
// half of its 16-bit word, 1 = the LOW half.
[[nodiscard]] std::uint32_t onesSum(std::span<const std::uint8_t> bytes,
                                    unsigned start_parity = 0) noexcept;

// Fold carries into 16 bits. Two folds are provably sufficient for any 32-bit
// accumulator reachable here.
[[nodiscard]] std::uint16_t onesFold(std::uint32_t acc) noexcept;

// CRC32, IEEE 802.3: reflected, polynomial 0xEDB88320, init 0xFFFFFFFF, final
// XOR 0xFFFFFFFF.
// TODO(rtl-contract): SESS_TMPL_CRC's exact convention is not defined anywhere
//   in rtl/ yet (no csr_regfile.sv, no tcp_tx_lite.sv). This is the host's
//   proposal, chosen to match the CRC32 the MAC already implements
//   (rtl/eth/crc32). The bytes covered are the template row's words in
//   ascending index order, each serialised little-endian — i.e. exactly the
//   byte sequence the host wrote. Reconcile before UAT.
[[nodiscard]] std::uint32_t crc32Ieee(std::span<const std::uint8_t> bytes) noexcept;
[[nodiscard]] std::uint32_t crc32IeeeWords(std::span<const std::uint32_t> words) noexcept;

// =============================================================================
// 4. Template parameters
// =============================================================================
struct FrameTemplateParams {
    MacAddress    src_mac{};
    MacAddress    dst_mac{};        // venue gateway, from the static ARP entry
    std::uint32_t src_ip = 0;       // host byte order
    std::uint32_t dst_ip = 0;       // host byte order
    std::uint16_t src_port = 0;
    std::uint16_t dst_port = 0;
    std::uint8_t  ip_ttl  = 64;
    std::uint8_t  ip_dscp = 0;
    std::uint16_t tcp_window = 0;   // ⚠️ conservative; see the header comment
    std::uint16_t session_epoch = 0;
};

// =============================================================================
// 5. The template
// =============================================================================
class FrameTemplate {
 public:
    // A default-constructed template is EMPTY and invalid — all-zero words, no
    // addresses, no ports. valid() is false and writeFrameTemplate() refuses it.
    // It exists so a SessionDaemon can hold one before its first login.
    FrameTemplate() = default;

    [[nodiscard]] bool valid() const noexcept {
        return params_.dst_port != 0 && params_.src_port != 0 && params_.tcp_window != 0;
    }

    // Builds the byte image and both partial checksums. Fails (rather than
    // producing a template that would silently be discarded by the venue) on any
    // unset MAC, zero port, zero window or zero address.
    [[nodiscard]] static trading::expected<FrameTemplate, SessionError> build(
            const FrameTemplateParams& p) noexcept;

    [[nodiscard]] std::span<const std::uint8_t> headerBytes() const noexcept {
        return std::span<const std::uint8_t>(bytes_.data(), kFrameHdrLen);
    }
    [[nodiscard]] std::span<const std::uint32_t> words() const noexcept {
        return std::span<const std::uint32_t>(words_.data(), words_.size());
    }
    [[nodiscard]] std::uint16_t tcpPartialSum() const noexcept { return tcp_partial_; }
    [[nodiscard]] std::uint16_t ipPartialSum() const noexcept  { return ip_partial_; }
    [[nodiscard]] std::uint16_t epoch() const noexcept         { return params_.session_epoch; }
    [[nodiscard]] const FrameTemplateParams& params() const noexcept { return params_; }

    // CRC32 of the exact word image written to the fabric. Compared against
    // SESS_TMPL_CRC. A mismatch means the fabric does not hold what we sent, and
    // nothing may be armed.
    [[nodiscard]] std::uint32_t crc32() const noexcept;

    // Human-readable, for the audit log. Contains no credentials.
    [[nodiscard]] std::string describe() const;

    // ── The arithmetic the FABRIC performs per order ─────────────────────────
    // Exposed so that the host can (a) prove the template is self-consistent at
    // write time and (b) generate golden vectors for the cocotb testbench
    // (manuals/08-nasdaq/05-ouch-5.0-order-entry.md §12.4 demands byte-exact
    // golden-vector and exhaustive incremental-checksum tests).
    //
    // ⚠️ `tcp_len_pseudo` is TCP header + payload = kTcpHdrLen + soup::kHeaderBytes
    //    + ouch_len. `soup_len` is the Soup packet-length FIELD value
    //    (ouch_len + kLengthBias), not the byte count of the Soup header.
    //    `ouch_partial` is the unfolded one's-complement sum of the OUCH message
    //    bytes taken at TCP-PAYLOAD parity (OUCH byte k sits at payload offset
    //    3 + k) — the value ouch_encoder.sv produces on m_csum.
    [[nodiscard]] static std::uint16_t finishTcpChecksum(std::uint16_t partial,
                                                         std::uint32_t seq,
                                                         std::uint32_t ack,
                                                         std::uint16_t tcp_len_pseudo,
                                                         std::uint16_t soup_len,
                                                         std::uint32_t ouch_partial) noexcept;

    // ⚠️ 0x0000 is a LEGAL TCP checksum — never substitute 0xFFFF the way UDP
    //    requires. finishTcpChecksum does not.
    [[nodiscard]] static std::uint16_t finishIpChecksum(std::uint16_t partial,
                                                         std::uint16_t total_length,
                                                         std::uint16_t ip_id) noexcept;

    // ── Reference encoder, for verification ONLY ─────────────────────────────
    // ⚠️ THIS DOES NOT SEND ANYTHING AND MUST NEVER BE WIRED TO A SOCKET.
    //    host/README.md §3.2: there is no software path that emits an order.
    //    This builds the frame in memory so it can be compared, byte for byte
    //    including both checksums, against what the fabric produced — which is
    //    how we find out that an offset is wrong BEFORE the venue does.
    //    It recomputes both checksums from scratch over the whole frame, so
    //    comparing it against finishTcpChecksum() is a genuine independent
    //    check of the incremental arithmetic, not a restatement of it.
    [[nodiscard]] std::size_t buildReferenceFrame(std::span<std::uint8_t> out,
                                                  std::span<const std::uint8_t> ouch_msg,
                                                  std::uint32_t seq,
                                                  std::uint32_t ack,
                                                  std::uint16_t ip_id) const noexcept;

 private:
    std::array<std::uint8_t, kFrameHdrWords * 4> bytes_{};   // 60, last 3 are pad
    std::array<std::uint32_t, kTemplateWords>    words_{};
    FrameTemplateParams                          params_{};
    std::uint16_t                                tcp_partial_ = 0;
    std::uint16_t                                ip_partial_  = 0;
};

}  // namespace trading::sessiond
