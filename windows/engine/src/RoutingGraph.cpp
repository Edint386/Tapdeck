#include "tapdeck/RoutingGraph.h"

#include <utility>

namespace tapdeck {

void RoutingGraph::connect(const std::vector<std::string>& inputs, const std::vector<std::string>& outputs) {
    for (const auto& input : inputs) {
        // An input with no outputs still becomes a node, as in the Swift code.
        auto& targets = edges_[input];
        targets.insert(outputs.begin(), outputs.end());
    }
}

std::optional<std::vector<std::string>> RoutingGraph::firstCycle() const {
    for (const auto& [start, ignored] : edges_) {
        (void)ignored;
        std::vector<std::pair<std::string, std::vector<std::string>>> stack{{start, {start}}};
        std::set<std::string> visited;
        while (!stack.empty()) {
            auto [node, path] = std::move(stack.back());
            stack.pop_back();
            const auto found = edges_.find(node);
            if (found == edges_.end()) continue;
            for (const auto& next : found->second) {
                if (next == start) {
                    path.push_back(start);
                    return path;
                }
                if (visited.insert(next).second) {
                    auto extended = path;
                    extended.push_back(next);
                    stack.emplace_back(next, std::move(extended));
                }
            }
        }
    }
    return std::nullopt;
}

} // namespace tapdeck
