import Foundation
import SeedKit
import UserNotifications

/// Notificações locais: reunião detectada (com ação Gravar), auto-stop e
/// resumo pronto.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Chamado quando o usuário clica em "Gravar" na notificação.
    var onRecordAction: (@MainActor (DetectedMeeting) -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "RECORD", title: "Gravar", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "SEED_DETECTED",
            actions: [record],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAuthorization(_ completion: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized: status = "authorized"
            case .denied: status = "denied"
            case .notDetermined: status = "notDetermined"
            case .provisional: status = "provisional"
            @unknown default: status = "desconhecido"
            }
            completion(status)
        }
    }

    func notifyDetected(_ meeting: DetectedMeeting) {
        let content = UNMutableNotificationContent()
        content.title = "Reunião detectada — \(meeting.source.rawValue)"
        content.body = "\(meeting.title) · seu microfone está ativo."
        content.categoryIdentifier = "SEED_DETECTED"
        content.userInfo = [
            "title": meeting.title,
            "source": meeting.source.rawValue,
            "viaBrowser": meeting.viaBrowser,
        ]
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "seed-detected",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Ação da notificação (Gravar ou clique no corpo)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let isRecord = response.actionIdentifier == "RECORD"
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if isRecord,
           response.notification.request.content.categoryIdentifier == "SEED_DETECTED",
           let title = userInfo["title"] as? String,
           let sourceRaw = userInfo["source"] as? String,
           let source = DetectedMeeting.Source(rawValue: sourceRaw) {
            let viaBrowser = userInfo["viaBrowser"] as? Bool ?? false
            let meeting = DetectedMeeting(source: source, title: title, viaBrowser: viaBrowser)
            Task { @MainActor in
                self.onRecordAction?(meeting)
            }
        }
        completionHandler()
    }

    // Mostrar banner mesmo com o app em primeiro plano
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
