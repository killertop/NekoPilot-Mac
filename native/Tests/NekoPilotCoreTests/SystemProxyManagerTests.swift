import Foundation
import Testing
@testable import NekoPilotCore

@Suite("System proxy ownership handoff")
struct SystemProxyManagerTests {
    @Test("Successful handoff keeps every proxy kind enabled")
    func successfulHandoffNeverDisablesProxy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-SystemProxy-Handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fake = FakeNetworkSetup()
        let manager = SystemProxyManager(
            markerURL: root.appendingPathComponent("owner.json"),
            commandRunner: { arguments in await fake.run(arguments) }
        )
        let session = try await manager.apply(port: 16_789)
        let beforeHandoff = await fake.commands()

        try await manager.handoff(expectedSession: session, toPort: 16_790)

        let handoffCommands = Array((await fake.commands()).dropFirst(beforeHandoff.count))
        #expect(!handoffCommands.contains { $0.contains(" off") })
        #expect(await fake.snapshot() == .enabled(port: 16_790))
        let marker = try JSONValue.decodeObject(
            from: Data(contentsOf: root.appendingPathComponent("owner.json"))
        )
        #expect(marker["port"]?.numberValue == 16_790)

        try await manager.removeOwnedProxy(expectedSession: session)
        #expect(!(await fake.snapshot()).enabled)
    }

    @Test("Partial handoff failure rolls back to the old port without release")
    func failedHandoffRetainsOldProxyOwnership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilot-SystemProxy-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fake = FakeNetworkSetup()
        let manager = SystemProxyManager(
            markerURL: root.appendingPathComponent("owner.json"),
            commandRunner: { arguments in await fake.run(arguments) }
        )
        let session = try await manager.apply(port: 16_789)
        let beforeHandoff = await fake.commands()
        await fake.failNext(command: "-setsecurewebproxy")

        do {
            try await manager.handoff(expectedSession: session, toPort: 16_790)
            Issue.record("Expected the injected proxy command failure")
        } catch {
            // The manager must report the failed handoff while retaining the
            // old NekoPilot-owned listener and marker.
        }

        let handoffCommands = Array((await fake.commands()).dropFirst(beforeHandoff.count))
        #expect(!handoffCommands.contains { $0.contains(" off") })
        #expect(await fake.snapshot() == .enabled(port: 16_789))
        let marker = try JSONValue.decodeObject(
            from: Data(contentsOf: root.appendingPathComponent("owner.json"))
        )
        #expect(marker["port"]?.numberValue == 16_789)
    }
}

private actor FakeNetworkSetup {
    struct Snapshot: Equatable, Sendable {
        let enabled: Bool
        let port: Int

        static let disabled = Snapshot(enabled: false, port: 0)

        static func enabled(port: Int) -> Snapshot {
            Snapshot(enabled: true, port: port)
        }
    }

    private var web = Snapshot.disabled
    private var secureWeb = Snapshot.disabled
    private var socks = Snapshot.disabled
    private var bypass: [String] = []
    private var recordedCommands: [[String]] = []
    private var failingCommand: String?

    func failNext(command: String) {
        failingCommand = command
    }

    func commands() -> [[String]] { recordedCommands }

    func snapshot() -> Snapshot {
        guard web == secureWeb, secureWeb == socks else {
            return Snapshot(enabled: false, port: -1)
        }
        return web
    }

    func run(_ arguments: [String]) -> CommandResult {
        recordedCommands.append(arguments)
        guard let command = arguments.first else {
            return failure("missing command")
        }
        if failingCommand == command {
            failingCommand = nil
            return failure("injected failure")
        }

        switch command {
        case "-listallnetworkservices":
            return success("An asterisk denotes that a network service is disabled.\nWi-Fi\n")
        case "-getwebproxy":
            return success(proxyOutput(web))
        case "-getsecurewebproxy":
            return success(proxyOutput(secureWeb))
        case "-getsocksfirewallproxy":
            return success(proxyOutput(socks))
        case "-getproxybypassdomains":
            return bypass.isEmpty
                ? success("There aren't any bypass domains set on Wi-Fi.\n")
                : success(bypass.joined(separator: "\n") + "\n")
        case "-setwebproxy":
            web = Snapshot(enabled: web.enabled, port: Int(arguments[3]) ?? 0)
            return success()
        case "-setsecurewebproxy":
            secureWeb = Snapshot(enabled: secureWeb.enabled, port: Int(arguments[3]) ?? 0)
            return success()
        case "-setsocksfirewallproxy":
            socks = Snapshot(enabled: socks.enabled, port: Int(arguments[3]) ?? 0)
            return success()
        case "-setwebproxystate":
            web = Snapshot(enabled: arguments[2] == "on", port: web.port)
            return success()
        case "-setsecurewebproxystate":
            secureWeb = Snapshot(enabled: arguments[2] == "on", port: secureWeb.port)
            return success()
        case "-setsocksfirewallproxystate":
            socks = Snapshot(enabled: arguments[2] == "on", port: socks.port)
            return success()
        case "-setproxybypassdomains":
            bypass = arguments.dropFirst(2).first == "Empty"
                ? []
                : Array(arguments.dropFirst(2))
            return success()
        default:
            return failure("unsupported command")
        }
    }

    private func proxyOutput(_ value: Snapshot) -> String {
        "Enabled: \(value.enabled ? "Yes" : "No")\nServer: 127.0.0.1\nPort: \(value.port)\n"
    }

    private func success(_ output: String = "") -> CommandResult {
        CommandResult(status: 0, output: output, errorOutput: "")
    }

    private func failure(_ message: String) -> CommandResult {
        CommandResult(status: 1, output: "", errorOutput: message)
    }
}
