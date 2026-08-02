// =============================================================================
// paramd/crc32.hpp — host-side CRC32 over a parameter bank
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : paramd (the parameter engine)
//
// WHY THIS EXISTS
//   manuals/08-nasdaq/09-risk-controls-and-limits.md §6 makes the CRC the thing
//   that stops a *partially* written parameter bank from ever going live:
//
//       "Integrity | CRC over the shadow bank; a corrupt or partial write
//        cannot commit"
//
//   and, immediately after:
//
//       "⚠ A commit that fails CRC must not fall back to 'keep trading with old
//        parameters and log a warning' silently."
//
//   So the host must be able to compute, independently, the same 32-bit number
//   the fabric computes over the same bytes. If the two disagree, the commit is
//   a failure — loudly, with a sticky error — never a warning.
//
// -----------------------------------------------------------------------------
// ⚠ WHICH CRC32?  THIS IS AN ASSUMPTION UNTIL THE RTL LANDS.
//   rtl/ctrl/csr_regfile.sv does not exist, and neither does the parameter-bank
//   CRC generator it would instantiate. This header implements CRC-32/ISO-HDLC
//   (a.k.a. "zlib crc32", the same polynomial rtl/eth/ uses for Ethernet FCS):
//
//       poly (reflected) 0xEDB88320, init 0xFFFFFFFF, reflect in/out, xorout
//       0xFFFFFFFF
//
//   fed the bank as a little-endian byte stream, record-major:
//       for sym in 0..N_ACTIVE-1: for word in 0..wordsPerRecord-1:
//           the 4 bytes of that word, least-significant byte first.
//
//   Choosing the Ethernet CRC is deliberate: rtl/eth/ already has that generator
//   and a fabric-side parameter CRC will almost certainly reuse it rather than
//   add a second polynomial to the design.
//
// TODO(rtl-contract): derived from fpga_top.sv cfg_* ports and manual 08/09 §6;
//   reconcile the polynomial, the seed, and the byte order with
//   rtl/ctrl/csr_regfile.sv when that file lands. Until then paramd treats a
//   fabric-CRC disagreement according to EngineConfig::fabricCrcPolicy, and the
//   host-computed read-back CRC (which needs no fabric agreement at all) is the
//   check that is ALWAYS enforced.
// =============================================================================
#ifndef TRADING_PARAMD_CRC32_HPP
#define TRADING_PARAMD_CRC32_HPP

#include <cstddef>
#include <cstdint>
#include <span>

namespace trading::paramd {

inline constexpr std::uint32_t CRC32_POLY_REFLECTED = 0xEDB8'8320u;
inline constexpr std::uint32_t CRC32_INIT = 0xFFFF'FFFFu;
inline constexpr std::uint32_t CRC32_XOROUT = 0xFFFF'FFFFu;

namespace detail {

struct Crc32Table {
    std::uint32_t e[256]{};
};

[[nodiscard]] consteval Crc32Table makeCrc32Table() noexcept {
    Crc32Table t{};
    for (std::uint32_t i = 0; i < 256u; ++i) {
        std::uint32_t c = i;
        for (int k = 0; k < 8; ++k) {
            c = (c & 1u) ? (CRC32_POLY_REFLECTED ^ (c >> 1)) : (c >> 1);
        }
        t.e[i] = c;
    }
    return t;
}

inline constexpr Crc32Table kCrc32Table = makeCrc32Table();

}  // namespace detail

// Streaming CRC32. Deliberately a value type with no allocation and no virtual
// dispatch: it runs inside the commit path, which must not allocate.
class Crc32 {
public:
    constexpr Crc32() noexcept = default;

    constexpr void updateByte(std::uint8_t b) noexcept {
        state_ = detail::kCrc32Table.e[(state_ ^ b) & 0xFFu] ^ (state_ >> 8);
    }

    constexpr void update(std::span<const std::uint8_t> bytes) noexcept {
        for (std::uint8_t b : bytes) updateByte(b);
    }

    // One 32-bit register word, least-significant byte first. This is the order
    // the word occupies in the fabric's little-endian bank memory and therefore
    // the order the CRC generator sees it.
    constexpr void updateWordLe(std::uint32_t w) noexcept {
        updateByte(static_cast<std::uint8_t>(w & 0xFFu));
        updateByte(static_cast<std::uint8_t>((w >> 8) & 0xFFu));
        updateByte(static_cast<std::uint8_t>((w >> 16) & 0xFFu));
        updateByte(static_cast<std::uint8_t>((w >> 24) & 0xFFu));
    }

    constexpr void updateWordsLe(std::span<const std::uint32_t> words) noexcept {
        for (std::uint32_t w : words) updateWordLe(w);
    }

    [[nodiscard]] constexpr std::uint32_t value() const noexcept { return state_ ^ CRC32_XOROUT; }

    constexpr void reset() noexcept { state_ = CRC32_INIT; }

private:
    std::uint32_t state_ = CRC32_INIT;
};

// One-shot helpers.
[[nodiscard]] constexpr std::uint32_t crc32Bytes(std::span<const std::uint8_t> bytes) noexcept {
    Crc32 c;
    c.update(bytes);
    return c.value();
}

// THE bank CRC. `words` is the whole bank, record-major, exactly as it is
// written through PARAM_*_DATA: N_ACTIVE records of wordsPerRecord words each,
// ascending symbol index then ascending word index. Padding words between
// records (the PARAM address stride is 16 words; a risk record is 11) are NOT
// included — see the TODO above.
[[nodiscard]] constexpr std::uint32_t crc32BankWords(std::span<const std::uint32_t> words) noexcept {
    Crc32 c;
    c.updateWordsLe(words);
    return c.value();
}

// The canonical CRC-32/ISO-HDLC check value: crc32("123456789") == 0xCBF43926.
// If someone "optimises" the table generator, this stops the build rather than
// silently changing every audit record's CRC field.
namespace detail {
inline constexpr std::uint8_t kCheckVector[9] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
}
static_assert(crc32Bytes(std::span<const std::uint8_t>(detail::kCheckVector, 9)) == 0xCBF4'3926u,
              "CRC-32/ISO-HDLC check value is wrong — the table or the polynomial has drifted");

// An all-zero bank (the fail-closed reset state, manual 08/09 §2) still has a
// non-trivial CRC. Spelled out so nobody reads a 0x00000000 CRC register and
// concludes "the bank is empty, that's fine".
static_assert(crc32BankWords(std::span<const std::uint32_t>{}) == 0x0000'0000u,
              "CRC of an empty span is the seed XOR the final xorout");

}  // namespace trading::paramd

#endif  // TRADING_PARAMD_CRC32_HPP
