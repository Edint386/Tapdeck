#include "tapdeck/GainStage.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdlib>

namespace tapdeck {

// MARK: - MasterVolume

MasterVolume& MasterVolume::shared() {
    static MasterVolume instance;
    return instance;
}

std::uint64_t MasterVolume::pack(float volume, bool muted) {
    return static_cast<std::uint64_t>(std::bit_cast<std::uint32_t>(volume))
         | (muted ? std::uint64_t{1} << 32 : 0);
}

float MasterVolume::volumeOf(std::uint64_t state) {
    return std::bit_cast<float>(static_cast<std::uint32_t>(state));
}

bool MasterVolume::mutedOf(std::uint64_t state) {
    return (state >> 32) & 1;
}

float MasterVolume::volume() const {
    return volumeOf(state_.load(std::memory_order_acquire));
}

void MasterVolume::setVolume(float volume) {
    const float stored = std::max(0.0f, volume);
    auto state = state_.load(std::memory_order_relaxed);
    while (!state_.compare_exchange_weak(state, pack(stored, mutedOf(state)),
                                         std::memory_order_acq_rel, std::memory_order_relaxed)) {}
}

bool MasterVolume::isMuted() const {
    return mutedOf(state_.load(std::memory_order_acquire));
}

void MasterVolume::setMuted(bool muted) {
    auto state = state_.load(std::memory_order_relaxed);
    while (!state_.compare_exchange_weak(state, pack(volumeOf(state), muted),
                                         std::memory_order_acq_rel, std::memory_order_relaxed)) {}
}

float MasterVolume::gain() const {
    const auto state = state_.load(std::memory_order_acquire);
    return mutedOf(state) ? 0 : volumeOf(state);
}

// MARK: - GainRamp

void GainRamp::apply(Channels channels, int frameCount, float target) {
    if (frameCount <= 0) return;
    const float start = current_;
    current_ = target;

    if (start == target) {
        if (target == 1) return;
        for (float* channel : channels) {
            for (int frame = 0; frame < frameCount; ++frame) channel[frame] *= target;
        }
        return;
    }

    const float step = (target - start) / static_cast<float>(frameCount);
    for (float* channel : channels) {
        float gain = start;
        for (int frame = 0; frame < frameCount; ++frame) {
            gain += step;
            channel[frame] *= gain;
        }
    }
}

// MARK: - LookaheadLimiter

LookaheadLimiter::LookaheadLimiter(int channels, double sampleRate, double ceiling,
                                   double lookaheadSeconds, double releaseSeconds)
    : channelCount_(std::max(1, channels)),
      lookahead_(std::max(1, static_cast<int>(std::round(lookaheadSeconds * sampleRate)))),
      ceiling_(ceiling),
      release_(std::exp(-1 / (releaseSeconds * sampleRate))),
      delayLength_(lookahead_ - 1),
      delayed_(static_cast<std::size_t>(std::max(1, channelCount_ * delayLength_)), 0.0f),
      minimumIndices_(static_cast<std::size_t>(lookahead_ + 1), 0),
      minimumValues_(static_cast<std::size_t>(lookahead_ + 1), 0.0),
      averageRing_(static_cast<std::size_t>(lookahead_), 1.0),
      averageSum_(static_cast<double>(lookahead_)) {}

double LookaheadLimiter::process(Channels channels, int frameCount) {
    const int width = std::min(static_cast<int>(channels.size()), channelCount_);
    const int capacity = lookahead_ + 1;
    const float hardCeiling = static_cast<float>(ceiling_);
    double lowest = 1;

    for (int frame = 0; frame < frameCount; ++frame) {
        double peak = 0;
        for (int channel = 0; channel < width; ++channel) {
            peak = std::max(peak, static_cast<double>(std::abs(channels[channel][frame])));
        }
        const double needed = peak > ceiling_ ? ceiling_ / peak : 1;

        // Recover slowly, but never above what this sample needs.
        released_ = needed <= released_ ? needed : needed + (released_ - needed) * release_;

        // Sliding minimum over the last `lookahead` samples.
        while (dequeCount_ > 0) {
            const int back = (dequeHead_ + dequeCount_ - 1) % capacity;
            if (minimumValues_[back] >= released_) {
                dequeCount_ -= 1;
            } else {
                break;
            }
        }
        const int slot = (dequeHead_ + dequeCount_) % capacity;
        minimumIndices_[slot] = sampleIndex_;
        minimumValues_[slot] = released_;
        dequeCount_ += 1;
        if (minimumIndices_[dequeHead_] <= sampleIndex_ - lookahead_) {
            dequeHead_ = (dequeHead_ + 1) % capacity;
            dequeCount_ -= 1;
        }
        const double minimum = minimumValues_[dequeHead_];

        // Average the minimum over the same window.
        averageSum_ += minimum - averageRing_[averageIndex_];
        averageRing_[averageIndex_] = minimum;
        averageIndex_ += 1;
        if (averageIndex_ == lookahead_) {
            averageIndex_ = 0;
            // Re-add from scratch once per window so rounding never drifts.
            double exact = 0;
            for (int index = 0; index < lookahead_; ++index) exact += averageRing_[index];
            averageSum_ = exact;
        }
        const double gain = std::min(1.0, averageSum_ / static_cast<double>(lookahead_));
        if (gain < lowest) lowest = gain;

        // Swap the incoming sample for the one leaving the delay, which is the
        // sample this gain was worked out for.
        const float value = static_cast<float>(gain);
        for (int channel = 0; channel < width; ++channel) {
            const float incoming = channels[channel][frame];
            float outgoing;
            if (delayLength_ > 0) {
                const int index = channel * delayLength_ + delayIndex_;
                outgoing = delayed_[index] * value;
                delayed_[index] = incoming;
            } else {
                outgoing = incoming * value;
            }
            // Rounding can leave a sample a hair over; never let it through.
            if (outgoing > hardCeiling) {
                outgoing = hardCeiling;
            } else if (outgoing < -hardCeiling) {
                outgoing = -hardCeiling;
            }
            channels[channel][frame] = outgoing;
        }
        if (delayLength_ > 0) delayIndex_ = (delayIndex_ + 1) % delayLength_;
        sampleIndex_ += 1;
    }
    return lowest;
}

} // namespace tapdeck
