#include "tapdeck/AudioRingBuffer.h"

#include <algorithm>
#include <cmath>

namespace tapdeck {

AudioRingBuffer::AudioRingBuffer(int channels, int capacityFrames, int primeFrames)
    : channelCount_(std::max(1, channels)),
      capacityFrames_(std::max(512, capacityFrames)),
      storage_(std::make_unique<std::atomic<float>[]>(static_cast<std::size_t>(channelCount_)
                                                      * static_cast<std::size_t>(capacityFrames_))),
      primeFrames_(std::clamp(primeFrames, 0, capacityFrames_ / 2)) {}

void AudioRingBuffer::setPrimeFrames(int frames) {
    primeFrames_.store(std::clamp(frames, 0, capacityFrames_ / 2), std::memory_order_relaxed);
    unprimeRequested_.store(true, std::memory_order_release);
}

// MARK: - Writing

template <typename SourceChannel>
void AudioRingBuffer::store(int frameCount, SourceChannel sourceChannel) {
    const auto written = writeCount_.load(std::memory_order_relaxed);
    // A block longer than the buffer leaves only its newest frames, as on
    // macOS; the skipped frames still count as written, so the reader sees the
    // overflow.
    const int skipped = std::max(0, frameCount - capacityFrames_);
    const int first = static_cast<int>((written + static_cast<std::uint64_t>(skipped))
                                       % static_cast<std::uint64_t>(capacityFrames_));

    // Announce the block before storing it. A reader that sees any of the
    // frames below also sees this announcement after its acquire fence.
    writeEnd_.store(written + static_cast<std::uint64_t>(frameCount), std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);

    float peak = 0;
    for (int channel = 0; channel < channelCount_; ++channel) {
        const float* input = sourceChannel(channel);
        std::atomic<float>* base = storage_.get() + static_cast<std::size_t>(channel) * capacityFrames_;
        int slot = first;
        for (int frame = skipped; frame < frameCount; ++frame) {
            const float value = input ? input[frame] : 0.0f;
            base[slot].store(value, std::memory_order_relaxed);
            peak = std::max(peak, std::abs(value));
            if (++slot == capacityFrames_) slot = 0;
        }
    }
#ifdef TAPDECK_TESTING
    if (testing.holdPublish) {
        raisePeak(peak);
        return;
    }
#endif
    writeCount_.store(written + static_cast<std::uint64_t>(frameCount), std::memory_order_release);
    raisePeak(peak);
}

void AudioRingBuffer::write(ConstChannels source, int frameCount) {
    if (frameCount <= 0 || source.empty()) return;
    const int sourceCount = static_cast<int>(source.size());
    store(frameCount, [&](int channel) -> const float* {
        return channel < sourceCount ? source[channel] : nullptr;
    });
}

void AudioRingBuffer::writeMapped(ConstChannels source, int frameCount) {
    if (frameCount <= 0 || source.empty()) return;
    const int sourceCount = static_cast<int>(source.size());
    store(frameCount, [&](int channel) -> const float* {
        // Mono fans out to every channel; wider sources map from the front.
        return source[sourceCount == 1 ? 0 : std::min(channel, sourceCount - 1)];
    });
}

void AudioRingBuffer::raisePeak(float peak) {
    float current = recentPeak_.load(std::memory_order_relaxed);
    while (peak > current
           && !recentPeak_.compare_exchange_weak(current, peak, std::memory_order_relaxed)) {}
}

// MARK: - Reading

namespace {

/// Unread frames beyond this share of the capacity count as an overrun. The
/// macOS buffer waits until it is completely full, because its lock keeps the
/// writer out while it reads. Here the writer never waits, so the reader keeps
/// a quarter of the buffer between itself and the writer: a read would have to
/// take longer than the writer needs for a quarter of the buffer (about 85 ms at
/// the default size) before the two could touch the same frames.
constexpr int overrunShare = 4;

} // namespace

void AudioRingBuffer::mixInto(Channels destination, int frameCount, float gain, int channelOffset) {
    if (unprimeRequested_.exchange(false, std::memory_order_acq_rel)) isPrimed_ = false;
    if (frameCount <= 0) return;
    if (gain == 0) {
        consume(frameCount);
        return;
    }

    const auto capacity = static_cast<std::uint64_t>(capacityFrames_);
    const auto written = writeCount_.load(std::memory_order_acquire);
    auto read = readCount_.load(std::memory_order_relaxed);

    // The writer got too far ahead: drop the oldest frames, keeping half the
    // buffer, which still holds the largest cushion a mix can ask for.
    if (written - read > capacity - capacity / overrunShare) {
        read = written - capacity / 2;
        overruns_.fetch_add(1, std::memory_order_relaxed);
    }
    const auto filled = written - read;

    // Hold everything back until the cushion is full; partial reads just
    // produce a run of gaps.
    if (!isPrimed_) {
        if (filled < static_cast<std::uint64_t>(primeFrames_.load(std::memory_order_relaxed))) {
            readCount_.store(read, std::memory_order_release);
            return;
        }
        isPrimed_ = true;
    }

    const int usable = static_cast<int>(std::min<std::uint64_t>(static_cast<std::uint64_t>(frameCount), filled));
    if (usable == 0) {
        isPrimed_ = false;
        underruns_.fetch_add(1, std::memory_order_relaxed);
        readCount_.store(read, std::memory_order_release);
        return;
    }

    const int start = static_cast<int>(read % capacity);
    const int destinationCount = static_cast<int>(destination.size());
    for (int sourceChannel = 0; sourceChannel < channelCount_; ++sourceChannel) {
        const int target = channelOffset + sourceChannel;
        if (target < 0 || target >= destinationCount) continue;
        float* output = destination[target];
        const std::atomic<float>* base = storage_.get() + static_cast<std::size_t>(sourceChannel) * capacityFrames_;
        int slot = start;
        for (int frame = 0; frame < usable; ++frame) {
            output[frame] += base[slot].load(std::memory_order_relaxed) * gain;
            if (++slot == capacityFrames_) slot = 0;
        }
    }

#ifdef TAPDECK_TESTING
    if (testing.afterCopy) testing.afterCopy();
#endif

    // If the writer lapped this read after all, some of what was read may
    // already be newer audio. It cannot be taken back, but it is counted. The
    // fence pairs with the writer's: had any frame read here come from a block
    // still being stored, that block's announcement is visible now.
    std::atomic_thread_fence(std::memory_order_acquire);
    if (writeEnd_.load(std::memory_order_relaxed) > read + capacity) {
        overruns_.fetch_add(1, std::memory_order_relaxed);
    }
    readCount_.store(read + static_cast<std::uint64_t>(usable), std::memory_order_release);
}

void AudioRingBuffer::consume(int frameCount) {
    const auto capacity = static_cast<std::uint64_t>(capacityFrames_);
    const auto written = writeCount_.load(std::memory_order_acquire);
    auto read = readCount_.load(std::memory_order_relaxed);
    if (written - read > capacity - capacity / overrunShare) {
        read = written - capacity / 2;
        overruns_.fetch_add(1, std::memory_order_relaxed);
    }
    const auto filled = written - read;
    read += std::min<std::uint64_t>(static_cast<std::uint64_t>(frameCount), filled);
    readCount_.store(read, std::memory_order_release);
}

// MARK: - Any thread

int AudioRingBuffer::availableFrames() const {
    const auto read = readCount_.load(std::memory_order_acquire);
    const auto written = writeCount_.load(std::memory_order_acquire);
    const auto filled = written > read ? written - read : 0;
    return static_cast<int>(std::min<std::uint64_t>(filled, static_cast<std::uint64_t>(capacityFrames_)));
}

float AudioRingBuffer::takePeak() {
    return recentPeak_.exchange(0, std::memory_order_relaxed);
}

void AudioRingBuffer::clear() {
    const auto size = static_cast<std::size_t>(channelCount_) * static_cast<std::size_t>(capacityFrames_);
    for (std::size_t index = 0; index < size; ++index) storage_[index].store(0, std::memory_order_relaxed);
    writeCount_.store(0, std::memory_order_relaxed);
    readCount_.store(0, std::memory_order_relaxed);
    writeEnd_.store(0, std::memory_order_relaxed);
    unprimeRequested_.store(false, std::memory_order_relaxed);
    isPrimed_ = false;
    recentPeak_.store(0, std::memory_order_relaxed);
    underruns_.store(0, std::memory_order_relaxed);
    overruns_.store(0, std::memory_order_relaxed);
}

} // namespace tapdeck
