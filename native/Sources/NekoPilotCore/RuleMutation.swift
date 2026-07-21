import Darwin
import Foundation

public struct RuleBatchMutation: Equatable, Sendable {
    public let rules: [RoutingRule]
    public let added: Int
    public let duplicates: Int
    public let hasCrossActionConflict: Bool
}

public struct RuleEditMutation: Equatable, Sendable {
    public let rules: [RoutingRule]
    public let unchanged: Bool
    public let hasCrossActionConflict: Bool
}

public enum RuleMutation {
    public static func add(
        to current: [RoutingRule],
        action: RuleAction,
        kind: RuleKind,
        rawInput: String
    ) throws -> RuleBatchMutation {
        let values = split(rawInput)
        guard !values.isEmpty, values.count <= 500, current.count + values.count <= 5_000,
              values.allSatisfy({ isValid($0, kind: kind) }) else {
            throw NekoPilotError.invalidRule
        }

        var next = current
        var added = 0
        var duplicates = 0
        var conflict = false
        for value in values {
            if next.contains(where: { $0.action == action && $0.kind == kind && $0.value == value }) {
                duplicates += 1
                continue
            }
            if next.contains(where: { $0.action != action && $0.value == value }) {
                conflict = true
            }
            next.append(RoutingRule(action: action, kind: kind, value: value))
            added += 1
        }
        guard added > 0 else { throw NekoPilotError.duplicateRule }
        return RuleBatchMutation(
            rules: sorted(next),
            added: added,
            duplicates: duplicates,
            hasCrossActionConflict: conflict
        )
    }

    public static func update(
        in current: [RoutingRule],
        original: RoutingRule,
        action: RuleAction,
        kind: RuleKind,
        value rawValue: String
    ) throws -> RuleEditMutation {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(value, kind: kind), compatible(original.kind, kind) else {
            throw NekoPilotError.invalidRule
        }
        guard let index = current.firstIndex(where: { $0.id == original.id }) else {
            throw NekoPilotError.invalidRule
        }
        if original.action == action, original.kind == kind, original.value == value {
            return RuleEditMutation(rules: current, unchanged: true, hasCrossActionConflict: false)
        }
        guard !current.contains(where: {
            $0.id != original.id && $0.action == action && $0.kind == kind && $0.value == value
        }) else {
            throw NekoPilotError.duplicateRule
        }

        let conflict = current.contains(where: {
            $0.id != original.id && $0.action != action && $0.value == value
        })
        var next = current
        next[index].action = action
        next[index].kind = kind
        next[index].value = value
        return RuleEditMutation(
            rules: sorted(next),
            unchanged: false,
            hasCrossActionConflict: conflict
        )
    }

    public static func compatibleKinds(for kind: RuleKind) -> [RuleKind] {
        kind == .ipCIDR ? [.ipCIDR] : [.domain, .domainSuffix]
    }

    public static func isValid(_ value: String, kind: RuleKind) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.contains(where: \.isWhitespace), !value.contains("://") else { return false }
        guard kind == .ipCIDR else { return true }
        guard let slash = value.lastIndex(of: "/"),
              let prefix = Int(value[value.index(after: slash)...]) else { return false }
        let address = String(value[..<slash])
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let isV4 = address.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        let isV6 = address.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
        return (isV4 && (0 ... 32).contains(prefix)) || (isV6 && (0 ... 128).contains(prefix))
    }

    public static func sorted(_ rules: [RoutingRule]) -> [RoutingRule] {
        let actionOrder: [RuleAction: Int] = [.direct: 0, .proxy: 1]
        let kindOrder: [RuleKind: Int] = [.domain: 0, .domainSuffix: 1, .ipCIDR: 2]
        return rules.sorted { lhs, rhs in
            if actionOrder[lhs.action] != actionOrder[rhs.action] {
                return actionOrder[lhs.action, default: 0] < actionOrder[rhs.action, default: 0]
            }
            if kindOrder[lhs.kind] != kindOrder[rhs.kind] {
                return kindOrder[lhs.kind, default: 0] < kindOrder[rhs.kind, default: 0]
            }
            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }
    }

    private static func split(_ rawInput: String) -> [String] {
        rawInput
            .split(whereSeparator: { ["\n", "\r", ",", "，"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func compatible(_ lhs: RuleKind, _ rhs: RuleKind) -> Bool {
        (lhs == .ipCIDR) == (rhs == .ipCIDR)
    }
}
