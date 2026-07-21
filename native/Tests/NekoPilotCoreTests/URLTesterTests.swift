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
