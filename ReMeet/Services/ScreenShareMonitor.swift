import AppKit
import CoreGraphics
import Darwin
import ReMeetKit

/// Looks at running processes (via BSD `proc_listallpids` + `NSWorkspace`) and on-screen window
/// metadata (`CGWindowListCopyWindowInfo`) to detect active screen sharing.
/// Does not ask for Screen Recording permission: `proc_listallpids` sees Zoom's `CptHost` helper
/// and `screencapture` directly, and elevated full-display window layers catch Teams/Zoom sharing
/// borders even when `kCGWindowName` is redacted by macOS.
enum ScreenShareMonitor {
    static var isSharing: Bool {
        ScreenShare.reason(processes: processNames(), windows: windows(), displaySizes: displaySizes()) != nil
    }

    private static func processNames() -> [String] {
        var names = NSWorkspace.shared.runningApplications.flatMap { app in
            [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        }
        // `NSWorkspace.runningApplications` only lists GUI/LS-registered apps and can miss
        // helper binaries like Zoom's `CptHost` or `/usr/sbin/screencapture`.
        let byteCount = proc_listallpids(nil, 0)
        if byteCount > 0 {
            let count = Int(byteCount) / MemoryLayout<pid_t>.size + 64
            var pids = [pid_t](repeating: 0, count: count)
            let actualBytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            let actualCount = max(0, Int(actualBytes) / MemoryLayout<pid_t>.size)
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
            for i in 0..<actualCount {
                let pid = pids[i]
                guard pid > 0 else { continue }
                let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                if len > 0 {
                    names.append(String(cString: nameBuffer))
                }
            }
        }
        return names
    }

    private static func displaySizes() -> [(width: Double, height: Double)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { id in
            let b = CGDisplayBounds(id)
            return (width: Double(b.width), height: Double(b.height))
        }
    }

    private static func windows() -> [ShareWindow] {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            let title = item[kCGWindowName as String] as? String ?? ""
            guard !owner.isEmpty || !title.isEmpty else { return nil }
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            let bounds = item[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            return ShareWindow(owner: owner, title: title, layer: layer, width: width, height: height)
        }
    }
}
