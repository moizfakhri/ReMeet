import Foundation
import ReMeetKit
import UserNotifications

/// "Summary ready" and "couldn't finish" notifications. Clicking one opens that meeting.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((MeetingFolder) -> Void)?
    /// When true, notifications stay silent so a finishing pipeline does not chirp over a live call.
    var isRecording: () -> Bool = { false }
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func summaryReady(_ folder: MeetingFolder, meta: MeetingMeta) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifyWhenReady) else { return }
        let content = UNMutableNotificationContent()
        content.title = meta.title
        let summary = try? folder.read(MeetingSummary.self, .summary)
        content.body = summary?.summary.first?.text ?? "The summary is ready."
        post(content, folder: folder)
    }

    /// "Transcript ready": Copy for AI works from here on; the summary follows separately.
    func transcriptReady(_ folder: MeetingFolder, meta: MeetingMeta) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifyWhenReady) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcript ready: \(meta.title)"
        let minutes = Int((meta.processing.stageSeconds["transcribe"] ?? 0) / 60)
        let took = minutes >= 1 ? " in \(minutes) min" : ""
        content.body = "Transcribed\(took). Open it, or press ⇧⌘C to copy it for an AI chat. The summary is on its way."
        post(content, folder: folder)
    }

    func failed(_ folder: MeetingFolder, failure: MeetingFailure) {
        let content = UNMutableNotificationContent()
        let title = (try? folder.readMeta().title) ?? "Meeting"
        content.title = "Couldn't finish \u{201C}\(title)\u{201D}"
        content.body = "\(failure.stage.displayName) failed: \(failure.message) Your audio is safe; open the meeting to retry."
        post(content, folder: folder)
    }

    /// Sample banner for `--notify-preview`. Same icon and presentation path as a real summary.
    func previewBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        deliver(content, identifier: "preview-\(UUID().uuidString)", userInfo: [:])
    }

    /// Asks for permission the first time one is needed if the welcome step was skipped
    /// (audit M2); macOS shows its prompt once and remembers the answer.
    private func post(_ content: UNMutableNotificationContent, folder: MeetingFolder) {
        // Banner always; system chime only when idle. A finishing transcript during a
        // live call is useful as a banner, not as a surprise sound over the meeting.
        if !isRecording() { content.sound = .default }
        // A fresh id so a second finish still banners. Reusing folder.id replaces the
        // old notification in the list and often does not present again.
        deliver(content, identifier: "\(folder.id)-\(UUID().uuidString)", userInfo: ["folder": folder.url.path])
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String, userInfo: [String: String]) {
        content.userInfo = userInfo
        content.threadIdentifier = "remeet.summary"
        // No image attachment. On this macOS an attachment takes the leading tile and
        // the app icon shrinks to the trailing side, which is the blank square on the
        // left and the grille on the right. The left tile is the bundle icon.
        DockPresence.installIcon()
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.getNotificationSettings { [center] settings in
            let post = {
                center.add(request) { error in
                    if let error { NSLog("ReMeet notification failed: \(error.localizedDescription)") }
                }
            }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post() }
                }
            } else {
                post()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["folder"] as? String else { return }
        await MainActor.run { onOpen?(MeetingFolder(url: URL(fileURLWithPath: path, isDirectory: true))) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Foreground: show the banner. `.banner` alone is dropped on macOS 26 when the
        // app is already active (the meeting window is open as the summary finishes),
        // so the notification only landed in Notification Center. `.list` keeps it there
        // as well. Sound while ReMeet is already on screen feels like a glitch.
        [.banner, .list]
    }
}
