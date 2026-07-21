import Foundation

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
}
