import AppKit
import SwiftUI

@main
struct ThumbPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned by the app rather than a view: the menu command and the launch
    /// check both reach it, and it has to outlive any single screen.
    @State private var updates = UpdateController()

    /// Owned here for the same reason. A copy must outlive its window — closing
    /// the window mid-backup used to leave the copy running with nothing
    /// showing it, and reopening from the Dock made a second, idle job that
    /// could start another copy onto the same drive.
    @State private var job = CloneJob()

    var body: some Scene {
        // `Window`, not `WindowGroup`: one job, so one window. Reopening it from
        // the Dock or the Window menu shows the copy that's already running.
        Window("ThumbPrint", id: "main") {
            ContentView(updates: updates, job: job)
                .onAppear { appDelegate.job = job }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Under the app menu, next to About — where every Mac app puts it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(updates.isBusy)
            }
        }
    }
}

/// Asks before quitting in the middle of a copy.
///
/// Quitting mid-Exact-Clone is the worst of it: the Swift side that remounts
/// both drives and explains the half-written target never runs. So a confirmed
/// quit cancels the job and waits for it to wind down — `dd` stopped, drives
/// remounted — before the app actually exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var job: CloneJob?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let job, let consequence = job.cancelConsequence else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A copy is still running. Quit anyway?"
        alert.informativeText = consequence
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Going")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        job.cancel()
        Task { @MainActor in
            // Bounded, so a wedged engine can't hold the app open forever.
            for _ in 0..<100 where job.isBusy {
                try? await Task.sleep(for: .milliseconds(200))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
