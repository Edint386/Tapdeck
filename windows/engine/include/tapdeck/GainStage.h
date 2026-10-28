// Gain stages: the master volume, gain ramps and the output limiter.
//
// Ported from Sources/Engine/GainStage.swift. Behaviour and arithmetic follow the
// Swift code line by line, so that windows/vectors can check one against the
// other; see windows/PARITY.md for what differs and why.

#pragma once

#include <atomic>
#include <cstdint>
#include <span>
#include <vector>

namespace tapdeck {

/// The planar channels of one block, as a render callback hands them over: one
/// pointer per channel, non-interleaved float.
using Channels = std::span<float* const>;

/// App-wide volume, applied last on every output of every mix.
///
/// Every running mix reads it from its own real-time thread. The macOS version
/// keeps it behind an unfair lock; here volume and mute share one atomic word,
/// so a reader always sees a matching pair and never waits.
class MasterVolume {
public:
    static MasterVolume& shared();

    float volume() const;
    /// Negative values are stored as 0.
    void setVolume(float volume);

    bool isMuted() const;
    void setMuted(bool muted);

    /// The multiplier to apply right now.
    float gain() const;

private:
    static std::uint64_t pack(float volume, bool muted);
    static float volumeOf(std::uint64_t state);
    static bool mutedOf(std::uint64_t state);

    std::atomic<std::uint64_t> state_{pack(1, false)};
};

/// Applies a gain that may change from one block to the next.
///
/// Jumping straight to a new gain at a block boundary puts a step in the
/// waveform, which is heard as a click or "zipper" noise while a slider moves.
/// The change is spread linearly across the block instead.
class GainRamp {
public:
    explicit GainRamp(float initial = 1) : current_(initial) {}

    float current() const { return current_; }

    /// Multiply every channel by a gain moving from the previous block's value
    /// to `target`. An empty block changes nothing, not even the current gain.
    void apply(Channels channels, int frameCount, float target);

    /// Jump without ramping, for when playback restarts from silence.
    void reset(float value) { current_ = value; }

private:
    float current_;
};

/// The last stage of every output: keeps it under the ceiling without cutting
/// samples off.
///
/// Anything over full scale used to be clipped, which is heard as harsh
/// distortion even at low listening levels, because the device's own volume
/// turns the damaged signal down afterwards. This limiter looks a little ahead
/// instead and lowers the gain smoothly before a peak arrives.
///
/// The gain for each sample is the lowest gain any sample needs within the
/// look-ahead window, then averaged over the same window. Averaging only values
/// at or below what a sample needs cannot exceed it, so the ceiling holds
/// exactly, and the average turns the step into a ramp. The signal is delayed by
/// the window length less one sample to line up with its gain.
class LookaheadLimiter {
public:
    /// - ceiling: linear amplitude no sample may exceed.
    /// - lookaheadSeconds: how far ahead peaks are seen, and how long the gain
    ///   takes to come down.
    /// - releaseSeconds: time constant for the gain to recover.
    LookaheadLimiter(int channels, double sampleRate, double ceiling,
                     double lookaheadSeconds = 0.002, double releaseSeconds = 0.1);

    int channelCount() const { return channelCount_; }
    int lookahead() const { return lookahead_; }

    /// Samples of delay this stage adds.
    int latencyFrames() const { return delayLength_; }

    /// Limit the channels in place and return the lowest gain applied, for
    /// showing when the limiter works. Runs on a real-time thread: no
    /// allocation, no locks. Channels beyond the limiter's own count are left
    /// as they are.
    double process(Channels channels, int frameCount);

private:
    int channelCount_;
    int lookahead_;
    double ceiling_;
    double release_;

    // The signal is held back by this many samples, one less than the window.
    int delayLength_;
    std::vector<float> delayed_;
    int delayIndex_ = 0;

    // Sliding minimum over the window: a deque of (index, gain), increasing.
    std::vector<std::int64_t> minimumIndices_;
    std::vector<double> minimumValues_;
    int dequeHead_ = 0;
    int dequeCount_ = 0;

    // Moving average of the sliding minimum.
    std::vector<double> averageRing_;
    int averageIndex_ = 0;
    double averageSum_;

    double released_ = 1;
    std::int64_t sampleIndex_ = 0;
};

} // namespace tapdeck
