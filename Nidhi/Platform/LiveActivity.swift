import Foundation
import ActivityKit

/// Starts / updates / stops the monthly-budget Live Activity.
enum BudgetLiveActivity {
    static var isRunning: Bool {
        !Activity<BudgetActivityAttributes>.activities.isEmpty
    }

    static func start(month: String, spent: Double, plan: Double, daysLeft: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !isRunning else { return }
        let attrs = BudgetActivityAttributes(month: month)
        let state = BudgetActivityAttributes.ContentState(spent: spent, plan: plan, daysLeft: daysLeft)
        _ = try? Activity.request(attributes: attrs,
                                  content: .init(state: state, staleDate: nil))
    }

    static func update(spent: Double, plan: Double, daysLeft: Int) {
        let state = BudgetActivityAttributes.ContentState(spent: spent, plan: plan, daysLeft: daysLeft)
        Task {
            for activity in Activity<BudgetActivityAttributes>.activities {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    static func stop() {
        Task {
            for activity in Activity<BudgetActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
