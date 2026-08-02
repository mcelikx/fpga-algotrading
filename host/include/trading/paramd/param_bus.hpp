// =============================================================================
// paramd/param_bus.hpp — the narrow register interface paramd is allowed to use
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
//
// WHY paramd DOES NOT TAKE A `trading::Device&` DIRECTLY
//   Two reasons, and the second is the important one.
//
//   1. host/include/trading/device.hpp is owned by another component and does
//      not exist yet. paramd is written against the three operations the shared
//      brief guarantees (read32 / write32 / writeVerify) and binds to Device
//      through a thin adapter, so paramd compiles and is testable today.
//
//   2. ⚠ paramd must be *unable* to reach any register outside the two parameter
//      windows. Handed a full Device, a future edit could "just also set
//      CTRL_TRADING_EN while we're here" — which is precisely the bundling
//      host/README.md §3.3 and manual 08/09 §9 forbid. ParamBus exposes three
//      offset-taking primitives and nothing else, and ParamBus::Restricted below
//      refuses any offset outside the PARAM block at runtime. The restriction is
//      in the type system and in the transport, not in a review comment.
//
// The fake in paramd/testing (see host/src/paramd/) implements the same
// interface, so the whole write/read-back/verify/commit cycle is exercisable
// without hardware.
// =============================================================================
#ifndef TRADING_PARAMD_PARAM_BUS_HPP
#define TRADING_PARAMD_PARAM_BUS_HPP

#include <cstdint>
#include <type_traits>
#include <utility>

#include "trading/expected.hpp"
#include "trading/paramd/param_window.hpp"
#include "trading/regmap.hpp"

namespace trading::paramd {

// Transport-level failure. `code` is whatever the device layer's error enum
// carried, cast to an integer: paramd does not need to interpret it, only to
// record it in the audit trail so the incident is reconstructable.
struct BusError {
    std::uint32_t offset = 0;
    std::int32_t code = 0;
    bool isWrite = false;
    bool isVerify = false;
    std::uint32_t wrote = 0;     // verify only
    std::uint32_t readBack = 0;  // verify only
};

// -----------------------------------------------------------------------------
// The interface. Three operations. No block transfers, no bulk DMA, no "just
// give me the mapping" escape hatch.
// -----------------------------------------------------------------------------
class ParamBus {
public:
    virtual ~ParamBus() = default;

    ParamBus() = default;
    ParamBus(const ParamBus&) = delete;
    ParamBus& operator=(const ParamBus&) = delete;

    [[nodiscard]] virtual expected<std::uint32_t, BusError> read32(std::uint32_t offset) = 0;
    [[nodiscard]] virtual expected<void, BusError> write32(std::uint32_t offset,
                                                           std::uint32_t value) = 0;

    // Write, then read back and compare. Only legal on Access::RW registers —
    // regmap::isVerifiable() says which. paramd uses it for PARAM_*_ADDR, whose
    // round-trip both proves the address latched AND flushes the posted write
    // ahead of the PARAM_*_RB read that follows.
    [[nodiscard]] virtual expected<void, BusError> writeVerify(std::uint32_t offset,
                                                               std::uint32_t value) = 0;

    // Counters, for the audit record. A commit whose access count does not match
    // the expected 2*N + ... shape is a commit that took a path nobody designed.
    [[nodiscard]] std::uint64_t reads() const noexcept { return reads_; }
    [[nodiscard]] std::uint64_t writes() const noexcept { return writes_; }

protected:
    void countRead() noexcept { ++reads_; }
    void countWrite() noexcept { ++writes_; }

private:
    std::uint64_t reads_ = 0;
    std::uint64_t writes_ = 0;
};

// -----------------------------------------------------------------------------
// Typed register helpers. These take a regmap::Reg so the access class is
// checked at compile time in the same spirit as device.hpp's typed accessors.
// -----------------------------------------------------------------------------
template <regmap::Reg R>
[[nodiscard]] inline expected<std::uint32_t, BusError> readReg(ParamBus& bus) {
    static_assert(regmap::isReadable(R.access), "register is not readable");
    static_assert(!regmap::hasReadSideEffect(R.access),
                  "this register's read has a side effect; paramd must not touch it");
    return bus.read32(R.offset);
}

template <regmap::Reg R>
[[nodiscard]] inline expected<void, BusError> writeReg(ParamBus& bus, std::uint32_t v) {
    static_assert(regmap::isWritable(R.access), "register is not writable");
    return bus.write32(R.offset, v);
}

template <regmap::Reg R>
[[nodiscard]] inline expected<void, BusError> writeVerifyReg(ParamBus& bus, std::uint32_t v) {
    static_assert(regmap::isVerifiable(R.access),
                  "writeVerify is only meaningful on a plain RW register; verifying a WO or "
                  "W1S register reads garbage and 'proves' a mismatch");
    return bus.writeVerify(R.offset, v);
}

// Runtime equivalents, for the ParamWindow-driven paths where the register comes
// out of a descriptor rather than a template parameter.
[[nodiscard]] inline expected<std::uint32_t, BusError> readReg(ParamBus& bus, regmap::Reg r) {
    return bus.read32(r.offset);
}
[[nodiscard]] inline expected<void, BusError> writeReg(ParamBus& bus, regmap::Reg r,
                                                       std::uint32_t v) {
    return bus.write32(r.offset, v);
}
[[nodiscard]] inline expected<void, BusError> writeVerifyReg(ParamBus& bus, regmap::Reg r,
                                                             std::uint32_t v) {
    return bus.writeVerify(r.offset, v);
}

// Map a transport failure onto the paramd failure vocabulary without losing the
// underlying code.
[[nodiscard]] inline ParamFailure fromBus(const BusError& e, ParamDomain d) noexcept {
    ParamFailure f{};
    f.code = e.isVerify ? ParamError::BusVerify
                        : (e.isWrite ? ParamError::BusWrite : ParamError::BusRead);
    f.domain = d;
    f.offset = e.offset;
    f.busCode = e.code;
    f.expected = e.wrote;
    f.actual = e.readBack;
    return f;
}

// =============================================================================
// Adapter onto trading::Device
// -----------------------------------------------------------------------------
// Templated so this header does not depend on device.hpp existing. Bind it once
// where paramd is wired up:
//
//     #include "trading/device.hpp"
//     trading::paramd::DeviceParamBus<trading::Device> bus{dev};
//
// DeviceT must provide, each returning something contextually convertible to
// bool with .error() and (for read32) operator*:
//     read32(std::uint32_t) / write32(std::uint32_t, std::uint32_t)
//     writeVerify(std::uint32_t, std::uint32_t)
// which is exactly the contract in the shared brief.
// =============================================================================
template <class DeviceT>
class DeviceParamBus final : public ParamBus {
public:
    explicit DeviceParamBus(DeviceT& dev) noexcept : dev_(dev) {}

    [[nodiscard]] expected<std::uint32_t, BusError> read32(std::uint32_t offset) override {
        countRead();
        auto r = dev_.read32(offset);
        if (!r) return fail(BusError{offset, toCode(r.error()), false, false, 0, 0});
        return *r;
    }

    [[nodiscard]] expected<void, BusError> write32(std::uint32_t offset,
                                                   std::uint32_t value) override {
        countWrite();
        auto r = dev_.write32(offset, value);
        if (!r) return fail(BusError{offset, toCode(r.error()), true, false, value, 0});
        return {};
    }

    [[nodiscard]] expected<void, BusError> writeVerify(std::uint32_t offset,
                                                       std::uint32_t value) override {
        countWrite();
        countRead();
        auto r = dev_.writeVerify(offset, value);
        if (!r) return fail(BusError{offset, toCode(r.error()), true, true, value, 0});
        return {};
    }

private:
    template <class E>
    [[nodiscard]] static std::int32_t toCode(const E& e) noexcept {
        if constexpr (std::is_enum_v<E>) {
            return static_cast<std::int32_t>(static_cast<std::underlying_type_t<E>>(e));
        } else if constexpr (std::is_integral_v<E>) {
            return static_cast<std::int32_t>(e);
        } else {
            // A structured device error. Record that it failed; the device layer
            // logs the detail on its own side.
            (void)e;
            return -1;
        }
    }

    DeviceT& dev_;
};

// =============================================================================
// Restricted — a decorator that refuses any offset outside the PARAM block
// -----------------------------------------------------------------------------
// Defence in depth for the "paramd may not touch anything else" rule. Wrap the
// real bus in this and a stray CTRL_TRADING_EN write becomes a returned error
// instead of an armed FPGA.
// =============================================================================
class RestrictedParamBus final : public ParamBus {
public:
    explicit RestrictedParamBus(ParamBus& inner) noexcept : inner_(inner) {}

    [[nodiscard]] expected<std::uint32_t, BusError> read32(std::uint32_t offset) override {
        if (!inParamBlock(offset)) return fail(outOfRange(offset, false));
        countRead();
        return inner_.read32(offset);
    }
    [[nodiscard]] expected<void, BusError> write32(std::uint32_t offset,
                                                   std::uint32_t value) override {
        if (!inParamBlock(offset)) return fail(outOfRange(offset, true));
        countWrite();
        return inner_.write32(offset, value);
    }
    [[nodiscard]] expected<void, BusError> writeVerify(std::uint32_t offset,
                                                       std::uint32_t value) override {
        if (!inParamBlock(offset)) return fail(outOfRange(offset, true));
        countWrite();
        countRead();
        return inner_.writeVerify(offset, value);
    }

    [[nodiscard]] static constexpr bool inParamBlock(std::uint32_t offset) noexcept {
        return offset >= regmap::PARAM_BASE &&
               offset + regmap::REG_STRIDE <= regmap::PARAM_BASE + regmap::PARAM_SIZE &&
               offset % regmap::REG_STRIDE == 0;
    }

private:
    [[nodiscard]] static BusError outOfRange(std::uint32_t offset, bool isWrite) noexcept {
        BusError e{};
        e.offset = offset;
        e.code = -2;  // "paramd attempted an access outside the PARAM window"
        e.isWrite = isWrite;
        return e;
    }

    ParamBus& inner_;
};

static_assert(RestrictedParamBus::inParamBlock(regmap::PARAM_RISK_DATA.offset));
static_assert(RestrictedParamBus::inParamBlock(regmap::PARAM_STRAT_CRC.offset));
static_assert(!RestrictedParamBus::inParamBlock(regmap::CTRL_TRADING_EN.offset),
              "paramd must not be able to reach the CONTROL block");
static_assert(!RestrictedParamBus::inParamBlock(regmap::CTRL_KILL.offset),
              "paramd must not be able to reach the kill switch");

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_PARAM_BUS_HPP
