// =============================================================================
// jitter_hist.hpp — bucketed latency histogram for the heartbeat thread
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Owner   : host/src/heartbeat  (heartbeat + watchdog)
// Mirrors : the BUCKETING SHAPE of rtl/telemetry/latency_hist.sv, as specified
//           in manuals/06-operations/03-monitoring-and-telemetry.md §3 and
//           repeated in host/include/trading/regmap.hpp §8.
//           ⚠ It mirrors the SHAPE, not a hardware register: these are host
//           software measurements, so there is no packed-struct static_assert
//           to make here. The size assertions that do apply are on Snapshot,
//           below, because metricsd copies it.
//
// WHY A HISTOGRAM AND NOT A MEAN
//   CLAUDE.md §5.8: determinism over average speed, report p50/p99/p99.9/max,
//   never just the mean. That rule was written for the fast path and it applies
//   just as hard here. The mean wake-up jitter of this thread is uninteresting;
//   the question that matters is "how bad does it get", because a single 60 ms
//   stall is a hardware kill and a thousand perfect ticks do not compensate for
//   it. So: full distribution, plus an exact max and an exact sum, exactly like
//   latency_hist.sv keeps max_cycles and sum_cycles alongside its buckets.
//
// TWO INSTANCES ARE KEPT BY THE HEARTBEAT THREAD, AND THEY ANSWER DIFFERENT
// QUESTIONS:
//   wakeJitter   — (actual wake time - intended absolute deadline). Measures
//                  the OS: preemption, C-state exit, an interrupt landing on
//                  the isolated core, a page fault. This is the number that
//                  predicts a watchdog kill.
//   writeLatency — (MMIO write returned - MMIO write issued). Measures the
//                  PCIe path and the card. A posted 32-bit BAR write should be
//                  hundreds of nanoseconds; if this starts climbing, the root
//                  port or the card is in trouble and the heartbeat is only the
//                  first symptom.
//
// BUCKETING (identical shape to regmap::histBucketUpperCycles, different unit)
//   32 buckets. Linear below 16 * 50 us = 800 us at 50 us per bucket, then
//   doubling, top bucket saturates:
//       k <  16 : upper edge = (k+1) * 50 us
//       k >= 16 : upper edge = 800 us << (k - 16 + 1)
//   The linear region is where a correctly configured isolated SCHED_FIFO core
//   lives (tens of microseconds); the log region exists to characterise the
//   failures, not to resolve them precisely. A sample in bucket 20 or above is
//   already an incident.
// =============================================================================
#ifndef TRADING_HEARTBEAT_JITTER_HIST_HPP
#define TRADING_HEARTBEAT_JITTER_HIST_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "trading/heartbeat/seqlock.hpp"

namespace trading::heartbeat {

inline constexpr std::size_t kJitterBuckets = 32;
inline constexpr std::size_t kJitterLinearBuckets = kJitterBuckets / 2;      // 16
inline constexpr std::uint64_t kJitterLinearStepNs = 50'000;                // 50 us
inline constexpr std::uint64_t kJitterLinearMaxNs =
    kJitterLinearBuckets * kJitterLinearStepNs;                             // 800 us

// Upper edge of bucket k, in nanoseconds. Integer arithmetic only — CLAUDE.md
// §5.3 and host/README.md: no floating point anywhere near a measurement that
// feeds an operational decision. The top bucket saturates and is reported as
// "everything above", never as a number.
[[nodiscard]] constexpr std::uint64_t jitterBucketUpperNs(std::size_t k) noexcept {
    if (k < kJitterLinearBuckets) {
        return static_cast<std::uint64_t>(k + 1) * kJitterLinearStepNs;
    }
    const std::size_t over = k - kJitterLinearBuckets;
    if (over >= 40) return ~std::uint64_t{0};
    return kJitterLinearMaxNs << (over + 1);
}
static_assert(jitterBucketUpperNs(0) == 50'000);
static_assert(jitterBucketUpperNs(15) == 800'000);
static_assert(jitterBucketUpperNs(16) == 1'600'000);

[[nodiscard]] constexpr std::size_t jitterBucketOf(std::uint64_t ns) noexcept {
    if (ns < kJitterLinearMaxNs) {
        return static_cast<std::size_t>(ns / kJitterLinearStepNs);
    }
    std::size_t k = kJitterLinearBuckets;
    while (k + 1 < kJitterBuckets && ns >= jitterBucketUpperNs(k)) ++k;
    return k;  // saturating top bucket
}
static_assert(jitterBucketOf(0) == 0);
static_assert(jitterBucketOf(49'999) == 0);
static_assert(jitterBucketOf(50'000) == 1);
static_assert(jitterBucketOf(799'999) == 15);
static_assert(jitterBucketOf(800'000) == 16);
static_assert(jitterBucketOf(~std::uint64_t{0}) == kJitterBuckets - 1);

// -----------------------------------------------------------------------------
// The published snapshot. Trivially copyable so it can go through SeqLocked,
// and POD so metricsd can memcpy it into an export buffer without touching the
// heartbeat thread.
// -----------------------------------------------------------------------------
struct JitterSnapshot {
    std::array<std::uint64_t, kJitterBuckets> bucket{};
    std::uint64_t count = 0;          // samples recorded (late or on time)
    std::uint64_t earlyCount = 0;     // woke BEFORE the deadline; see record()
    std::uint64_t sumNs = 0;          // exact sum -> exact mean, no bucket midpoints
    std::uint64_t maxNs = 0;          // exact max. THE number that matters.
    std::uint64_t minNs = 0;          // exact min (valid only when count > 0)
    std::uint64_t saturatedCount = 0; // landed in the saturating top bucket ⚠

    [[nodiscard]] constexpr std::uint64_t meanNs() const noexcept {
        return count == 0 ? 0 : sumNs / count;
    }
    // Count of samples at or above `ns`. Cheap enough for an export path and
    // exact at the bucket boundaries, which is all an alert threshold needs.
    [[nodiscard]] constexpr std::uint64_t countAtOrAboveNs(std::uint64_t ns) const noexcept {
        std::uint64_t n = 0;
        for (std::size_t k = 0; k < kJitterBuckets; ++k) {
            if (jitterBucketUpperNs(k) > ns) n += bucket[k];
        }
        return n;
    }
};

static_assert(sizeof(JitterSnapshot) == kJitterBuckets * 8 + 6 * 8,
              "JitterSnapshot gained padding or a field; metricsd copies this "
              "struct by value and its size is part of that contract");
static_assert(std::is_trivially_copyable_v<JitterSnapshot>);

// -----------------------------------------------------------------------------
// The histogram itself.
//
// ⚠ record() is called from the heartbeat thread ONLY, once per tick, on the
//   deadline path. It must therefore be allocation-free, branch-light and
//   non-blocking: it is an array increment and a publish. It is deliberately
//   NOT clearable at runtime — manual 06/03 §3 notes that clearing a histogram
//   loses in-flight samples, and a heartbeat histogram that an operator can
//   zero is a heartbeat histogram that hides last night's 80 ms stall. Read it
//   and difference it host-side, exactly as the fabric histograms are handled.
// -----------------------------------------------------------------------------
class JitterHistogram {
public:
    // `lateNs` is (actual - intended). Negative means the thread woke EARLY,
    // which clock_nanosleep(TIMER_ABSTIME) does not normally do; it is counted
    // separately rather than folded in as zero, because a non-zero earlyCount
    // means CLOCK_MONOTONIC stepped or the measurement is wrong, and either of
    // those invalidates every other number in this histogram.
    void record(std::int64_t lateNs) noexcept {
        if (lateNs < 0) {
            ++shadow_.earlyCount;
            publish();
            return;
        }
        const std::uint64_t ns = static_cast<std::uint64_t>(lateNs);
        const std::size_t k = jitterBucketOf(ns);
        ++shadow_.bucket[k];
        if (k == kJitterBuckets - 1) ++shadow_.saturatedCount;
        if (shadow_.count == 0 || ns < shadow_.minNs) shadow_.minNs = ns;
        if (ns > shadow_.maxNs) shadow_.maxNs = ns;
        shadow_.sumNs += ns;
        ++shadow_.count;
        publish();
    }

    [[nodiscard]] JitterSnapshot read(bool* torn = nullptr) const noexcept {
        return pub_.read(torn);
    }

private:
    void publish() noexcept { pub_.publish(shadow_); }

    // Writer-private working copy. Only the heartbeat thread touches it, so it
    // needs no synchronisation of its own; `pub_` is what crosses threads.
    JitterSnapshot shadow_{};
    SeqLocked<JitterSnapshot> pub_{};
};

}  // namespace trading::heartbeat

#endif  // TRADING_HEARTBEAT_JITTER_HIST_HPP
