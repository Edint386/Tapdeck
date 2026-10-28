// Where audio flows between devices, for spotting feedback loops.
//
// Ported from Sources/Engine/RoutingGraph.swift.

#pragma once

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace tapdeck {

/// Each running mix adds an edge from every device it captures to every device
/// it plays into. A cycle means audio comes back around to where it started:
/// one mix capturing Streaming and playing to Meetings while another captures
/// Meetings and plays to Streaming will howl.
///
/// Devices are compared and ordered as UTF-8 bytes, which matches Swift's
/// ordering for the identifiers Tapdeck uses (endpoint IDs, cable pairs).
class RoutingGraph {
public:
    void connect(const std::vector<std::string>& inputs, const std::vector<std::string>& outputs);

    /// A route that returns to its starting device, or nothing if there is
    /// none. The first and last elements of the route are the same device.
    /// Starting devices and neighbours are visited in sorted order, so the
    /// answer is the same on every run and on every platform.
    std::optional<std::vector<std::string>> firstCycle() const;

    const std::map<std::string, std::set<std::string>>& edges() const { return edges_; }

private:
    std::map<std::string, std::set<std::string>> edges_;
};

} // namespace tapdeck
