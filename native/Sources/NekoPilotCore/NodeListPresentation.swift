import Foundation

public struct NodeListRow: Identifiable, Equatable, Sendable {
    public let node: ProxyNode
    public let displayName: String
    public let sourceName: String
    public let hasDuplicateDisplayName: Bool

    public var id: String { node.id }

    public init(
        node: ProxyNode,
        displayName: String,
        sourceName: String,
        hasDuplicateDisplayName: Bool
    ) {
        self.node = node
        self.displayName = displayName
        self.sourceName = sourceName
        self.hasDuplicateDisplayName = hasDuplicateDisplayName
    }
}

/// Deterministic presentation rules shared by the SwiftUI node surfaces.
/// Keeping these rules outside the views makes sorting and naming regressions
/// testable without launching a second application process.
public enum NodeListPresentation {
    public static func countsBySource(_ nodes: [ProxyNode]) -> [String: Int] {
        nodes.reduce(into: [:]) { counts, node in
            counts[node.sourceIdentifier, default: 0] += 1
        }
    }

    public static func displayName(for node: ProxyNode) -> String {
        let prefix = "\(node.protocolName.uppercased()) · "
        return node.originalTag.hasPrefix(prefix)
            ? String(node.originalTag.dropFirst(prefix.count))
            : node.originalTag
    }

    public static func sorted(
        _ nodes: [ProxyNode],
        using delays: [String: DelayRecord]
    ) -> [ProxyNode] {
        nodes.sorted { lhs, rhs in
            let left = delays[lhs.runtimeTag]?.delay
            let right = delays[rhs.runtimeTag]?.delay
            switch (left, right) {
            case let (leftDelay?, rightDelay?):
                if leftDelay != rightDelay { return leftDelay < rightDelay }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.originalTag.localizedStandardCompare(rhs.originalTag) == .orderedAscending
        }
    }

    /// Chooses an instant connection candidate from recent persisted history.
    /// Connecting never waits for a new URL Test; stale data falls back to the
    /// user's existing selection in the application layer.
    public static func preferredNode(
        _ nodes: [ProxyNode],
        using delays: [String: DelayRecord],
        now: Date = Date(),
        maximumAge: TimeInterval = 30 * 60
    ) -> ProxyNode? {
        let freshnessLimit = now.addingTimeInterval(-maximumAge)
        return nodes.compactMap { node -> (ProxyNode, Int)? in
            guard let record = delays[node.runtimeTag],
                  record.measuredAt >= freshnessLimit,
                  let delay = record.delay else { return nil }
            return (node, delay)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.runtimeTag < rhs.0.runtimeTag : lhs.1 < rhs.1
        }.first?.0
    }

    /// Builds all values needed by the home node rows in one pass. Keeping
    /// this work out of SwiftUI's body avoids repeated name and source scans
    /// while URL Test results arrive in small batches.
    public static func rows(
        _ nodes: [ProxyNode],
        using delays: [String: DelayRecord]
    ) -> [NodeListRow] {
        let sortedNodes = sorted(nodes, using: delays)
        let names = sortedNodes.map(displayName(for:))
        let counts = names.reduce(into: [String: Int]()) { result, name in
            result[name.localizedLowercase, default: 0] += 1
        }
        return zip(sortedNodes, names).map { node, name in
            NodeListRow(
                node: node,
                displayName: name,
                sourceName: node.sourceName,
                hasDuplicateDisplayName: counts[name.localizedLowercase, default: 0] > 1
            )
        }
    }
}
