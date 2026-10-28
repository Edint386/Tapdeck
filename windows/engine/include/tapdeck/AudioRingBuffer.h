// A ring buffer between one source's clock and the output's.
//
// The design of Sources/Engine/AudioRingBuffer.swift, rewritten without a lock:
// one thread writes, one thread reads, and neither ever waits for the other.
// See windows/PARITY.md for how overflow differs.

#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <span>

#include "tapdeck/GainStage.h"

namespace tapdeck {

/// The planar channels a writer hands over.
using ConstChannels = std::span<const float* const>;

/// Every mixer source runs on its own clock — a process loopback stream, a
/// microphone — and none of them line up with the output callback in period or
/// phase. This sits between them and absorbs the difference.
///
/// Reading starts only once a cushion of frames has gathered, because matching
/// rates still leaves phases unmatched: reading without a cushion keeps the
/// buffer near empty, and every small wobble punches a gap in the waveform. On
/// underflow the reader gets silence and the cushion is rebuilt; on overflow the
/// oldest frames are dropped. Latency that keeps growing sounds worse than an
/// occasional gap, which is why it drops rather than stretches.
///
/// Threads: `write` and `writeMapped` from one writer thread; `mixInto` from one
/// reader thread; `setPrimeFrames`, `availableFrames`, `takePeak`, `underruns`
/// and `overruns` from any thread; `clear` only while neither side runs.
class AudioRingBuffer {
public:
    AudioRingBuffer(int channels, int capacityFrames = 16384, int primeFrames = 2048);

    int channelCount() const { return channelCount_; }
    int capacityFrames() const { return capacityFrames_; }

    /// Change the cushion. Takes effect the next time the buffer primes, so it
    /// is applied when a mix starts rather than mid-stream.
    void setPrimeFrames(int frames);

    // MARK: Writing (one writer thread)

    /// Write planar samples; channels the source does not have are written as
    /// silence. Used to fan a finished mix out to other outputs and to the
    /// recorder.
    void write(ConstChannels source, int frameCount);

    /// Write a buffer that arrived from a source: a mono source fans out to
    /// every channel, and a wider or narrower one maps from its first channels,
    /// repeating its last channel when the buffer is wider.
    void writeMapped(ConstChannels source, int frameCount);

    // MARK: Reading (one reader thread)

    /// Add into the output buffer. The mixer calls this once per source.
    /// Whatever is not yet buffered contributes nothing, leaving silence.
    ///
    /// `channelOffset` is the output channel this source's first channel lands
    /// on. That is what lets several sources share one multichannel device
    /// without being mixed together — a microphone on channels 1–2 and system
    /// audio on 3–4, say. Channels that fall outside the destination are
    /// skipped.
    ///
    /// A gain of zero still consumes the frames, so latency does not pile up
    /// behind a muted source.
    void mixInto(Channels destination, int frameCount, float gain, int channelOffset = 0);

    // MARK: Any thread

    /// Frames buffered right now, as a rough measure of latency.
    int availableFrames() const;

    /// The peak written since the last call, reset to zero.
    float takePeak();

    /// How often reading ran dry. If this climbs, raise the cushion.
    int underruns() const { return underruns_.load(std::memory_order_relaxed); }

    /// How often unread frames were dropped because the writer got too far
    /// ahead. Causes phase jumps while the amplitude still looks correct.
    int overruns() const { return overruns_.load(std::memory_order_relaxed); }

    // MARK: Neither side running

    void clear();

private:
    template <typename SourceChannel>
    void store(int frameCount, SourceChannel sourceChannel);
    void consume(int frameCount);
    void raisePeak(float peak);

    const int channelCount_;
    const int capacityFrames_;

    // Channel-major: channel * capacity + slot. Relaxed atomics, so that when
    // an overflowing writer laps the reader the two touch the same frame
    // without undefined behaviour; on x64 and arm64 they are plain loads and
    // stores. The counters below order the frames between the threads.
    std::unique_ptr<std::atomic<float>[]> storage_;

    // Frames written and read since the start, never wrapping in practice. The
    // writer owns writeCount_ and the reader owns readCount_; each publishes
    // its own with release and reads the other's with acquire.
    std::atomic<std::uint64_t> writeCount_{0};
    std::atomic<std::uint64_t> readCount_{0};

    // Where the writer is about to write up to, announced before it stores a
    // block. A read that overlapped a block still being stored checks this,
    // not writeCount_, to know whether it may have read newer frames.
    std::atomic<std::uint64_t> writeEnd_{0};

    std::atomic<int> primeFrames_;
    std::atomic<bool> unprimeRequested_{false};
    bool isPrimed_ = false; // reader only

    std::atomic<float> recentPeak_{0};
    std::atomic<int> underruns_{0};
    std::atomic<int> overruns_{0};
};

} // namespace tapdeck
