// =============================================================================
// expected.hpp — error-return vocabulary type for the slow path
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : device layer (agent 1). Included by every other host component.
//
// WHY THIS EXISTS
//   host/README.md §3 and CLAUDE.md forbid exceptions on control paths. A throw
//   crossing the control daemon is unbounded in time and, worse, unbounded in
//   *state*: an exception unwinding out of the middle of the startup sequence
//   leaves the fabric half-configured with no record of how far it got. Every
//   fallible operation therefore returns a value that the caller must inspect.
//
//   `std::expected` is C++23. This project targets C++20, so this header aliases
//   `std::expected` when the standard library has it and otherwise provides a
//   minimal, conforming-enough subset. Client code always spells it
//   `trading::expected<T, E>` and never `std::expected`, so the fallback is
//   invisible and the migration is a one-line change here.
//
// USAGE
//     trading::expected<std::uint32_t, DeviceError> v = dev.read32(off);
//     if (!v) return trading::fail(v.error());
//     use(*v);
//
//   Always construct failures with `trading::fail(e)` rather than naming
//   `unexpected<E>` directly — CTAD through alias templates (P1814R0) is not
//   available on every C++20 toolchain we care about.
// =============================================================================
#ifndef TRADING_EXPECTED_HPP
#define TRADING_EXPECTED_HPP

#include <initializer_list>
#include <new>
#include <type_traits>
#include <utility>
#include <version>

#if defined(__cpp_lib_expected) && (__cpp_lib_expected >= 202202L)
#define TRADING_HAS_STD_EXPECTED 1
#include <expected>
#else
#define TRADING_HAS_STD_EXPECTED 0
#endif

namespace trading {

#if TRADING_HAS_STD_EXPECTED

template <class T, class E>
using expected = std::expected<T, E>;

template <class E>
using unexpected = std::unexpected<E>;

using std::unexpect;
using std::unexpect_t;

#else  // ---------------------------------------------------------------------
// Minimal std::expected-alike. Deliberately small: it supports exactly the
// operations the host code uses. It is NOT a drop-in for every std::expected
// feature (no monadic and_then/transform, no in-place-with-initializer-list
// forwarding beyond the single-arg case). If you find yourself needing more,
// raise the toolchain requirement to C++23 and delete this block rather than
// growing it — a partial reimplementation of a standard type is a liability.

struct unexpect_t {
    explicit unexpect_t() = default;
};
inline constexpr unexpect_t unexpect{};

template <class E>
class unexpected {
public:
    constexpr explicit unexpected(const E& e) : err_(e) {}
    constexpr explicit unexpected(E&& e) : err_(std::move(e)) {}

    constexpr const E& error() const& noexcept { return err_; }
    constexpr E& error() & noexcept { return err_; }
    constexpr E&& error() && noexcept { return std::move(err_); }

private:
    E err_;
};

template <class E>
unexpected(E) -> unexpected<E>;

// -----------------------------------------------------------------------------
// Primary template
// -----------------------------------------------------------------------------
template <class T, class E>
class expected {
    static_assert(!std::is_reference_v<T>, "expected<T&,E> is not supported");
    static_assert(!std::is_void_v<E>, "E may not be void");

public:
    using value_type = T;
    using error_type = E;

    constexpr expected() noexcept(std::is_nothrow_default_constructible_v<T>)
        : has_(true) {
        ::new (static_cast<void*>(std::addressof(storage_.val))) T();
    }

    constexpr expected(const T& v) : has_(true) {
        ::new (static_cast<void*>(std::addressof(storage_.val))) T(v);
    }
    constexpr expected(T&& v) : has_(true) {
        ::new (static_cast<void*>(std::addressof(storage_.val))) T(std::move(v));
    }

    constexpr expected(const unexpected<E>& u) : has_(false) {
        ::new (static_cast<void*>(std::addressof(storage_.err))) E(u.error());
    }
    constexpr expected(unexpected<E>&& u) : has_(false) {
        ::new (static_cast<void*>(std::addressof(storage_.err))) E(std::move(u).error());
    }

    template <class... Args>
    constexpr explicit expected(unexpect_t, Args&&... args) : has_(false) {
        ::new (static_cast<void*>(std::addressof(storage_.err))) E(std::forward<Args>(args)...);
    }

    expected(const expected& o) : has_(o.has_) {
        if (has_) {
            ::new (static_cast<void*>(std::addressof(storage_.val))) T(o.storage_.val);
        } else {
            ::new (static_cast<void*>(std::addressof(storage_.err))) E(o.storage_.err);
        }
    }

    expected(expected&& o) noexcept(std::is_nothrow_move_constructible_v<T> &&
                                    std::is_nothrow_move_constructible_v<E>)
        : has_(o.has_) {
        if (has_) {
            ::new (static_cast<void*>(std::addressof(storage_.val))) T(std::move(o.storage_.val));
        } else {
            ::new (static_cast<void*>(std::addressof(storage_.err))) E(std::move(o.storage_.err));
        }
    }

    expected& operator=(const expected& o) {
        if (this != &o) {
            expected tmp(o);
            swapWith(tmp);
        }
        return *this;
    }

    expected& operator=(expected&& o) noexcept(
        std::is_nothrow_move_constructible_v<T> && std::is_nothrow_move_constructible_v<E>) {
        if (this != &o) {
            destroy();
            has_ = o.has_;
            if (has_) {
                ::new (static_cast<void*>(std::addressof(storage_.val))) T(std::move(o.storage_.val));
            } else {
                ::new (static_cast<void*>(std::addressof(storage_.err))) E(std::move(o.storage_.err));
            }
        }
        return *this;
    }

    ~expected() { destroy(); }

    constexpr bool has_value() const noexcept { return has_; }
    constexpr explicit operator bool() const noexcept { return has_; }

    constexpr T& operator*() & noexcept { return storage_.val; }
    constexpr const T& operator*() const& noexcept { return storage_.val; }
    constexpr T&& operator*() && noexcept { return std::move(storage_.val); }

    constexpr T* operator->() noexcept { return std::addressof(storage_.val); }
    constexpr const T* operator->() const noexcept { return std::addressof(storage_.val); }

    // NOTE: unlike std::expected, value() does NOT throw on a valueless object —
    // this project builds with -fno-exceptions on the control path. Calling
    // value() without checking has_value() is undefined; check first.
    constexpr T& value() & noexcept { return storage_.val; }
    constexpr const T& value() const& noexcept { return storage_.val; }
    constexpr T&& value() && noexcept { return std::move(storage_.val); }

    constexpr E& error() & noexcept { return storage_.err; }
    constexpr const E& error() const& noexcept { return storage_.err; }
    constexpr E&& error() && noexcept { return std::move(storage_.err); }

    template <class U>
    constexpr T value_or(U&& fallback) const& {
        return has_ ? storage_.val : static_cast<T>(std::forward<U>(fallback));
    }
    template <class U>
    constexpr T value_or(U&& fallback) && {
        return has_ ? std::move(storage_.val) : static_cast<T>(std::forward<U>(fallback));
    }

private:
    void destroy() noexcept {
        if (has_) {
            storage_.val.~T();
        } else {
            storage_.err.~E();
        }
    }

    void swapWith(expected& o) noexcept {
        expected tmp(std::move(o));
        o = std::move(*this);
        destroy();
        has_ = tmp.has_;
        if (has_) {
            ::new (static_cast<void*>(std::addressof(storage_.val))) T(std::move(tmp.storage_.val));
        } else {
            ::new (static_cast<void*>(std::addressof(storage_.err))) E(std::move(tmp.storage_.err));
        }
    }

    union Storage {
        Storage() {}
        ~Storage() {}
        T val;
        E err;
    } storage_;
    bool has_;
};

// -----------------------------------------------------------------------------
// void specialisation — the common case for "did this side effect succeed"
// -----------------------------------------------------------------------------
template <class E>
class expected<void, E> {
public:
    using value_type = void;
    using error_type = E;

    constexpr expected() noexcept : has_(true) {}

    constexpr expected(const unexpected<E>& u) : has_(false) {
        ::new (static_cast<void*>(std::addressof(err_))) E(u.error());
    }
    constexpr expected(unexpected<E>&& u) : has_(false) {
        ::new (static_cast<void*>(std::addressof(err_))) E(std::move(u).error());
    }

    template <class... Args>
    constexpr explicit expected(unexpect_t, Args&&... args) : has_(false) {
        ::new (static_cast<void*>(std::addressof(err_))) E(std::forward<Args>(args)...);
    }

    expected(const expected& o) : has_(o.has_) {
        if (!has_) ::new (static_cast<void*>(std::addressof(err_))) E(o.err_);
    }
    expected(expected&& o) noexcept(std::is_nothrow_move_constructible_v<E>) : has_(o.has_) {
        if (!has_) ::new (static_cast<void*>(std::addressof(err_))) E(std::move(o.err_));
    }

    expected& operator=(const expected& o) {
        if (this != &o) {
            if (!has_) err_.~E();
            has_ = o.has_;
            if (!has_) ::new (static_cast<void*>(std::addressof(err_))) E(o.err_);
        }
        return *this;
    }
    expected& operator=(expected&& o) noexcept(std::is_nothrow_move_constructible_v<E>) {
        if (this != &o) {
            if (!has_) err_.~E();
            has_ = o.has_;
            if (!has_) ::new (static_cast<void*>(std::addressof(err_))) E(std::move(o.err_));
        }
        return *this;
    }

    ~expected() {
        if (!has_) err_.~E();
    }

    constexpr bool has_value() const noexcept { return has_; }
    constexpr explicit operator bool() const noexcept { return has_; }
    constexpr void value() const noexcept {}

    constexpr E& error() & noexcept { return err_; }
    constexpr const E& error() const& noexcept { return err_; }
    constexpr E&& error() && noexcept { return std::move(err_); }

private:
    union {
        char dummy_;
        E err_;
    };
    bool has_;
};

#endif  // TRADING_HAS_STD_EXPECTED

// -----------------------------------------------------------------------------
// fail() — the ONLY sanctioned way to build a failure return.
// Works identically on both the std and fallback paths, and does not depend on
// CTAD-through-alias-template support.
// -----------------------------------------------------------------------------
template <class E>
[[nodiscard]] constexpr auto fail(E e) noexcept {
#if TRADING_HAS_STD_EXPECTED
    return std::unexpected<E>(std::move(e));
#else
    return unexpected<E>(std::move(e));
#endif
}

// -----------------------------------------------------------------------------
// TRADING_TRY / TRADING_TRY_VOID — early-return propagation without exceptions.
//
//   TRADING_TRY(auto gen, dev.read32(regmap::PARAM_RISK_GEN.offset));
//   TRADING_TRY_VOID(dev.writeVerify(regmap::CTRL_WDOG_BLOCK_MS.offset, 250));
//
// Uses a statement expression-free formulation so it works on MSVC too. The
// hidden temporary is uniquely named per line to allow several in one scope.
// -----------------------------------------------------------------------------
#define TRADING_DETAIL_CAT2(a, b) a##b
#define TRADING_DETAIL_CAT(a, b) TRADING_DETAIL_CAT2(a, b)

#define TRADING_TRY(decl, expr)                                       \
    auto TRADING_DETAIL_CAT(trading_try_, __LINE__) = (expr);         \
    if (!TRADING_DETAIL_CAT(trading_try_, __LINE__)) {                \
        return ::trading::fail(TRADING_DETAIL_CAT(trading_try_, __LINE__).error()); \
    }                                                                 \
    decl = std::move(*TRADING_DETAIL_CAT(trading_try_, __LINE__))

#define TRADING_TRY_VOID(expr)                                        \
    do {                                                              \
        auto TRADING_DETAIL_CAT(trading_tryv_, __LINE__) = (expr);    \
        if (!TRADING_DETAIL_CAT(trading_tryv_, __LINE__)) {           \
            return ::trading::fail(TRADING_DETAIL_CAT(trading_tryv_, __LINE__).error()); \
        }                                                             \
    } while (false)

}  // namespace trading

#endif  // TRADING_EXPECTED_HPP
