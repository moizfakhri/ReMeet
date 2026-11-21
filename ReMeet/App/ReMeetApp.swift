import AppKit
import SwiftUI

@main
struct ReMeetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .tint(Theme.accentFill)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("ReMeet", id: WindowID.meetings) {
            MeetingWindowRoot()
                .environment(model)
                .tint(Theme.accentFill)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1040, height: 680)
        .commands { ReMeetCommands() }
        // Minimum comes from the content; the user can resize larger and smaller.
        // `.automatic` lets the split view lock the window to its current size.
        .windowResizability(.contentMinSize)

        Window("Welcome to ReMeet", id: WindowID.welcome) {
            FirstLaunchView()
                .environment(model)
                .tint(Theme.accentFill)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        Settings {
            SettingsRoot()
                .environment(model)
                .tint(Theme.accentFill)
        }
    }
}

/// Quitting mid-meeting stops the session and finalizes both WAV files first.
/// ReMeet is a menu bar app (LSUIElement); the Dock icon appears only while the
/// meeting window is open. Clicking that Dock tile (or a kept Dock shortcut while
/// windows are hidden/minimized) must reopen the meetings window — SwiftUI's
/// `.defaultLaunchBehavior(.suppressed)` will not create one on its own.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            DockPresence.installIcon()
            if CommandLine.arguments.contains("--notify-preview") {
                let title = CommandLine.arguments.drop(while: { $0 != "--notify-title" }).dropFirst().first
                    ?? "Weekly Product Sync"
                let body = CommandLine.arguments.drop(while: { $0 != "--notify-body" }).dropFirst().first
                    ?? "Alex previews a team meeting focusing on release planning and API rollout."
                // A banner posted while this process is in the background is easy to miss,
                // and the permission prompt only presents for the active app.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                AppModel.shared.notifier.previewBanner(title: title, body: body)
                return
            }
            if let name = SelfTest.requested {
                SelfTest.run(name, model: AppModel.shared)
                return
            }
            if let directory = SnapshotRenderer.requestedDirectory {
                SnapshotRenderer.run(into: directory, model: AppModel.shared)
                return
            }
            let openOnLaunch = Self.shouldOpenWindowOnLaunch()
            AppModel.shared.launch(openWindowOnLaunch: openOnLaunch)
        }
    }

    /// Hybrid launch behavior:
    /// - Launched at login (Login Item) or from CLI/perf/background scripts -> stay quiet in the menu bar.
    /// - Launched interactively by the user (Spotlight, Applications, Finder, Dock) -> open the
    ///   meetings window immediately so clicking ReMeet always gives instant feedback.
    private static func shouldOpenWindowOnLaunch() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--background") || args.contains("--perf-open-window")
            || args.contains("--perf-record-now") || args.contains("-storageFolder") {
            return false
        }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else {
            return false
        }
        let prop = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        if prop == keyAELaunchedAsLogInItem || prop == keyAELaunchedAsServiceItem {
            return false
        }
        return true
    }

    /// Dock / Finder / Spotlight reactivation. Without this, LSUIElement + suppressed Window
    /// scenes leave Dock/Spotlight clicks as a no-op when nothing is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // `flag` is true when the recording bar or the menu is up. Those are not the
            // meetings window, so a Dock or Spotlight click still has to open it.
            AppModel.shared.openMeetings()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            // Always drain via terminateLater: the shared queue can look idle while a
            // private self-test queue (or a just-cancelled worker) still holds MLX/Metal.
            // Quitting under that tore down CommandEncoders → SIGSEGV / MTL assert
            // (IPS 2026-11-02-235833). Idle drain is a single run-loop hop.
            if model.recorder.isRecording {
                model.recorder.stop {
                    Task { @MainActor in
                        await model.drainInferenceForTermination()
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                return .terminateLater
            }
            Task { @MainActor in
                await model.drainInferenceForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
