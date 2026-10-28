// RoutingGraph against cases whose answer is known. Ported from tapproof's
// graphtest (Sources/CLI/main.swift, runGraphTest).

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include "tapdeck/RoutingGraph.h"

using tapdeck::RoutingGraph;

namespace {

bool check(const std::string& label, const std::function<void(RoutingGraph&)>& build, bool expectLoop) {
    RoutingGraph graph;
    build(graph);
    const auto loop = graph.firstCycle();
    const bool ok = loop.has_value() == expectLoop;
    std::string route = "no loop";
    if (loop) {
        route.clear();
        for (std::size_t index = 0; index < loop->size(); ++index) {
            if (index > 0) route += " → ";
            route += (*loop)[index];
        }
    }
    std::printf("%s  %s  ->  %s\n", ok ? "PASS" : "FAIL", label.c_str(), route.c_str());
    return ok;
}

} // namespace

int main() {
    std::vector<bool> results;
    results.push_back(check("mic -> Tapdeck", [](auto& g) { g.connect({"mic"}, {"Tapdeck"}); }, false));
    results.push_back(check("Tapdeck -> Tapdeck (same mix)",
                            [](auto& g) { g.connect({"Tapdeck"}, {"Tapdeck", "speakers"}); }, true));
    results.push_back(check("Tapdeck -> speakers (listen)", [](auto& g) { g.connect({"Tapdeck"}, {"speakers"}); }, false));
    results.push_back(check("A -> B, B -> A (two mixes)", [](auto& g) {
        g.connect({"Streaming"}, {"Meetings"});
        g.connect({"Meetings"}, {"Streaming"});
    }, true));
    results.push_back(check("A -> B -> C (chain)", [](auto& g) {
        g.connect({"A"}, {"B"});
        g.connect({"B"}, {"C"});
    }, false));
    results.push_back(check("A -> B -> C -> A (three mixes)", [](auto& g) {
        g.connect({"A"}, {"B"});
        g.connect({"B"}, {"C"});
        g.connect({"C"}, {"A"});
    }, true));
    results.push_back(check("app sources only (no device edges)", [](auto& g) { g.connect({}, {"Tapdeck"}); }, false));

    int passed = 0;
    for (bool ok : results) passed += ok ? 1 : 0;
    std::printf("%d/%zu passed\n", passed, results.size());
    return passed == static_cast<int>(results.size()) ? 0 : 1;
}
