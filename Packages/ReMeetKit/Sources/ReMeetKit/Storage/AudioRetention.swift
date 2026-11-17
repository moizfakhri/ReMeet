import Foundation

/// Settings > Keep audio. Default is forever (0 days). Only audio is removed; meta, notes,
/// transcript and summary always stay. Meetings that are not finished (or failed) keep
/// their audio so they can still be processed or retried.
public enum AudioRetention {
    public static let audioFiles: [MeetingFolder.File] = [.audio, .mic16k, .system16k, .micWAV, .systemWAV]

    public static func shouldRemoveAudio(_ meta: MeetingMeta, keepDays: Int, now: Date = Date()) -> Bool {
        guard keepDays > 0, meta.status == .summarized else { return false }
        let end = meta.endTime ?? meta.startTime.addingTimeInterval(meta.effectiveDuration)
        return now.timeIntervalSince(end) > Double(keepDays) * 86_400
    }

    /// Removes old audio under `root`; returns the folders that changed.
    @discardableResult
    public static func clean(root: URL, keepDays: Int, now: Date = Date()) -> [MeetingFolder] {
        guard keepDays > 0 else { return [] }
        var changed: [MeetingFolder] = []
        for folder in MeetingFolder.scan(root: root) {
            guard let meta = try? folder.readMeta(), shouldRemoveAudio(meta, keepDays: keepDays, now: now) else { continue }
            let present = audioFiles.filter(folder.exists)
            guard !present.isEmpty else { continue }
            for file in present { try? FileManager.default.removeItem(at: folder.file(file)) }
            _ = try? folder.updateMeta {
                $0.events.append(SessionEvent(time: now, offsetSeconds: 0, type: "audio_removed",
                                              detail: "Keep audio is set to \(keepDays) days; removed \(present.map(\.rawValue).joined(separator: ", "))"))
            }
            changed.append(folder)
        }
        return changed
    }
}
