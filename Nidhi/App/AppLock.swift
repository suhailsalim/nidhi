import SwiftUI
import LocalAuthentication

/// Optional biometric (Face ID / Touch ID, passcode fallback) app lock.
///
/// The lock is **UI-only**: it never gates `Store` loading, so widgets and the Gmail/statement
/// background tasks keep working while the app is visually locked. Settings live in `UserDefaults`
/// (not the Persist blob) so the lock survives — and acts independently of — a data restore.
@MainActor
final class AppLock: ObservableObject {
    // UserDefaults keys (see AGENTS.md conventions: nidhi_ prefix)
    private static let onKey    = "nidhi_lock_on"
    private static let graceKey = "nidhi_lock_grace"   // seconds; 0 = immediately

    /// Grace period before a backgrounded app re-locks.
    enum Grace: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute:   return "After 1 minute"
            case .fiveMinutes: return "After 5 minutes"
            }
        }
    }

    /// Whether the lock feature is enabled. Persisted; changing it re-arms `isLocked`.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.onKey)
            if !enabled { isLocked = false }
        }
    }
    @Published var grace: Grace {
        didSet { UserDefaults.standard.set(grace.rawValue, forKey: Self.graceKey) }
    }

    /// True when the lock screen should cover the app. Starts locked iff the feature is enabled.
    @Published var isLocked: Bool
    /// True while an `evaluatePolicy` prompt is on screen (prevents re-triggering auth).
    @Published private(set) var authenticating = false

    private var backgroundedAt: Date?

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.onKey)
        enabled = on
        grace = Grace(rawValue: UserDefaults.standard.integer(forKey: Self.graceKey)) ?? .immediately
        isLocked = on
    }

    /// Whether this device can actually authenticate (biometrics or a device passcode).
    /// Used to refuse enabling the lock on a device where the user would lock themselves out.
    func canAuthenticate() -> (ok: Bool, reason: String) {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if ok { return (true, "") }
        return (false, error?.localizedDescription ?? "This device has no passcode or biometrics set up.")
    }

    /// Prompt for Face ID / Touch ID / passcode and unlock on success.
    func unlock() {
        guard isLocked, !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Nothing to authenticate against — don't strand the user behind a lock we can't open.
            isLocked = false
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your finances") { success, _ in
            Task { @MainActor in
                self.authenticating = false
                if success { self.isLocked = false }
            }
        }
    }

    // MARK: Scene phase hooks (called from the app shell)

    func didEnterBackground() {
        guard enabled else { return }
        backgroundedAt = Date()
    }

    /// On returning to the foreground, re-lock if the grace period has elapsed.
    func didBecomeActive() {
        guard enabled, !isLocked else { return }
        guard let since = backgroundedAt else { return }
        if Date().timeIntervalSince(since) >= Double(grace.rawValue) {
            isLocked = true
        }
        backgroundedAt = nil
    }
}

// MARK: - Lock screen

/// Full-screen cover shown while `AppLock.isLocked`. Auto-triggers Face ID on appear
/// (so unlocking feels instant) and offers a manual retry after a cancel.
struct LockScreen: View {
    @EnvironmentObject var lock: AppLock

    var body: some View {
        ZStack {
            ZenBackground()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Zen.accentDeep)
                Text("Locked")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Zen.ink)
                Text("Your finances are private.")
                    .font(.subheadline)
                    .foregroundStyle(Zen.ink3)
                Button { lock.unlock() } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Zen.accentDeep)
                .disabled(lock.authenticating)
                .padding(.top, 6)
            }
            .padding()
        }
        .onAppear { lock.unlock() }
    }
}

/// Opaque cover shown while the scene is inactive/backgrounded — this is what the app
/// switcher snapshots, so balances never appear in the multitasking preview.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            ZenBackground()
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Zen.accentDeep)
        }
    }
}
