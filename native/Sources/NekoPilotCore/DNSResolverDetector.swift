import Darwin
import Foundation

/// Reads the resolver order selected by macOS instead of assuming that one
/// public DNS service is reachable on every network.
public enum DNSResolverDetector {
    public static let fallback = "223.5.5.5"

    public static func detectSystemResolver() async -> String? {
        do {
            let result = try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
                arguments: ["--dns"],
                timeout: 5
            )
            guard result.status == 0 else { return nil }
            return parseResolvers(from: result.output).first
        } catch {
            AppLogger.shared.warning("system DNS detection failed: \(error.localizedDescription)")
            return nil
        }
    }

    public static func parseResolvers(from output: String) -> [String] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("nameserver[") else { return nil }
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let raw = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let address = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
            guard isUsableIPAddress(address), seen.insert(address).inserted else { return nil }
            return address
        }
    }

    public static func isUsableIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let host = UInt32(bigEndian: ipv4.s_addr)
            let firstOctet = host >> 24
            return host != 0 && firstOctet < 224
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return bytes.contains(where: { $0 != 0 }) && bytes.first != 0xff
        }
        return false
    }
}
