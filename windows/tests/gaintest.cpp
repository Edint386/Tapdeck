// The gain stages without any devices. Ported from tapproof's gaintest
// (Sources/CLI/main.swift, runGainTest).

#include <algorithm>
#include <cmath>
#include <limits>
#include <numbers>
#include <vector>

#include "TestSupport.h"
#include "tapdeck/GainStage.h"

using namespace tapdeck;
using test::format;

int main() {
    test::Report report(46);
    constexpr int frames = 512;
    constexpr double rate = 48'000;

    // A 1 kHz sine whose gain changes from 1 to 0.5 at a block boundary.
    auto largestStep = [&](bool ramped) {
        std::vector<float> samples(frames * 2);
        for (int i = 0; i < frames * 2; ++i) {
            samples[i] = static_cast<float>(std::sin(2 * std::numbers::pi * 1000 * i / rate));
        }
        float* first = samples.data();
        float* second = samples.data() + frames;
        GainRamp ramp(1);
        if (ramped) {
            float* firstChannels[] = {first};
            float* secondChannels[] = {second};
            ramp.apply(firstChannels, frames, 1);
            ramp.apply(secondChannels, frames, 0.5f);
        } else {
            for (int i = 0; i < frames; ++i) second[i] *= 0.5f;
        }
        // A pure 1 kHz sine at 48 kHz never moves more than
        // 2·sin(π·1000/48000) ≈ 0.131 between samples. Anything larger is a
        // discontinuity introduced by the gain change.
        float largest = 0;
        for (int i = 1; i < frames * 2; ++i) {
            const float step = std::abs(samples[i] - samples[i - 1]);
            if (std::isnan(step)) return std::numeric_limits<float>::infinity();
            largest = std::max(largest, step);
        }
        return largest;
    };
    const float hard = largestStep(false);
    const float smooth = largestStep(true);
    const auto sineSlope = static_cast<float>(2 * std::sin(std::numbers::pi * 1000 / rate));
    report("hard gain change leaves a step", hard > sineSlope * 1.2f,
           format("largest step %.3f (sine alone %.3f)", hard, sineSlope));
    report("ramped gain change stays within the sine", smooth <= sineSlope * 1.01f,
           format("largest step %.3f", smooth));

    {
        std::vector<float> dc(frames, 1.0f);
        float* channels[] = {dc.data()};
        GainRamp ramp(1);
        ramp.apply(channels, frames, 0);
        bool monotonic = true;
        for (int i = 1; i < frames; ++i) monotonic = monotonic && dc[i] <= dc[i - 1];
        report("ramp to silence ends at zero and never rises", monotonic && std::abs(dc[frames - 1]) < 1e-6f,
               format("first %.4f last %.6f", dc[0], dc[frames - 1]));
    }

    MasterVolume master;
    master.setVolume(0.5f);
    report("master volume gain", master.gain() == 0.5f, format("0.5 -> %g", master.gain()));
    master.setMuted(true);
    report("master mute", master.gain() == 0, format("muted -> %g", master.gain()));
    master.setMuted(false);
    master.setVolume(-3);
    report("master volume never negative", master.gain() == 0, format("-3 -> %g", master.gain()));

    return report.finish();
}
