import Testing
@testable import NekoPilotCore

@Suite("Async serial gate")
struct AsyncSerialGateTests {
    @Test("Queued control mutations preserve FIFO order")
    func serializesControlMutations() async throws {
        let gate = AsyncSerialGate()
        let probe = SerialGateProbe()

        let first = Task {
            try await gate.acquire()
            await probe.firstEntered()
            await probe.waitForFirstRelease()
            await gate.release()
        }
        await probe.waitUntilFirstEntered()

        let second = Task {
            await probe.secondAttempted()
            try await gate.acquire()
            await probe.secondEntered()
            await gate.release()
        }
        await probe.waitUntilSecondAttempted()
        let third = Task {
            await probe.thirdAttempted()
            try await gate.acquire()
            await probe.thirdEntered()
            await gate.release()
        }
        await probe.waitUntilThirdAttempted()
        #expect(await probe.entries == ["first"])

        await probe.releaseFirst()
        try await first.value
        try await second.value
        try await third.value
        #expect(await probe.entries == ["first", "second", "third"])
    }

    @Test("A cancelled waiter leaves the queue without entering")
    func cancelledWaiterIsRemoved() async throws {
        let gate = AsyncSerialGate()
        let probe = SerialGateProbe()

        let first = Task {
            try await gate.acquire()
            await probe.firstEntered()
            await probe.waitForFirstRelease()
            await gate.release()
        }
        await probe.waitUntilFirstEntered()

        let cancelled = Task {
            await probe.secondAttempted()
            do {
                try await gate.acquire()
                try Task.checkCancellation()
                await probe.secondEntered()
                await gate.release()
            } catch is CancellationError {
                await probe.secondCancelled()
            }
        }
        await probe.waitUntilSecondAttempted()
        cancelled.cancel()
        await probe.waitUntilSecondCancelled()

        let third = Task {
            try await gate.acquire()
            await probe.thirdEntered()
            await gate.release()
        }
        await probe.releaseFirst()

        try await first.value
        try await cancelled.value
        try await third.value
        #expect(await probe.entries == ["first", "third"])
    }
}

private actor SerialGateProbe {
    private(set) var entries: [String] = []
    private var didEnterFirst = false
    private var didAttemptSecond = false
    private var didAttemptThird = false
    private var didCancelSecond = false
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var thirdAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func firstEntered() {
        entries.append("first")
        didEnterFirst = true
        firstEntryWaiters.forEach { $0.resume() }
        firstEntryWaiters.removeAll()
    }

    func waitUntilFirstEntered() async {
        guard !didEnterFirst else { return }
        await withCheckedContinuation { firstEntryWaiters.append($0) }
    }

    func secondAttempted() {
        didAttemptSecond = true
        secondAttemptWaiters.forEach { $0.resume() }
        secondAttemptWaiters.removeAll()
    }

    func waitUntilSecondAttempted() async {
        guard !didAttemptSecond else { return }
        await withCheckedContinuation { secondAttemptWaiters.append($0) }
    }

    func secondEntered() {
        entries.append("second")
    }

    func secondCancelled() {
        didCancelSecond = true
        secondCancellationWaiters.forEach { $0.resume() }
        secondCancellationWaiters.removeAll()
    }

    func waitUntilSecondCancelled() async {
        guard !didCancelSecond else { return }
        await withCheckedContinuation { secondCancellationWaiters.append($0) }
    }

    func thirdAttempted() {
        didAttemptThird = true
        thirdAttemptWaiters.forEach { $0.resume() }
        thirdAttemptWaiters.removeAll()
    }

    func waitUntilThirdAttempted() async {
        guard !didAttemptThird else { return }
        await withCheckedContinuation { thirdAttemptWaiters.append($0) }
    }

    func thirdEntered() {
        entries.append("third")
    }

    func waitForFirstRelease() async {
        await withCheckedContinuation { firstRelease = $0 }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}
