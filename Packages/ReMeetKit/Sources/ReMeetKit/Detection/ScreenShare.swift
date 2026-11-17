import Foundation

public struct ShareWindow: Equatable, Sendable {
    public var owner: String
    public var title: String

    public init(owner: String, title: String) {
        self.owner = owner
        self.title = title
    }
}

/// Decides whether the screen looks like it is being shared. A meeting app merely being
/// open is not enough: Zoom's meeting window stays up for the whole call, and its capture
/// helper (`CptHost`) only runs while the screen is shared.
public enum ScreenShare {
    public static func reason(processes: [String], windows: [ShareWindow]) -> String? {
        let names = processes.map { $0.lowercased() }
        if names.contains(where: isZoomCaptureHelper) {
            return "Zoom is sharing the screen"
        }
        for window in windows {
            let owner = window.owner.lowercased()
            let title = window.title.lowercased()
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
        }
        return nil
    }

    private static func isZoomCaptureHelper(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base == "cpthost" || base == "zoomcpthost"
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
