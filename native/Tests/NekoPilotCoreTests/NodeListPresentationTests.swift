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
