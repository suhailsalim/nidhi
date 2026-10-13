import Foundation
import BackgroundTasks

/// Schedules the periodic Gmail refresh (BGAppRefreshTask). iOS runs it
/// opportunistically (≈ once a day when permitted); we also scan on app launch.
enum GmailBackground {
    static let id = "com.suhail.Nidhi.gmailrefresh"

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)   // not before 4h
        try? BGTaskScheduler.shared.submit(req)
    }
}
