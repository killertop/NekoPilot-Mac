import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Per-node traffic meter")
struct NodeTrafficMeterTests {
    @Test("Reset establishes baselines without replaying historical traffic")
    func resetSeedsOnlyActiveKnownOutbounds() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a"])
        await meter.apply(batch(
            reset: true,
            events: [
                event(.connectionEventNew, id: "active", connection: connection(
                    id: "active", outbound: "node-a", upload: 100, download: 200
                )),
                event(.connectionEventNew, id: "direct", connection: connection(
                    id: "direct", outbound: "direct", upload: 1_000, download: 2_000
                )),
                event(.connectionEventNew, id: "closed", connection: connection(
                    id: "closed", outbound: "node-a", upload: 3_000, download: 4_000, closedAt: 1
                )),
            ]
        ))

        #expect(await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000).isEmpty)

        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "active", upload: 30, download: 70),
            event(.connectionEventUpdate, id: "direct", upload: 500, download: 900),
            event(.connectionEventUpdate, id: "closed", upload: 500, download: 900),
        ]))
        let measuredAt = Date(timeIntervalSince1970: 123)
        let sample = await meter.takeSnapshot(
            elapsedNanoseconds: 1_000_000_000,
            measuredAt: measuredAt
        )

        #expect(sample == [
            "node-a": NodeTrafficSnapshot(upload: 30, download: 70, measuredAt: measuredAt),
        ])
        #expect(await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000).isEmpty)
    }

    @Test("Concurrent connections aggregate by their real outbound")
    func aggregatesConnectionsAndNormalizesInterval() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a", "node-b"])
        await meter.apply(batch(reset: true, events: [
            event(.connectionEventNew, id: "a1", connection: connection(id: "a1", outbound: "node-a")),
            event(.connectionEventNew, id: "a2", connection: connection(id: "a2", outbound: "node-a")),
            event(.connectionEventNew, id: "b1", connection: connection(id: "b1", outbound: "node-b")),
        ]))
        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "a1", upload: 10, download: 40),
            event(.connectionEventUpdate, id: "a2", upload: 20, download: 60),
            event(.connectionEventUpdate, id: "b1", upload: 5, download: 25),
        ]))

        let sample = await meter.takeSnapshot(elapsedNanoseconds: 500_000_000)
        #expect(sample["node-a"]?.upload == 60)
        #expect(sample["node-a"]?.download == 200)
        #expect(sample["node-b"]?.upload == 10)
        #expect(sample["node-b"]?.download == 50)
    }

    @Test("Close events add final unreported bytes exactly once")
    func closeAddsOnlyRemainingTotals() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a"])
        await meter.apply(batch(reset: true, events: [
            event(.connectionEventNew, id: "short", connection: connection(
                id: "short", outbound: "node-a", upload: 10, download: 20
            )),
        ]))
        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "short", upload: 5, download: 7),
            event(.connectionEventClosed, id: "short", connection: connection(
                id: "short", outbound: "node-a", upload: 20, download: 40, closedAt: 2
            )),
            // A duplicate close must not replay the final cumulative totals.
            event(.connectionEventClosed, id: "short", connection: connection(
                id: "short", outbound: "node-a", upload: 20, download: 40, closedAt: 2
            )),
        ]))

        let sample = await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000)
        #expect(sample["node-a"]?.upload == 10)
        #expect(sample["node-a"]?.download == 20)
    }

    @Test("Reset discards pending bytes and replaces connection ownership")
    func laterResetClearsPendingState() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a", "node-b"])
        await meter.apply(batch(reset: true, events: [
            event(.connectionEventNew, id: "connection", connection: connection(
                id: "connection", outbound: "node-a"
            )),
        ]))
        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "connection", download: 500),
        ]))

        await meter.apply(batch(reset: true, events: [
            event(.connectionEventNew, id: "connection", connection: connection(
                id: "connection", outbound: "node-b", download: 500
            )),
        ]))
        #expect(await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000).isEmpty)

        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "connection", download: 80),
        ]))
        let sample = await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000)
        #expect(sample["node-a"] == nil)
        #expect(sample["node-b"]?.download == 80)
    }

    @Test("Connection payload ID is accepted when the event ID is empty")
    func connectionIDFallbackSupportsAllEvents() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a"])
        await meter.apply(batch(reset: true, events: [
            event(.connectionEventNew, id: "", connection: connection(
                id: "payload-id", outbound: "node-a"
            )),
        ]))
        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "", connection: connection(
                id: "payload-id", outbound: "node-a"
            ), download: 42),
            event(.connectionEventClosed, id: "", connection: connection(
                id: "payload-id", outbound: "node-a", download: 50, closedAt: 1
            )),
        ]))

        #expect(await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000)["node-a"]?.download == 50)
    }

    @Test("Invalid reset event and counter extremes do not create traffic")
    func malformedEventsAreIgnoredSafely() async {
        let meter = NodeTrafficMeter(validOutbounds: ["node-a"])
        await meter.apply(batch(reset: true, events: [
            event(.connectionEventUpdate, id: "bad", connection: connection(
                id: "bad", outbound: "node-a"
            ), download: 100),
            event(.connectionEventNew, id: "valid", connection: connection(
                id: "valid", outbound: "node-a", upload: Int64.max, download: Int64.max
            )),
        ]))
        await meter.apply(batch(events: [
            event(.connectionEventUpdate, id: "bad", download: 100),
            event(.connectionEventClosed, id: "valid", connection: connection(
                id: "valid", outbound: "node-a", upload: Int64.min, download: Int64.min, closedAt: 1
            )),
        ]))

        #expect(await meter.takeSnapshot(elapsedNanoseconds: 1_000_000_000).isEmpty)
    }

    private func batch(
        reset: Bool = false,
        events: [Nekopilot_Api_ConnectionEvent]
    ) -> Nekopilot_Api_ConnectionEvents {
        var value = Nekopilot_Api_ConnectionEvents()
        value.reset = reset
        value.events = events
        return value
    }

    private func event(
        _ type: Nekopilot_Api_ConnectionEventType,
        id: String,
        connection: Nekopilot_Api_Connection? = nil,
        upload: Int64 = 0,
        download: Int64 = 0
    ) -> Nekopilot_Api_ConnectionEvent {
        var value = Nekopilot_Api_ConnectionEvent()
        value.type = type
        value.id = id
        value.uplinkDelta = upload
        value.downlinkDelta = download
        if let connection { value.connection = connection }
        return value
    }

    private func connection(
        id: String,
        outbound: String,
        upload: Int64 = 0,
        download: Int64 = 0,
        closedAt: Int64 = 0
    ) -> Nekopilot_Api_Connection {
        var value = Nekopilot_Api_Connection()
        value.id = id
        value.outbound = outbound
        value.uplinkTotal = upload
        value.downlinkTotal = download
        value.closedAt = closedAt
        return value
    }
}
