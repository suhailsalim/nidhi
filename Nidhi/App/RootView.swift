import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView(selection: $store.tab) {
            SwiftUI.Tab("Home", systemImage: "house", value: Tab.home) {
                NavigationStack { screen { HomeView() } }
            }
            SwiftUI.Tab("Plan", systemImage: "chart.pie", value: Tab.plan) {
                NavigationStack { screen { PlanView() } }
            }
            SwiftUI.Tab("Insights", systemImage: "chart.bar.xaxis", value: Tab.insights) {
                NavigationStack { InsightsView() }
            }
            SwiftUI.Tab("Goals", systemImage: "target", value: Tab.goals) {
                NavigationStack { screen { GoalsView() } }
            }
            SwiftUI.Tab("Wealth", systemImage: "chart.line.uptrend.xyaxis", value: Tab.wealth) {
                NavigationStack { screen { WealthView() } }
            }
            SwiftUI.Tab("Income", systemImage: "indianrupeesign", value: Tab.income) {
                NavigationStack { screen { IncomeView() } }
            }
        }
        .tint(Zen.accentDeep)
    }

    /// Common screen chrome: zen background behind a scroll view.
    @ViewBuilder private func screen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            ZenBackground()
            ScrollView { content().padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 24) }
        }
    }
}
