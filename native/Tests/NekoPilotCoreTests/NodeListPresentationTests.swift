import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Native node-list presentation")
struct NodeListPresentationTests {
    @Test("Protocol prefix is removed only when it matches the node protocol")
    func displayNameRemovesMatchingProtocolPrefix() {
        #expect(NodeListPresentation.displayName(for: node("VLESS · Tokyo", protocolName: "vless")) == "Tokyo")
        #expect(NodeListPresentation.displayName(for: node("Tokyo", protocolName: "vless")) == "Tokyo")
        #expect(NodeListPresentation.displayName(for: node("ANYTLS · Tokyo", protocolName: "vless")) == "ANYTLS · Tokyo")
    }

    @Test("Measured nodes sort by delay and unmeasured nodes remain last")
    func measuredNodesSortBeforeUnmeasuredNodes() {
        let nodes = [
            node("VLESS · C", protocolName: "vless"),
            node("VLESS · A", protocolName: "vless"),
            node("VLESS · B", protocolName: "vless"),
        ]
        let history = [
            nodes[0].runtimeTag: DelayRecord(delay: nil),
            nodes[1].runtimeTag: DelayRecord(delay: 180),
            nodes[2].runtimeTag: DelayRecord(delay: 90),
        ]

        #expect(NodeListPresentation.sorted(nodes, using: history).map(\.originalTag) == [
            "VLESS · B", "VLESS · A", "VLESS · C",
        ])
    }

    @Test("Equal and missing delay values use stable natural name ordering")
    func equalDelaysUseNaturalNameOrdering() {
        let nodes = [
            node("VLESS · HK 10", protocolName: "vless"),
            node("VLESS · HK 2", protocolName: "vless"),
            node("VLESS · HK 1", protocolName: "vless"),
        ]
        let history = Dictionary(uniqueKeysWithValues: nodes.prefix(2).map {
            ($0.runtimeTag, DelayRecord(delay: 100))
        })

        #expect(NodeListPresentation.sorted(nodes, using: history).map(\.originalTag) == [
            "VLESS · HK 2", "VLESS · HK 10", "VLESS · HK 1",
        ])
    }

    @Test("The active node stays first while remaining nodes sort by delay")
    func activeNodeIsPinnedBeforeLatencyOrder() {
        let nodes = [
            node("VLESS · Selected", protocolName: "vless"),
            node("VLESS · Fast", protocolName: "vless"),
            node("VLESS · Slow", protocolName: "vless"),
        ]
        let history = [
            nodes[0].runtimeTag: DelayRecord(delay: 180),
            nodes[1].runtimeTag: DelayRecord(delay: 60),
            nodes[2].runtimeTag: DelayRecord(delay: 240),
        ]

        #expect(NodeListPresentation.sorted(
            nodes,
            using: history,
            pinning: nodes[0].runtimeTag
        ).map(\.originalTag) == [
            "VLESS · Selected", "VLESS · Fast", "VLESS · Slow",
        ])
    }

    @Test("Pinning preserves strict ordering when duplicate runtime tags are present")
    func pinningDuplicateRuntimeTagsFallsBackToStableOrdering() {
        let slower = ProxyNode(
            sourceIdentifier: "source",
            sourceName: "Source",
            originalTag: "VLESS · Slower",
            runtimeTag: "@np:source:duplicate",
            protocolName: "vless",
            outbound: [:]
        )
        let faster = ProxyNode(
            sourceIdentifier: "source",
            sourceName: "Source",
            originalTag: "VLESS · Faster",
            runtimeTag: "@np:source:duplicate",
            protocolName: "vless",
            outbound: [:]
        )

        #expect(NodeListPresentation.sorted(
            [slower, faster],
            using: [slower.runtimeTag: DelayRecord(delay: 80)],
            pinning: slower.runtimeTag
        ).map(\.originalTag) == ["VLESS · Faster", "VLESS · Slower"])
    }

    @Test("Connection recommendation uses only fresh reachable history")
    func preferredConnectionNodeUsesFreshHistory() {
        let now = Date(timeIntervalSince1970: 10_000)
        let nodes = [
            node("VLESS · Old", protocolName: "vless"),
            node("VLESS · Fresh", protocolName: "vless"),
            node("VLESS · Timeout", protocolName: "vless"),
        ]
        let history = [
            nodes[0].runtimeTag: DelayRecord(delay: 40, measuredAt: now.addingTimeInterval(-3_600)),
            nodes[1].runtimeTag: DelayRecord(delay: 90, measuredAt: now.addingTimeInterval(-60)),
            nodes[2].runtimeTag: DelayRecord(delay: nil, measuredAt: now),
        ]

        let preferred = NodeListPresentation.preferredNode(nodes, using: history, now: now)
        #expect(preferred?.runtimeTag == nodes[1].runtimeTag)
    }

    @Test("Node counts are precomputed once per source")
    func countsNodesBySource() {
        let first = node("VLESS · A", protocolName: "vless")
        let second = node("VLESS · B", protocolName: "vless")
        let other = ProxyNode(
            sourceIdentifier: "other",
            sourceName: "Other",
            originalTag: "VLESS · C",
            runtimeTag: "@np:other:C",
            protocolName: "vless",
            outbound: [:]
        )
        #expect(NodeListPresentation.countsBySource([first, second, other]) == ["source": 2, "other": 1])
    }

    @Test("Rows precompute source labels and duplicate names")
    func rowsPrecomputeHomePresentation() {
        let first = node("VLESS · Tokyo", protocolName: "vless")
        let second = ProxyNode(
            sourceIdentifier: "other",
            sourceName: "Other source",
            originalTag: "VLESS · Tokyo",
            runtimeTag: "@np:other:Tokyo",
            protocolName: "vless",
            outbound: [:]
        )
        let rows = NodeListPresentation.rows([first, second], using: [:])
        #expect(rows.map(\.displayName) == ["Tokyo", "Tokyo"])
        #expect(rows.map(\.hasDuplicateDisplayName).allSatisfy { $0 })
        #expect(rows[1].sourceName == "Other source")
    }

    private func node(_ name: String, protocolName: String) -> ProxyNode {
        ProxyNode(
            sourceIdentifier: "source",
            sourceName: "Source",
            originalTag: name,
            runtimeTag: "@np:source:\(name)",
            protocolName: protocolName,
            outbound: [:]
        )
    }
}
