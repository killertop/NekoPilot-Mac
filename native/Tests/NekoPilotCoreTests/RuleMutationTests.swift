import Testing
@testable import NekoPilotCore

@Suite("Routing rule mutations")
struct RuleMutationTests {
    @Test("Bulk input accepts line breaks and commas while skipping duplicates")
    func bulkAdd() throws {
        let current = [rule(.direct, .domain, "existing.example")]
        let result = try RuleMutation.add(
            to: current,
            action: .direct,
            kind: .domain,
            rawInput: "new.example\nexisting.example，third.example, new.example"
        )

        #expect(result.added == 2)
        #expect(result.duplicates == 2)
        #expect(result.rules.map(\.value) == ["existing.example", "new.example", "third.example"])
    }

    @Test("The same value under another action is reported as a conflict")
    func crossActionConflict() throws {
        let result = try RuleMutation.add(
            to: [rule(.proxy, .domain, "example.com")],
            action: .direct,
            kind: .domain,
            rawInput: "example.com"
        )
        #expect(result.hasCrossActionConflict)
    }

    @Test("Valid IPv4 and IPv6 CIDR values are accepted")
    func validCIDR() {
        #expect(RuleMutation.isValid("192.168.1.0/24", kind: .ipCIDR))
        #expect(RuleMutation.isValid("2001:db8::/32", kind: .ipCIDR))
    }

    @Test("Invalid CIDR values and proxy links are rejected")
    func invalidValues() {
        #expect(!RuleMutation.isValid("192.168.1.0/33", kind: .ipCIDR))
        #expect(!RuleMutation.isValid("2001:db8::/129", kind: .ipCIDR))
        #expect(!RuleMutation.isValid("vless://example.com", kind: .domain))
    }

    @Test("Rules sort in effective action and match order")
    func sorting() {
        let sorted = RuleMutation.sorted([
            rule(.proxy, .ipCIDR, "10.0.0.0/8"),
            rule(.direct, .domainSuffix, ".example.com"),
            rule(.direct, .domain, "example.com"),
            rule(.proxy, .domain, "proxy.example"),
        ])
        #expect(sorted.map { "\($0.action.rawValue):\($0.kind.rawValue)" } == [
            "direct:domain", "direct:domain_suffix", "proxy:domain", "proxy:ip_cidr",
        ])
    }

    @Test("Domain rules can switch between exact and suffix matching")
    func editDomainKind() throws {
        let original = rule(.direct, .domain, "example.com")
        let result = try RuleMutation.update(
            in: [original],
            original: original,
            action: .proxy,
            kind: .domainSuffix,
            value: ".example.com"
        )
        #expect(result.rules.first?.action == .proxy)
        #expect(result.rules.first?.kind == .domainSuffix)
    }

    @Test("CIDR rules cannot be converted into domain rules")
    func cidrClassIsLocked() {
        let original = rule(.direct, .ipCIDR, "10.0.0.0/8")
        #expect(throws: NekoPilotError.invalidRule) {
            try RuleMutation.update(
                in: [original],
                original: original,
                action: .direct,
                kind: .domain,
                value: "example.com"
            )
        }
    }

    @Test("Editing cannot create an exact duplicate")
    func duplicateEdit() {
        let original = rule(.direct, .domain, "one.example")
        let existing = rule(.direct, .domain, "two.example")
        #expect(throws: NekoPilotError.duplicateRule) {
            try RuleMutation.update(
                in: [original, existing],
                original: original,
                action: .direct,
                kind: .domain,
                value: "two.example"
            )
        }
    }

    private func rule(_ action: RuleAction, _ kind: RuleKind, _ value: String) -> RoutingRule {
        RoutingRule(action: action, kind: kind, value: value)
    }
}
