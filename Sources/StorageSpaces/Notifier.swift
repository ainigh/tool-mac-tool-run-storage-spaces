import AppKit
import UserNotifications

/// A notification, as the updater (and a request for access) posts them.
enum Notifier {
    enum Tone { case info, success, warning, failure }

    static func post(title: String, body: String, update: Bool = false, tone: Tone = .info) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if update { content.userInfo = ["update": true] }
            if tone == .failure || tone == .warning { content.sound = .default }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
