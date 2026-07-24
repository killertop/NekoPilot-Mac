import Foundation
import Testing
@testable import NekoPilotCore

@Suite("URL Test scheduling")
struct URLTesterTests {
    @Test("Offline worker budget follows node count and available processors")
    func offlineWorkerBudget() {
        #expect(URLTester.offlineWorkerCount(for: 1, processors: 4) == 1)
        #expect(URLTester.offlineWorkerCount(for: 20, processors: 4) == 2)
        #expect(URLTester.offlineWorkerCount(for: 30, processors: 8) == 3)
        #expect(URLTester.offlineWorkerCount(for: 60, processors: 16) == 4)
    }
}

@Suite("Proxy health quorum")
struct ProxyHealthProbeTests {
    @Test(
        "Live health quorum reaches the running core",
        .enabled(if: ProcessInfo.processInfo.environment["NEKOPILOT_PROXY_HEALTH_PORT"] != nil)
    )
    func liveHealthQuorum() async {
        guard let rawPort = ProcessInfo.processInfo.environment["NEKOPILOT_PROXY_HEALTH_PORT"],
              let port = Int(rawPort) else {
            Issue.record("NEKOPILOT_PROXY_HEALTH_PORT is not a valid port")
            return
        }
        let result = await ProxyHealthProbe().check(port: port)
        guard case .reachable = result else {
            Issue.record("Expected a reachable health quorum, got \(result)")
            return
        }
    }

    @Test("Network readiness emits an initial snapshot")
    func networkReadinessInitialSnapshot() async {
        let readiness = NetworkReadiness()
        var iterator = readiness.states().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial != nil)
    }

    @Test("One blocked health target does not fail a healthy proxy")
    func blockedTargetDoesNotFailQuorum() async {
        let targets = [
            ProxyHealthTarget(
                url: URL(string: "https://fast.example/204")!,
                acceptableStatusCodes: [204]
            ),
            ProxyHealthTarget(
                url: URL(string: "https://slow.example/204")!,
                acceptableStatusCodes: [204]
            ),
            ProxyHealthTarget(
                url: URL(string: "https://blocked.example/204")!,
                acceptableStatusCodes: [204]
            ),
        ]
        let probe = ProxyHealthProbe(
            targets: targets,
            requiredReachableTargets: 2
        ) { target, _ in
            if target.host == "blocked.example" { return .unreachable }
            return target.host == "fast.example" ? .reachable(delay: 40) : .reachable(delay: 60)
        }
        #expect(await probe.check(port: 16_789) == .reachable(delay: 60))
    }

    @Test("A single health target cannot satisfy the quorum")
    func singleTargetDoesNotSatisfyQuorum() {
        #expect(
            ProxyHealthProbe.aggregate(
                results: [.reachable(delay: 40), .unreachable, .unreachable],
                requiredReachableTargets: 2
            ) == .unreachable
        )
    }

    @Test("Indeterminate health results remain indeterminate")
    func indeterminateResultIsPreserved() {
        #expect(
            ProxyHealthProbe.aggregate(
                results: [.reachable(delay: 40), .indeterminate, .unreachable],
                requiredReachableTargets: 2
            ) == .indeterminate
        )
    }
}
