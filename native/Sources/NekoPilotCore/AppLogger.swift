import Foundation

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let lock = NSLock()
    private var destination: URL?
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private let formatter = ISO8601DateFormatter()

    private init() {}

    public func configure(destination: URL) {
        lock.lock()
        try? handle?.close()
        handle = nil
        currentSize = 0
        self.destination = destination
        lock.unlock()
    }

    public func info(_ message: String) { write("INFO", message) }
    public func warning(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(formatter.string(from: Date())) [\(level)] \(clean)\n"
        guard let destination, let data = line.data(using: .utf8) else { return }
        do {
            let handle = try openHandleIfNeeded(destination)
            try handle.write(contentsOf: data)
            currentSize += UInt64(data.count)
            if currentSize > 4 * 1024 * 1024 {
                try rotate(destination)
            }
        } catch {
            try? handle?.close()
            handle = nil
            currentSize = 0
            fputs("NekoPilot logging failed: \(error)\n", stderr)
        }
    }

    private func openHandleIfNeeded(_ file: URL) throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: file.path) {
            try AtomicFile.write(Data(), to: file)
        }
        let opened = try FileHandle(forWritingTo: file)
        currentSize = try opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotate(_ file: URL) throws {
        try handle?.close()
        handle = nil
        currentSize = 0
        let archive = file.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: file, to: archive)
    }
}
