// =============================================================================
// session_regs.cpp — SESSION block (BAR0 + 0x3000) accessors
// -----------------------------------------------------------------------------
// sessiond is the only writer of this block. Every parameter commit is followed
// by a read-back and a verify (host/README.md §3.1) — there is no path through
// this file that writes the template and trusts it.
// =============================================================================
#include "trading/sessiond/session_regs.hpp"

namespace trading::sessiond {

trading::expected<std::uint32_t, SessionError> SessionRegisters::readTemplateWord(
        std::uint16_t addr) {
    // Point the indirect window, then read the read-back register.
    auto w = wrReg<regmap::SESS_TMPL_ADDR>(addr);
    if (!w.has_value()) {
        return trading::fail(w.error());
    }
    return rdReg<regmap::SESS_TMPL_RB>();
}

// -----------------------------------------------------------------------------
// Frame template
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionRegisters::writeFrameTemplate(const FrameTemplate& t) {
    if (!t.valid()) {
        // An empty template is all zeros: a frame with no destination, no ports
        // and no window. Refuse it here as well as in FrameTemplate::build(),
        // because this is the last place before it reaches hardware.
        return trading::fail(SessionError::InvalidConfig);
    }
    const auto words = t.words();

    for (std::size_t i = 0; i < words.size(); ++i) {
        const std::uint16_t addr = frameTemplateAddr(static_cast<std::uint16_t>(i));

        // ⚠️ The valid bit is held back to the very end. If anything below
        //    fails, the fabric is left holding a template it will not emit from,
        //    which is the fail-closed outcome we want.
        const std::uint32_t value = (i == kMetaFlags) ? 0U : words[i];

        auto a = wrReg<regmap::SESS_TMPL_ADDR>(addr);
        if (!a.has_value()) {
            return trading::fail(a.error());
        }
        auto d = wrReg<regmap::SESS_TMPL_DATA>(value);   // the DATA write pulses cfg_tmpl_wr
        if (!d.has_value()) {
            return trading::fail(d.error());
        }
    }

    // ── Read back and verify, word by word ───────────────────────────────────
    for (std::size_t i = 0; i < words.size(); ++i) {
        const std::uint32_t expect = (i == kMetaFlags) ? 0U : words[i];
        auto got = readTemplateWord(frameTemplateAddr(static_cast<std::uint16_t>(i)));
        if (!got.has_value()) {
            return trading::fail(got.error());
        }
        if (*got != expect) {
            // ⚠️ Do not retry silently. A word that did not stick is a PCIe or
            //    fabric fault, and the next thing that happens must be a human
            //    looking at it, not another write.
            return trading::fail(SessionError::TemplateVerifyMismatch);
        }
    }

    // ── Commit the valid bit, then re-verify it ──────────────────────────────
    {
        auto a = wrReg<regmap::SESS_TMPL_ADDR>(frameTemplateAddr(kMetaFlags));
        if (!a.has_value()) {
            return trading::fail(a.error());
        }
        auto d = wrReg<regmap::SESS_TMPL_DATA>(words[kMetaFlags]);
        if (!d.has_value()) {
            return trading::fail(d.error());
        }
        auto got = readTemplateWord(frameTemplateAddr(kMetaFlags));
        if (!got.has_value()) {
            return trading::fail(got.error());
        }
        if (*got != words[kMetaFlags]) {
            return trading::fail(SessionError::TemplateVerifyMismatch);
        }
    }

    // ── Cross-check the fabric's CRC against ours ────────────────────────────
    // The word-by-word read-back proves the words we can read are right. The CRC
    // is computed by the fabric over what it will actually emit from, which is
    // not necessarily the same storage — that is exactly why both checks exist.
    auto crc = readTemplateCrc();
    if (!crc.has_value()) {
        return trading::fail(crc.error());
    }
    if (*crc != t.crc32()) {
        return trading::fail(SessionError::TemplateCrcMismatch);
    }

    // Tell the fabric the frame template is complete and armed for use.
    return writeField(SessionField::FrameTemplateCommit, kTemplateCommitMagic);
}

trading::expected<void, SessionError> SessionRegisters::verifyFrameTemplate(const FrameTemplate& t) {
    const auto words = t.words();
    for (std::size_t i = 0; i < words.size(); ++i) {
        auto got = readTemplateWord(frameTemplateAddr(static_cast<std::uint16_t>(i)));
        if (!got.has_value()) {
            return trading::fail(got.error());
        }
        if (*got != words[i]) {
            return trading::fail(SessionError::TemplateVerifyMismatch);
        }
    }
    auto crc = readTemplateCrc();
    if (!crc.has_value()) {
        return trading::fail(crc.error());
    }
    if (*crc != t.crc32()) {
        return trading::fail(SessionError::TemplateCrcMismatch);
    }
    return {};
}

trading::expected<std::uint32_t, SessionError> SessionRegisters::readTemplateCrc() {
    return rdReg<regmap::SESS_TMPL_CRC>();
}

// -----------------------------------------------------------------------------
// Session scalars
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionRegisters::writeField(SessionField f,
                                                               std::uint32_t value) {
    // Selector first, then data — the SESS_DATA write is what pulses
    // cfg_session_wr, so the selector must already be settled.
    auto s = wrReg<regmap::SESS_CTRL>(static_cast<std::uint32_t>(f));
    if (!s.has_value()) {
        return trading::fail(s.error());
    }
    return wrReg<regmap::SESS_DATA>(value);
}

// -----------------------------------------------------------------------------
// Sequence state
// -----------------------------------------------------------------------------
trading::expected<void, SessionError> SessionRegisters::publishTxSequence(std::uint64_t seq64) {
    // ⚠️ Write HI first, then LO. The fabric latches on the LO write, so the
    //    pair can never be observed half-updated in the direction that matters.
    auto hi = wrReg<regmap::SESS_SEQ_TX_HI>(static_cast<std::uint32_t>(seq64 >> 32));
    if (!hi.has_value()) {
        return trading::fail(hi.error());
    }
    auto lo = wrReg<regmap::SESS_SEQ_TX_LO>(static_cast<std::uint32_t>(seq64));
    if (!lo.has_value()) {
        return trading::fail(lo.error());
    }
    // Read back: the TCP sequence number handed to the fabric is the one field
    // where a dropped write produces silently discarded segments rather than an
    // error. Verify it like any other committed parameter.
    auto rb = readTxSequence();
    if (!rb.has_value()) {
        return trading::fail(rb.error());
    }
    if (*rb != seq64) {
        return trading::fail(SessionError::TemplateVerifyMismatch);
    }
    return {};
}

trading::expected<std::uint64_t, SessionError> SessionRegisters::readTxSequence() {
    auto hi = rdReg<regmap::SESS_SEQ_TX_HI>();
    if (!hi.has_value()) {
        return trading::fail(hi.error());
    }
    auto lo = rdReg<regmap::SESS_SEQ_TX_LO>();
    if (!lo.has_value()) {
        return trading::fail(lo.error());
    }
    return (static_cast<std::uint64_t>(*hi) << 32) | *lo;
}

trading::expected<std::uint64_t, SessionError> SessionRegisters::readRxSequence() {
    // HI / LO / HI: two 32-bit reads of a counter the fabric is still
    // incrementing can tear across the 2^32 boundary. Retry once on a tear;
    // a second tear in the same microsecond is not physically plausible at any
    // sequenced-data rate a venue produces.
    for (int attempt = 0; attempt < 2; ++attempt) {
        auto hi1 = rdReg<regmap::SESS_SEQ_RX_HI>();
        if (!hi1.has_value()) {
            return trading::fail(hi1.error());
        }
        auto lo = rdReg<regmap::SESS_SEQ_RX_LO>();
        if (!lo.has_value()) {
            return trading::fail(lo.error());
        }
        auto hi2 = rdReg<regmap::SESS_SEQ_RX_HI>();
        if (!hi2.has_value()) {
            return trading::fail(hi2.error());
        }
        if (*hi1 == *hi2) {
            return (static_cast<std::uint64_t>(*hi1) << 32) | *lo;
        }
    }
    return trading::fail(SessionError::DeviceIo);
}

// -----------------------------------------------------------------------------
// Status
// -----------------------------------------------------------------------------
trading::expected<SessionState, SessionError> SessionRegisters::readState() {
    auto v = rdReg<regmap::SESS_STATE>();
    if (!v.has_value()) {
        return trading::fail(v.error());
    }
    switch (*v) {
        case 0: return SessionState::Down;
        case 1: return SessionState::Connecting;
        case 2: return SessionState::LoginSent;
        case 3: return SessionState::Up;
        case 4: return SessionState::Fault;
        default:
            // An encoding the contract does not define. Treat as a fabric
            // disagreement rather than mapping it onto something plausible.
            return trading::fail(SessionError::FabricStateMismatch);
    }
}

trading::expected<LinkStatus, SessionError> SessionRegisters::readLinkStatus() {
    auto v = rdReg<regmap::SESS_LINK_UP>();
    if (!v.has_value()) {
        return trading::fail(v.error());
    }
    LinkStatus s{};
    s.order_entry   = (*v & 0x1U) != 0;
    s.market_data_a = (*v & 0x2U) != 0;
    s.market_data_b = (*v & 0x4U) != 0;
    return s;
}

}  // namespace trading::sessiond
