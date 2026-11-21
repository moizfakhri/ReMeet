import Foundation

public struct ShareWindow: Equatable, Sendable {
    public var owner: String
    public var title: String
    /// Window level from `kCGWindowLayer` (normal windows are 0; floating/sharing overlays are > 0).
    public var layer: Int
    public var width: Double
    public var height: Double

    public init(owner: String, title: String, layer: Int = 0, width: Double = 0, height: Double = 0) {
        self.owner = owner
        self.title = title
        self.layer = layer
        self.width = width
        self.height = height
    }
}

/// Decides whether the screen looks like it is being shared. A meeting app merely being
/// open is not enough: Zoom's meeting window stays up for the whole call, and its capture
/// helper (`CptHost`) only runs while the screen is shared.
///
/// Works both with and without macOS Screen Recording permission:
/// - Without permission, `kCGWindowName` is redacted to `""` by macOS, so detection relies on
///   capture helper processes (`CptHost`, `screencapture`), `CptHost` windows, and elevated-layer
///   full-display sharing border overlays drawn by Teams / Zoom.
/// - With permission, window title checks also match Teams, Zoom, Chrome/Google Meet, and Control Center.
public enum ScreenShare {
    public static func reason(processes: [String], windows: [ShareWindow],
                              displaySizes: [(width: Double, height: Double)] = []) -> String? {
        let names = processes.map { $0.lowercased() }
        if names.contains(where: isZoomCaptureHelper) {
            return "Zoom is sharing the screen"
        }
        if names.contains(where: isMacOSScreenCapture) {
            return "macOS screen recording is on"
        }
        for window in windows {
            let owner = window.owner.lowercased()
            let title = window.title.lowercased()
            if isZoomCaptureHelper(owner) {
                return "Zoom is sharing the screen"
            }
            if title.contains("is sharing your screen")
                || title.contains("is sharing a window")
                || title.contains("is sharing your entire screen") {
                return window.title.isEmpty ? "Screen sharing" : window.title
            }
            if owner.contains("zoom"), isZoomShareTitle(title) {
                return "Zoom is sharing the screen"
            }
            if isTeams(owner), isTeamsShareTitle(title) {
                return "Teams is sharing the screen"
            }
            if owner == "control center", title.contains("screen recording") || title.contains("screen sharing") {
                return "Screen recording is on"
            }
            // Title-free detection for Teams / Zoom red/green full-screen sharing border overlays:
            // normal meeting windows sit at layer 0, and mini-call PIPs are small; sharing borders
            // sit at an elevated layer (> 0) and span a full display.
            if window.layer > 0, coversDisplay(window, displays: displaySizes) {
                if isTeams(owner) { return "Teams is sharing the screen" }
                if owner.contains("zoom") { return "Zoom is sharing the screen" }
            }
        }
        return nil
    }

    private static func isZoomCaptureHelper(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base == "cpthost" || base == "zoomcpthost"
    }

    private static func isMacOSScreenCapture(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base == "screencapture"
    }

    private static func coversDisplay(_ window: ShareWindow, displays: [(width: Double, height: Double)]) -> Bool {
        guard window.width > 0, window.height > 0 else { return false }
        return displays.contains { d in
            d.width > 0 && d.height > 0
                && window.width >= d.width * 0.85
                && window.height >= d.height * 0.85
        }
    }

    private static func isZoomShareTitle(_ title: String) -> Bool {
        title.contains("zoom share") || title.contains("you are sharing")
            || title.contains("share toolbar") || title.contains("sharing status")
    }

    private static func isTeams(_ owner: String) -> Bool {
        owner.contains("teams")
    }

    private static func isTeamsShareTitle(_ title: String) -> Bool {
        title.contains("you are sharing") || title.contains("sharing control") || title.contains("stop presenting")
    }
}

/// Whether the recording pill should be on screen. Hiding removes the window. It does not
/// mark the window invisible to screen-capture APIs.
public enum RecordingPill {
    public static func visible(recording: Bool, settingAllows: Bool, manuallyHidden: Bool,
                               sessionShown: Bool, screenSharing: Bool, broughtBackDuringShare: Bool,
                               callEnding: Bool) -> Bool {
        guard recording else { return false }
        if manuallyHidden { return false }
        if screenSharing && !broughtBackDuringShare { return false }
        if callEnding { return true }
        return settingAllows || sessionShown
    }
}
