import SwiftUI

// MARK: - Color hex
extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8: r = Double((v >> 24) & 0xff)/255; g = Double((v >> 16) & 0xff)/255; b = Double((v >> 8) & 0xff)/255; a = Double(v & 0xff)/255
        case 6: r = Double((v >> 16) & 0xff)/255; g = Double((v >> 8) & 0xff)/255; b = Double(v & 0xff)/255; a = 1
        default: r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Zen palette (calm light blue + light green, no orange/red)
enum Zen {
    // accents stay constant (legible in light & dark)
    static let accent     = Color(hex: "6E9BD8")   // calm blue (primary tint)
    static let accentDeep = Color(hex: "4F7FC4")
    static let green      = Color(hex: "7FC4A3")   // soft sage
    static let greenDeep  = Color(hex: "5BA585")
    static let caution    = Color(hex: "9AA7BE")   // muted slate (replaces alarm red)
    // chrome adapts to light/dark via the asset catalog
    static let ink        = Color("ZenInk")
    static let ink2       = Color("ZenInk2")
    static let ink3       = Color("ZenInk3")
    static let track      = Color("ZenTrack")

    static var calmGradient: LinearGradient {
        LinearGradient(colors: [accent, green], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Zen background (adapts to light/dark; calm blue → green)
struct ZenBackground: View {
    var body: some View {
        LinearGradient(colors: [Color("ZenBG1"), Color("ZenBG2"), Color("ZenBG3")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

// MARK: - Native Liquid Glass card helpers
extension View {
    /// Native iOS Liquid Glass surface in a rounded rect. `interactive` makes it react to touch.
    func zenCard(_ radius: CGFloat = 24, interactive: Bool = false) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: radius))
    }
    /// Tinted Liquid Glass (for hero surfaces).
    func zenCard(tinted color: Color, _ radius: CGFloat = 24) -> some View {
        self.glassEffect(.regular.tint(color.opacity(0.16)), in: .rect(cornerRadius: radius))
    }
}

/// Group adjacent glass cards so they sample one backdrop and blend/morph fluidly.
struct ZenGlassGroup<Content: View>: View {
    var spacing: CGFloat = 9
    @ViewBuilder var content: () -> Content
    var body: some View { GlassEffectContainer(spacing: spacing) { content() } }
}

// MARK: - Native progress bar (Gauge) — used everywhere instead of a hand-rolled bar
struct ZenBar: View {
    var value: Double                 // 0...1
    var tint: AnyShapeStyle = AnyShapeStyle(Zen.accent)
    var body: some View {
        Gauge(value: max(0, min(1, value))) { EmptyView() }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(tint)
            .scaleEffect(y: 1, anchor: .center)
    }
}

// MARK: - Currency formatting (Indian)
enum INR {
    static func full(_ v: Double) -> String {
        let sign = v < 0 ? "-" : ""
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_IN")
        return "\(sign)₹\(f.string(from: NSNumber(value: abs(v))) ?? "0")"
    }
    static func compact(_ v: Double) -> String {
        let sign = v < 0 ? "-" : ""
        let n = abs(v)
        if n >= 10_000_000 { return "\(sign)₹\(trim(n/10_000_000))Cr" }
        if n >= 100_000    { return "\(sign)₹\(trim(n/100_000))L" }
        if n >= 1_000      { return "\(sign)₹\(trim(n/1_000))k" }
        return "\(sign)₹\(Int(n))"
    }
    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}
