import Foundation

/// Where audio flows between devices, for spotting feedback loops.
///
/// Each running mix adds an edge from every device it captures to every device
/// it plays into. A cycle means audio comes back around to where it started:
/// one mix capturing Streaming and playing to Meetings while another captures
/// Meetings and plays to Streaming will howl.
struct RoutingGraph {
    private(set) var edges: [String: Set<String>] = [:]

    mutating func connect(from inputs: [String], to outputs: [String]) {
        for input in inputs {
            edges[input, default: []].formUnion(outputs)
        }
    }

    /// A route that returns to its starting device, or nil if there is none.
    /// The first and last elements of the route are the same device.
    func firstCycle() -> [String]? {
        for start in edges.keys.sorted() {
            var stack: [(node: String, path: [String])] = [(start, [start])]
            var visited: Set<String> = []
            while let (node, path) = stack.popLast() {
                for next in (edges[node] ?? []).sorted() {
                    if next == start { return path + [start] }
                    if visited.insert(next).inserted { stack.append((next, path + [next])) }
                }
            }
        }
        return nil
    }
}
