import AppKit
import Foundation
import UserNotifications

/// Posts a system notification when a clone finishes, so a long backup can be
/// started and walked away from.
///
/// Every path here is best-effort: a notification that fails to post must never
/// obscure the clone's actual result, which the window always shows regardless.
@MainActor
final class Notifier {
    static let shared = Notifier()

    private var authorized: Bool?

    private init() {}

    func cloneFinished(_ summary: CloneSummary) async {
        let title: String
        let body: String

        if summary.succeededCleanly {
            title = "Backup complete"
            body = "“\(summary.targetName)” is up to date — \(ByteFormat.string(summary.bytesCopied)) copied in \(DurationFormat.string(summary.duration))."
        } else {
            title = "Backup finished with problems"
            let issues = (summary.verification?.discrepancyCount ?? 0) + summary.skipped.count
            body = "“\(summary.targetName)” finished, but \(issues) item\(issues == 1 ? "" : "s") need attention. Open ThumbPrint for details."
        }

        await post(title: title, body: body)
    }

    func cloneFailed(targetName: String, message: String) async {
        await post(title: "Backup failed", body: message)
    }

    // MARK: - Delivery

    private func post(title: String, body: String) async {
        guard await ensureAuthorized() else {
            fallbackAlert()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            fallbackAlert()
        }
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true

        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false

        default:
            authorized = false
        }

        return authorized ?? false
    }

    /// Notifications are off or unavailable — make some noise and bounce the
    /// Dock icon instead. The window still carries the full result.
    private func fallbackAlert() {
        NSSound.beep()
        NSApp.requestUserAttention(.informationalRequest)
    }
}
