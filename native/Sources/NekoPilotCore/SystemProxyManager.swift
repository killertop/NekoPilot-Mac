import Darwin
import Foundation

public actor SystemProxyManager {
    private let markerURL: URL
    private let executable = URL(fileURLWithPath: "/usr/sbin/networksetup")
    private let host = "127.0.0.1"
    private let transaction = AsyncMutex()
    private var activeSession: UUID?

    public init(markerURL: URL) {
        self.markerURL = markerURL
    }

    public func recoverStaleOwnership() async throws {
        try await withTransaction {
            guard let marker = try self.readMarker() else { return }
            if self.markerBelongsToLiveOtherProcess(marker) {
                AppLogger.shared.info("system proxy belongs to live NekoPilot pid=\(marker.pid); preserving")
                return
            }
            AppLogger.shared.warning("recovering stale system proxy session=\(marker.sessionID)")
            try await self.restoreLocked(marker)
        }
    }

    @discardableResult
    public func apply(port: Int, bypassDomains: [String] = []) async throws -> UUID {
        try await withTransaction {
            if let existing = try self.readMarker() {
                if existing.pid == getpid(), existing.port == port,
                   let session = UUID(uuidString: existing.sessionID) {
                    self.activeSession = session
                    return session
                }
                guard !self.markerBelongsToLiveOtherProcess(existing) else {
                    throw NekoPilotError.processFailed("另一个 NekoPilot 实例正在管理系统代理")
                }
                try await self.restoreLocked(existing)
            }

            let services = try await self.networkServices()
            let snapshots = try await services.asyncMap { try await self.snapshot(service: $0) }
            let prepared = snapshots.map {
                $0.withAppliedBypass(self.ownedBypass(existing: $0.bypassDomains, extra: bypassDomains))
            }
            let session = UUID()
            let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let marker = OwnershipMarker(
                owner: "NekoPilot",
                host: self.host,
                port: port,
                pid: getpid(),
                executablePath: executablePath,
                processIdentity: ProcessIdentity.current(executablePath: executablePath),
                sessionID: session.uuidString,
                createdAt: Date(),
                services: prepared
            )
            try self.writeMarker(marker)
            do {
                for backup in prepared {
                    try await self.setOwnedProxy(
                        service: backup.name,
                        port: port,
                        bypass: backup.appliedBypassDomains ?? []
                    )
                }
                self.activeSession = session
                AppLogger.shared.info("system proxy applied to \(prepared.count) services on \(self.host):\(port)")
                return session
            } catch {
                AppLogger.shared.error("system proxy apply failed: \(error.localizedDescription)")
                do {
                    try await self.restoreLocked(marker)
                } catch {
                    AppLogger.shared.error("system proxy rollback failed; marker retained: \(error.localizedDescription)")
                }
                throw error
            }
        }
    }

    public func removeOwnedProxy(expectedSession: UUID? = nil) async throws {
        try await withTransaction {
            guard let marker = try self.readMarker() else {
                self.activeSession = nil
                return
            }
            if let expectedSession, marker.sessionID != expectedSession.uuidString {
                AppLogger.shared.info("skipping proxy cleanup for superseded session=\(expectedSession)")
                return
            }
            try await self.restoreLocked(marker)
        }
    }

    private func withTransaction<T>(_ body: () async throws -> T) async throws -> T {
        await transaction.lock()
        do {
            let result = try await body()
            await transaction.unlock()
            return result
        } catch {
            await transaction.unlock()
            throw error
        }
    }

    private func restoreLocked(_ marker: OwnershipMarker) async throws {
        let availableServices = Set(try await networkServices())
        var failures: [String] = []
        for backup in marker.services {
            guard availableServices.contains(backup.name) else {
                AppLogger.shared.info("network service removed; skipping proxy restore for \(backup.name)")
                continue
            }
            do {
                let current = try await snapshot(service: backup.name)
                try await restore(kind: .web, current: current.web, state: backup.web, service: backup.name, marker: marker)
                try await restore(kind: .secureWeb, current: current.secureWeb, state: backup.secureWeb, service: backup.name, marker: marker)
                try await restore(kind: .socks, current: current.socks, state: backup.socks, service: backup.name, marker: marker)
                if let appliedBypass = backup.appliedBypassDomains,
                   Set(current.bypassDomains) == Set(appliedBypass) {
                    try await setBypass(backup.bypassDomains, service: backup.name)
                }
            } catch {
                failures.append("\(backup.name): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw NekoPilotError.processFailed("系统代理恢复失败：\(failures.joined(separator: "; "))")
        }
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
        activeSession = nil
        AppLogger.shared.info("system proxy ownership released")
    }

    private func restore(
        kind: ProxyKind,
        current: ProxyState,
        state: ProxyState,
        service: String,
        marker: OwnershipMarker
    ) async throws {
        guard current.enabled, current.server == marker.host, current.port == marker.port else {
            return
        }
        if !state.server.isEmpty, state.port > 0 {
            try await checked([kind.setCommand, service, state.server, String(state.port)])
        }
        try await checked([kind.stateCommand, service, state.enabled ? "on" : "off"])
    }

    private func setOwnedProxy(service: String, port: Int, bypass: [String]) async throws {
        for kind in ProxyKind.allCases {
            try await checked([kind.setCommand, service, host, String(port)])
            try await checked([kind.stateCommand, service, "on"])
        }
        try await setBypass(bypass, service: service)
    }

    private func ownedBypass(existing: [String], extra: [String]) -> [String] {
        let required = [
            "localhost", "127.0.0.1", "::1", "*.local", "169.254/16",
            "10/8", "172.16/12", "192.168/16",
        ]
        return Array(Set(existing + required + extra)).sorted()
    }

    private func networkServices() async throws -> [String] {
        let result = try await checked(["-listallnetworkservices"])
        return result.output
            .components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    private func snapshot(service: String) async throws -> ServiceBackup {
        ServiceBackup(
            name: service,
            web: try await proxyState(.web, service: service),
            secureWeb: try await proxyState(.secureWeb, service: service),
            socks: try await proxyState(.socks, service: service),
            bypassDomains: try await bypassDomains(service: service),
            appliedBypassDomains: nil
        )
    }

    private func proxyState(_ kind: ProxyKind, service: String) async throws -> ProxyState {
        let result = try await checked([kind.getCommand, service])
        var values: [String: String] = [:]
        for line in result.output.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            values[String(line[..<separator]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        return ProxyState(
            enabled: values["Enabled"]?.lowercased() == "yes",
            server: values["Server"] ?? "",
            port: Int(values["Port"] ?? "") ?? 0
        )
    }

    private func bypassDomains(service: String) async throws -> [String] {
        let result = try await checked(["-getproxybypassdomains", service])
        if result.output.lowercased().contains("aren't any") { return [] }
        return result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func setBypass(_ domains: [String], service: String) async throws {
        try await checked(["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains))
    }

    @discardableResult
    private func checked(_ arguments: [String]) async throws -> CommandResult {
        let result = try await CommandRunner.run(executable: executable, arguments: arguments, timeout: 15)
        guard result.status == 0 else {
            let message = result.errorOutput.isEmpty ? result.output : result.errorOutput
            throw NekoPilotError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private func readMarker() throws -> OwnershipMarker? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OwnershipMarker.self, from: Data(contentsOf: markerURL))
    }

    private func writeMarker(_ marker: OwnershipMarker) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(marker), to: markerURL)
    }

    private func markerBelongsToLiveOtherProcess(_ marker: OwnershipMarker) -> Bool {
        guard marker.pid != getpid() else { return false }
        if let identity = marker.processIdentity { return ProcessIdentity.matches(identity) }
        guard pidIsAlive(marker.pid) else { return false }
        return ProcessIdentity.record(
            pid: marker.pid,
            expectedExecutablePath: marker.executablePath
        ) != nil
    }
}

private actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private enum ProxyKind: CaseIterable {
    case web, secureWeb, socks

    var getCommand: String {
        switch self {
        case .web: "-getwebproxy"
        case .secureWeb: "-getsecurewebproxy"
        case .socks: "-getsocksfirewallproxy"
        }
    }

    var setCommand: String {
        switch self {
        case .web: "-setwebproxy"
        case .secureWeb: "-setsecurewebproxy"
        case .socks: "-setsocksfirewallproxy"
        }
    }

    var stateCommand: String {
        switch self {
        case .web: "-setwebproxystate"
        case .secureWeb: "-setsecurewebproxystate"
        case .socks: "-setsocksfirewallproxystate"
        }
    }
}

private struct ProxyState: Codable, Sendable {
    let enabled: Bool
    let server: String
    let port: Int
}

private struct ServiceBackup: Codable, Sendable {
    let name: String
    let web: ProxyState
    let secureWeb: ProxyState
    let socks: ProxyState
    let bypassDomains: [String]
    let appliedBypassDomains: [String]?

    func withAppliedBypass(_ domains: [String]) -> ServiceBackup {
        ServiceBackup(
            name: name,
            web: web,
            secureWeb: secureWeb,
            socks: socks,
            bypassDomains: bypassDomains,
            appliedBypassDomains: domains
        )
    }
}

private struct OwnershipMarker: Codable, Sendable {
    let owner: String
    let host: String
    let port: Int
    let pid: Int32
    let executablePath: String
    let processIdentity: ProcessIdentityRecord?
    let sessionID: String
    let createdAt: Date
    let services: [ServiceBackup]
}

private func pidIsAlive(_ pid: Int32) -> Bool {
    pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
