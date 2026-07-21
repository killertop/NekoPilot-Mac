import Darwin
import Foundation
import Testing
@testable import NekoPilotCore

@Suite("Subscription import validation")
struct SubscriptionImporterTests {
    @Test("Candidate validation failure never writes the real repository")
    func candidateValidationFailureNeverWritesRealRepository() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let importer = SubscriptionImporter(
            repository: repository,
            candidateValidator: { _ in
                throw NekoPilotError.processFailed("candidate rejected")
            }
        )

        do {
            _ = try await importer.importInput(
                "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Rejected"
            )
            Issue.record("Rejected candidate was imported")
        } catch let error as NekoPilotError {
            #expect(error == .processFailed("candidate rejected"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let subscriptions = try await repository.subscriptions()
        let nodes = try await repository.nodes()
        #expect(subscriptions.isEmpty)
        #expect(nodes.isEmpty)
    }

    @Test("Injected no-op validator permits a structurally valid import")
    func injectedNoOpValidatorPermitsValidImport() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let importer = SubscriptionImporter(
            repository: repository,
            candidateValidator: { _ in }
        )

        _ = try await importer.importInput(
            "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Accepted"
        )
        let subscriptions = try await repository.subscriptions()
        let nodes = try await repository.nodes()
        #expect(subscriptions.count == 1)
        #expect(nodes.map(\.originalTag) == ["VLESS · Accepted"])
    }

    @Test("Editing a local node replaces its name and link atomically")
    func editingLocalNodeReplacesNameAndLink() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let importer = SubscriptionImporter(repository: repository, candidateValidator: { _ in })
        let original = "vless://00000000-0000-0000-0000-000000000001@one.example:443?security=tls#Original"
        let replacement = "anytls://password@two.example:443?insecure=1#Replacement"
        let identifier = try await importer.importInput(original, name: "Before")

        try await importer.replace(identifier: identifier, rawInput: replacement, name: "After")

        let subscription = try #require(try await repository.subscription(identifier: identifier))
        let nodes = try await repository.nodes()
        #expect(subscription.name == "After")
        #expect(subscription.subscriptionURL == replacement)
        #expect(subscription.sourceType == .localLink)
        #expect(nodes.map(\.protocolName) == ["anytls"])
        #expect(nodes.map(\.originalTag) == ["ANYTLS · Replacement"])
    }

    @Test("Renaming an unchanged subscription is local and preserves its content timestamp")
    func renamingSubscriptionDoesNotFetchOrRewriteContent() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let url = "https://offline.example/sub"
        let identifier = try await repository.upsert(
            url: url,
            name: "Before",
            sourceType: .subscription,
            config: configuration([endpoint(tag: "kept", server: "example.com", port: 443)])
        )
        let before = try #require(try await repository.subscription(identifier: identifier))
        let importer = SubscriptionImporter(repository: repository) { _ in
            Issue.record("A name-only edit unexpectedly validated node content")
        }

        let result = try await importer.replace(identifier: identifier, rawInput: url, name: "  After  ")

        let after = try #require(try await repository.subscription(identifier: identifier))
        #expect(result == .renamed)
        #expect(after.name == "After")
        #expect(after.lastUpdateTime == before.lastUpdateTime)
        #expect(try await repository.nodes().map(\.originalTag) == ["kept"])
    }

    @Test("Invalid edit leaves the previous local node untouched")
    func invalidEditLeavesPreviousNodeUntouched() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let importer = SubscriptionImporter(repository: repository, candidateValidator: { _ in })
        let original = "vless://00000000-0000-0000-0000-000000000001@one.example:443?security=tls#Original"
        let identifier = try await importer.importInput(original, name: "Before")

        do {
            try await importer.replace(identifier: identifier, rawInput: "https://example.com/sub", name: "After")
            Issue.record("A local node accepted a subscription URL")
        } catch {
            // Expected: editing keeps the existing source type.
        }

        let subscription = try #require(try await repository.subscription(identifier: identifier))
        let nodes = try await repository.nodes()
        #expect(subscription.name == "Before")
        #expect(subscription.subscriptionURL == original)
        #expect(nodes.map(\.originalTag) == ["VLESS · Original"])
    }

    @Test(
        "Default candidate validator runs the bundled sing-box checker",
        .enabled(if: ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_SINGBOX_IMPORT"] == "1")
    )
    func defaultCandidateValidatorRunsBundledSingBoxChecker() async throws {
        let location = try temporaryRepositoryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let repository = try SubscriptionRepository(databaseURL: location.database)
        let importer = SubscriptionImporter(repository: repository)

        _ = try await importer.importInput(
            "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Checked"
        )
        let nodes = try await repository.nodes()
        #expect(nodes.map(\.originalTag) == ["VLESS · Checked"])
    }

    @Test("Structural validation accepts a normal endpoint")
    func structuralValidationAcceptsEndpoint() throws {
        let config = configuration([
            endpoint(tag: "node", server: "example.com", port: 443),
        ])
        #expect(try SubscriptionImporter.validateConfiguration(config) == config)
    }

    @Test("Structural validation rejects duplicate tags")
    func structuralValidationRejectsDuplicateTags() {
        #expect(throws: (any Error).self) {
            try SubscriptionImporter.validateConfiguration(configuration([
                endpoint(tag: "same", server: "one.example", port: 443),
                endpoint(tag: "same", server: "two.example", port: 443),
            ]))
        }
    }

    @Test("Structural validation rejects invalid endpoint fields")
    func structuralValidationRejectsInvalidEndpointFields() {
        #expect(throws: (any Error).self) {
            try SubscriptionImporter.validateConfiguration(configuration([
                endpoint(tag: "bad", server: "example.com", port: 0),
            ]))
        }
        #expect(throws: (any Error).self) {
            try SubscriptionImporter.validateConfiguration(configuration([
                .object(["type": .string("vless"), "tag": .string("missing")]),
            ]))
        }
    }

    @Test("Payload rejects oversized input before parsing")
    func payloadRejectsOversizedInputBeforeParsing() {
        let data = Data(repeating: 0x41, count: 8 * 1024 * 1024 + 1)
        do {
            _ = try SubscriptionImporter.parsePayload(data)
            Issue.record("Oversized payload was accepted")
        } catch let error as NekoPilotError {
            #expect(error == .responseTooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Private and special IPv4 addresses are blocked", arguments: [
        "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1",
        "172.16.0.1", "192.168.1.1", "192.0.2.1", "198.18.0.1",
        "198.51.100.1", "203.0.113.1", "224.0.0.1", "168.63.129.16",
    ])
    func privateAndSpecialIPv4AddressesAreBlocked(_ address: String) throws {
        #expect(!NetworkAddressPolicy.isPublicAddress(try ipv4(address)))
    }

    @Test("Public IPv4 address is accepted")
    func publicIPv4AddressIsAccepted() throws {
        #expect(NetworkAddressPolicy.isPublicAddress(try ipv4("1.1.1.1")))
    }

    @Test("Private and special IPv6 addresses are blocked", arguments: [
        "::1", "fe80::1", "fc00::1", "2001:db8::1", "2001::1", "2001:20::1",
        "2002::1", "3fff::1",
    ])
    func privateAndSpecialIPv6AddressesAreBlocked(_ address: String) throws {
        #expect(!NetworkAddressPolicy.isPublicAddress(try ipv6(address)))
    }

    @Test("Public IPv6 address is accepted")
    func publicIPv6AddressIsAccepted() throws {
        #expect(NetworkAddressPolicy.isPublicAddress(try ipv6("2606:4700:4700::1111")))
    }

    @Test("Literal loopback subscription URL is blocked")
    func literalLoopbackSubscriptionURLIsBlocked() {
        #expect(!NetworkAddressPolicy.isPublic(url: URL(string: "http://127.0.0.1/sub")!))
    }

    @Test(
        "Pinned HTTPS client preserves TLS hostname validation",
        .enabled(if: ProcessInfo.processInfo.environment["NEKOPILOT_VALIDATE_SUBSCRIPTION_HTTP"] == "1")
    )
    func pinnedHTTPSClientPreservesTLSHostnameValidation() async throws {
        let data = try await PinnedHTTPClient.fetch(
            url: URL(string: "https://example.com/")!,
            maximumBodyBytes: 64 * 1024,
            maximumURLBytes: 1_024,
            userAgent: "NekoPilot-Native-Check"
        )
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body.localizedCaseInsensitiveContains("example domain"))
    }

    @Test("HTTP parser handles Content-Length and a partial body")
    func httpParserHandlesContentLengthAndPartialBody() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe".utf8)
        #expect(try HTTPWireResponseParser.parse(partial, streamComplete: false, maximumBodyBytes: 10) == nil)

        let complete = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let parsed = try HTTPWireResponseParser.parse(
            complete,
            streamComplete: false,
            maximumBodyBytes: 10
        )
        let response = try #require(parsed)
        #expect(response.statusCode == 200)
        #expect(String(data: response.body, encoding: .utf8) == "hello")
    }

    @Test("HTTP parser handles chunked response and trailer")
    func httpParserHandlesChunkedResponseAndTrailer() throws {
        let responseText = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "4;name=value\r\nWiki\r\n5\r\npedia\r\n0\r\nX-End: yes\r\n\r\n"
        #expect(
            try HTTPWireResponseParser.parse(
                Data(responseText.utf8),
                streamComplete: false,
                maximumBodyBytes: 9
            ) == nil
        )
        let parsed = try HTTPWireResponseParser.parse(
            Data(responseText.utf8),
            streamComplete: true,
            maximumBodyBytes: 9
        )
        let response = try #require(parsed)
        #expect(String(data: response.body, encoding: .utf8) == "Wikipedia")
    }

    @Test("HTTP parser rejects oversized and conflicting responses")
    func httpParserRejectsOversizedAndConflictingResponses() {
        let tooLarge = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n".utf8)
        #expect(throws: (any Error).self) {
            try HTTPWireResponseParser.parse(tooLarge, streamComplete: false, maximumBodyBytes: 10)
        }
        let conflicting = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        )
        #expect(throws: (any Error).self) {
            try HTTPWireResponseParser.parse(conflicting, streamComplete: true, maximumBodyBytes: 10)
        }
        let unsupportedTransfer = Data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n".utf8
        )
        #expect(throws: (any Error).self) {
            try HTTPWireResponseParser.parse(unsupportedTransfer, streamComplete: true, maximumBodyBytes: 10)
        }
    }

    @Test("HTTP parser returns redirect without buffering body")
    func httpParserReturnsRedirectWithoutBufferingBody() throws {
        let header = Data("HTTP/1.1 302 Found\r\nLocation: /next\r\n\r\n".utf8)
        let parsed = try HTTPWireResponseParser.parse(
            header,
            streamComplete: false,
            maximumBodyBytes: 1
        )
        let response = try #require(parsed)
        #expect(response.statusCode == 302)
        #expect(response.headers["location"] == "/next")
        #expect(response.body.isEmpty)
    }

    private func configuration(_ outbounds: [JSONValue]) -> [String: JSONValue] {
        ["outbounds": .array(outbounds)]
    }

    private func endpoint(tag: String, server: String, port: Double) -> JSONValue {
        .object([
            "type": .string("vless"),
            "tag": .string(tag),
            "server": .string(server),
            "server_port": .number(port),
            "uuid": .string("uuid"),
        ])
    }

    private func ipv4(_ string: String) throws -> Data {
        var address = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw NekoPilotError.invalidLink
        }
        return Data(bytes: &address, count: MemoryLayout<in_addr>.size)
    }

    private func ipv6(_ string: String) throws -> Data {
        var address = in6_addr()
        guard string.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            throw NekoPilotError.invalidLink
        }
        return Data(bytes: &address, count: MemoryLayout<in6_addr>.size)
    }

    private func temporaryRepositoryLocation() throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoPilotImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("nekopilot.sqlite3"))
    }
}
