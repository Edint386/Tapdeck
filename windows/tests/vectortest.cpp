// The C++ port against the reference vectors the Swift code wrote (see
// windows/tools/vectors). Run with the vectors directory as its argument.
//
// Everything must match bit for bit, with one exception. The limiter computes
// its release coefficient with exp(), which Apple's and Microsoft's math
// libraries may round one unit in the last place (ulp) apart. Each case stores
// the Swift value; only when this platform's exp() gives a different one may
// each output sample sit one ulp from the Swift output and each block's lowest
// gain eight. On top of that, no limited sample may exceed the ceiling. NaN
// never matches anything but NaN.

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include "TestSupport.h"
#include "VectorFile.h"
#include "tapdeck/GainStage.h"
#include "tapdeck/RoutingGraph.h"

using namespace tapdeck;
using test::format;
using test::VectorFile;

namespace {

/// Split planar samples stored channel after channel.
std::vector<std::vector<float>> planar(const std::vector<float>& samples, int channels, int frames) {
    if (samples.size() != static_cast<std::size_t>(channels) * static_cast<std::size_t>(frames)) {
        throw std::runtime_error("a vector holds " + std::to_string(samples.size()) + " samples, expected "
                                 + std::to_string(channels) + " x " + std::to_string(frames));
    }
    std::vector<std::vector<float>> result(channels);
    for (int c = 0; c < channels; ++c) {
        result[c].assign(samples.begin() + static_cast<std::ptrdiff_t>(c) * frames,
                         samples.begin() + static_cast<std::ptrdiff_t>(c + 1) * frames);
    }
    return result;
}

/// Units in the last place between two values: 0 for identical bits,
/// infinite when only one is NaN.
template <typename T>
double ulps(T a, T b) {
    using Bits = std::conditional_t<sizeof(T) == 4, std::uint32_t, std::uint64_t>;
    if (std::bit_cast<Bits>(a) == std::bit_cast<Bits>(b)) return 0;
    if (std::isnan(a) || std::isnan(b)) return std::numeric_limits<double>::infinity();
    const T larger = std::max(std::abs(a), std::abs(b));
    const T unit = std::nextafter(larger, std::numeric_limits<T>::infinity()) - larger;
    return static_cast<double>(std::abs(a - b) / unit);
}

/// The largest distance in ulps between the processed channels and the
/// expected samples, stored channel after channel.
double worstUlps(const std::vector<std::vector<float>>& actual, const std::vector<float>& expected) {
    std::size_t total = 0;
    for (const auto& channel : actual) total += channel.size();
    if (total != expected.size()) {
        throw std::runtime_error("expected " + std::to_string(expected.size()) + " samples, have " + std::to_string(total));
    }
    double worst = 0;
    std::size_t index = 0;
    for (const auto& channel : actual) {
        for (float sample : channel) worst = std::max(worst, ulps(sample, expected[index++]));
    }
    return worst;
}

std::string describe(double worst) {
    if (worst == 0) return "bit for bit";
    if (!std::isfinite(worst)) return "differs";
    return format("within %.0f ulp", worst);
}

std::vector<std::string> split(const std::string& text, char separator) {
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (true) {
        const auto end = text.find(separator, start);
        parts.push_back(text.substr(start, end - start));
        if (end == std::string::npos) return parts;
        start = end + 1;
    }
}

void gainRamp(test::Report& report, const VectorFile& file) {
    const int frames = file.i32("frames")[0];
    auto audio = planar(file.f32("input"), 2, frames);
    const auto& kinds = file.i32("opKinds");
    const auto& lengths = file.i32("opFrames");
    const auto& values = file.f32("opValues");

    GainRamp ramp(file.f32("initial")[0]);
    int start = 0;
    for (std::size_t op = 0; op < kinds.size(); ++op) {
        if (kinds[op] == 1) {
            ramp.reset(values[op]);
            continue;
        }
        float* channels[] = {audio[0].data() + start, audio[1].data() + start};
        ramp.apply(channels, lengths[op], values[op]);
        start += lengths[op];
    }
    const double worst = worstUlps(audio, file.f32("output"));
    const bool finalMatches = ulps(ramp.current(), file.f32("finalGain")[0]) == 0;
    report("gain ramp matches bit for bit", worst == 0 && finalMatches,
           format("%s over %zu operations", describe(worst).c_str(), kinds.size()));
}

void masterVolume(test::Report& report, const VectorFile& file) {
    const auto& kinds = file.i32("opKinds");
    const auto& values = file.f32("opValues");
    MasterVolume master;
    bool same = true;
    for (std::size_t op = 0; op < kinds.size(); ++op) {
        if (kinds[op] == 0) {
            master.setVolume(values[op]);
        } else {
            master.setMuted(values[op] != 0);
        }
        same = same && ulps(master.gain(), file.f32("gains").at(op)) == 0
            && ulps(master.volume(), file.f32("volumes").at(op)) == 0
            && master.isMuted() == (file.i32("muted").at(op) != 0);
    }
    report("master volume matches", same, format("%zu operations", kinds.size()));
}

void limiter(test::Report& report, const VectorFile& file) {
    const int cases = file.i32("cases")[0];
    for (int index = 0; index < cases; ++index) {
        const std::string prefix = "case" + std::to_string(index) + ".";
        const int channels = file.i32(prefix + "channels")[0];
        const int inputChannels = file.i32(prefix + "inputChannels")[0];
        const int frames = file.i32(prefix + "frames")[0];
        LookaheadLimiter limiter(channels, file.number(prefix + "sampleRate"), file.number(prefix + "ceiling"),
                                 file.number(prefix + "lookaheadSeconds"), file.number(prefix + "releaseSeconds"));
        auto audio = planar(file.f32(prefix + "input"), inputChannels, frames);
        const auto original = audio;
        const auto& expectedLowest = file.f64(prefix + "lowest");

        double worstLowest = 0;
        int start = 0;
        std::size_t block = 0;
        for (int size : file.i32(prefix + "blocks")) {
            std::vector<float*> pointers;
            for (auto& channel : audio) pointers.push_back(channel.data() + start);
            const double lowest = limiter.process(pointers, size);
            if (block < expectedLowest.size()) worstLowest = std::max(worstLowest, ulps(lowest, expectedLowest[block]));
            start += size;
            block += 1;
        }
        const double worst = worstUlps(audio, file.f32(prefix + "output"));
        const double release = std::exp(-1 / (file.number(prefix + "releaseSeconds") * file.number(prefix + "sampleRate")));
        const bool sameExp = ulps(release, file.number(prefix + "release")) == 0;

        // The guarantee itself: no limited sample above the ceiling, and the
        // channels beyond the limiter's own left exactly as they were.
        const auto ceiling = static_cast<float>(file.number(prefix + "ceiling"));
        bool underCeiling = true, othersUntouched = true;
        for (int c = 0; c < inputChannels; ++c) {
            for (int f = 0; f < frames; ++f) {
                if (c < channels) {
                    underCeiling = underCeiling && std::abs(audio[c][f]) <= ceiling;
                } else {
                    othersUntouched = othersUntouched && ulps(audio[c][f], original[c][f]) == 0;
                }
            }
        }
        const bool ok = worst <= (sameExp ? 0 : 1) && worstLowest <= (sameExp ? 0 : 8)
                     && block == expectedLowest.size() && underCeiling
                     && othersUntouched && limiter.latencyFrames() == file.i32(prefix + "latency").at(0);
        report("limiter: " + file.text(prefix + "name"), ok,
               format("%s, gain %s, delay %d%s%s", describe(worst).c_str(), describe(worstLowest).c_str(),
                      limiter.latencyFrames(), sameExp ? "" : " (exp() rounds apart here)",
                      underCeiling ? "" : ", ABOVE THE CEILING"));
    }
}

void routingGraph(test::Report& report, const VectorFile& file) {
    const int cases = file.i32("cases")[0];
    for (int index = 0; index < cases; ++index) {
        const std::string prefix = "case" + std::to_string(index) + ".";
        RoutingGraph graph;
        for (const auto& call : split(file.text(prefix + "connects"), ';')) {
            const auto sides = split(call, '>');
            std::vector<std::string> inputs, outputs;
            if (!sides[0].empty()) inputs = split(sides[0], ',');
            if (!sides[1].empty()) outputs = split(sides[1], ',');
            graph.connect(inputs, outputs);
        }
        std::string route;
        if (const auto cycle = graph.firstCycle()) {
            for (std::size_t i = 0; i < cycle->size(); ++i) route += (i ? "," : "") + (*cycle)[i];
        }
        const auto& expected = file.text(prefix + "cycle");
        report("graph: " + file.text(prefix + "name"), route == expected,
               route.empty() ? "no loop" : route);
    }
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: vectortest VECTORS_DIRECTORY\n");
        return 2;
    }
    const std::string directory = argv[1];
    test::Report report(52);
    try {
        gainRamp(report, VectorFile::load(directory + "/gainramp.tdv"));
        masterVolume(report, VectorFile::load(directory + "/mastervolume.tdv"));
        limiter(report, VectorFile::load(directory + "/lookahead.tdv"));
        routingGraph(report, VectorFile::load(directory + "/routinggraph.tdv"));
    } catch (const std::exception& error) {
        std::fprintf(stderr, "error: %s\n", error.what());
        return 2;
    }
    return report.finish();
}
