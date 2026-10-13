import Foundation
import UserNotifications

/// Local notifications — a monthly budget reminder. No server, no push.
enum NotificationManager {
    static let reminderId = "nidhi_monthly_budget"

    /// Toggle the monthly reminder. Requests authorization on enable.
    static func setEnabled(_ on: Bool) {
        let center = UNUserNotificationCenter.current()
        guard on else { center.removePendingNotificationRequests(withIdentifiers: [reminderId]); return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Nidhi"
            content.body = "A few days left this month — review your budget and stay on plan."
            content.sound = .default
            var when = DateComponents(); when.day = 25; when.hour = 10
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            center.add(UNNotificationRequest(identifier: reminderId, content: content, trigger: trigger))
        }
    }

    private static func cardDueId(_ mask: String, _ suffix: String) -> String { "carddue-\(mask)-\(suffix)" }

    /// Schedule two reminders for a card bill: T-3 days and the due-day morning. Reschedules by
    /// cancelling the card's existing reminders first; never schedules a trigger in the past.
    static func scheduleCardDue(mask: String, cardName: String, dueDate: Date, totalDue: Double?) {
        let center = UNUserNotificationCenter.current()
        cancelCardDue(mask: mask)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let cal = Calendar.current
            let amount = totalDue.map { " of ₹\(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))" } ?? ""
            let plan: [(suffix: String, fire: Date, body: String)] = [
                ("t3", cal.date(byAdding: .day, value: -3, to: dueDate).map { cal.date(bySettingHour: 10, minute: 0, second: 0, of: $0) ?? $0 } ?? dueDate,
                 "Your \(cardName) bill\(amount) is due in 3 days."),
                ("due", cal.date(bySettingHour: 9, minute: 0, second: 0, of: dueDate) ?? dueDate,
                 "Your \(cardName) bill\(amount) is due today."),
            ]
            for p in plan where p.fire > Date() {
                let content = UNMutableNotificationContent()
                content.title = "Card payment due"
                content.body = p.body
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: p.fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(identifier: cardDueId(mask, p.suffix), content: content, trigger: trigger))
            }
        }
    }

    /// Cancel a card's pending due reminders (e.g. once the bill is paid).
    static func cancelCardDue(mask: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [cardDueId(mask, "t3"), cardDueId(mask, "due")])
    }

    private static let recurringPrefix = "recurring-"

    /// Reminders one day before each predicted recurring charge.
    ///
    /// Cancel-and-reschedule as a SET: every pending `recurring-` request is removed first, so a
    /// recompute that drops or re-dates a group can't leave an orphan behind. Ids are derived from
    /// the stable group key, so rescheduling replaces rather than duplicates.
    static func scheduleRecurring(_ charges: [(key: String, name: String, date: Date, amount: Double?)]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(recurringPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard !charges.isEmpty else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                let cal = Calendar.current
                for c in charges {
                    guard let fire = cal.date(byAdding: .day, value: -1, to: c.date).map({
                        cal.date(bySettingHour: 10, minute: 0, second: 0, of: $0) ?? $0
                    }), fire > Date() else { continue }
                    let amount = c.amount.map {
                        " of ₹\(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))"
                    } ?? ""
                    let content = UNMutableNotificationContent()
                    content.title = "Upcoming charge"
                    content.body = "\(c.name)\(amount) is expected tomorrow."
                    content.sound = .default
                    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    center.add(UNNotificationRequest(
                        identifier: recurringPrefix + c.key,
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                }
            }
        }
    }

    /// Fired once per Gmail scan when it queues one or more newly-locked statements (never on
    /// app-launch rehydration of an already-persisted pending list — the caller only invokes this
    /// for genuinely new appends). Not gated by the app's own "Monthly budget reminder" toggle,
    /// matching `scheduleCardDue`'s pattern — self-gates via OS authorization.
    static func notifyPendingStatements(total: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Nidhi"
            content.body = total == 1
                ? "A locked statement needs its password — accounts may be missing transactions."
                : "\(total) locked statements need a password — accounts may be missing transactions."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "nidhi_pending_stmt_\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
