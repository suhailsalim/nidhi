import SwiftUI

struct GoalsView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false
    @State private var editingGoal: Goal?
    @State private var allocatingGoal: Goal?

    private var active: [Goal] { store.goals.filter(\.active) }
    private var paused: [Goal] { store.goals.filter { $0.status == .paused } }
    private var achieved: [Goal] { store.goals.filter { $0.status == .achieved } }

    var body: some View {
        VStack(spacing: 20) {
            levelCard
            badgesRow

            if store.goals.isEmpty {
                EmptyState(icon: "target", title: "No goals yet",
                           message: "Create a savings quest and track your progress.",
                           actionTitle: "New goal") { showAdd = true }
            } else if !active.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Active quests")
                    VStack(spacing: 11) { ForEach(active) { activeGoalCard($0) } }
                }
            }

            if !paused.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Paused quests")
                    VStack(spacing: 9) { ForEach(paused) { pausedGoalRow($0) } }
                }
            }

            if !achieved.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Achieved")
                    VStack(spacing: 9) { ForEach(achieved) { achievedRow($0) } }
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Label("New", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddGoalSheet() }
        .sheet(item: $editingGoal) { AddGoalSheet(editing: $0) }
        .sheet(item: $allocatingGoal) { g in
            AssetAllocationPicker(existing: g.allocations) { store.addAllocation($0, to: g) }
        }
    }

    private var levelCard: some View {
        let frac = Double(store.xp) / Double(store.nextLevelXP)
        return HStack(spacing: 14) {
            Image(systemName: "bolt.fill").font(.title2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Zen.calmGradient))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Level \(store.level) · \(store.levelName)").font(.headline).foregroundStyle(Zen.ink)
                    Spacer()
                    Text("\(store.xp) XP").font(.caption.weight(.bold)).foregroundStyle(Zen.ink2)
                }
                ZenBar(value: frac, tint: AnyShapeStyle(Zen.calmGradient)).padding(.top, 8)
                Text("\(store.nextLevelXP - store.xp) XP to Level \(store.level+1)")
                    .font(.caption.weight(.medium)).foregroundStyle(Zen.ink2).padding(.top, 6)
            }
        }
        .padding(18)
        .zenCard(tinted: Zen.green, 26)
    }

    private var badgesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(store.badges) { b in
                    VStack(spacing: 5) {
                        Image(systemName: b.symbol).font(.title3.weight(.semibold))
                            .foregroundStyle(b.earned ? Zen.accentDeep : Zen.ink3).frame(height: 28)
                        Text(b.label).font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink2)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(width: 74).padding(.vertical, 13).padding(.horizontal, 8)
                    .zenCard(18).opacity(b.earned ? 1 : 0.55)
                }
            }.padding(.vertical, 2)
        }
    }

    // status menu (lets you set any status, incl. reactivating)
    private func statusMenu(_ g: Goal) -> some View {
        Menu {
            Button { store.setGoalStatus(g, .onTrack) } label: { Label("On track", systemImage: "leaf") }
            Button { store.setGoalStatus(g, .atRisk) } label: { Label("At risk", systemImage: "exclamationmark.circle") }
            Button { store.pause(g) } label: { Label("Pause", systemImage: "pause.circle") }
        } label: {
            Text(g.status.rawValue).font(.caption.weight(.bold)).foregroundStyle(Color(hex: g.status.colorHex))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func activeGoalCard(_ g: Goal) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconChip(symbol: g.symbol, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("\(INR.compact(g.monthly))/mo · by \(g.deadlineText)").font(.caption2).foregroundStyle(Zen.ink3)
                }
                Spacer()
                statusMenu(g)
            }
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 3) {
                    Text(INR.compact(g.saved)).foregroundStyle(Zen.ink)
                    Text("/ \(INR.compact(g.target))").foregroundStyle(Zen.ink3)
                }.font(.caption.weight(.bold))
                Spacer()
                Text("\(Int(g.pct*100))%").font(.subheadline.weight(.bold)).foregroundStyle(Zen.accentDeep)
            }
            .padding(.top, 13).padding(.bottom, 6)
            ZenBar(value: g.pct, tint: AnyShapeStyle(Zen.calmGradient))
            if !g.allocations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(g.allocations) { a in
                            HStack(spacing: 4) {
                                Image(systemName: a.kind.symbol).font(.system(size: 9))
                                Text(store.assetName(a)).lineLimit(1)
                                if a.kind != .cash, a.percent < 100 { Text("\(Int(a.percent))%").foregroundStyle(Zen.ink3) }
                            }
                            .font(.caption2.weight(.medium)).foregroundStyle(Zen.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Zen.track.opacity(0.5), in: Capsule())
                        }
                    }
                }.padding(.top, 9)
            }
        }
        .padding(16).zenCard(22)
        .contextMenu {
            Button { editingGoal = g } label: { Label("Edit", systemImage: "pencil") }
            Button { allocatingGoal = g } label: { Label("Allocate asset", systemImage: "link.badge.plus") }
            Button(role: .destructive) { store.remove(goal: g) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func pausedGoalRow(_ g: Goal) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: g.symbol, size: 40, tint: Zen.ink3)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text("\(INR.compact(g.saved)) / \(INR.compact(g.target)) · \(g.deadlineText)").font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            Button { store.reactivate(g) } label: {
                Label("Reactivate", systemImage: "play.circle.fill").font(.caption.weight(.bold))
            }
            .buttonStyle(.glassProminent)
            .tint(Zen.green)
        }
        .padding(.horizontal, 15).padding(.vertical, 12).zenCard(18).opacity(0.85)
        .contextMenu {
            Button { editingGoal = g } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { store.remove(goal: g) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func achievedRow(_ g: Goal) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: g.symbol, size: 38, tint: Zen.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text("\(INR.compact(g.target)) · \(g.deadlineText)").font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Zen.green)
        }
        .padding(.horizontal, 15).padding(.vertical, 13).zenCard(18).opacity(0.7)
        .contextMenu {
            Button { editingGoal = g } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { store.remove(goal: g) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
