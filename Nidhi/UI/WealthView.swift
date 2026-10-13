import SwiftUI
import Charts

struct WealthView: View {
    @EnvironmentObject var store: Store
    @State private var range = 2   // 0:1M 1:6M 2:1Y 3:All

    private var rangedPoints: [Double] {
        switch range {
        case 0: return Array(store.nwHistory.suffix(2))
        case 1: return Array(store.nwHistory.suffix(6))
        default: return store.nwHistory
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            heroCard
            if !store.segments.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Composition")
                    composition
                }
            }
            LoansSection()
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: "Milestone ladder")
                VStack(spacing: 9) { ForEach(store.milestones) { milestoneRow($0) } }
            }
        }
        .navigationTitle("Net worth")
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Total tracked").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink2)
            Text(INR.compact(store.totalTracked)).font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Zen.ink)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                Text("\(INR.compact(store.nwChange)) (\(String(format: "%.1f", store.nwChangePct))%) vs last month")
            }.font(.caption.weight(.semibold)).foregroundStyle(Zen.greenDeep).padding(.top, 4)
            // Loans are a liability, so Wealth states the net-of-loans figure explicitly rather
            // than folding it into the headline users already know.
            if store.hasLoans {
                Text("\(INR.compact(store.totalTrackedNetOfLoans)) after \(INR.compact(store.loansOutstanding)) of loans")
                    .font(.caption.weight(.semibold)).foregroundStyle(Zen.caution).padding(.top, 3)
            }

            Chart(Array(rangedPoints.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Zen.accent.opacity(0.30), Zen.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.catmullRom).foregroundStyle(Zen.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round))
                if i == rangedPoints.count - 1 {
                    PointMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(Zen.accent).symbolSize(80)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 130).padding(.top, 14)

            Picker("Range", selection: $range) {
                Text("1M").tag(0); Text("6M").tag(1); Text("1Y").tag(2); Text("All").tag(3)
            }
            .pickerStyle(.segmented).padding(.top, 14)
        }
        .padding(20).zenCard(30)
    }

    private var composition: some View {
        let segs = store.segments
        return HStack(spacing: 18) {
            Chart(segs) { s in
                SectorMark(angle: .value("v", abs(s.value)), innerRadius: .ratio(0.62), angularInset: 2)
                    .cornerRadius(4)
                    .foregroundStyle(Color(hex: s.colorHex))
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(segs) { s in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hex: s.colorHex)).frame(width: 10, height: 10)
                        Text(s.label).font(.subheadline.weight(.medium)).foregroundStyle(Zen.ink)
                        Spacer()
                        Text(INR.compact(s.value)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity).zenCard(26)
    }

    private func milestoneRow(_ m: Milestone) -> some View {
        let ring: Color = m.reached ? Zen.green : (m.active ? Zen.accent : Zen.ink3.opacity(0.5))
        let pct = m.active ? min(1, store.liquidNetWorth / m.amount) : (m.reached ? 1 : 0)
        return HStack(spacing: 13) {
            Image(systemName: m.reached ? "checkmark" : (m.active ? "hourglass" : "lock.fill"))
                .font(.subheadline.weight(.bold)).foregroundStyle(ring)
                .frame(width: 42, height: 42)
                .glassEffect(.regular, in: Circle())
                .overlay(Circle().stroke(ring, lineWidth: 2.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(INR.compact(m.amount)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    Spacer()
                    Text(m.name).font(.caption.weight(.semibold)).foregroundStyle(Zen.ink3)
                }
                Text(m.tag).font(.caption2).foregroundStyle(Zen.ink3)
                if m.active { ZenBar(value: pct) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14).zenCard(20)
    }
}
