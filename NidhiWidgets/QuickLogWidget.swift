import WidgetKit
import SwiftUI
import AppIntents

// Interactive quick-log widget (iOS 17+ `Button(intent:)`). The buttons run LogTransactionIntent
// inside *this* extension process: it appends to the shared inbox, optimistically bumps the
// snapshot's spent figure (so the bar below moves on the tap) and reloads timelines. The app
// reconciles the real figure when it next opens and drains the inbox.
struct QuickLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickLogWidget", provider: NidhiProvider()) { e in
            QuickLogWidgetView(snap: e.snap).containerBackground(WG.bg, for: .widget)
        }
        .configurationDisplayName("Quick log")
        .description("One-tap logging for your usual cash spends.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickLogWidgetView: View {
    @Environment(\.widgetFamily) var family
    let snap: NidhiSnapshot

    private var presets: [NidhiQuickPreset] {
        let p = snap.quickPresets.isEmpty ? NidhiQuickPreset.defaults : snap.quickPresets
        return Array(p.prefix(family == .systemMedium ? 4 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Quick log", systemImage: "bolt.circle").font(.caption2.weight(.semibold)).foregroundStyle(WG.ink2)
                Spacer()
                if snap.plan > 0 {
                    Text("\(Int(snap.planPct*100))%").font(.caption2.weight(.bold)).foregroundStyle(WG.accentDeep)
                }
            }
            if snap.plan > 0 {
                Gauge(value: snap.planPct) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).tint(WG.calm)
                Text("\(NidhiShared.inr(snap.spent)) of \(NidhiShared.inr(snap.plan))")
                    .font(.caption2).foregroundStyle(WG.ink3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(presets) { p in
                    Button(intent: LogTransactionIntent(amount: p.amount,
                                                        merchant: p.label,
                                                        category: p.category.isEmpty ? nil : p.category)) {
                        VStack(spacing: 2) {
                            Text(NidhiShared.inr(p.amount))
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(WG.ink)
                            Text(p.category.isEmpty ? p.label : p.category)
                                .font(.system(size: 9)).foregroundStyle(WG.ink3).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(WG.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
