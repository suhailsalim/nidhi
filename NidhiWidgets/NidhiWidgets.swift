import WidgetKit
import SwiftUI
import Charts
import ActivityKit

// MARK: - Zen palette (self-contained; widget target has no app sources).
// Chrome colors adapt to light/dark via a dynamic UIColor (widgets can't read app assets).
enum WG {
    static let accent     = Color(red: 0.431, green: 0.608, blue: 0.847)
    static let accentDeep = Color(red: 0.310, green: 0.498, blue: 0.769)
    static let green      = Color(red: 0.498, green: 0.769, blue: 0.639)
    static let greenDeep  = Color(red: 0.357, green: 0.647, blue: 0.522)

    private static func dyn(_ l: (CGFloat, CGFloat, CGFloat), _ d: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let ink  = dyn((0.165, 0.200, 0.251), (0.910, 0.925, 0.949))
    static let ink2 = dyn((0.361, 0.400, 0.459), (0.682, 0.722, 0.776))
    static let ink3 = dyn((0.604, 0.639, 0.698), (0.431, 0.478, 0.541))
    static var bg: LinearGradient {
        LinearGradient(colors: [dyn((0.918, 0.945, 0.984), (0.063, 0.082, 0.110)),
                                dyn((0.918, 0.969, 0.941), (0.063, 0.102, 0.086))],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var calm: LinearGradient {
        LinearGradient(colors: [accent, green], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Timeline
struct NidhiEntry: TimelineEntry { let date: Date; let snap: NidhiSnapshot }

struct NidhiProvider: TimelineProvider {
    func placeholder(in context: Context) -> NidhiEntry { NidhiEntry(date: Date(), snap: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (NidhiEntry) -> Void) {
        completion(NidhiEntry(date: Date(), snap: NidhiSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NidhiEntry>) -> Void) {
        let entry = NidhiEntry(date: Date(), snap: NidhiSnapshot.load())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Net worth widget (small + medium)
struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetWorthWidget", provider: NidhiProvider()) { e in
            NetWorthView(snap: e.snap).containerBackground(WG.bg, for: .widget)
        }
        .configurationDisplayName("Net worth")
        .description("Your liquid net worth and trend.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NetWorthView: View {
    @Environment(\.widgetFamily) var family
    let snap: NidhiSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Net worth", systemImage: "leaf").font(.caption2.weight(.semibold)).foregroundStyle(WG.ink2)
            Text(NidhiShared.inr(snap.netWorth)).font(.system(size: family == .systemMedium ? 34 : 26, weight: .bold, design: .rounded)).foregroundStyle(WG.ink)
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.right"); Text("\(NidhiShared.inr(snap.netWorthChange)) this month")
            }.font(.caption2.weight(.semibold)).foregroundStyle(WG.greenDeep)
            if family == .systemMedium {
                Chart(Array(snap.nwHistory.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("i", i), y: .value("v", v))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [WG.accent.opacity(0.3), WG.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("i", i), y: .value("v", v))
                        .interpolationMethod(.catmullRom).foregroundStyle(WG.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 46).padding(.top, 4)
            } else {
                Spacer()
                Text("\(snap.targetPct)% to goal").font(.caption2).foregroundStyle(WG.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Budget widget (small)
struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BudgetWidget", provider: NidhiProvider()) { e in
            BudgetView(snap: e.snap).containerBackground(WG.bg, for: .widget)
        }
        .configurationDisplayName("This month")
        .description("Spend vs your monthly plan.")
        .supportedFamilies([.systemSmall])
    }
}

struct BudgetView: View {
    let snap: NidhiSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This month", systemImage: "chart.pie").font(.caption2.weight(.semibold)).foregroundStyle(WG.ink2)
            Gauge(value: snap.planPct) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(snap.planPct*100))%").font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(WG.ink)
            }
            .gaugeStyle(.accessoryCircular).tint(WG.calm)
            .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
            Text(NidhiShared.inr(snap.spent)).font(.headline).foregroundStyle(WG.ink)
            Text("of \(NidhiShared.inr(snap.plan)) planned").font(.caption2).foregroundStyle(WG.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Top goal widget (small)
struct GoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GoalWidget", provider: NidhiProvider()) { e in
            GoalView(snap: e.snap).containerBackground(WG.bg, for: .widget)
        }
        .configurationDisplayName("Top quest")
        .description("Progress on your active goal.")
        .supportedFamilies([.systemSmall])
    }
}

struct GoalView: View {
    let snap: NidhiSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Quest", systemImage: "target").font(.caption2.weight(.semibold)).foregroundStyle(WG.ink2)
            Text(snap.topGoalTitle).font(.headline).foregroundStyle(WG.ink).lineLimit(1)
            Spacer()
            Text("\(Int(snap.goalPct*100))%").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(WG.accentDeep)
            Gauge(value: snap.goalPct) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity).tint(WG.calm)
            Text("\(NidhiShared.inr(snap.topGoalSaved)) / \(NidhiShared.inr(snap.topGoalTarget))").font(.caption2).foregroundStyle(WG.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Live Activity (monthly budget)
struct BudgetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BudgetActivityAttributes.self) { context in
            // Lock screen / banner
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(context.attributes.month) budget", systemImage: "leaf").font(.caption.weight(.semibold)).foregroundStyle(WG.ink2)
                    Spacer()
                    Text("\(context.state.daysLeft) days left").font(.caption2).foregroundStyle(WG.ink3)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(NidhiShared.inr(context.state.spent)).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(WG.ink)
                    Text("of \(NidhiShared.inr(context.state.plan))").font(.caption).foregroundStyle(WG.ink3)
                    Spacer()
                    Text("\(Int(context.state.pct*100))%").font(.headline).foregroundStyle(WG.accentDeep)
                }
                Gauge(value: context.state.pct) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).tint(WG.calm)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.attributes.month)", systemImage: "leaf").font(.caption.weight(.semibold)).foregroundStyle(WG.greenDeep)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.pct*100))%").font(.headline).foregroundStyle(WG.accentDeep)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Gauge(value: context.state.pct) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity).tint(WG.calm)
                        Text("\(NidhiShared.inr(context.state.spent)) of \(NidhiShared.inr(context.state.plan)) · \(context.state.daysLeft) days left")
                            .font(.caption2).foregroundStyle(WG.ink3)
                    }
                }
            } compactLeading: {
                Image(systemName: "leaf").foregroundStyle(WG.greenDeep)
            } compactTrailing: {
                Text("\(Int(context.state.pct*100))%").foregroundStyle(WG.accentDeep)
            } minimal: {
                Image(systemName: "leaf").foregroundStyle(WG.greenDeep)
            }
        }
    }
}

// MARK: - Bundle
@main
struct NidhiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        BudgetWidget()
        GoalWidget()
        QuickLogWidget()
        BudgetLiveActivityWidget()
    }
}
