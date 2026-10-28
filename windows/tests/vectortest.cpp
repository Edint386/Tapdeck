// The C++ port against the reference vectors the Swift code wrote (see
// windows/tools/vectors). Run with the vectors directory as its argument.
//
// The gain ramp and the master volume use only multiplication and addition, so
// they must match bit for bit. The limiter computes its release coefficient
// with exp(), which Apple's and Microsoft's math libraries may round apart in
// the last bit, so its output may differ by at most 1e-6 (-120 dBFS).

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
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
    std::vector<std::vector<float>> result(channels);
    for (int c = 0; c < channels; ++c) {
        result[c].assign(samples.begin() + static_cast<std::ptrdiff_t>(c) * frames,
                         samples.begin() + static_cast<std::ptrdiff_t>(c + 1) * frames);
    }
    return result;
}

double largestDifference(const std::vector<std::vector<float>>& actual, const std::vector<float>& expected) {
    double worst = 0;
    std::size_t index = 0;
    for (const auto& channel : actual) {
        for (float sample : channel) {
            worst = std::max(worst, std::abs(static_cast<double>(sample) - expected[index++]));
        }
    }
    return worst;
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
    const double worst = largestDifference(audio, file.f32("output"));
    const bool finalMatches = ramp.current() == file.f32("finalGain")[0];
    report("gain ramp matches bit for bit", worst == 0 && finalMatches,
           format("largest difference %.1e over %zu operations", worst, kinds.size()));
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
        same = same && master.gain() == file.f32("gains")[op] && master.volume() == file.f32("volumes")[op]
            && master.isMuted() == (file.i32("muted")[op] != 0);
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
        const auto& expectedLowest = file.f64(prefix + "lowest");

        double worstLowest = 0;
        int start = 0;
        std::size_t block = 0;
        for (int size : file.i32(prefix + "blocks")) {
            std::vector<float*> pointers;
            for (auto& channel : audio) pointers.push_back(channel.data() + start);
            const double lowest = limiter.process(pointers, size);
            worstLowest = std::max(worstLowest, std::abs(lowest - expectedLowest.at(block)));
            start += size;
            block += 1;
        }
        const double worst = largestDifference(audio, file.f32(prefix + "output"));
        const bool ok = worst <= 1e-6 && worstLowest <= 1e-9 && block == expectedLowest.size()
                     && limiter.latencyFrames() == file.i32(prefix + "latency")[0];
        report("limiter: " + file.text(prefix + "name"), ok,
               format("largest difference %.1e, gain %.1e, delay %d", worst, worstLowest, limiter.latencyFrames()));
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
