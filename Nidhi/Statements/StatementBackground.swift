import Foundation
import BackgroundTasks

/// Schedules the periodic Gmail statement-PDF scan (separate from the alert-email scan).
/// iOS runs it opportunistically (≈ once a day); we also scan on app launch.
enum StatementBackground {
    static let id = "com.suhail.Nidhi.stmtrefresh"

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)   // not before 6h
        try? BGTaskScheduler.shared.submit(req)
    }
}
