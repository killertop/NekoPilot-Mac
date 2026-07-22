import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Automatic node selection decisions")
struct AutoNodeSelectionDecisionTests {
    @Test("Small transient improvements keep the current node")
    func ignoresSmallImprovement() {
        var state = AutoNodeSelectionDecisionState()
        let decision = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: delays(current: 120, candidate: 90),
            now: Date(timeIntervalSince1970: 1_000),
            state: &state
        )

        #expect(decision == .keep(node: "current", delay: 120))
        #expect(state.candidate == nil)
    }

    @Test("A large absolute change still needs a meaningful relative improvement")
    func requiresRelativeImprovement() {
        var state = AutoNodeSelectionDecisionState()
        let decision = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: delays(current: 1_000, candidate: 940),
            now: Date(timeIntervalSince1970: 1_000),
            state: &state
        )

        #expect(decision == .keep(node: "current", delay: 1_000))
    }

    @Test("A clearly faster node must win two consecutive cycles")
    func requiresTwoConfirmations() {
        var state = AutoNodeSelectionDecisionState()
        let first = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: delays(current: 300, candidate: 100),
            now: Date(timeIntervalSince1970: 1_000),
            state: &state
        )
        let second = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: delays(current: 290, candidate: 105),
            now: Date(timeIntervalSince1970: 1_600),
            state: &state
        )

        #expect(first == .considering(node: "candidate", delay: 100, confirmations: 1, retrySoon: false))
        #expect(second == .switchTo(node: "candidate", delay: 105))
    }

    @Test("An unavailable current node receives one quick confirmation")
    func confirmsFailureBeforeFailover() {
        var state = AutoNodeSelectionDecisionState()
        let records = [
            "current": DelayRecord(delay: nil),
            "candidate": DelayRecord(delay: 95),
        ]
        let first = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: records,
            now: Date(timeIntervalSince1970: 1_000),
            state: &state
        )
        let second = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: records,
            now: Date(timeIntervalSince1970: 1_003),
            state: &state
        )

        #expect(first == .considering(node: "candidate", delay: 95, confirmations: 1, retrySoon: true))
        #expect(second == .switchTo(node: "candidate", delay: 95))
    }

    @Test("The switch cooldown prevents immediate oscillation")
    func respectsSwitchCooldown() {
        var state = AutoNodeSelectionDecisionState(
            lastSwitchAt: Date(timeIntervalSince1970: 900)
        )
        let decision = AutoNodeSelectionDecision.evaluate(
            currentNode: "current",
            delays: delays(current: 300, candidate: 80),
            now: Date(timeIntervalSince1970: 1_000),
            state: &state
        )

        #expect(decision == .keep(node: "current", delay: 300))
    }

    private func delays(current: Int, candidate: Int) -> [String: DelayRecord] {
        [
            "current": DelayRecord(delay: current),
            "candidate": DelayRecord(delay: candidate),
        ]
    }
}
