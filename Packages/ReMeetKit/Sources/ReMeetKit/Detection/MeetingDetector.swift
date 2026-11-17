import Foundation

/// Meeting apps, matched by the bundle identifier of the process that uses the mic.
/// Browsers and some apps capture audio in a helper process, so matching is by prefix.
public struct MeetingApp: Equatable, Sendable {
    public var name: String
    /// The app's main bundle identifier (stored as meta.json `sourceApp`).
    public var bundleID: String
    public var prefixes: [String]

    public static let known: [MeetingApp] = [
        MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", prefixes: ["us.zoom."]),
        MeetingApp(name: "Teams", bundleID: "com.microsoft.teams2", prefixes: ["com.microsoft.teams"]),
        MeetingApp(name: "FaceTime", bundleID: "com.apple.FaceTime", prefixes: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        MeetingApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", prefixes: ["com.tinyspeck.slackmacgap"]),
        MeetingApp(name: "Webex", bundleID: "Cisco-Systems.Spark", prefixes: ["Cisco-Systems.Spark", "com.cisco.webex"]),
        MeetingApp(name: "Discord", bundleID: "com.hnc.Discord", prefixes: ["com.hnc.Discord"]),
        MeetingApp(name: "Google Chrome", bundleID: "com.google.Chrome", prefixes: ["com.google.Chrome"]),
        MeetingApp(name: "Arc", bundleID: "company.thebrowser.Browser", prefixes: ["company.thebrowser."]),
        MeetingApp(name: "Edge", bundleID: "com.microsoft.edgemac", prefixes: ["com.microsoft.edgemac"]),
        MeetingApp(name: "Brave", bundleID: "com.brave.Browser", prefixes: ["com.brave.Browser"]),
        MeetingApp(name: "Firefox", bundleID: "org.mozilla.firefox", prefixes: ["org.mozilla.firefox"]),
        // Safari captures in WebKit's GPU process.
        MeetingApp(name: "Safari", bundleID: "com.apple.Safari", prefixes: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
    ]

    public static func match(_ processBundleID: String) -> MeetingApp? {
        known.first { app in app.prefixes.contains { processBundleID.hasPrefix($0) } }
    }

    public var isBrowser: Bool {
        ["com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
         "org.mozilla.firefox", "com.apple.Safari"].contains(bundleID)
    }

    /// Default title for a recording started from the prompt.
    public var meetingTitle: String { isBrowser ? "Browser call" : "\(name) call" }
}

/// Decides when to ask "Record this meeting?". Never starts anything itself.
public struct MeetingDetector: Sendable {
    public var cooldown: TimeInterval = 600
    private var active: Set<String> = []
    private var lastPrompt: [String: Date] = [:]

    public init() {}

    /// Feed the bundle IDs of processes currently using audio input. Returns the app to ask
    /// about, if one just started using the mic, ReMeet is idle and it was not asked recently.
    public mutating func update(inputProcesses: Set<String>, isRecording: Bool, now: Date = Date()) -> MeetingApp? {
        let apps = Set(inputProcesses.compactMap { MeetingApp.match($0)?.bundleID })
        let started = apps.subtracting(active)
        active = apps
        guard !isRecording else { return nil }
        for bundleID in started.sorted() {
            if let last = lastPrompt[bundleID], now.timeIntervalSince(last) < cooldown { continue }
            lastPrompt[bundleID] = now
            return MeetingApp.known.first { $0.bundleID == bundleID }
        }
        return nil
    }

    /// True while the app we asked about is still using the mic (the prompt stays up).
    public func isActive(_ app: MeetingApp) -> Bool { active.contains(app.bundleID) }
}
