import Darwin
import Foundation

struct ProcessIdentityRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum ProcessIdentity {
    static func current(executablePath: String? = nil) -> ProcessIdentityRecord? {
        record(
            pid: getpid(),
            expectedExecutablePath: executablePath ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        )
    }

    static func record(
        pid: Int32,
        expectedExecutablePath: String? = nil
    ) -> ProcessIdentityRecord? {
        guard pid > 1, kill(pid, 0) == 0 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1_024)
        let pathCount = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathCount > 0 else { return nil }
        let executablePath = String(cString: pathBuffer)
        if let expectedExecutablePath,
           URL(fileURLWithPath: executablePath).standardizedFileURL.path !=
           URL(fileURLWithPath: expectedExecutablePath).standardizedFileURL.path {
            return nil
        }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else { return nil }
        return ProcessIdentityRecord(
            pid: pid,
            executablePath: executablePath,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    static func matches(_ expected: ProcessIdentityRecord) -> Bool {
        guard let actual = record(
            pid: expected.pid,
            expectedExecutablePath: expected.executablePath
        ) else { return false }
        return actual == expected
    }
}
