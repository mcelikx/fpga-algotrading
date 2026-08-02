// =============================================================================
// seqlock.hpp — single-writer / many-reader snapshot publication
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/heartbeat  (heartbeat + watchdog)
//
// WHY THIS EXISTS
//   The heartbeat thread is a SCHED_FIFO thread on an isolated core whose only
//   job is to hit a deadline. metricsd must be able to read its statistics
//   without ever making that thread wait: a mutex here means a metrics scrape
//   can, in principle, delay a heartbeat write, and a delayed heartbeat write
//   is a step towards the fabric killing the session. So the publication path
//   is wait-free for the writer and lock-free (bounded-retry) for the reader.
//
//   This is the host-side analogue of the snapshot bank in
//   manuals/06-operations/03-monitoring-and-telemetry.md §5/§9: the writer
//   latches a whole consistent set in one go, the reader reads only the latched
//   copy, and a torn read is DETECTED rather than silently believed. §9 lists
//   "non-atomic multi-word reads" as one of the ways counter monitoring lies to
//   you; this type is the answer to that hazard on the host side.
//
// ⚠ ONE WRITER. Calling publish() from two threads corrupts the sequence
//   number and silently defeats the tear detection. The heartbeat thread is the
//   only writer, structurally: HeartbeatThread owns the SeqLocked members
//   privately and only its loop body touches them.
//
// MEMORY MODEL NOTE (read before "fixing" this)
//   This is the classical seqlock formulation: an odd sequence number marks a
//   write in progress, release/acquire fences order the payload against the
//   sequence number, and the reader retries until it sees the same even number
//   twice. The payload copy uses std::memcpy rather than per-field atomics.
//   That is technically a data race in the C++ abstract machine, and it is the
//   universally deployed formulation on x86-64 and aarch64, where the fences
//   compile to exactly the required barriers. The bounded retry means a reader
//   can never spin forever behind a descheduled writer; it returns the last
//   coherent value it managed to get and reports `torn = true` instead. A
//   metrics scrape that reports "I could not get a coherent snapshot" is
//   correct behaviour; one that reports a half-updated struct is not.
// =============================================================================
#ifndef TRADING_HEARTBEAT_SEQLOCK_HPP
#define TRADING_HEARTBEAT_SEQLOCK_HPP

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace trading::heartbeat {

// Conservative cache-line size. std::hardware_destructive_interference_size is
// not reliably available across the toolchains this project targets, and using
// it inconsistently across translation units is an ODR hazard. 64 is correct
// for every x86-64 and aarch64 part this will run on.
inline constexpr std::size_t kCacheLine = 64;

// How many times a reader retries before giving up and reporting a torn read.
// Sized so that a reader only fails if the writer was preempted mid-publish,
// which on an isolated SCHED_FIFO core is itself the alertable condition.
inline constexpr unsigned kSeqLockMaxRetries = 64;

template <class T>
class SeqLocked {
    static_assert(std::is_trivially_copyable_v<T>,
                  "SeqLocked<T> publishes T by memcpy; T must be trivially copyable");

public:
    SeqLocked() noexcept = default;

    // ── writer side. HEARTBEAT THREAD ONLY. Wait-free. ──────────────────────
    void publish(const T& v) noexcept {
        const std::uint32_t s = seq_.load(std::memory_order_relaxed);
        seq_.store(s + 1, std::memory_order_relaxed);  // odd: write in progress
        std::atomic_thread_fence(std::memory_order_release);
        std::memcpy(&value_, &v, sizeof(T));
        std::atomic_thread_fence(std::memory_order_release);
        seq_.store(s + 2, std::memory_order_relaxed);  // even: coherent again
    }

    // ── reader side. Any thread. Bounded retry, never blocks the writer. ────
    // `torn` (optional out-param) is set true if no coherent snapshot could be
    // obtained within kSeqLockMaxRetries; the returned value is then whatever
    // was last read and MUST NOT be trusted field-by-field.
    [[nodiscard]] T read(bool* torn = nullptr) const noexcept {
        T out{};
        for (unsigned attempt = 0; attempt < kSeqLockMaxRetries; ++attempt) {
            const std::uint32_t s1 = seq_.load(std::memory_order_acquire);
            if ((s1 & 1u) != 0u) continue;  // writer mid-publish
            std::memcpy(&out, &value_, sizeof(T));
            std::atomic_thread_fence(std::memory_order_acquire);
            const std::uint32_t s2 = seq_.load(std::memory_order_relaxed);
            if (s1 == s2) {
                if (torn != nullptr) *torn = false;
                return out;
            }
        }
        if (torn != nullptr) *torn = true;
        return out;
    }

    // Number of completed publications. Useful on its own: if this stops
    // advancing, the heartbeat thread has stopped ticking, which is exactly the
    // condition the fabric watchdog is about to act on.
    [[nodiscard]] std::uint64_t generation() const noexcept {
        return seq_.load(std::memory_order_relaxed) / 2u;
    }

private:
    alignas(kCacheLine) mutable std::atomic<std::uint32_t> seq_{0};
    alignas(kCacheLine) T value_{};
};

}  // namespace trading::heartbeat

#endif  // TRADING_HEARTBEAT_SEQLOCK_HPP
