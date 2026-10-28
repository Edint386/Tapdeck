// The output limiter: transparent below the ceiling, never above it, and far
// cleaner than the hard clipping it replaced. Ported from tapproof's limittest
// (Sources/CLI/main.swift, runLimiterTest).

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <numbers>
#include <vector>

#include "TestSupport.h"
#include "tapdeck/GainStage.h"

using namespace tapdeck;
using test::format;

namespace {

constexpr double rate = 48'000;

struct Run {
    std::vector<float> input;
    std::vector<float> output;
    int latency = 0;
};

/// Run `seconds` of a signal through either the limiter or a hard clip.
Run run(const std::function<float(int)>& signal, double seconds, bool limit, double ceiling) {
    LookaheadLimiter limiter(2, rate, ceiling);
    constexpr int block = 512;
    const int frames = static_cast<int>(seconds * rate) / block * block;
    Run result;
    std::vector<float> left(block), right(block);
    for (int start = 0; start < frames; start += block) {
        for (int i = 0; i < block; ++i) {
            left[i] = signal(start + i);
            right[i] = left[i];
            result.input.push_back(left[i]);
        }
        if (limit) {
            float* channels[] = {left.data(), right.data()};
            limiter.process(channels, block);
        } else {
            for (int i = 0; i < block; ++i) left[i] = std::min(1.0f, std::max(-1.0f, left[i]));
        }
        for (int i = 0; i < block; ++i) result.output.push_back(left[i]);
    }
    result.latency = limit ? limiter.latencyFrames() : 0;
    return result;
}

/// Level of one frequency over the last half second, in dB relative to full scale.
double level(const std::vector<float>& samples, double hertz) {
    const int count = static_cast<int>(rate / 2);
    const std::size_t first = samples.size() > static_cast<std::size_t>(count) ? samples.size() - count : 0;
    double re = 0, im = 0, index = 0;
    for (std::size_t i = first; i < samples.size(); ++i) {
        re += samples[i] * std::cos(2 * std::numbers::pi * hertz * index / rate);
        im += samples[i] * std::sin(2 * std::numbers::pi * hertz * index / rate);
        index += 1;
    }
    return 20 * std::log10(std::max(2 * std::sqrt(re * re + im * im) / count, 1e-12));
}

/// Peak in dBFS; a NaN anywhere reads as infinitely loud, so it fails every
/// "at or under" check.
double peakDecibels(const std::vector<float>& samples) {
    float peak = 0;
    for (float sample : samples) {
        if (std::isnan(sample)) return std::numeric_limits<double>::infinity();
        peak = std::max(peak, std::abs(sample));
    }
    return 20 * std::log10(static_cast<double>(peak));
}

} // namespace

int main() {
    test::Report report(50);
    const double ceiling = std::pow(10, -1.0 / 20);

    auto tone = [](double amplitude) {
        return [amplitude](int i) {
            return static_cast<float>(amplitude * std::sin(2 * std::numbers::pi * 1'000 * i / rate));
        };
    };

    // Below the ceiling nothing changes except the fixed delay.
    const auto quiet = run(tone(0.5), 1, true, ceiling);
    float worst = 0;
    for (std::size_t i = quiet.latency; i < quiet.output.size(); ++i) {
        const float difference = std::abs(quiet.output[i] - quiet.input[i - quiet.latency]);
        worst = std::isnan(difference) ? std::numeric_limits<float>::infinity() : std::max(worst, difference);
    }
    report("-6 dBFS passes untouched, only delayed", worst < 1e-6f,
           format("largest difference %.1e, delay %d samples (%.2f ms)", worst, quiet.latency,
                  quiet.latency / rate * 1000));

    // A +6 dBFS tone: under the ceiling, and a clean sine rather than a clipped one.
    const auto loud = run(tone(2), 1, true, ceiling);
    const auto clipped = run(tone(2), 1, false, ceiling);
    const double loudPeak = peakDecibels(loud.output);
    report("+6 dBFS tone stays at or under -1 dBFS", loudPeak <= -1 + 1e-4, format("peak %.3f dBFS", loudPeak));
    const double limitedThird = level(loud.output, 3'000) - level(loud.output, 1'000);
    const double clippedThird = level(clipped.output, 3'000) - level(clipped.output, 1'000);
    report("3rd harmonic far below hard clipping's", limitedThird < -60 && limitedThird < clippedThird - 40,
           format("limiter %.1f dB, hard clip %.1f dB relative to the tone", limitedThird, clippedThird));

    // A sudden burst out of silence is still held under the ceiling.
    const auto burst = run([](int i) {
        return i < 24'000 ? 0.0f : static_cast<float>(4 * std::sin(2 * std::numbers::pi * 440 * i / rate));
    }, 1, true, ceiling);
    const double burstPeak = peakDecibels(burst.output);
    report("burst from silence to +12 dBFS never passes -1 dBFS", burstPeak <= -1 + 1e-4,
           format("peak %.3f dBFS", burstPeak));

    // Noise with random peaks.
    std::uint64_t seed = 42;
    const auto noisy = run([&seed](int) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<float>(static_cast<std::int64_t>(seed >> 11) - (std::int64_t{1} << 52))
             / static_cast<float>(std::int64_t{1} << 52) * 3;
    }, 1, true, ceiling);
    const double noisyPeak = peakDecibels(noisy.output);
    report("noise with peaks at +9.5 dBFS never passes -1 dBFS", noisyPeak <= -1 + 1e-4,
           format("peak %.3f dBFS", noisyPeak));

    return report.finish();
}
