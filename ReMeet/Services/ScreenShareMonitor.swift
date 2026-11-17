import AppKit
import ReMeetKit

/// Looks at running apps and on-screen window titles. Window titles can be blank without
/// Screen Recording permission; this does not ask for that permission. Process names are enough
/// for Zoom's capture helper.
enum ScreenShareMonitor {
    static var isSharing: Bool {
        ScreenShare.reason(processes: processNames(), windows: windows()) != nil
    }

    private static func processNames() -> [String] {
        NSWorkspace.shared.runningApplications.flatMap { app in
            [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 }
        }
    }

    private static func windows() -> [ShareWindow] {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            let title = item[kCGWindowName as String] as? String ?? ""
            guard !owner.isEmpty || !title.isEmpty else { return nil }
            return ShareWindow(owner: owner, title: title)
        }
    }
}
