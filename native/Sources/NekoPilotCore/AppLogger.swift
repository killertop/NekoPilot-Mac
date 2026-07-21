import Foundation

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let lock = NSLock()
    private var destination: URL?
    private let formatter = ISO8601DateFormatter()

    private init() {}

    public func configure(destination: URL) {
        lock.lock()
        self.destination = destination
        lock.unlock()
    }

    public func info(_ message: String) { write("INFO", message) }
    public func warning(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(formatter.string(from: Date())) [\(level)] \(clean)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let destination, let data = line.data(using: .utf8) else { return }
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try AtomicFile.write(data, to: destination)
                return
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            try rotateIfNeeded(destination)
        } catch {
            fputs("NekoPilot logging failed: \(error)\n", stderr)
        }
    }

    private func rotateIfNeeded(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 4 * 1024 * 1024 else { return }
        let archive = file.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: file, to: archive)
    }
}
