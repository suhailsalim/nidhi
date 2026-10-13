import SwiftUI
import Charts
import UIKit
import PhotosUI

/// A reusable row to attach a user image (Photos pick or pasted URL) → an imageRef.
struct ImageRefRow: View {
    @Binding var imageRef: String?
    @State private var item: PhotosPickerItem?
    @State private var urlText = ""
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
            .onChange(of: item) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self), let name = LocalImage.save(data) {
                        await MainActor.run { imageRef = name }
                    }
                }
            }
        HStack {
            TextField("or paste an image URL", text: $urlText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Use") { if !urlText.isEmpty { imageRef = urlText } }.disabled(urlText.isEmpty)
        }
        if imageRef != nil {
            Button(role: .destructive) { imageRef = nil; urlText = "" } label: { Label("Remove image", systemImage: "trash") }
        }
    }
}

// MARK: - User-supplied images (Documents file name, or remote URL)
enum LocalImage {
    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func uiImage(_ ref: String?) -> UIImage? {
        guard let ref, !ref.isEmpty, !ref.hasPrefix("http") else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(ref).path)
    }
    static func remoteURL(_ ref: String?) -> URL? {
        guard let ref, ref.hasPrefix("http") else { return nil }
        return URL(string: ref)
    }
    /// Save image data to Documents and return its file name (the imageRef).
    @discardableResult static func save(_ data: Data, suggested: String = UUID().uuidString) -> String? {
        let name = "img_\(suggested).jpg"
        do { try data.write(to: dir.appendingPathComponent(name)); return name } catch { return nil }
    }
}

/// Bank "logo": user image if set, else a brand-colour monogram tile. No trademarked logos.
struct BankBadge: View {
    var monogram: String
    var colorHex: String
    var imageRef: String? = nil
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let ui = LocalImage.uiImage(imageRef) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let u = LocalImage.remoteURL(imageRef) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { tile }
            } else { tile }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3))
    }
    private var tile: some View {
        Text(monogram).font(.system(size: size * 0.26, weight: .heavy)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: colorHex))
    }
}

/// Generated credit-card cover (gradient + text). No card artwork is bundled.
struct CardCoverView: View {
    var card: CreditCard
    var bankName: String
    private var stops: [Color] {
        CardCatalog.gradient(name: card.name, network: card.network, colorHex: card.colorHex).map { Color(hex: $0) }
    }
    var body: some View {
        ZStack {
            if let ui = LocalImage.uiImage(card.imageRef) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let u = LocalImage.remoteURL(card.imageRef) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { gradient }
            } else { gradient }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(bankName).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(card.network ?? "").font(.caption.weight(.heavy)).textCase(.uppercase)
                }
                Spacer()
                HStack {
                    Text("•••• \(card.mask)").font(.system(.subheadline, design: .monospaced).weight(.semibold)).tracking(2)
                    Spacer()
                    if let r = card.rewardLabel {
                        Text(r).font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(card.limit > 0 ? "\(INR.compact(card.outstanding)) of \(INR.compact(card.limit))" : INR.compact(card.outstanding)).font(.caption.weight(.semibold))
                    Spacer()
                    if let t = card.tier { Text(t).font(.caption2.weight(.bold)).textCase(.uppercase).opacity(0.85) }
                }
            }
            .padding(16).foregroundStyle(.white)
        }
        .frame(height: 150).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
    }
    private var gradient: some View {
        LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Form fields with always-visible labels
/// A labelled text row for a Form (label left, value right) that never hides the label.
struct LabeledField: View {
    var label: String
    var placeholder: String = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocaps: TextInputAutocapitalization = .sentences
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Zen.ink2)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocaps)
        }
    }
}

/// A money field with an always-visible label + currency symbol prefix and grouped formatting.
struct LabeledAmountField: View {
    var label: String
    @Binding var amount: Double
    var currency: String = "INR"
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Zen.ink2)
            Spacer(minLength: 12)
            Text(Currencies.symbol(currency)).foregroundStyle(Zen.ink3)
            TextField("0", value: $amount, format: .number.grouping(.automatic))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .frame(maxWidth: 160)
        }
    }
}

/// A small coloured tag pill (deterministic colour/icon per tag name).
struct TagPill: View {
    var text: String
    var removable: Bool = false
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: TagStyle.icon(text)).font(.system(size: 9, weight: .bold))
            Text(text).font(.caption2.weight(.semibold))
            if removable { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(TagStyle.color(text).opacity(0.18), in: Capsule())
        .foregroundStyle(TagStyle.color(text))
        .contentShape(Capsule())
        .onTapGesture { if removable { onRemove?() } }
    }
}

/// A destructive Delete row for the bottom of an edit Form (with confirmation).
struct DeleteSheetButton: View {
    var noun: String
    var action: () -> Void
    @State private var confirm = false
    var body: some View {
        Section {
            Button(role: .destructive) { confirm = true } label: {
                Label("Delete \(noun)", systemImage: "trash").frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Delete this \(noun)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Section header
struct SectionHeader: View {
    var title: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(Zen.ink)
            Spacer()
            if let l = actionLabel {
                Button { action?() } label: {
                    Text(l).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Icon chip (native SF Symbol on Liquid Glass)
struct IconChip: View {
    var symbol: String
    var brandIcon: String? = nil   // Assets.xcassets image name — a real brand mark, shown untinted instead of `symbol`
    var size: CGFloat = 36
    var tint: Color = Zen.accentDeep
    var body: some View {
        Group {
            if let brandIcon {
                Image(brandIcon).resizable().renderingMode(.original).scaledToFit().padding(size * 0.22)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .glassEffect(.regular, in: .rect(cornerRadius: size * 0.32))
    }
}

// MARK: - Empty state
struct EmptyState: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Zen.accent)
            Text(title).font(.headline).foregroundStyle(Zen.ink)
            Text(message).font(.caption).foregroundStyle(Zen.ink3).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "plus") }
                    .buttonStyle(.glassProminent).tint(Zen.accent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 18).zenCard(24)
    }
}

// MARK: - Sparkline via Swift Charts (native)
struct Sparkline: View {
    var points: [Double]
    var tint: Color = Zen.accent
    var filled = false
    var showDot = false
    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { i, v in
            if filled {
                AreaMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            LineMark(x: .value("i", i), y: .value("v", v))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            if showDot, i == points.count - 1 {
                PointMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(tint).symbolSize(70)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
