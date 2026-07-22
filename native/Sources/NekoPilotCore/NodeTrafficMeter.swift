import Foundation

/// Converts sing-box connection events into per-outbound byte rates.
///
/// The daemon reports deltas for established connections, while close events
/// carry final cumulative totals. Keeping a baseline per connection lets the
/// meter include bytes transferred by short-lived connections without counting
/// traffic that predates a reset or subscription.
actor NodeTrafficMeter {
    private struct ConnectionState: Sendable {
        let outbound: String
        var uploadTotal: Int64
        var downloadTotal: Int64
    }

    private struct PendingTraffic: Sendable {
        var upload: Int64 = 0
        var download: Int64 = 0
    }

    private let validOutbounds: Set<String>
    private var connections: [String: ConnectionState] = [:]
    private var pending: [String: PendingTraffic] = [:]

    init(validOutbounds: Set<String>) {
        self.validOutbounds = validOutbounds
    }

    func apply(_ message: Nekopilot_Api_ConnectionEvents) {
        if message.reset {
            connections.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            for event in message.events {
                guard event.type == .connectionEventNew else { continue }
                seed(event)
            }
            return
        }

        for event in message.events {
            switch event.type {
            case .connectionEventNew:
                seed(event)
            case .connectionEventUpdate:
                applyUpdate(event)
            case .connectionEventClosed:
                close(event)
            case .UNRECOGNIZED:
                continue
            }
        }
    }

    /// Consumes all bytes observed since the previous snapshot and normalizes
    /// them to bytes per second. The returned dictionary is sparse: a missing
    /// outbound has zero traffic for this interval.
    func takeSnapshot(
        elapsedNanoseconds: UInt64,
        measuredAt: Date = Date()
    ) -> [String: NodeTrafficSnapshot] {
        guard elapsedNanoseconds > 0 else { return [:] }
        let captured = pending
        pending.removeAll(keepingCapacity: true)
        return captured.reduce(into: [:]) { result, item in
            let upload = Self.bytesPerSecond(item.value.upload, elapsedNanoseconds: elapsedNanoseconds)
            let download = Self.bytesPerSecond(item.value.download, elapsedNanoseconds: elapsedNanoseconds)
            guard upload > 0 || download > 0 else { return }
            result[item.key] = NodeTrafficSnapshot(
                upload: upload,
                download: download,
                measuredAt: measuredAt
            )
        }
    }

    private func seed(_ event: Nekopilot_Api_ConnectionEvent) {
        guard event.hasConnection else { return }
        let connection = event.connection
        let identifier = identifier(for: event)
        guard !identifier.isEmpty,
              connection.closedAt <= 0,
              validOutbounds.contains(connection.outbound) else { return }
        connections[identifier] = ConnectionState(
            outbound: connection.outbound,
            uploadTotal: max(0, connection.uplinkTotal),
            downloadTotal: max(0, connection.downlinkTotal)
        )
    }

    private func applyUpdate(_ event: Nekopilot_Api_ConnectionEvent) {
        let identifier = identifier(for: event)
        guard var state = connections[identifier] else { return }
        let upload = max(0, event.uplinkDelta)
        let download = max(0, event.downlinkDelta)
        accumulate(outbound: state.outbound, upload: upload, download: download)
        state.uploadTotal = Self.saturatingAdd(state.uploadTotal, upload)
        state.downloadTotal = Self.saturatingAdd(state.downloadTotal, download)
        connections[identifier] = state
    }

    private func close(_ event: Nekopilot_Api_ConnectionEvent) {
        let identifier = identifier(for: event)
        guard var state = connections.removeValue(forKey: identifier) else { return }

        let explicitUpload = max(0, event.uplinkDelta)
        let explicitDownload = max(0, event.downlinkDelta)
        if explicitUpload > 0 || explicitDownload > 0 {
            accumulate(outbound: state.outbound, upload: explicitUpload, download: explicitDownload)
            state.uploadTotal = Self.saturatingAdd(state.uploadTotal, explicitUpload)
            state.downloadTotal = Self.saturatingAdd(state.downloadTotal, explicitDownload)
        }

        guard event.hasConnection else { return }
        let final = event.connection
        // A final total lower than the last observed value means the daemon's
        // counter restarted. Treat it as a new baseline rather than a huge
        // wrapped delta.
        let remainingUpload = Self.positiveDifference(final.uplinkTotal, state.uploadTotal)
        let remainingDownload = Self.positiveDifference(final.downlinkTotal, state.downloadTotal)
        accumulate(outbound: state.outbound, upload: remainingUpload, download: remainingDownload)
    }

    private func identifier(for event: Nekopilot_Api_ConnectionEvent) -> String {
        if !event.id.isEmpty { return event.id }
        return event.hasConnection ? event.connection.id : ""
    }

    private func accumulate(outbound: String, upload: Int64, download: Int64) {
        guard upload > 0 || download > 0 else { return }
        var value = pending[outbound, default: PendingTraffic()]
        value.upload = Self.saturatingAdd(value.upload, upload)
        value.download = Self.saturatingAdd(value.download, download)
        pending[outbound] = value
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private static func positiveDifference(_ final: Int64, _ baseline: Int64) -> Int64 {
        guard final > baseline, final >= 0, baseline >= 0 else { return 0 }
        return final - baseline
    }

    private static func bytesPerSecond(_ bytes: Int64, elapsedNanoseconds: UInt64) -> Int64 {
        guard bytes > 0 else { return 0 }
        let rate = Double(bytes) * 1_000_000_000 / Double(elapsedNanoseconds)
        guard rate.isFinite else { return Int64.max }
        return Int64(min(rate.rounded(), Double(Int64.max)))
    }
}
