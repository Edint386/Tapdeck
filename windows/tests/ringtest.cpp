// The lock-free ring buffer. macOS has no test of its own for AudioRingBuffer;
// these checks pin down the behaviour the Windows buffer keeps from it, and run
// one writer and one reader against each other. Build with
// -DTAPDECK_SANITIZE=thread to run the stress part under ThreadSanitizer.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <random>
#include <thread>
#include <vector>

#include "TestSupport.h"
#include "tapdeck/AudioRingBuffer.h"

using namespace tapdeck;
using test::format;

namespace {

/// Planar channels holding a running count, so any gap or repeat shows.
struct Ramp {
    std::vector<std::vector<float>> data;
    std::vector<const float*> pointers;

    Ramp(int channels, int frames, float first, float channelStep = 1000) {
        data.assign(channels, std::vector<float>(frames));
        for (int c = 0; c < channels; ++c) {
            for (int f = 0; f < frames; ++f) data[c][f] = first + f + c * channelStep;
            pointers.push_back(data[c].data());
        }
    }
    ConstChannels channels() const { return pointers; }
};

/// A zeroed destination of `channels` × `frames`.
struct Out {
    std::vector<std::vector<float>> data;
    std::vector<float*> pointers;

    Out(int channels, int frames) {
        data.assign(channels, std::vector<float>(frames, 0.0f));
        for (auto& channel : data) pointers.push_back(channel.data());
    }
    Channels channels() { return pointers; }
    bool silent(int channel) const {
        return std::all_of(data[channel].begin(), data[channel].end(), [](float v) { return v == 0; });
    }
    /// Whether channel `c` holds first, first+1, … for its first `count` frames.
    bool counts(int c, float first, int count) const {
        for (int f = 0; f < count; ++f) {
            if (data[c][f] != first + f) return false;
        }
        return true;
    }
};

void priming(test::Report& report) {
    AudioRingBuffer ring(2, 4096, 512);
    Ramp first(2, 300, 0);
    ring.writeMapped(first.channels(), 300);
    Out out(2, 256);
    ring.mixInto(out.channels(), 256, 1);
    report("nothing is read before the cushion fills", out.silent(0) && ring.availableFrames() == 300,
           format("available %d", ring.availableFrames()));

    Ramp second(2, 300, 300);
    ring.writeMapped(second.channels(), 300);
    Out after(2, 256);
    ring.mixInto(after.channels(), 256, 1);
    report("once primed, frames come out in order", after.counts(0, 0, 256) && after.counts(1, 1000, 256),
           format("available %d", ring.availableFrames()));
}

void underflow(test::Report& report) {
    AudioRingBuffer ring(1, 4096, 100);
    Ramp ramp(1, 150, 0);
    ring.writeMapped(ramp.channels(), 150);
    Out first(1, 128);
    ring.mixInto(first.channels(), 128, 1);
    Out partial(1, 128);
    ring.mixInto(partial.channels(), 128, 1);
    const bool partialOk = partial.counts(0, 128, 22) && partial.data[0][22] == 0 && ring.underruns() == 0;
    report("a short read returns what is there, not an underrun", partialOk,
           format("underruns %d", ring.underruns()));

    Out dry(1, 128);
    ring.mixInto(dry.channels(), 128, 1);
    report("reading dry counts an underrun and leaves silence", dry.silent(0) && ring.underruns() == 1,
           format("underruns %d", ring.underruns()));

    Ramp more(1, 50, 150);
    ring.writeMapped(more.channels(), 50);
    Out waiting(1, 32);
    ring.mixInto(waiting.channels(), 32, 1);
    Ramp rest(1, 60, 200);
    ring.writeMapped(rest.channels(), 60);
    Out resumed(1, 32);
    ring.mixInto(resumed.channels(), 32, 1);
    report("after an underrun the cushion is rebuilt first", waiting.silent(0) && resumed.counts(0, 150, 32),
           format("available %d", ring.availableFrames()));
}

void gainAndMixing(test::Report& report) {
    AudioRingBuffer a(1, 1024, 0), b(1, 1024, 0);
    Ramp ones(1, 64, 1, 0);
    for (auto& v : ones.data[0]) v = 1;
    a.writeMapped(ones.channels(), 64);
    b.writeMapped(ones.channels(), 64);
    Out out(1, 64);
    a.mixInto(out.channels(), 64, 0.5f);
    b.mixInto(out.channels(), 64, 0.25f);
    report("sources add into the destination with their gains", out.data[0][0] == 0.75f && out.data[0][63] == 0.75f,
           format("sample %.3f", out.data[0][0]));

    AudioRingBuffer muted(1, 1024, 512);
    Ramp ramp(1, 300, 0);
    muted.writeMapped(ramp.channels(), 300);
    Out untouched(1, 200);
    muted.mixInto(untouched.channels(), 200, 0);
    report("a muted source still consumes, even unprimed", untouched.silent(0) && muted.availableFrames() == 100,
           format("available %d", muted.availableFrames()));
}

void offsets(test::Report& report) {
    AudioRingBuffer ring(2, 1024, 0);
    Ramp ramp(2, 16, 1);
    ring.writeMapped(ramp.channels(), 16);
    Out out(6, 16);
    ring.mixInto(out.channels(), 8, 1, 2);
    const bool placed = out.silent(0) && out.silent(1) && out.counts(2, 1, 8) && out.counts(3, 1001, 8)
                     && out.silent(4) && out.silent(5);
    report("channel offset 2 lands on channels 3 and 4", placed);

    Out edge(6, 16);
    ring.mixInto(edge.channels(), 4, 1, 5);
    Out before(6, 16);
    ring.mixInto(before.channels(), 4, 1, -1);
    report("channels outside the destination are skipped",
           edge.counts(5, 9, 4) && edge.silent(4) && before.counts(0, 1013, 4) && before.silent(1));
}

void writeMappings(test::Report& report) {
    AudioRingBuffer wide(4, 1024, 0);
    Ramp mono(1, 8, 1);
    wide.writeMapped(mono.channels(), 8);
    Out fanned(4, 8);
    wide.mixInto(fanned.channels(), 8, 1);
    report("a mono source fans out to every channel",
           fanned.counts(0, 1, 8) && fanned.counts(1, 1, 8) && fanned.counts(2, 1, 8) && fanned.counts(3, 1, 8));

    AudioRingBuffer mapped(4, 1024, 0);
    Ramp stereo(2, 8, 1);
    mapped.writeMapped(stereo.channels(), 8);
    Out repeated(4, 8);
    mapped.mixInto(repeated.channels(), 8, 1);
    report("a narrower source repeats its last channel",
           repeated.counts(0, 1, 8) && repeated.counts(1, 1001, 8) && repeated.counts(3, 1001, 8));

    AudioRingBuffer padded(4, 1024, 0);
    padded.write(stereo.channels(), 8);
    Out zeros(4, 8);
    padded.mixInto(zeros.channels(), 8, 1);
    report("planar writes leave missing channels silent",
           zeros.counts(1, 1001, 8) && zeros.silent(2) && zeros.silent(3));
}

void overflowAndWrap(test::Report& report) {
    AudioRingBuffer ring(1, 1024, 0);
    Ramp ramp(1, 1100, 0);
    ring.writeMapped(ramp.channels(), 1100);
    Out out(1, 16);
    ring.mixInto(out.channels(), 16, 1);
    report("overflow drops the oldest and keeps the newest half", ring.overruns() == 1 && out.counts(0, 1100 - 512, 16),
           format("overruns %d, first frame %.0f", ring.overruns(), out.data[0][0]));

    AudioRingBuffer wrapping(2, 1024, 0);
    float next = 0;
    float expected = 0;
    bool continuous = true;
    std::mt19937 random(7);
    for (int round = 0; round < 2000; ++round) {
        const int writeFrames = 1 + static_cast<int>(random() % 300);
        Ramp block(2, writeFrames, next);
        next += writeFrames;
        wrapping.writeMapped(block.channels(), writeFrames);
        // Random sizes, but never more than 400 frames left behind, so the
        // buffer (1024 frames, overrun beyond 768) wraps without overflowing.
        const int available = wrapping.availableFrames();
        int readFrames = std::min(available, 1 + static_cast<int>(random() % 300));
        if (available - readFrames > 400) readFrames = available;
        Out read(2, readFrames);
        wrapping.mixInto(read.channels(), readFrames, 1);
        continuous = continuous && read.counts(0, expected, readFrames) && read.counts(1, expected + 1000, readFrames);
        expected += readFrames;
    }
    report("frames stay in order across thousands of wraps", continuous && wrapping.overruns() == 0,
           format("%.0f frames read", expected));

    AudioRingBuffer huge(1, 512, 0);
    Ramp big(1, 2000, 0);
    huge.write(big.channels(), 2000);
    Out tail(1, 8);
    huge.mixInto(tail.channels(), 8, 1);
    report("a block longer than the buffer keeps its newest frames", tail.counts(0, 2000 - 256, 8),
           format("first frame %.0f", tail.data[0][0]));
}

void controls(test::Report& report) {
    AudioRingBuffer ring(1, 4096, 100);
    Ramp ramp(1, 200, 0);
    ring.writeMapped(ramp.channels(), 200);
    Out first(1, 50);
    ring.mixInto(first.channels(), 50, 1);
    ring.setPrimeFrames(1000);
    Out held(1, 50);
    ring.mixInto(held.channels(), 50, 1);
    report("a new cushion applies at the next priming", first.counts(0, 0, 50) && held.silent(0),
           format("available %d", ring.availableFrames()));

    AudioRingBuffer peaks(2, 1024, 0);
    std::vector<float> left{0.1f, -0.7f, 0.2f}, right{0.3f, 0.4f, -0.5f};
    const float* channels[] = {left.data(), right.data()};
    peaks.write(channels, 3);
    const float peak = peaks.takePeak();
    report("the peak is taken once, then reset", peak == 0.7f && peaks.takePeak() == 0,
           format("peak %.2f", peak));

    peaks.clear();
    report("clear empties the buffer and its counts",
           peaks.availableFrames() == 0 && peaks.underruns() == 0 && peaks.overruns() == 0);
}

/// One writer and one reader, as the real threads will be. Frame n carries the
/// value n + 1 on the left and its negative on the right, so a frame that was
/// not read stays 0, a gap shows as a jump, and a torn frame as a mismatch.
///
/// Paced, the writer waits while half the buffer is full, as a source never
/// gets that far ahead of a healthy output: nothing may be lost or torn.
/// Racing, the writer never waits and the reader dawdles: frames are dropped,
/// but every jump or tear must come with an overrun counted in the same read.
void stress(test::Report& report, bool racing) {
    constexpr int capacity = 4096;
    AudioRingBuffer ring(2, capacity, 512);
    std::atomic<bool> done{false};
    constexpr std::int64_t total = 400'000; // floats count exactly up to 2^24

    std::thread writer([&] {
        std::mt19937 random(1);
        std::vector<float> left(512), right(512);
        std::int64_t written = 0;
        while (written < total) {
            const int frames = 64 + static_cast<int>(random() % 448);
            if (!racing) {
                while (ring.availableFrames() > capacity / 2) std::this_thread::yield();
            }
            for (int f = 0; f < frames; ++f) {
                left[f] = static_cast<float>(written + f + 1);
                right[f] = -left[f];
            }
            const float* channels[] = {left.data(), right.data()};
            ring.write(channels, frames);
            written += frames;
            if (random() % 8 == 0) std::this_thread::yield();
        }
        done.store(true, std::memory_order_release);
    });

    std::mt19937 random(2);
    std::vector<float> left(512), right(512);
    float last = 0;
    int jumps = 0, torn = 0, unexplained = 0;
    std::int64_t read = 0;
    while (true) {
        const bool finished = done.load(std::memory_order_acquire);
        const int frames = 64 + static_cast<int>(random() % 448);
        std::fill(left.begin(), left.end(), 0.0f);
        std::fill(right.begin(), right.end(), 0.0f);
        float* channels[] = {left.data(), right.data()};
        const int overrunsBefore = ring.overruns();
        ring.mixInto(channels, frames, 1);
        const bool overranNow = ring.overruns() != overrunsBefore;

        const float previous = last;
        int got = 0, anomalies = 0;
        for (int f = 0; f < frames && left[f] != 0; ++f, ++got) {
            if (right[f] != -left[f]) { torn += 1; anomalies += 1; }
            if (left[f] != last + 1) { jumps += 1; anomalies += 1; }
            last = left[f];
        }
        if (anomalies > 0 && !overranNow) {
            unexplained += 1;
            std::fprintf(stderr, "uncounted jump or tear: %d frames from %.0f after %.0f\n", got, left[0], previous);
        }
        read += got;
        if (finished && got == 0) break; // drained, or less than a cushion left
        if (!racing && random() % 4 == 0) std::this_thread::yield();
        if (racing && random() % 2 == 0) std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    writer.join();

    if (racing) {
        report("racing writer: every jump is a counted overrun", unexplained == 0 && ring.overruns() > 0,
               format("%lld frames read, %d jumps, %d torn, %d overruns", static_cast<long long>(read), jumps, torn,
                      ring.overruns()));
    } else {
        report("paced writer and reader: no frame lost or torn",
               jumps == 0 && torn == 0 && unexplained == 0 && ring.overruns() == 0,
               format("%lld frames read, %d underruns", static_cast<long long>(read), ring.underruns()));
    }
}

} // namespace

int main() {
    test::Report report(50);
    priming(report);
    underflow(report);
    gainAndMixing(report);
    offsets(report);
    writeMappings(report);
    overflowAndWrap(report);
    controls(report);
    stress(report, false);
    stress(report, true);
    return report.finish();
}
