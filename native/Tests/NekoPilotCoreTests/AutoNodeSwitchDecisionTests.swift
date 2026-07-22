import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Automatic node failover decisions")
struct AutoNodeSwitchDecisionTests {
    @Test("The first failed live probe only schedules confirmation")
    func confirmsFirstFailure() {
        var state = AutoNodeSwitchDecisionState()

        let decision = state.evaluate(node: "current", result: .unreachable)

        #expect(decision == .confirmFailure(node: "current", failures: 1))
        #expect(state.monitoredNode == "current")
        #expect(state.consecutiveFailures == 1)
    }

    @Test("Two consecutive failed live probes trigger candidate verification")
    func verifiesCandidatesAfterConsecutiveFailures() {
        var state = AutoNodeSwitchDecisionState()

        _ = state.evaluate(node: "current", result: .unreachable)
        let decision = state.evaluate(node: "current", result: .unreachable)

        #expect(decision == .verifyCandidates(node: "current"))
        #expect(state.consecutiveFailures == AutoNodeSwitchDecision.requiredFailures)
    }

    @Test("A successful probe resets the failure count")
    func successResetsFailures() {
        var state = AutoNodeSwitchDecisionState()

        _ = state.evaluate(node: "current", result: .unreachable)
        let healthy = state.evaluate(node: "current", result: .reachable(delay: 42))
        let nextFailure = state.evaluate(node: "current", result: .unreachable)

        #expect(healthy == .healthy(node: "current", delay: 42))
        #expect(nextFailure == .confirmFailure(node: "current", failures: 1))
        #expect(state.consecutiveFailures == 1)
    }

    @Test("Changing the selected node starts a fresh confirmation sequence")
    func nodeChangeResetsFailures() {
        var state = AutoNodeSwitchDecisionState()

        _ = state.evaluate(node: "old", result: .unreachable)
        let decision = state.evaluate(node: "new", result: .unreachable)

        #expect(decision == .confirmFailure(node: "new", failures: 1))
        #expect(state.monitoredNode == "new")
        #expect(state.consecutiveFailures == 1)
    }

    @Test("An indeterminate probe breaks the consecutive failure sequence")
    func indeterminateResetsFailures() {
        var state = AutoNodeSwitchDecisionState()

        _ = state.evaluate(node: "current", result: .unreachable)
        let indeterminate = state.evaluate(node: "current", result: .indeterminate)
        let nextFailure = state.evaluate(node: "current", result: .unreachable)

        #expect(indeterminate == .indeterminate(node: "current"))
        #expect(nextFailure == .confirmFailure(node: "current", failures: 1))
    }

    @Test("Candidates use saved latency order and reject corrupt delays")
    func ranksCandidatesBySavedLatency() {
        let nodes = [
            node("current"),
            node("slow"),
            node("unknown"),
            node("invalid"),
            node("fast-b"),
            node("fast-a"),
        ]
        let history = [
            "current": DelayRecord(delay: 5),
            "slow": DelayRecord(delay: 180),
            "unknown": DelayRecord(delay: nil),
            "invalid": DelayRecord(delay: -1),
            "fast-a": DelayRecord(delay: 40),
            "fast-b": DelayRecord(delay: 40),
        ]

        let candidates = AutoNodeSwitchCandidates.ranked(
            nodes: nodes,
            excluding: "current",
            history: history,
            limit: 2
        )

        #expect(candidates.map(\.runtimeTag) == ["fast-a", "fast-b"])
        let allCandidates = AutoNodeSwitchCandidates.ranked(
            nodes: nodes,
            excluding: "current",
            history: history,
            limit: 10
        )
        #expect(!allCandidates.map(\.runtimeTag).contains("invalid"))
    }

    @Test("A non-positive candidate limit performs no checks")
    func rejectsNonPositiveCandidateLimit() {
        let candidates = AutoNodeSwitchCandidates.ranked(
            nodes: [node("current"), node("candidate")],
            excluding: "current",
            history: ["candidate": DelayRecord(delay: 10)],
            limit: 0
        )

        #expect(candidates.isEmpty)
    }

    @Test("Nodes without saved latency fill the candidate batch deterministically")
    func fillsCandidatesWithoutHistory() {
        let candidates = AutoNodeSwitchCandidates.ranked(
            nodes: [node("current"), node("zulu"), node("alpha"), node("mike")],
            excluding: "current",
            history: [:],
            limit: 2
        )

        #expect(candidates.map(\.runtimeTag) == ["alpha", "mike"])
    }

    @Test("Recently failed nodes are skipped even when their saved latency is lowest")
    func skipsRecentlyFailedNodes() {
        let candidates = AutoNodeSwitchCandidates.rankedForFailover(
            nodes: [node("current"), node("failed-fast"), node("healthy-next")],
            excluding: "current",
            recentlyUnavailable: ["failed-fast"],
            history: [
                "failed-fast": DelayRecord(delay: 10),
                "healthy-next": DelayRecord(delay: 30),
            ],
            limit: 3
        )

        #expect(candidates.map(\.runtimeTag) == ["healthy-next"])
    }

    @Test("Cooldown falls back to the best candidate instead of leaving a dead node selected")
    func cooldownIsNotAHardBlacklist() {
        let candidates = AutoNodeSwitchCandidates.rankedForFailover(
            nodes: [node("current"), node("fast"), node("slow")],
            excluding: "current",
            recentlyUnavailable: ["fast", "slow"],
            history: [
                "fast": DelayRecord(delay: 20),
                "slow": DelayRecord(delay: 80),
            ],
            limit: 2
        )

        #expect(candidates.map(\.runtimeTag) == ["fast", "slow"])
    }

    @Test("A failed first batch advances to later candidates on the next cycle")
    func failedBatchDoesNotStarveLaterCandidates() {
        let candidates = AutoNodeSwitchCandidates.rankedForFailover(
            nodes: [node("current"), node("one"), node("two"), node("three"), node("four")],
            excluding: "current",
            recentlyUnavailable: ["one", "two", "three"],
            history: [
                "one": DelayRecord(delay: 10),
                "two": DelayRecord(delay: 20),
                "three": DelayRecord(delay: 30),
                "four": DelayRecord(delay: 40),
            ],
            limit: 3
        )

        #expect(candidates.map(\.runtimeTag) == ["four"])
    }

    @Test("The fastest result from one verification batch wins")
    func selectsFastestVerifiedCandidate() throws {
        let candidates = [node("history-fast"), node("history-slow"), node("unknown")]
        let verified = try #require(AutoNodeSwitchCandidates.fastestVerified(
            candidates: candidates,
            results: [
                "history-fast": DelayRecord(delay: 90),
                "history-slow": DelayRecord(delay: 35),
                "unknown": DelayRecord(delay: nil),
            ]
        ))

        #expect(verified.node.runtimeTag == "history-slow")
        #expect(verified.delay == 35)
    }

    private func node(_ tag: String) -> ProxyNode {
        ProxyNode(
            sourceIdentifier: "source",
            sourceName: "Source",
            originalTag: tag,
            runtimeTag: tag,
            protocolName: "test",
            outbound: [:]
        )
    }
}
