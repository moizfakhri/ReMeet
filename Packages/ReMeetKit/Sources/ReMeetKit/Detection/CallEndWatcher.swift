import Foundation

/// Notices when the meeting app a recording belongs to has let go of the mic long enough to
/// call the meeting over. Pure state: the app feeds it mic changes and owns the timers.
public struct CallEndWatcher: Sendable {
    public enum Change: Equatable, Sendable {
        case none
        /// The app let go of the mic; check `callEnded` once `grace` has passed.
        case released
        /// The app took the mic back before the recording was stopped.
        case returned
    }

    public var grace: TimeInterval
    /// Bundle ID of the meeting app this recording follows, nil while none is known.
    public private(set) var app: String?
    private var seen = false
    private var releasedAt: Date?
    private var dismissed = false

    public init(grace: TimeInterval = 30) {
        self.grace = grace
    }

    /// A recording started, for `app` if it was started from a meeting app (prompt, or a
    /// meeting app holding the mic). Without one, the first meeting app to use the mic during
    /// the recording is adopted, so "record, then join the call" works too.
    public mutating func begin(app: String?, inputProcesses: Set<String>) {
        self.app = app
        seen = false
        releasedAt = nil
        dismissed = false
        _ = update(inputProcesses: inputProcesses)
    }

    /// The recording ended.
    public mutating func end() {
        app = nil
        seen = false
        releasedAt = nil
        dismissed = false
    }

    /// The user chose Keep recording: no automatic stop for the rest of this recording.
    public mutating func dismiss() {
        dismissed = true
        releasedAt = nil
    }

    /// Feed the bundle IDs of the processes currently using audio input.
    public mutating func update(inputProcesses: Set<String>, now: Date = Date()) -> Change {
        guard !dismissed else { return .none }
        let apps = Set(inputProcesses.compactMap { MeetingApp.match($0)?.bundleID })
        if app == nil { app = apps.sorted().first }
        guard let app else { return .none }
        if apps.contains(app) {
            seen = true
            guard releasedAt != nil else { return .none }
            releasedAt = nil
            return .returned
        }
        // Only an app that was on the mic during this recording can end the call.
        guard seen, releasedAt == nil else { return .none }
        releasedAt = now
        return .released
    }

    /// True once the app has been off the mic for `grace` seconds.
    public func callEnded(now: Date = Date()) -> Bool {
        guard !dismissed, let releasedAt else { return false }
        return now.timeIntervalSince(releasedAt) >= grace
    }
}
