// =============================================================================
// device.hpp — PCIe BAR0 access, and the DMA audit-log ring reader
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : device layer (agent 1). Included by ctrld, paramd, sessiond,
//           logd, metricsd, heartbeat and the reconciler.
//
// WHAT THIS IS
//   The only code in host/ that touches the card. Everything above it speaks in
//   registers from regmap.hpp and records from log_record.hpp, and nothing above
//   it may compute an offset or dereference a mapping.
//
// WHAT THIS IS NOT
//   An order path. host/README.md §3.2: the host never bypasses the risk gate,
//   and there is no software path that emits an order. There is deliberately no
//   method here that writes an order, a token, or anything to the TX datapath.
//   The write surface is exactly the cfg_* control plane of
//   rtl/fpga_top.sv::u_host_ctrl and nothing else.
//
// NO EXCEPTIONS
//   Every fallible call returns trading::expected<T, DeviceError>. Nothing in
//   this header throws, and the implementation is compilable with
//   -fno-exceptions.
// =============================================================================
#ifndef TRADING_DEVICE_HPP
#define TRADING_DEVICE_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>

#include "trading/expected.hpp"
#include "trading/log_record.hpp"
#include "trading/regmap.hpp"
#include "trading/types.hpp"

namespace trading {

// =============================================================================
// 1. Errors
// =============================================================================
enum class DeviceError : std::uint16_t {
    None = 0,
    NotOpen,             // operation on a moved-from or unopened Device
    OpenFailed,          // could not open the resource path
    MapFailed,           // mmap of BAR0 failed
    BarTooSmall,         // the mapping is smaller than regmap::BAR0_SIZE
    PermissionDenied,    // need CAP_SYS_RAWIO / root / vfio group membership
    OffsetOutOfRange,    // offset past the end of the BAR
    Misaligned,          // offset not 4-byte aligned, or buffer not aligned
    AccessViolation,     // wrote a RO register / read a WO register at runtime
    VerifyMismatch,      // read-back after write did not match  ⚠ startup abort
    IdentityMismatch,    // IDENT_MAGIC / BUILD_ID / REGMAP_VER / CAPS wrong
    Timeout,
    InvalidArgument,
    Unsupported,         // e.g. a vfio path on a build without vfio support
    IoError,

    // --- log ring ---------------------------------------------------------
    RingNotConfigured,
    RingBadSize,         // not a power of two, or outside the allowed range
    RingBadIndex,        // PROD/CONS pair is not self-consistent
    RingOverrun,         // ⚠ the fabric lapped us; records are gone
    RingCorruptRecord,   // ⚠ bad magic / length / checksum
    RingBufferTooSmall,  // caller's output span could not hold one record
};

[[nodiscard]] std::string_view toString(DeviceError e) noexcept;

// Convenience aliases. Every component in host/ should use these two rather
// than spelling out expected<..., DeviceError>.
template <class T>
using Result = expected<T, DeviceError>;
using Status = expected<void, DeviceError>;

// =============================================================================
// 2. Backend interface
// -----------------------------------------------------------------------------
// Two implementations:
//   MmioBar  — a real mapped BAR0 (see device.cpp)
//   MockBar  — an in-process register model, so the other nine components can
//              be tested with no card in the machine
//
// The virtual call costs a few nanoseconds. A real MMIO read across PCIe costs
// ~1 microsecond (host/README.md §1), so the dispatch is three orders of
// magnitude below the thing it is dispatching to. This is the slow path by
// definition; the indirection is free in any sense that matters.
// =============================================================================
class IBar {
public:
    virtual ~IBar() = default;

    [[nodiscard]] virtual std::uint32_t size() const noexcept = 0;
    [[nodiscard]] virtual bool isMock() const noexcept = 0;

    // Offsets are pre-validated by Device; implementations do not re-check.
    [[nodiscard]] virtual std::uint32_t read(std::uint32_t offset) noexcept = 0;
    virtual void write(std::uint32_t offset, std::uint32_t value) noexcept = 0;
};

// =============================================================================
// 3. Mock backend — the register model
// -----------------------------------------------------------------------------
// Selectable at construction (Device::openMock). It models enough of the
// fabric's behaviour that the mandatory startup sequence in host/README.md §3.1
// can be exercised end to end, including the parts that are supposed to FAIL:
//
//   * IDENT reads back the configured build identity and this host's expected
//     REGMAP_VER / CAPS, so a mismatch test is a one-line change
//   * PARAM_*_DATA writes land in a shadow bank indexed by PARAM_*_ADDR, and
//     PARAM_*_RB reads that entry back — so the mandatory read-back-and-verify
//     step actually verifies something
//   * PARAM_*_COMMIT only takes effect when written with PARAM_COMMIT_MAGIC,
//     and increments GEN and flips ACTIVE_BANK when it does
//   * the two-step arm requires ARM_KEY then a matching ARM_EXEC
//   * CTRL_KILL is write-1-to-set and latches CTRL_KILL_SRC = KILL_HOST
//   * the log ring PROD/CONS/DROPS registers behave, and records can be pushed
//     into the ring from a test
//
// It is a model, not a simulator: it has no notion of time, no datapath, and
// makes no attempt to reproduce fabric latency. Anything that needs those
// belongs in tb/ against the RTL.
// =============================================================================
class MockBar : public IBar {
public:
    struct Options {
        std::uint32_t buildId = 0xDEAD'0000u;  // fpga_top.sv default BUILD_ID
        std::uint32_t gitSha = 0;
        bool startArmed = false;
        bool startKilled = false;
    };

    explicit MockBar(Options opt);
    ~MockBar() override;

    MockBar(const MockBar&) = delete;
    MockBar& operator=(const MockBar&) = delete;

    [[nodiscard]] std::uint32_t size() const noexcept override { return regmap::BAR0_SIZE; }
    [[nodiscard]] bool isMock() const noexcept override { return true; }
    [[nodiscard]] std::uint32_t read(std::uint32_t offset) noexcept override;
    void write(std::uint32_t offset, std::uint32_t value) noexcept override;

    // --- test hooks: force fabric-owned state -----------------------------
    void pokeRegister(std::uint32_t offset, std::uint32_t value) noexcept;
    [[nodiscard]] std::uint32_t peekRegister(std::uint32_t offset) const noexcept;
    void setTelemetryWord(std::uint32_t wordIndex, std::uint32_t value) noexcept;
    void setHealth(std::uint32_t healthWord) noexcept;
    void setLinkUp(std::uint32_t linkMask) noexcept;
    void setSessionState(SessionState s) noexcept;
    void advanceUptime(std::uint64_t cycles) noexcept;
    void forceKill(KillSrc src) noexcept;

    // --- test hooks: inspect host-owned state -----------------------------
    [[nodiscard]] bool tradingEnabled() const noexcept;
    [[nodiscard]] bool armed() const noexcept;
    [[nodiscard]] bool killActive() const noexcept;
    [[nodiscard]] std::uint32_t lastHeartbeat() const noexcept;
    [[nodiscard]] std::uint64_t heartbeatCount() const noexcept;
    [[nodiscard]] std::uint32_t riskGeneration() const noexcept;
    [[nodiscard]] std::uint32_t stratGeneration() const noexcept;

    // Read back a word paramd wrote, addressed exactly as the fabric sees it
    // (see types.hpp::paramAddr). Returns 0 for an out-of-range address.
    [[nodiscard]] std::uint32_t riskShadowWord(ParamBank bank, std::uint32_t sym,
                                               std::uint32_t word) const noexcept;
    [[nodiscard]] std::uint32_t stratShadowWord(ParamBank bank, std::uint32_t sym,
                                                std::uint32_t word) const noexcept;
    [[nodiscard]] std::uint32_t filterShadowWord(std::uint32_t locate) const noexcept;

    // --- test hooks: the DMA log ring -------------------------------------
    // Give the model the same host buffer the DmaLogRing was configured with,
    // so pushRecord() can write into it and advance PROD the way fabric would.
    void attachRingMemory(std::span<std::byte> ring) noexcept;
    // Append one record and advance PROD. Returns false if the ring is full, in
    // which case DROPS is incremented — which is exactly the condition
    // DmaLogRing must surface as an alert.
    bool pushRecord(std::span<const std::byte> record) noexcept;
    // Drop `n` records without writing them: bumps DROPS and skips `n` sequence
    // numbers, so BOTH drop-detection paths in DmaLogRing fire.
    void dropRecords(std::uint32_t n) noexcept;
    [[nodiscard]] std::uint64_t nextSeq() const noexcept;
    void setNextSeq(std::uint64_t seq) noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// =============================================================================
// 4. Device
// =============================================================================

// Decoded IDENT block.
struct Identity {
    std::uint32_t magic = 0;
    std::uint32_t buildId = 0;
    std::uint32_t gitSha = 0;
    std::uint32_t regmapVer = 0;
    std::uint32_t caps = 0;
    cycle_t uptimeCycles = 0;
    std::uint32_t killRespCycles = 0;

    [[nodiscard]] std::uint16_t regmapMajor() const noexcept {
        return regmap::regmapVerMajor(regmapVer);
    }
    [[nodiscard]] std::uint16_t regmapMinor() const noexcept {
        return regmap::regmapVerMinor(regmapVer);
    }
    [[nodiscard]] std::uint64_t uptimeNs() const noexcept { return cyclesToNs(uptimeCycles); }
};

struct DeviceOptions {
    // Reject the mapping if BAR0 is smaller than the register map needs.
    bool requireFullBar = true;
    // Read IDENT_MAGIC during open and fail on mismatch. Cheap, and it turns
    // "the BAR is mapped but the device is in reset" into an error at open
    // rather than a wrong answer three registers later.
    bool checkMagicOnOpen = true;
};

class Device {
public:
    // -----------------------------------------------------------------------
    // Open a real card. `resourcePath` is a sysfs BAR file such as
    //   /sys/bus/pci/devices/0000:65:00.0/resource0
    // or a vfio region path. IT IS ALWAYS A PARAMETER — there is no default and
    // no compiled-in path. Which card this host talks to is deployment
    // configuration, and configuration does not live in the binary.
    //
    // Requires CAP_SYS_RAWIO or vfio group membership; without it this returns
    // PermissionDenied rather than aborting.
    // -----------------------------------------------------------------------
    [[nodiscard]] static Result<Device> openMmio(std::string_view resourcePath,
                                                 DeviceOptions opt = {});

    // Open the in-process register model. Same interface, no hardware.
    [[nodiscard]] static Result<Device> openMock(MockBar::Options opt = {});

    // Adopt an already-constructed backend. Lets a test drive a custom IBar.
    [[nodiscard]] static Result<Device> adopt(std::unique_ptr<IBar> bar, DeviceOptions opt = {});

    ~Device();
    Device(Device&&) noexcept;
    Device& operator=(Device&&) noexcept;
    Device(const Device&) = delete;
    Device& operator=(const Device&) = delete;

    [[nodiscard]] bool isOpen() const noexcept { return static_cast<bool>(bar_); }
    [[nodiscard]] bool isMock() const noexcept { return bar_ && bar_->isMock(); }
    // Non-null only on the mock backend. Production code must never call this;
    // it exists so tests can reach the model's hooks.
    [[nodiscard]] MockBar* mock() noexcept;
    [[nodiscard]] const std::string& path() const noexcept { return path_; }

    // -----------------------------------------------------------------------
    // Raw 32-bit access.
    //
    // read32 is NOT const. An MMIO read is not a pure function: regmap marks
    // TELEM_SNAPSHOT and TELEM_HIST_CLEAR as RO_SE because reading them latches
    // the shadow bank and zeroes the histogram respectively. A const read32
    // would be a lie about that.
    // -----------------------------------------------------------------------
    [[nodiscard]] Result<std::uint32_t> read32(std::uint32_t offset) noexcept;
    [[nodiscard]] Status write32(std::uint32_t offset, std::uint32_t value) noexcept;

    // -----------------------------------------------------------------------
    // Write, then read back and compare. host/README.md §3.1 makes this
    // MANDATORY after every parameter commit: "Skipping the read-back step
    // defeats the purpose of the double-buffered parameter design."
    //
    // `mask` selects the bits that must match, for registers where the fabric
    // owns some bits. A mismatch is VerifyMismatch and the caller must treat it
    // as an abort of the startup sequence, not a retry.
    // -----------------------------------------------------------------------
    [[nodiscard]] Status writeVerify(std::uint32_t offset, std::uint32_t value,
                                     std::uint32_t mask = 0xFFFF'FFFFu) noexcept;

    // Bulk helpers for the telemetry bank and the parameter windows. `out`/`in`
    // are word counts, not bytes. These issue one MMIO access per word — there
    // is no burst read on a BAR — so keep spans short on a latency-sensitive
    // scrape (host/README.md §2, metricsd: "scrape cadence must not perturb the
    // datapath").
    [[nodiscard]] Status readBlock(std::uint32_t offset, std::span<std::uint32_t> out) noexcept;
    [[nodiscard]] Status writeBlock(std::uint32_t offset,
                                    std::span<const std::uint32_t> in) noexcept;

    // -----------------------------------------------------------------------
    // Typed accessors. The register is a template parameter, so its access type
    // is known at compile time:
    //
    //     dev.write<regmap::CTRL_KILL_ACTIVE>(1);  // error: RO register
    //     dev.read<regmap::CTRL_HEARTBEAT>();      // error: WO register
    //     dev.writeVerify<regmap::CTRL_KILL>(1);   // error: W1S does not read back
    //
    // This is the compile-time guarantee the brief asks for: nobody writes a
    // read-only register, and the mistake is caught at build time rather than
    // by staring at a card that ignored the write.
    // -----------------------------------------------------------------------
    template <regmap::Reg R>
    [[nodiscard]] Result<std::uint32_t> read() noexcept {
        static_assert(regmap::isReadable(R.access),
                      "read() on a write-only register — check regmap.hpp");
        return read32(R.offset);
    }

    template <regmap::Reg R>
    [[nodiscard]] Status write(std::uint32_t value) noexcept {
        static_assert(regmap::isWritable(R.access),
                      "write() to a read-only register — check regmap.hpp");
        return write32(R.offset, value);
    }

    template <regmap::Reg R>
    [[nodiscard]] Status writeVerify(std::uint32_t value,
                                     std::uint32_t mask = 0xFFFF'FFFFu) noexcept {
        static_assert(regmap::isVerifiable(R.access),
                      "writeVerify() needs a plain RW register: a WO or W1S register does "
                      "not read back what was written, so the 'verify' would be fiction");
        return writeVerify(R.offset, value, mask);
    }

    // -----------------------------------------------------------------------
    // Identity — step 1 of the startup sequence.
    // -----------------------------------------------------------------------
    [[nodiscard]] Result<Identity> readIdentity() noexcept;

    // Refuse to proceed unless the fabric is the bitstream this host was built
    // against AND agrees with regmap.hpp about the map version and the geometry
    // constants that the PARAM address encoding depends on.
    //
    // host/README.md §3.1 step 1: "Verify BUILD_ID (refuse to proceed on
    // mismatch)". A host talking to the wrong bitstream will load risk limits
    // into the wrong field offsets, which is a limit that silently does not
    // exist.
    [[nodiscard]] Status verifyIdentity(std::uint32_t expectedBuildId) noexcept;

    // Read the 48-bit uptime counter as one value. Two 32-bit reads cannot be
    // atomic, so this re-reads the high word and retries on a carry.
    [[nodiscard]] Result<cycle_t> readUptimeCycles() noexcept;

private:
    Device() = default;
    explicit Device(std::unique_ptr<IBar> bar, std::string path);

    [[nodiscard]] Status checkOffset(std::uint32_t offset) const noexcept;

    std::unique_ptr<IBar> bar_;
    std::string path_;
};

// =============================================================================
// 5. DMA log ring reader
// -----------------------------------------------------------------------------
// Drains the fabric's audit log. logd owns an instance of this.
//
// DROP DETECTION — TWO INDEPENDENT MECHANISMS, NEITHER OF WHICH IS OPTIONAL
//
//   1. LOG_RING_DROPS increments. The fabric had a record to write and no space
//      to write it in. It knows it dropped and says so.
//   2. A GAP IN THE PER-RECORD `seq`. telemetry_pkg.sv §5: seq increments for
//      EVERY record the fabric decides to emit, INCLUDING records it then had
//      to drop. So a gap tells us exactly how many were lost and between which
//      two surviving records they sat.
//
//   The two exist because they fail differently. (1) misses a drop caused by
//   anything downstream of the counter; (2) misses nothing but cannot report a
//   loss until a later record arrives to show the gap. Together they cover the
//   space. CLAUDE.md §5.7: "Every drop, error, and rejected order is counted.
//   Silent failure is the worst failure mode in this domain."
//
//   Both surface through RingAlert, which LATCHES. It is not a return code that
//   can be dropped on the floor by forgetting to check it: it stays set until
//   takeAlert() explicitly clears it, and hasAlert() is a standing condition
//   logd is expected to escalate. A hole in the CAT trail is a reportable
//   event, not a log line.
//
// CONSUME SEMANTICS
//   poll() returns references INTO the ring — no copying, and therefore no
//   allocation on the drain path. Those references stay valid until the space
//   is released back to the fabric. So poll() does NOT release the records it
//   just returned; it releases the ones returned by the PREVIOUS poll(), and
//   consume() releases immediately when the caller is done early. The effect is
//   that LOG_RING_CONS advances on every poll, one call behind, and the fabric
//   can never overwrite a record the caller is still reading.
// =============================================================================

// A latched, alertable condition. `any()` being true is an operational event.
struct RingAlert {
    // --- mechanism 1: the drop counter ---
    bool dropRegisterIncremented = false;
    std::uint32_t dropDelta = 0;   // increments observed since the last takeAlert()
    std::uint32_t dropTotal = 0;   // last raw value of LOG_RING_DROPS

    // --- mechanism 2: sequence gaps ---
    bool seqGap = false;
    std::uint64_t expectedSeq = 0;
    std::uint64_t observedSeq = 0;
    std::uint64_t recordsLost = 0;  // summed across every gap since the last take

    // --- ring-level faults ---
    bool overrun = false;         // ⚠ prod - cons exceeded the ring: fabric lapped us
    bool corruptRecord = false;   // bad magic / length / checksum
    std::uint32_t corruptCount = 0;
    std::uint32_t firstCorruptIndex = 0;  // ring byte index of the first bad record

    [[nodiscard]] constexpr bool any() const noexcept {
        return dropRegisterIncremented || seqGap || overrun || corruptRecord;
    }
    constexpr void clear() noexcept { *this = RingAlert{}; }
};

// One record, by reference into the ring (or into the stitch buffer if it
// straddled the wrap). Valid until the next poll() or consume().
struct RecordRef {
    const std::byte* data = nullptr;
    std::uint32_t bytes = 0;
    std::uint64_t seq = 0;
    std::uint16_t type = 0;      // LogRecordType or FabricLogType, per format
    std::uint32_t ringIndex = 0; // byte index within the ring, for diagnostics
    bool stitched = false;       // copied out of the wrap, not a direct view
    bool checksumOk = false;

    // Decode as a Fabric64 record. Only valid when the ring format is Fabric64
    // and bytes == LOG_REC_BYTES; check before calling.
    [[nodiscard]] FabricLogRecord asFabric() const noexcept {
        return unpackFabricLog(loadFabricWords(data));
    }
    // Decode the ContractV0 header. Only valid when the format is ContractV0.
    [[nodiscard]] LogRecordHeader asContractHeader() const noexcept {
        LogRecordHeader h{};
        std::memcpy(&h, data, sizeof(h));
        return h;
    }
    [[nodiscard]] std::span<const std::byte> contractPayload() const noexcept {
        return {data + sizeof(LogRecordHeader), bytes - sizeof(LogRecordHeader)};
    }
};

struct PollStats {
    std::size_t records = 0;     // records written into the caller's span
    std::uint32_t bytes = 0;     // ring bytes those records occupy
    bool outputFull = false;     // more records are ready; call poll() again
    std::uint32_t backlogBytes = 0;  // prod - cons at the time of the poll
};

class DmaLogRing {
public:
    struct Config {
        // Bus address the fabric DMAs to. On a vfio setup this is the IOVA the
        // mapping was created with; on a plain hugepage setup it is the physical
        // address. Obtaining it is deployment-specific and NOT this class's job
        // — see the note on configure().
        std::uint64_t iova = 0;
        // Host-virtual view of the SAME memory. Length must equal the ring size
        // and be a power of two in [LOG_RING_BYTES_MIN, LOG_RING_BYTES_MAX].
        std::span<std::byte> host{};
        LogFormat format = LogFormat::Fabric64;
        std::uint32_t irqThreshold = 0;  // 0 = leave LOG_RING_IRQ_THRESH alone
        // Verify each record's checksum. On by default: an unverified audit log
        // is not an audit log. Turning it off is a benchmarking affordance.
        bool verifyChecksums = true;
    };

    explicit DmaLogRing(Device& dev) noexcept;
    ~DmaLogRing();
    DmaLogRing(const DmaLogRing&) = delete;
    DmaLogRing& operator=(const DmaLogRing&) = delete;
    DmaLogRing(DmaLogRing&&) noexcept;
    DmaLogRing& operator=(DmaLogRing&&) noexcept;

    // Program LOG_RING_BASE_LO/HI, LOG_RING_SIZE and (optionally)
    // LOG_RING_IRQ_THRESH, each with a read-back verify, then sync CONS to the
    // fabric's current PROD so the first poll() does not walk stale bytes.
    //
    // ⚠ HARDWARE-DEPENDENT AND DELIBERATELY NOT DONE HERE: allocating the ring
    //   and obtaining its bus address. That needs hugepages plus /proc/self/
    //   pagemap, or a vfio container with VFIO_IOMMU_MAP_DMA, and the right
    //   answer depends on which of the two the deployment uses and on the IOMMU
    //   configuration. The caller supplies {iova, host} as a matched pair. This
    //   class programs the registers and parses the bytes; it does not guess at
    //   the memory topology.
    [[nodiscard]] Status configure(const Config& cfg) noexcept;

    [[nodiscard]] Status enable(bool on) noexcept;
    [[nodiscard]] bool isConfigured() const noexcept { return configured_; }
    [[nodiscard]] LogFormat format() const noexcept { return cfg_.format; }

    // Non-blocking. Fills `out` with complete records and returns how many.
    // Never blocks, never allocates, never throws.
    //
    // Returns RingOverrun / RingCorruptRecord as errors only when the ring can
    // no longer be walked safely. Recoverable conditions (a drop, a sequence
    // gap) are reported through the latched alert and do NOT fail the call —
    // the records that DID arrive are still valid and still have to be written
    // to durable storage.
    [[nodiscard]] Result<PollStats> poll(std::span<RecordRef> out) noexcept;

    // Release the records from the last poll() back to the fabric immediately,
    // rather than waiting for the next poll() to do it.
    [[nodiscard]] Status consume() noexcept;

    // --- the alert. Latched; survives until taken. ---
    [[nodiscard]] bool hasAlert() const noexcept { return alert_.any(); }
    [[nodiscard]] const RingAlert& peekAlert() const noexcept { return alert_; }
    [[nodiscard]] RingAlert takeAlert() noexcept;

    // Diagnostics.
    [[nodiscard]] std::uint64_t recordsSeen() const noexcept { return recordsSeen_; }
    [[nodiscard]] std::uint64_t lastSeq() const noexcept { return lastSeq_; }
    [[nodiscard]] std::uint32_t ringSize() const noexcept { return ringSize_; }

private:
    [[nodiscard]] Result<std::uint32_t> readProd() noexcept;
    [[nodiscard]] Status flushPendingConsume() noexcept;
    [[nodiscard]] Status checkDropRegister() noexcept;
    // Parse one record at `index`; returns bytes consumed, or 0 if incomplete.
    [[nodiscard]] std::uint32_t parseAt(std::uint32_t index, std::uint32_t availableBytes,
                                        RecordRef& out) noexcept;
    void noteSeq(std::uint64_t seq) noexcept;

    Device* dev_ = nullptr;
    Config cfg_{};
    bool configured_ = false;

    std::uint32_t ringSize_ = 0;
    std::uint32_t ringMask_ = 0;
    std::uint32_t cons_ = 0;           // our view of LOG_RING_CONS
    std::uint32_t pendingConsume_ = 0; // bytes handed out by the last poll()

    std::uint32_t lastDrops_ = 0;
    bool haveLastDrops_ = false;

    std::uint64_t lastSeq_ = 0;
    bool haveLastSeq_ = false;
    std::uint64_t recordsSeen_ = 0;

    RingAlert alert_{};

    // One record can straddle the ring wrap per poll (the walk crosses the wrap
    // point at most once), so a single stitch buffer is sufficient.
    std::unique_ptr<std::byte[]> stitch_;
    static constexpr std::size_t kStitchBytes = LOG_RECORD_MAX_BYTES;
};

}  // namespace trading

#endif  // TRADING_DEVICE_HPP
