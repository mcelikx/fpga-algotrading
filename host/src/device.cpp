// =============================================================================
// device.cpp — PCIe BAR0 access, mock backend, and the DMA log ring reader
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : device layer (agent 1)
// Header  : host/include/trading/device.hpp
//
// PLATFORM
//   The MMIO backend targets Linux (sysfs PCI resource files, or a vfio region
//   fd). The mmap/munmap calls themselves are POSIX, so this file compiles on
//   macOS for development; opening a real BAR there will simply fail at runtime
//   with OpenFailed, which is the correct answer. Linux-only flags are guarded.
//
// NO EXCEPTIONS
//   Nothing here throws. The only allocations are at open/configure time
//   (the mock's backing store, the ring stitch buffer); the poll path allocates
//   nothing.
// =============================================================================
#include "trading/device.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace trading {

// =============================================================================
// 1. Error strings
// =============================================================================
std::string_view toString(DeviceError e) noexcept {
    switch (e) {
        case DeviceError::None:              return "None";
        case DeviceError::NotOpen:           return "NotOpen";
        case DeviceError::OpenFailed:        return "OpenFailed";
        case DeviceError::MapFailed:         return "MapFailed";
        case DeviceError::BarTooSmall:       return "BarTooSmall";
        case DeviceError::PermissionDenied:  return "PermissionDenied";
        case DeviceError::OffsetOutOfRange:  return "OffsetOutOfRange";
        case DeviceError::Misaligned:        return "Misaligned";
        case DeviceError::AccessViolation:   return "AccessViolation";
        case DeviceError::VerifyMismatch:    return "VerifyMismatch";
        case DeviceError::IdentityMismatch:  return "IdentityMismatch";
        case DeviceError::Timeout:           return "Timeout";
        case DeviceError::InvalidArgument:   return "InvalidArgument";
        case DeviceError::Unsupported:       return "Unsupported";
        case DeviceError::IoError:           return "IoError";
        case DeviceError::RingNotConfigured: return "RingNotConfigured";
        case DeviceError::RingBadSize:       return "RingBadSize";
        case DeviceError::RingBadIndex:      return "RingBadIndex";
        case DeviceError::RingOverrun:       return "RingOverrun";
        case DeviceError::RingCorruptRecord: return "RingCorruptRecord";
        case DeviceError::RingBufferTooSmall:return "RingBufferTooSmall";
    }
    return "DeviceError(?)";
}

namespace {

// =============================================================================
// 2. MMIO primitives
// -----------------------------------------------------------------------------
// WHY `volatile`, AND WHY PLAIN LOADS AND STORES WOULD BE WRONG
//
//   A BAR mapping is not memory. Every access is a transaction on the PCIe bus
//   with a side effect at the far end. `volatile` is what tells the compiler
//   that, and it forbids four specific optimisations that are all legal on
//   ordinary memory and all catastrophic here:
//
//   1. ELISION. `while (read(CTRL_ARMED) == 0) {}` on a non-volatile pointer is
//      a load the compiler may hoist out of the loop, because nothing in the
//      loop body writes to it. The result is an infinite loop against a device
//      that armed correctly. Likewise a write whose value is "already there" may
//      be deleted — but the write is a doorbell, and deleting it is deleting the
//      command.
//
//   2. TEARING AND MERGING. The compiler is free to implement a 32-bit store as
//      two 16-bit stores, or to widen a run of adjacent 32-bit stores into one
//      vector store. Neither is legal on a BAR: the fabric decodes one 32-bit
//      transaction per register, and a 16-bit partial write to a command
//      register is an undefined command. `volatile` forces exactly one access of
//      exactly the declared width.
//
//   3. REORDERING BY THE COMPILER. Writing PARAM_RISK_ADDR then PARAM_RISK_DATA
//      is a protocol: the address must land first. To the compiler these are two
//      unrelated stores to unrelated addresses and it may swap them.
//      `volatile` accesses are not reordered with respect to each other.
//
//   4. SPECULATION AND DUPLICATION. A speculative read of TELEM_SNAPSHOT would
//      latch the telemetry shadow bank as a side effect of a branch that was
//      never taken (regmap marks it RO_SE precisely because of this).
//
//   `volatile` alone is NOT sufficient, because it constrains the COMPILER and
//   says nothing to the CPU. Two more things are needed:
//
//   * Ordering against the CPU's own store buffer and load/store reordering.
//     On x86 with an uncacheable BAR mapping this is nearly free — UC accesses
//     are strongly ordered — but on aarch64 device memory still needs explicit
//     barriers, and ordering an MMIO write against a preceding write to a DMA
//     buffer in normal cacheable memory needs a barrier on every architecture.
//     std::atomic_thread_fence gives us that portably.
//
//   * A release fence BEFORE a write, so everything the program did earlier
//     (notably: filling a DMA ring descriptor, or writing PARAM_*_ADDR) is
//     visible before the doorbell lands. An acquire fence AFTER a read, so
//     nothing later is hoisted above the value we just sampled.
//
//   This is the slow path. A fence costs tens of nanoseconds; the PCIe round
//   trip it is ordering costs ~1 microsecond (host/README.md §1). There is no
//   argument for shaving it.
// =============================================================================

[[nodiscard]] inline std::uint32_t mmioRead32(const volatile std::uint32_t* addr) noexcept {
    const std::uint32_t v = *addr;
    std::atomic_thread_fence(std::memory_order_acquire);
    return v;
}

inline void mmioWrite32(volatile std::uint32_t* addr, std::uint32_t value) noexcept {
    std::atomic_thread_fence(std::memory_order_release);
    *addr = value;
    // A second fence after the store keeps a following MMIO READ from being
    // issued before this write has been posted, which is what makes the
    // write-then-read-back in writeVerify() actually test anything.
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

// =============================================================================
// 3. MMIO backend
// =============================================================================
class MmioBar final : public IBar {
public:
    MmioBar(int fd, void* map, std::uint32_t len) noexcept : fd_(fd), map_(map), len_(len) {}

    ~MmioBar() override {
        if (map_ != nullptr && map_ != MAP_FAILED) {
            ::munmap(map_, len_);
        }
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }

    MmioBar(const MmioBar&) = delete;
    MmioBar& operator=(const MmioBar&) = delete;

    [[nodiscard]] std::uint32_t size() const noexcept override { return len_; }
    [[nodiscard]] bool isMock() const noexcept override { return false; }

    [[nodiscard]] std::uint32_t read(std::uint32_t offset) noexcept override {
        return mmioRead32(wordAt(offset));
    }

    void write(std::uint32_t offset, std::uint32_t value) noexcept override {
        mmioWrite32(wordAt(offset), value);
    }

private:
    [[nodiscard]] volatile std::uint32_t* wordAt(std::uint32_t offset) const noexcept {
        return reinterpret_cast<volatile std::uint32_t*>(static_cast<std::byte*>(map_) + offset);
    }

    int fd_ = -1;
    void* map_ = nullptr;
    std::uint32_t len_ = 0;
};

[[nodiscard]] DeviceError errnoToDeviceError(int e) noexcept {
    switch (e) {
        case EACCES:
        case EPERM:
            return DeviceError::PermissionDenied;
        case ENOENT:
        case ENODEV:
            return DeviceError::OpenFailed;
        default:
            return DeviceError::IoError;
    }
}

}  // namespace

// =============================================================================
// 4. Mock backend
// =============================================================================
struct MockBar::Impl {
    explicit Impl(MockBar::Options o) : opt(o) {
        regs.assign(regmap::BAR0_SIZE / regmap::REG_STRIDE, 0u);
        telem.assign(regmap::telem_word::LAST + 1, 0u);
        filterShadow.assign(N_SYMBOLS, 0u);
        riskShadow.assign(kBankWords * 2, 0u);
        stratShadow.assign(kBankWords * 2, 0u);
        tmplShadow.assign(RTL_TMPL_WORDS_MAX, 0u);
        sessionShadow.assign(RTL_SESSION_WORDS_MAX, 0u);

        armed = o.startArmed;
        if (o.startKilled) {
            killActive = true;
            killSrc = KillSrc::Host;
        }
        // A card that has just come out of reset reports a plausible telemetry
        // identity, so a version check in metricsd has something to check.
        telem[regmap::telem_word::VERSION] = regmap::TELEM_VERSION_VALUE;
        armWindowMs = regmap::CTRL_ARM_WINDOW_MS_DEFAULT;
    }

    static constexpr std::uint32_t kBankWords = N_ACTIVE * PARAM_WORDS_PER_SYM;  // 256*16

    MockBar::Options opt;

    std::vector<std::uint32_t> regs;   // plain storage for RW registers
    std::vector<std::uint32_t> telem;  // telemetry shadow bank, word-indexed

    std::vector<std::uint32_t> filterShadow;
    std::vector<std::uint32_t> riskShadow;   // [bank][sym][word], bank-major
    std::vector<std::uint32_t> stratShadow;
    std::vector<std::uint32_t> tmplShadow;
    std::vector<std::uint32_t> sessionShadow;

    std::uint32_t riskGen = 0;
    std::uint32_t stratGen = 0;
    std::uint32_t riskActiveBank = 0;
    std::uint32_t stratActiveBank = 0;
    std::uint32_t riskCrc = 0;
    std::uint32_t stratCrc = 0;
    std::uint32_t tmplCrc = 0;

    bool tradingEnReq = false;
    bool armed = false;
    bool killActive = false;
    KillSrc killSrc = KillSrc::None;

    std::uint32_t armKey = 0;
    bool armKeyValid = false;
    std::uint32_t armWindowMs = 0;

    std::uint32_t lastHeartbeat = 0;
    std::uint64_t heartbeatCount = 0;
    std::uint32_t hbAgeMs = 0;

    std::uint64_t uptimeCycles = 0;
    std::uint32_t health = health::ALL_OK;
    std::uint32_t linkMask = 0;
    std::uint32_t sessionState = static_cast<std::uint32_t>(SessionState::Down);

    // --- log ring ---
    std::span<std::byte> ringMem{};
    std::uint32_t ringProd = 0;
    std::uint32_t ringCons = 0;
    std::uint32_t ringDrops = 0;
    std::uint64_t seqCounter = 1;

    [[nodiscard]] std::uint32_t ringSizeBytes() const noexcept {
        return regs[regmap::LOG_RING_SIZE.offset / 4];
    }

    // Decode a PARAM_*_ADDR value the way types.hpp::paramAddr encodes it.
    static bool decodeParamAddr(std::uint32_t addr, std::uint32_t& bank, std::uint32_t& sym,
                                std::uint32_t& word) noexcept {
        bank = (addr >> PARAM_ADDR_BANK_SHIFT) & 1u;
        sym = (addr >> PARAM_ADDR_SYM_SHIFT) & (N_ACTIVE - 1);
        word = addr & (PARAM_WORDS_PER_SYM - 1);
        return true;
    }

    static std::uint32_t bankIndex(std::uint32_t bank, std::uint32_t sym,
                                   std::uint32_t word) noexcept {
        return bank * kBankWords + sym * PARAM_WORDS_PER_SYM + word;
    }

    // The fabric publishes a CRC32 of the LIVE bank so the host can prove the
    // committed record set is the one it computed. Modelled faithfully enough
    // that a host-side mismatch check is exercised.
    [[nodiscard]] std::uint32_t bankCrc(const std::vector<std::uint32_t>& shadow,
                                        std::uint32_t bank) const noexcept {
        const auto* base = shadow.data() + bank * kBankWords;
        return crc32({reinterpret_cast<const std::byte*>(base),
                      static_cast<std::size_t>(kBankWords) * sizeof(std::uint32_t)});
    }
};

MockBar::MockBar(Options opt) : impl_(std::make_unique<Impl>(opt)) {}
MockBar::~MockBar() = default;

std::uint32_t MockBar::read(std::uint32_t offset) noexcept {
    Impl& m = *impl_;
    const std::uint32_t idx = offset / regmap::REG_STRIDE;

    // --- telemetry window: word-addressed, read side effects modelled --------
    if (regmap::isTelemetryOffset(offset)) {
        const std::uint32_t word = (offset - regmap::TELEM_BASE) / 4;
        if (word == regmap::telem_word::SNAP) {
            // Reading SNAP latches the bank and returns the new sequence.
            ++m.telem[regmap::telem_word::SNAP_SEQ];
            return m.telem[regmap::telem_word::SNAP_SEQ];
        }
        if (word == regmap::telem_word::HIST_CLEAR) {
            for (std::uint32_t i = 0; i < regmap::TELEM_N_HIST; ++i) {
                m.telem[regmap::telem_word::HIST + i] = 0;
            }
            return 0;
        }
        if (word == regmap::telem_word::STATUS) {
            std::uint32_t s = (m.linkMask & 0x7u) << regmap::telem_status::LINK_LSB;
            if (m.killActive) s |= 1u << regmap::telem_status::KILL_ACTIVE;
            s |= (static_cast<std::uint32_t>(m.killSrc) & 0x7u)
                 << regmap::telem_status::KILL_SRC_LSB;
            return s;
        }
        if (word == regmap::telem_word::UPTIME_LO) {
            return static_cast<std::uint32_t>(m.uptimeCycles & 0xFFFF'FFFFu);
        }
        if (word == regmap::telem_word::UPTIME_HI) {
            return static_cast<std::uint32_t>((m.uptimeCycles >> 32) & 0xFFFFu);
        }
        if (word >= m.telem.size()) return regmap::TELEM_UNMAPPED;
        return m.telem[word];
    }

    switch (offset) {
        // --- IDENT ----------------------------------------------------------
        case regmap::IDENT_MAGIC.offset:      return regmap::IDENT_MAGIC_VALUE;
        case regmap::IDENT_BUILD_ID.offset:   return m.opt.buildId;
        case regmap::IDENT_GIT_SHA.offset:    return m.opt.gitSha;
        case regmap::IDENT_REGMAP_VER.offset: return regmap::REGMAP_VER_VALUE;
        case regmap::IDENT_CAPS.offset:       return regmap::IDENT_CAPS_EXPECTED;
        case regmap::IDENT_UPTIME_LO.offset:
            return static_cast<std::uint32_t>(m.uptimeCycles & 0xFFFF'FFFFu);
        case regmap::IDENT_UPTIME_HI.offset:
            return static_cast<std::uint32_t>((m.uptimeCycles >> 32) & 0xFFFFu);
        case regmap::IDENT_KILL_RESP_CYC.offset: return regmap::KILL_RESP_CYCLES_EXPECTED;

        // --- CONTROL --------------------------------------------------------
        // Trading is enabled only when the host asked for it AND the fabric is
        // armed AND the kill switch is clear. That is fail-closed, and it means
        // a writeVerify of CTRL_TRADING_EN before arming correctly FAILS —
        // which is the ordering host/README.md §3.1 mandates (arm is step 7,
        // enable trading is step 8).
        case regmap::CTRL_TRADING_EN.offset:
            return (m.tradingEnReq && m.armed && !m.killActive) ? 1u : 0u;
        case regmap::CTRL_KILL.offset:        return m.killActive ? 1u : 0u;
        case regmap::CTRL_KILL_SRC.offset:    return static_cast<std::uint32_t>(m.killSrc);
        case regmap::CTRL_KILL_ACTIVE.offset: return m.killActive ? 1u : 0u;
        case regmap::CTRL_ARMED.offset:       return m.armed ? 1u : 0u;
        case regmap::CTRL_HB_AGE_MS.offset:   return m.hbAgeMs;
        case regmap::CTRL_HEALTH.offset: {
            std::uint32_t h = m.health;
            if (m.killActive) h |= health::KILL_ACTIVE;
            if (!m.armed) h |= health::NOT_ARMED;
            if ((h & ~health::ALL_OK) != 0) h &= ~health::ALL_OK;
            return h;
        }
        case regmap::CTRL_ARM_WINDOW_MS.offset: return m.armWindowMs;

        // --- PARAM read-back ------------------------------------------------
        case regmap::PARAM_FILTER_RB.offset: {
            const std::uint32_t a = m.regs[regmap::PARAM_FILTER_ADDR.offset / 4] & (N_SYMBOLS - 1);
            return m.filterShadow[a];
        }
        case regmap::PARAM_RISK_RB.offset: {
            std::uint32_t b = 0, s = 0, w = 0;
            Impl::decodeParamAddr(m.regs[regmap::PARAM_RISK_ADDR.offset / 4], b, s, w);
            return m.riskShadow[Impl::bankIndex(b, s, w)];
        }
        case regmap::PARAM_STRAT_RB.offset: {
            std::uint32_t b = 0, s = 0, w = 0;
            Impl::decodeParamAddr(m.regs[regmap::PARAM_STRAT_ADDR.offset / 4], b, s, w);
            return m.stratShadow[Impl::bankIndex(b, s, w)];
        }
        case regmap::PARAM_RISK_GEN.offset:          return m.riskGen;
        case regmap::PARAM_STRAT_GEN.offset:         return m.stratGen;
        case regmap::PARAM_RISK_ACTIVE_BANK.offset:  return m.riskActiveBank;
        case regmap::PARAM_STRAT_ACTIVE_BANK.offset: return m.stratActiveBank;
        case regmap::PARAM_RISK_CRC.offset:          return m.riskCrc;
        case regmap::PARAM_STRAT_CRC.offset:         return m.stratCrc;

        // --- SESSION --------------------------------------------------------
        case regmap::SESS_TMPL_RB.offset: {
            const std::uint32_t a = m.regs[regmap::SESS_TMPL_ADDR.offset / 4];
            return a < m.tmplShadow.size() ? m.tmplShadow[a] : 0u;
        }
        case regmap::SESS_TMPL_CRC.offset: return m.tmplCrc;
        case regmap::SESS_STATE.offset:    return m.sessionState;
        case regmap::SESS_LINK_UP.offset:  return m.linkMask;

        // --- LOG RING -------------------------------------------------------
        case regmap::LOG_RING_PROD.offset:  return m.ringProd;
        case regmap::LOG_RING_CONS.offset:  return m.ringCons;
        case regmap::LOG_RING_DROPS.offset: return m.ringDrops;

        default:
            break;
    }

    // Write-only registers read back as zero on real hardware; do the same here
    // so a component that wrongly reads one sees an obviously wrong answer.
    const auto acc = regmap::accessOf(offset);
    if (acc.known && acc.access == regmap::Access::WO) return 0u;

    return idx < m.regs.size() ? m.regs[idx] : 0u;
}

void MockBar::write(std::uint32_t offset, std::uint32_t value) noexcept {
    Impl& m = *impl_;
    const std::uint32_t idx = offset / regmap::REG_STRIDE;

    // The telemetry window is read-only in the fabric. Silently ignore, exactly
    // as hardware would; Device::write32 already rejects this at a higher level.
    if (regmap::isTelemetryOffset(offset)) return;

    switch (offset) {
        case regmap::CTRL_TRADING_EN.offset:
            m.tradingEnReq = (value & regmap::CTRL_BIT0) != 0;
            return;

        case regmap::CTRL_KILL.offset:
            // Write-1-to-set, sticky. Writing 0 does NOT clear it: clearing the
            // kill switch is a human-in-the-loop workflow requiring the ARM_KEY
            // nonce, deliberately not modelled as a plain register write.
            if ((value & regmap::CTRL_KILL_SET) != 0 && !m.killActive) {
                m.killActive = true;
                m.killSrc = KillSrc::Host;
            }
            return;

        case regmap::CTRL_HEARTBEAT.offset:
            m.lastHeartbeat = value;
            ++m.heartbeatCount;
            m.hbAgeMs = 0;
            return;

        case regmap::CTRL_ARM_KEY.offset:
            // Step 1 of the two-step arm: the host presents a nonce.
            m.armKey = value;
            m.armKeyValid = (value != 0);
            return;

        case regmap::CTRL_ARM_EXEC.offset:
            // Step 2: the host echoes the nonce. A single stray write cannot
            // arm the card, which is the entire point of the two-step.
            if (m.armKeyValid && value == m.armKey) {
                m.armed = true;
            }
            m.armKeyValid = false;
            return;

        case regmap::CTRL_ARM_WINDOW_MS.offset:
            m.armWindowMs = value;
            m.regs[idx] = value;
            return;

        // --- PARAM windows ---------------------------------------------------
        case regmap::PARAM_FILTER_DATA.offset: {
            const std::uint32_t a = m.regs[regmap::PARAM_FILTER_ADDR.offset / 4] & (N_SYMBOLS - 1);
            m.filterShadow[a] = value;
            m.regs[idx] = value;
            return;
        }
        case regmap::PARAM_RISK_DATA.offset: {
            std::uint32_t b = 0, s = 0, w = 0;
            Impl::decodeParamAddr(m.regs[regmap::PARAM_RISK_ADDR.offset / 4], b, s, w);
            m.riskShadow[Impl::bankIndex(b, s, w)] = value;
            m.regs[idx] = value;
            return;
        }
        case regmap::PARAM_STRAT_DATA.offset: {
            std::uint32_t b = 0, s = 0, w = 0;
            Impl::decodeParamAddr(m.regs[regmap::PARAM_STRAT_ADDR.offset / 4], b, s, w);
            m.stratShadow[Impl::bankIndex(b, s, w)] = value;
            m.regs[idx] = value;
            return;
        }
        case regmap::PARAM_RISK_COMMIT.offset:
            // Only the doorbell value commits. A stray zero or a wild write
            // cannot swap a parameter bank under a live strategy.
            if (value == regmap::PARAM_COMMIT_MAGIC) {
                m.riskActiveBank ^= 1u;
                ++m.riskGen;
                m.riskCrc = m.bankCrc(m.riskShadow, m.riskActiveBank);
            }
            return;
        case regmap::PARAM_STRAT_COMMIT.offset:
            if (value == regmap::PARAM_COMMIT_MAGIC) {
                m.stratActiveBank ^= 1u;
                ++m.stratGen;
                m.stratCrc = m.bankCrc(m.stratShadow, m.stratActiveBank);
            }
            return;

        // --- SESSION ---------------------------------------------------------
        case regmap::SESS_TMPL_DATA.offset: {
            const std::uint32_t a = m.regs[regmap::SESS_TMPL_ADDR.offset / 4];
            if (a < m.tmplShadow.size()) {
                m.tmplShadow[a] = value;
                m.tmplCrc = crc32({reinterpret_cast<const std::byte*>(m.tmplShadow.data()),
                                   m.tmplShadow.size() * sizeof(std::uint32_t)});
            }
            m.regs[idx] = value;
            return;
        }
        case regmap::SESS_DATA.offset: {
            const std::uint32_t sel = m.regs[regmap::SESS_CTRL.offset / 4];
            if (sel < m.sessionShadow.size()) m.sessionShadow[sel] = value;
            m.regs[idx] = value;
            return;
        }

        // --- LOG RING --------------------------------------------------------
        case regmap::LOG_RING_CONS.offset:
            m.ringCons = value;
            m.regs[idx] = value;
            return;

        default:
            break;
    }

    if (idx < m.regs.size()) m.regs[idx] = value;
}

// --- mock test hooks --------------------------------------------------------
void MockBar::pokeRegister(std::uint32_t offset, std::uint32_t value) noexcept {
    const std::uint32_t idx = offset / regmap::REG_STRIDE;
    if (idx < impl_->regs.size()) impl_->regs[idx] = value;
}

std::uint32_t MockBar::peekRegister(std::uint32_t offset) const noexcept {
    const std::uint32_t idx = offset / regmap::REG_STRIDE;
    return idx < impl_->regs.size() ? impl_->regs[idx] : 0u;
}

void MockBar::setTelemetryWord(std::uint32_t wordIndex, std::uint32_t value) noexcept {
    if (wordIndex < impl_->telem.size()) impl_->telem[wordIndex] = value;
}

void MockBar::setHealth(std::uint32_t healthWord) noexcept { impl_->health = healthWord; }
void MockBar::setLinkUp(std::uint32_t linkMask) noexcept { impl_->linkMask = linkMask & 0x7u; }
void MockBar::setSessionState(SessionState s) noexcept {
    impl_->sessionState = static_cast<std::uint32_t>(s);
}
void MockBar::advanceUptime(std::uint64_t cycles) noexcept {
    impl_->uptimeCycles = (impl_->uptimeCycles + cycles) & CYCLE_MAX;
}
void MockBar::forceKill(KillSrc src) noexcept {
    impl_->killActive = true;
    impl_->killSrc = src;
}

bool MockBar::tradingEnabled() const noexcept {
    return impl_->tradingEnReq && impl_->armed && !impl_->killActive;
}
bool MockBar::armed() const noexcept { return impl_->armed; }
bool MockBar::killActive() const noexcept { return impl_->killActive; }
std::uint32_t MockBar::lastHeartbeat() const noexcept { return impl_->lastHeartbeat; }
std::uint64_t MockBar::heartbeatCount() const noexcept { return impl_->heartbeatCount; }
std::uint32_t MockBar::riskGeneration() const noexcept { return impl_->riskGen; }
std::uint32_t MockBar::stratGeneration() const noexcept { return impl_->stratGen; }

std::uint32_t MockBar::riskShadowWord(ParamBank bank, std::uint32_t sym,
                                      std::uint32_t word) const noexcept {
    if (!paramAddrValid(sym, word)) return 0;
    return impl_->riskShadow[Impl::bankIndex(static_cast<std::uint32_t>(bank), sym, word)];
}

std::uint32_t MockBar::stratShadowWord(ParamBank bank, std::uint32_t sym,
                                       std::uint32_t word) const noexcept {
    if (!paramAddrValid(sym, word)) return 0;
    return impl_->stratShadow[Impl::bankIndex(static_cast<std::uint32_t>(bank), sym, word)];
}

std::uint32_t MockBar::filterShadowWord(std::uint32_t locate) const noexcept {
    return locate < N_SYMBOLS ? impl_->filterShadow[locate] : 0u;
}

void MockBar::attachRingMemory(std::span<std::byte> ring) noexcept { impl_->ringMem = ring; }

bool MockBar::pushRecord(std::span<const std::byte> record) noexcept {
    Impl& m = *impl_;
    const std::uint32_t size = static_cast<std::uint32_t>(m.ringMem.size());
    if (size == 0 || (size & (size - 1)) != 0) return false;
    const std::uint32_t bytes = static_cast<std::uint32_t>(record.size());
    if (bytes == 0 || bytes > size) return false;

    const std::uint32_t used = m.ringProd - m.ringCons;  // free-running, wraps correctly
    if (used + bytes > size) {
        // No space. The fabric drops the record, counts it, AND still burns the
        // sequence number — which is what makes a seq gap visible to the host.
        ++m.ringDrops;
        ++m.seqCounter;
        return false;
    }

    const std::uint32_t mask = size - 1;
    const std::uint32_t at = m.ringProd & mask;
    const std::uint32_t firstChunk = (at + bytes <= size) ? bytes : (size - at);
    std::memcpy(m.ringMem.data() + at, record.data(), firstChunk);
    if (firstChunk < bytes) {
        std::memcpy(m.ringMem.data(), record.data() + firstChunk, bytes - firstChunk);
    }
    m.ringProd += bytes;
    ++m.seqCounter;
    return true;
}

void MockBar::dropRecords(std::uint32_t n) noexcept {
    impl_->ringDrops += n;
    impl_->seqCounter += n;
}

std::uint64_t MockBar::nextSeq() const noexcept { return impl_->seqCounter; }
void MockBar::setNextSeq(std::uint64_t seq) noexcept { impl_->seqCounter = seq; }

// =============================================================================
// 5. Device
// =============================================================================
Device::Device(std::unique_ptr<IBar> bar, std::string path)
    : bar_(std::move(bar)), path_(std::move(path)) {}

Device::~Device() = default;
Device::Device(Device&&) noexcept = default;
Device& Device::operator=(Device&&) noexcept = default;

MockBar* Device::mock() noexcept {
    if (!bar_ || !bar_->isMock()) return nullptr;
    return static_cast<MockBar*>(bar_.get());
}

Result<Device> Device::openMmio(std::string_view resourcePath, DeviceOptions opt) {
    if (resourcePath.empty()) return fail(DeviceError::InvalidArgument);

    // std::string_view is not guaranteed NUL-terminated; open() needs it to be.
    const std::string path(resourcePath);

    int flags = O_RDWR;
#ifdef O_SYNC
    // Linux sysfs `resource<N>` files want O_SYNC so the mapping is set up
    // uncached. Without it some kernels hand back a write-combining mapping,
    // under which stores to distinct registers may be merged or reordered by
    // the CPU — see the MMIO commentary above.
    flags |= O_SYNC;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif

    const int fd = ::open(path.c_str(), flags);
    if (fd < 0) return fail(errnoToDeviceError(errno));

    struct stat st {};
    std::uint32_t len = regmap::BAR0_SIZE;
    if (::fstat(fd, &st) == 0 && st.st_size > 0) {
        const auto sz = static_cast<std::uint64_t>(st.st_size);
        len = sz > regmap::BAR0_SIZE ? regmap::BAR0_SIZE : static_cast<std::uint32_t>(sz);
    }

    if (opt.requireFullBar && len < regmap::BAR0_SIZE) {
        ::close(fd);
        return fail(DeviceError::BarTooSmall);
    }

    void* map = ::mmap(nullptr, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        const int e = errno;
        ::close(fd);
        return fail(e == EACCES || e == EPERM ? DeviceError::PermissionDenied
                                              : DeviceError::MapFailed);
    }

    Device dev(std::make_unique<MmioBar>(fd, map, len), path);

    if (opt.checkMagicOnOpen) {
        auto magic = dev.read32(regmap::IDENT_MAGIC.offset);
        if (!magic) return fail(magic.error());
        if (*magic != regmap::IDENT_MAGIC_VALUE) return fail(DeviceError::IdentityMismatch);
    }

    return Result<Device>(std::move(dev));
}

Result<Device> Device::openMock(MockBar::Options opt) {
    return Result<Device>(Device(std::make_unique<MockBar>(opt), "<mock>"));
}

Result<Device> Device::adopt(std::unique_ptr<IBar> bar, DeviceOptions opt) {
    if (!bar) return fail(DeviceError::InvalidArgument);
    if (opt.requireFullBar && bar->size() < regmap::BAR0_SIZE) {
        return fail(DeviceError::BarTooSmall);
    }
    return Result<Device>(Device(std::move(bar), "<adopted>"));
}

Status Device::checkOffset(std::uint32_t offset) const noexcept {
    if (!bar_) return fail(DeviceError::NotOpen);
    if (offset % regmap::REG_STRIDE != 0) return fail(DeviceError::Misaligned);
    if (static_cast<std::uint64_t>(offset) + regmap::REG_STRIDE > bar_->size()) {
        return fail(DeviceError::OffsetOutOfRange);
    }
    return Status{};
}

Result<std::uint32_t> Device::read32(std::uint32_t offset) noexcept {
    if (auto ok = checkOffset(offset); !ok) return fail(ok.error());

    const auto acc = regmap::accessOf(offset);
    if (acc.known && !regmap::isReadable(acc.access)) {
        // A write-only register. Reading it returns garbage on real hardware,
        // and a caller that believes the garbage is worse than a failed call.
        return fail(DeviceError::AccessViolation);
    }

    return Result<std::uint32_t>(bar_->read(offset));
}

Status Device::write32(std::uint32_t offset, std::uint32_t value) noexcept {
    if (auto ok = checkOffset(offset); !ok) return ok;

    const auto acc = regmap::accessOf(offset);
    if (acc.known && !regmap::isWritable(acc.access)) {
        // The typed accessors catch this at compile time. This is the net under
        // callers that had to compute an offset at runtime.
        return fail(DeviceError::AccessViolation);
    }

    bar_->write(offset, value);
    return Status{};
}

Status Device::writeVerify(std::uint32_t offset, std::uint32_t value,
                           std::uint32_t mask) noexcept {
    if (auto ok = write32(offset, value); !ok) return ok;

    auto rb = read32(offset);
    if (!rb) return fail(rb.error());

    if ((*rb & mask) != (value & mask)) {
        // host/README.md §3.1: this is not a retryable condition. The caller
        // must abort the startup sequence. Either the register did not take the
        // value (wrong bitstream, wrong offset, RO in fabric but RW here) or
        // the fabric rejected it — and in both cases proceeding would arm a
        // system configured differently from what the host believes.
        return fail(DeviceError::VerifyMismatch);
    }
    return Status{};
}

Status Device::readBlock(std::uint32_t offset, std::span<std::uint32_t> out) noexcept {
    if (out.empty()) return Status{};
    if (auto ok = checkOffset(offset); !ok) return ok;
    const std::uint64_t end =
        static_cast<std::uint64_t>(offset) + out.size() * regmap::REG_STRIDE;
    if (end > bar_->size()) return fail(DeviceError::OffsetOutOfRange);

    for (std::size_t i = 0; i < out.size(); ++i) {
        const std::uint32_t off = offset + static_cast<std::uint32_t>(i) * regmap::REG_STRIDE;
        const auto acc = regmap::accessOf(off);
        if (acc.known && !regmap::isReadable(acc.access)) return fail(DeviceError::AccessViolation);
        out[i] = bar_->read(off);
    }
    return Status{};
}

Status Device::writeBlock(std::uint32_t offset, std::span<const std::uint32_t> in) noexcept {
    if (in.empty()) return Status{};
    if (auto ok = checkOffset(offset); !ok) return ok;
    const std::uint64_t end =
        static_cast<std::uint64_t>(offset) + in.size() * regmap::REG_STRIDE;
    if (end > bar_->size()) return fail(DeviceError::OffsetOutOfRange);

    for (std::size_t i = 0; i < in.size(); ++i) {
        const std::uint32_t off = offset + static_cast<std::uint32_t>(i) * regmap::REG_STRIDE;
        const auto acc = regmap::accessOf(off);
        if (acc.known && !regmap::isWritable(acc.access)) return fail(DeviceError::AccessViolation);
        bar_->write(off, in[i]);
    }
    return Status{};
}

Result<cycle_t> Device::readUptimeCycles() noexcept {
    // Two 32-bit reads of a 48-bit free-running counter cannot be atomic. Read
    // hi, lo, hi; if hi changed, the low word rolled between the reads, so take
    // the second pair. One retry is sufficient because a 32-bit rollover at
    // 156.25 MHz takes ~27 seconds.
    for (int attempt = 0; attempt < 3; ++attempt) {
        auto hi1 = read<regmap::IDENT_UPTIME_HI>();
        if (!hi1) return fail(hi1.error());
        auto lo = read<regmap::IDENT_UPTIME_LO>();
        if (!lo) return fail(lo.error());
        auto hi2 = read<regmap::IDENT_UPTIME_HI>();
        if (!hi2) return fail(hi2.error());
        if (*hi1 == *hi2) {
            const cycle_t v = (static_cast<cycle_t>(*hi1 & 0xFFFFu) << 32) | *lo;
            return Result<cycle_t>(v);
        }
    }
    return fail(DeviceError::Timeout);
}

Result<Identity> Device::readIdentity() noexcept {
    Identity id{};

    auto magic = read<regmap::IDENT_MAGIC>();
    if (!magic) return fail(magic.error());
    id.magic = *magic;

    auto build = read<regmap::IDENT_BUILD_ID>();
    if (!build) return fail(build.error());
    id.buildId = *build;

    auto sha = read<regmap::IDENT_GIT_SHA>();
    if (!sha) return fail(sha.error());
    id.gitSha = *sha;

    auto ver = read<regmap::IDENT_REGMAP_VER>();
    if (!ver) return fail(ver.error());
    id.regmapVer = *ver;

    auto caps = read<regmap::IDENT_CAPS>();
    if (!caps) return fail(caps.error());
    id.caps = *caps;

    auto krc = read<regmap::IDENT_KILL_RESP_CYC>();
    if (!krc) return fail(krc.error());
    id.killRespCycles = *krc;

    auto up = readUptimeCycles();
    if (!up) return fail(up.error());
    id.uptimeCycles = *up;

    return Result<Identity>(id);
}

Status Device::verifyIdentity(std::uint32_t expectedBuildId) noexcept {
    auto idr = readIdentity();
    if (!idr) return fail(idr.error());
    const Identity& id = *idr;

    // 1. Is this even our device?
    if (id.magic != regmap::IDENT_MAGIC_VALUE) return fail(DeviceError::IdentityMismatch);

    // 2. host/README.md §3.1 step 1 — the bitstream this host was built against.
    if (id.buildId != expectedBuildId) return fail(DeviceError::IdentityMismatch);

    // 3. Register map major version. A minor mismatch is additive (new words in
    //    reserved space) and is tolerated; a major mismatch means a register
    //    moved, and every offset in regmap.hpp is then suspect.
    if (regmap::regmapVerMajor(id.regmapVer) != regmap::REGMAP_VER_MAJOR) {
        return fail(DeviceError::IdentityMismatch);
    }

    // 4. Geometry. N_ACTIVE in particular is baked into the PARAM address
    //    encoding (types.hpp::paramAddr). If the fabric was built with a
    //    different one, every parameter write lands on the wrong symbol.
    if (id.caps != regmap::IDENT_CAPS_EXPECTED) return fail(DeviceError::IdentityMismatch);

    return Status{};
}

// =============================================================================
// 6. DmaLogRing
// =============================================================================
DmaLogRing::DmaLogRing(Device& dev) noexcept : dev_(&dev) {}
DmaLogRing::~DmaLogRing() = default;
DmaLogRing::DmaLogRing(DmaLogRing&&) noexcept = default;
DmaLogRing& DmaLogRing::operator=(DmaLogRing&&) noexcept = default;

namespace {

// Minimum framed size for a format. Below this a walk cannot even read a length.
[[nodiscard]] constexpr std::uint32_t minRecordBytes(LogFormat f) noexcept {
    return f == LogFormat::Fabric64 ? static_cast<std::uint32_t>(LOG_REC_BYTES)
                                    : LOG_RECORD_MIN_BYTES;
}

// The seq field width differs between the two formats, so gap arithmetic has to
// wrap at the right place: 32 bits for ContractV0, 48 for the fabric record.
[[nodiscard]] constexpr std::uint64_t seqMaskFor(LogFormat f) noexcept {
    return f == LogFormat::Fabric64 ? ((1ull << 48) - 1) : 0xFFFF'FFFFull;
}

}  // namespace

Status DmaLogRing::configure(const Config& cfg) noexcept {
    if (dev_ == nullptr) return fail(DeviceError::NotOpen);

    const std::size_t hostBytes = cfg.host.size();
    if (hostBytes == 0 || hostBytes > regmap::LOG_RING_BYTES_MAX) {
        return fail(DeviceError::RingBadSize);
    }
    const auto size = static_cast<std::uint32_t>(hostBytes);
    if (!regmap::logRingSizeValid(size)) return fail(DeviceError::RingBadSize);

    // The fabric computes the write address as base + (index & mask). A base
    // that is not at least page-aligned makes the ring straddle pages in a way
    // no IOMMU mapping will reproduce.
    if ((cfg.iova & 0xFFFu) != 0) return fail(DeviceError::InvalidArgument);
    if (cfg.format == LogFormat::Fabric64 && (size % LOG_REC_BYTES) != 0) {
        return fail(DeviceError::RingBadSize);
    }

    // Take the ring out of service before moving its base. Reprogramming the
    // base of a live ring points the fabric's next DMA at whatever used to be
    // at that address.
    if (auto s = dev_->write<regmap::LOG_RING_ENABLE>(0); !s) return s;

    const auto lo = static_cast<std::uint32_t>(cfg.iova & 0xFFFF'FFFFull);
    const auto hi = static_cast<std::uint32_t>(cfg.iova >> 32);

    if (auto s = dev_->writeVerify<regmap::LOG_RING_BASE_LO>(lo); !s) return s;
    if (auto s = dev_->writeVerify<regmap::LOG_RING_BASE_HI>(hi); !s) return s;
    if (auto s = dev_->writeVerify<regmap::LOG_RING_SIZE>(size); !s) return s;
    if (cfg.irqThreshold != 0) {
        if (auto s = dev_->writeVerify<regmap::LOG_RING_IRQ_THRESH>(cfg.irqThreshold); !s) {
            return s;
        }
    }

    // Start from wherever the fabric currently is, so the first poll does not
    // walk bytes left over from a previous run.
    auto prod = dev_->read<regmap::LOG_RING_PROD>();
    if (!prod) return fail(prod.error());
    if (auto s = dev_->writeVerify<regmap::LOG_RING_CONS>(*prod); !s) return s;

    auto drops = dev_->read<regmap::LOG_RING_DROPS>();
    if (!drops) return fail(drops.error());

    if (!stitch_) {
        stitch_ = std::make_unique<std::byte[]>(kStitchBytes);
    }

    cfg_ = cfg;
    ringSize_ = size;
    ringMask_ = size - 1;
    cons_ = *prod;
    pendingConsume_ = 0;
    lastDrops_ = *drops;
    haveLastDrops_ = true;
    lastSeq_ = 0;
    haveLastSeq_ = false;
    recordsSeen_ = 0;
    alert_.clear();
    configured_ = true;

    return Status{};
}

Status DmaLogRing::enable(bool on) noexcept {
    if (dev_ == nullptr) return fail(DeviceError::NotOpen);
    if (!configured_) return fail(DeviceError::RingNotConfigured);
    return dev_->writeVerify<regmap::LOG_RING_ENABLE>(on ? 1u : 0u);
}

Result<std::uint32_t> DmaLogRing::readProd() noexcept {
    return dev_->read<regmap::LOG_RING_PROD>();
}

Status DmaLogRing::flushPendingConsume() noexcept {
    if (pendingConsume_ == 0) return Status{};
    cons_ += pendingConsume_;  // free-running 32-bit byte index; wraps correctly
    pendingConsume_ = 0;
    return dev_->write<regmap::LOG_RING_CONS>(cons_);
}

Status DmaLogRing::consume() noexcept {
    if (!configured_) return fail(DeviceError::RingNotConfigured);
    return flushPendingConsume();
}

Status DmaLogRing::checkDropRegister() noexcept {
    auto drops = dev_->read<regmap::LOG_RING_DROPS>();
    if (!drops) return fail(drops.error());

    if (!haveLastDrops_) {
        lastDrops_ = *drops;
        haveLastDrops_ = true;
        return Status{};
    }

    if (*drops != lastDrops_) {
        // ⚠ Mechanism 1. The fabric had a record and nowhere to put it. This is
        // a hole in the CAT trail and it is alertable, not loggable.
        const std::uint32_t delta = *drops - lastDrops_;  // wraps correctly
        alert_.dropRegisterIncremented = true;
        alert_.dropDelta += delta;
        alert_.dropTotal = *drops;
        lastDrops_ = *drops;
    }
    return Status{};
}

void DmaLogRing::noteSeq(std::uint64_t seq) noexcept {
    const std::uint64_t mask = seqMaskFor(cfg_.format);
    seq &= mask;

    if (haveLastSeq_) {
        const std::uint64_t expected = (lastSeq_ + 1) & mask;
        if (seq != expected) {
            // ⚠ Mechanism 2. telemetry_pkg.sv §5: seq increments for EVERY
            // record the fabric decides to emit, including ones it then had to
            // drop. So a gap is an exact count of what was lost and exactly
            // where it sat.
            alert_.seqGap = true;
            alert_.expectedSeq = expected;
            alert_.observedSeq = seq;
            const std::uint64_t lost = (seq - expected) & mask;
            // A seq that went BACKWARDS is not a gap, it is a corrupt or stale
            // record — the ring is not being framed correctly.
            if (lost > (mask >> 1)) {
                alert_.corruptRecord = true;
                ++alert_.corruptCount;
            } else {
                alert_.recordsLost += lost;
            }
        }
    }

    lastSeq_ = seq;
    haveLastSeq_ = true;
    ++recordsSeen_;
}

std::uint32_t DmaLogRing::parseAt(std::uint32_t index, std::uint32_t availableBytes,
                                  RecordRef& out) noexcept {
    const std::byte* ring = cfg_.host.data();
    const std::uint32_t pos = index & ringMask_;

    // Return a direct view when the record is contiguous, or stitch it out of
    // the wrap. Only one record per poll can straddle the wrap point (the walk
    // crosses it at most once), so one stitch buffer is enough.
    auto view = [&](std::uint32_t at, std::uint32_t bytes, bool& stitched) -> const std::byte* {
        if (at + bytes <= ringSize_) {
            stitched = false;
            return ring + at;
        }
        const std::uint32_t first = ringSize_ - at;
        std::memcpy(stitch_.get(), ring + at, first);
        std::memcpy(stitch_.get() + first, ring, bytes - first);
        stitched = true;
        return stitch_.get();
    };

    if (cfg_.format == LogFormat::Fabric64) {
        constexpr std::uint32_t kRec = static_cast<std::uint32_t>(LOG_REC_BYTES);
        if (availableBytes < kRec) return 0;

        bool stitched = false;
        const std::byte* data = view(pos, kRec, stitched);

        const FabricLogWords words = loadFabricWords(data);
        const bool ok = !cfg_.verifyChecksums || checksumOk(words);

        out.data = data;
        out.bytes = kRec;
        out.seq = bits::get(words.data(), fields::LOGR_SEQ);
        out.type = static_cast<std::uint16_t>(bits::get(words.data(), fields::LOGR_REC_TYPE));
        out.ringIndex = pos;
        out.stitched = stitched;
        out.checksumOk = ok;

        if (!ok) {
            alert_.corruptRecord = true;
            if (alert_.corruptCount == 0) alert_.firstCorruptIndex = pos;
            ++alert_.corruptCount;
        }
        return kRec;
    }

    // --- ContractV0: 32-byte header then a variable payload ------------------
    if (availableBytes < LOG_RECORD_MIN_BYTES) return 0;

    bool hdrStitched = false;
    const std::byte* hdrBytes = view(pos, LOG_RECORD_MIN_BYTES, hdrStitched);
    LogRecordHeader hdr{};
    std::memcpy(&hdr, hdrBytes, sizeof(hdr));

    // Framing checks BEFORE trusting `length`. A bad length walks the parser
    // into the middle of the next record and every subsequent record is garbage,
    // so this has to fail hard rather than skip forward and hope.
    if (hdr.magic != LOG_RECORD_MAGIC || hdr.length < LOG_RECORD_MIN_BYTES ||
        hdr.length > LOG_RECORD_MAX_BYTES || (hdr.length % 4) != 0) {
        alert_.corruptRecord = true;
        if (alert_.corruptCount == 0) alert_.firstCorruptIndex = pos;
        ++alert_.corruptCount;
        return 0;  // stop the walk; the caller surfaces RingCorruptRecord
    }

    if (availableBytes < hdr.length) return 0;  // not yet fully written

    bool stitched = false;
    const std::byte* data = view(pos, hdr.length, stitched);

    bool ok = true;
    if (cfg_.verifyChecksums) {
        const std::span<const std::byte> payload{data + sizeof(LogRecordHeader),
                                                 hdr.length - sizeof(LogRecordHeader)};
        ok = (crc32(payload) == hdr.crc32);
    }

    out.data = data;
    out.bytes = hdr.length;
    out.seq = hdr.seq;
    out.type = hdr.type;
    out.ringIndex = pos;
    out.stitched = stitched;
    out.checksumOk = ok;

    if (!ok) {
        alert_.corruptRecord = true;
        if (alert_.corruptCount == 0) alert_.firstCorruptIndex = pos;
        ++alert_.corruptCount;
    }
    return hdr.length;
}

Result<PollStats> DmaLogRing::poll(std::span<RecordRef> out) noexcept {
    if (dev_ == nullptr) return fail(DeviceError::NotOpen);
    if (!configured_) return fail(DeviceError::RingNotConfigured);
    if (out.empty()) return fail(DeviceError::RingBufferTooSmall);

    // Release the previous batch first. Doing it here rather than at the end of
    // the previous poll is what keeps those RecordRefs valid for the caller
    // right up until it asks for more.
    if (auto s = flushPendingConsume(); !s) return fail(s.error());

    // Mechanism 1 runs on every poll, whether or not any records are available:
    // a drop with an empty ring is still a drop.
    if (auto s = checkDropRegister(); !s) return fail(s.error());

    auto prodR = readProd();
    if (!prodR) return fail(prodR.error());
    const std::uint32_t prod = *prodR;

    const std::uint32_t backlog = prod - cons_;  // free-running, unsigned wrap

    PollStats stats{};
    stats.backlogBytes = backlog;

    if (backlog > ringSize_) {
        // ⚠ The fabric lapped us. Record framing is lost: we cannot know where
        // a boundary is any more, so the only safe move is to resynchronise to
        // the producer and declare the interval lost. Reporting it is
        // mandatory — CLAUDE.md §5.7.
        alert_.overrun = true;
        cons_ = prod;
        pendingConsume_ = 0;
        haveLastSeq_ = false;  // the next seq is not comparable to the last
        if (auto s = dev_->write<regmap::LOG_RING_CONS>(cons_); !s) return fail(s.error());
        return fail(DeviceError::RingOverrun);
    }

    const std::uint32_t minRec = minRecordBytes(cfg_.format);
    std::uint32_t consumed = 0;
    std::size_t n = 0;
    bool framingLost = false;
    bool stoppedEarly = false;

    while (n < out.size() && (backlog - consumed) >= minRec) {
        RecordRef ref{};
        const std::uint32_t used = parseAt(cons_ + consumed, backlog - consumed, ref);
        if (used == 0) {
            // Either the record is not fully written yet (fine, come back) or
            // the header failed its framing checks (not fine). corruptRecord
            // distinguishes them.
            framingLost = alert_.corruptRecord;
            break;
        }
        noteSeq(ref.seq);
        out[n++] = ref;
        consumed += used;

        // A stitched record lives in the single shared stitch buffer, so it must
        // be the last one handed out in this batch.
        if (ref.stitched) {
            stoppedEarly = true;
            break;
        }
    }

    stats.records = n;
    stats.bytes = consumed;
    // "There is more to read, call again" — true whether we ran out of output
    // slots or stopped early to protect the stitch buffer.
    stats.outputFull = (stoppedEarly || n == out.size()) && ((backlog - consumed) >= minRec);
    pendingConsume_ = consumed;

    if (framingLost && n == 0) {
        // Nothing parsed and the framing is broken: do not advance, do not
        // pretend. The caller has to decide whether to re-arm the ring.
        return fail(DeviceError::RingCorruptRecord);
    }

    return Result<PollStats>(stats);
}

RingAlert DmaLogRing::takeAlert() noexcept {
    RingAlert a = alert_;
    alert_.clear();
    return a;
}

}  // namespace trading
