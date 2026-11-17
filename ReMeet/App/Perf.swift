import Darwin
import Foundation
import os

/// Developer timing marks for docs/performance.md. Each mark is milliseconds since the
/// kernel started the process (so it includes dyld and framework loading), written to the
/// unified log (subsystem com.moizfakhri.ReMeet, category perf) and to stdout.
enum Perf {
    private static let logger = Logger(subsystem: "com.moizfakhri.ReMeet", category: "perf")

    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()

    static func mark(_ name: String) {
        let ms = Date().timeIntervalSince(processStart) * 1000
        logger.log("perf \(name, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms")
        print(String(format: "PERF %@ %.1f ms", name, ms))
        fflush(stdout)
    }

    /// Duration of a block in ms, logged.
    @discardableResult
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            logger.log("perf \(name, privacy: .public) took \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            print(String(format: "PERF %@ took %.1f ms", name, ms))
            fflush(stdout)
        }
        return try body()
    }

    static var recordNow: Bool { CommandLine.arguments.contains("--perf-record-now") }
    static var openWindow: Bool { CommandLine.arguments.contains("--perf-open-window") }
}
