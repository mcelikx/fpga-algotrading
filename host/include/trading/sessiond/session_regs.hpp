// =============================================================================
// session_regs.hpp — the SESSION register block (BAR0 + 0x3000)
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/sessiond — sessiond is the ONLY writer of this block.
//
// TODO(rtl-contract): derived from fpga_top.sv cfg_tmpl_* / cfg_session_* ports
//   (u_order_gw, lines 414-418) and from the master SHARED_CONTRACT register
//   map; reconcile with rtl/ctrl/csr_regfile.sv when that file lands.
//
// Register offsets come from trading::regmap:: and are never hardcoded here.
// =============================================================================
#pragma once

#include <cstdint>
#include "trading/expected.hpp"

#include "trading/device.hpp"
#include "trading/regmap.hpp"
#include "trading/sessiond/frame_template.hpp"
#include "trading/sessiond/session_state.hpp"

namespace trading::sessiond {

// =============================================================================
// Template address space (SESS_TMPL_ADDR -> cfg_tmpl_addr[15:0])
// -----------------------------------------------------------------------------
// The same 16-bit address port feeds three different template stores. The
// region field selects which.
//
//   addr[15:14]  region
//     2'b00      OUCH Enter Order, per active symbol   (ouch_encoder.sv)
//                  addr[12:5] = active symbol index, addr[4:0] = word 0..19
//     2'b10      OUCH Cancel Order, per shape          (ouch_encoder.sv)
//                  addr[5:4]  = shape, addr[3:0] = word 0..11
//     2'b01      FRAME header (Eth/IPv4/TCP/Soup)      ← OURS
//                  addr[4:0]  = word 0..19
//     2'b11      reserved
//
// ⚠️ TODO(rtl-contract): rtl/order/ouch_encoder.sv currently decodes ONLY
//    cfg_tmpl_addr[15] (TA_SEL_BIT), so it claims the entire address space:
//    every write with bit15=0 lands in its Enter array and every write with
//    bit15=1 lands in its Cancel array. A frame-header write at 0x4000 would
//    therefore corrupt an Enter template. The required change is one line —
//        tmpl_wr_enter  = cfg_tmpl_wr && (cfg_tmpl_addr[15:14] == 2'b00);
//        tmpl_wr_cancel = cfg_tmpl_wr && (cfg_tmpl_addr[15:14] == 2'b10);
//    — and it is backward compatible with every address in use today (bit14 is
//    zero in all of them). Until that lands, writeFrameTemplate() MUST NOT be
//    pointed at real hardware. This is flagged, not assumed away.
// =============================================================================
enum class TemplateRegion : std::uint16_t {
    OuchEnter  = 0x0000,
    FrameHdr   = 0x4000,
    OuchCancel = 0x8000,
};

[[nodiscard]] constexpr std::uint16_t frameTemplateAddr(std::uint16_t word) noexcept {
    return static_cast<std::uint16_t>(static_cast<std::uint16_t>(TemplateRegion::FrameHdr) |
                                      (word & 0x1FU));
}

// =============================================================================
// Session field selector (SESS_CTRL -> the cfg_session_wr selector)
// -----------------------------------------------------------------------------
// Write protocol: write SESS_CTRL with the selector, then write SESS_DATA with
// the value — the SESS_DATA write is what pulses cfg_session_wr. This mirrors
// the PARAM_*_ADDR / PARAM_*_DATA convention in the shared register map.
// TODO(rtl-contract): the selector values below are the host's proposal; there
//   is no RTL decode for cfg_session_data yet (order_gateway.sv is unwritten).
// =============================================================================
enum class SessionField : std::uint32_t {
    // Session epoch. ⚠️ manuals/02-networking/02-ip-udp-tcp-in-hardware.md §6
    // hazard 5: a re-login means new sequence space and possibly a new source
    // port. The TX path must refuse to fire unless the template's epoch matches
    // this register, so a stale template physically cannot emit.
    Epoch = 0,

    // ⚠️ Hazard 1. 0 = the fabric may not emit and the HOST owns the TCP send
    // side. 1 = the fabric owns the send side exclusively, including the
    // SoupBinTCP client heartbeat. There is never a moment with two owners.
    TxArm = 1,

    // TCP acknowledgement seed: the fabric's rcv_nxt shadow / ack high-water.
    // ⚠️ Hazard 2: the fabric must never emit an ACK below its high-water mark;
    // three duplicate ACKs trigger fast retransmit at the venue.
    TcpRcvNxt = 2,

    // The venue's advertised receive window at hand-off (already unscaled).
    // ⚠️ Hazard 3: if snd_nxt - snd_una >= snd_wnd the fabric must not send.
    TcpSndWnd = 3,

    // The fabric's expected NEXT inbound SoupBinTCP sequenced-data number, so
    // its own gap detector agrees with the host's. Seeded on every login.
    SoupRxSeqLo = 4,
    SoupRxSeqHi = 5,

    // Base value for the IPv4 identification field the fabric increments.
    IpIdBase = 6,

    // The host's view of the session lifecycle, using the SESS_STATE encoding.
    // Published so the fabric's SESS_STATE and the host state machine can be
    // compared, and a divergence counted rather than discovered later.
    HostState = 7,

    // Marks the frame template complete. Written LAST, after read-back and CRC
    // verification, so a half-written template can never emit.
    FrameTemplateCommit = 8,
};

// Magic for FrameTemplateCommit, matching the PARAM_*_COMMIT convention in the
// shared register map. A commit must never be an accidental write.
inline constexpr std::uint32_t kTemplateCommitMagic = 0x00C0FFEEU;

// SESS_LINK_UP decode.
struct LinkStatus {
    bool order_entry = false;   // bit0 — oe_link_up
    bool market_data_a = false; // bit1 — md_link_up[0]
    bool market_data_b = false; // bit2 — md_link_up[1]
};

// =============================================================================
// SessionRegisters — every SESSION-block access in one place
// =============================================================================
class SessionRegisters {
 public:
    explicit SessionRegisters(Device& dev) noexcept : dev_(dev) {}

    // ── Frame template ───────────────────────────────────────────────────────
    // Writes every word, READS EACH ONE BACK AND VERIFIES IT, then cross-checks
    // SESS_TMPL_CRC against the host-computed CRC32, and only then commits the
    // valid bit. Any failure leaves the template UNCOMMITTED, which is the
    // fail-closed outcome: the fabric cannot emit from an invalid template.
    //
    // host/README.md §3.1: "Skipping the read-back step defeats the purpose".
    [[nodiscard]] trading::expected<void, SessionError> writeFrameTemplate(const FrameTemplate& t);

    // Read-back-and-compare on its own, without rewriting. Used by the periodic
    // integrity check — a template that changed under us is a hardware fault or
    // a second writer, and both are stop-trading events.
    [[nodiscard]] trading::expected<void, SessionError> verifyFrameTemplate(const FrameTemplate& t);

    [[nodiscard]] trading::expected<std::uint32_t, SessionError> readTemplateCrc();

    // ── Session scalars ──────────────────────────────────────────────────────
    [[nodiscard]] trading::expected<void, SessionError> writeField(SessionField f,
                                                               std::uint32_t value);

    // ── Sequence state ───────────────────────────────────────────────────────
    // SESS_SEQ_TX_LO/HI. ⚠️ NAMING NOTE: the shared register map calls this the
    // "SoupBinTCP outbound sequence", but SoupBinTCP client->server traffic is
    // UNSEQUENCED — there is no Soup sequence number on what we send (see
    // manuals/08-nasdaq/05-ouch-5.0-order-entry.md §2 and ouch_pkg.sv §2). The
    // only outbound sequence that exists is TCP's. sessiond therefore defines:
    //     LO = the TCP send sequence number handed to the fabric (wire value,
    //          wraps modulo 2^32 exactly as RFC 9293 says it does)
    //     HI = the wrap epoch, so the host keeps a monotonic 64-bit byte offset
    //          across those wraps and never has to reason about wrapping in its
    //          own bookkeeping.
    // TODO(rtl-contract): confirm this split with rtl/ctrl/csr_regfile.sv.
    [[nodiscard]] trading::expected<void, SessionError> publishTxSequence(std::uint64_t seq64);
    [[nodiscard]] trading::expected<std::uint64_t, SessionError> readTxSequence();

    // SESS_SEQ_RX_LO/HI — the FABRIC's count of the inbound SoupBinTCP
    // sequenced-data stream. Compared against the host's own count; a
    // disagreement means the fabric's fill and credit view is not ours.
    // Read HI/LO/HI to detect a torn 64-bit read.
    [[nodiscard]] trading::expected<std::uint64_t, SessionError> readRxSequence();

    // ── Status ───────────────────────────────────────────────────────────────
    [[nodiscard]] trading::expected<SessionState, SessionError> readState();
    [[nodiscard]] trading::expected<LinkStatus, SessionError>   readLinkStatus();

 private:
    // Typed register access: the register is a template parameter, so
    // regmap.hpp's Access classification is checked at COMPILE TIME. Writing
    // SESS_TMPL_RB or reading a write-only register is a build error here, not a
    // puzzle in front of a card that ignored the write.
    template <regmap::Reg R>
    [[nodiscard]] trading::expected<std::uint32_t, SessionError> rdReg() {
        auto r = dev_.read<R>();
        if (!r.has_value()) {
            // The concrete DeviceError is deliberately not fanned out here:
            // sessiond's caller needs to know a register access failed, and
            // ctrld owns the device-level diagnosis.
            return trading::fail(SessionError::DeviceIo);
        }
        return *r;
    }

    template <regmap::Reg R>
    [[nodiscard]] trading::expected<void, SessionError> wrReg(std::uint32_t v) {
        auto r = dev_.write<R>(v);
        if (!r.has_value()) {
            return trading::fail(SessionError::DeviceIo);
        }
        return {};
    }

    [[nodiscard]] trading::expected<std::uint32_t, SessionError> readTemplateWord(
            std::uint16_t addr);

    Device& dev_;
};

}  // namespace trading::sessiond
