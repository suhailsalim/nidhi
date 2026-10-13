import SwiftUI

@main
struct NidhiApp: App {
    @StateObject private var store = Store()
    @StateObject private var sync = SyncManager()
    @StateObject private var gmail = GmailManager()
    @StateObject private var ai = AIManager()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(store)
                    .environmentObject(sync)
                    .environmentObject(gmail)
                    .environmentObject(ai)
                    .environmentObject(lock)
                    .tint(Zen.accentDeep)
                // Lock overlay sits above RootView (and its sheets) but is driven only by
                // the UI lock — Store, widgets and background tasks are never gated on it.
                if lock.isLocked {
                    LockScreen().environmentObject(lock)
                        .transition(.opacity)
                } else if scenePhase != .active {
                    // App-switcher / inactive snapshot cover — hides balances in multitasking.
                    PrivacyCover()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.didEnterBackground()
                store.autoBackupIfEnabled()
                GmailBackground.schedule()
                StatementBackground.schedule()
            case .active:
                lock.didBecomeActive()
                store.drainQuickLogInbox()   // Siri/Shortcuts/widget quick logs → Store (main thread)
                // Drained quick logs are new charges, so re-derive reminders AFTER draining. They're
                // rescheduled as a set rather than patched individually, so this can't orphan any.
                store.rescheduleRecurringReminders()
                Task { await gmail.backgroundScanIfDue(into: store) }
                Task { await gmail.statementScanIfDue(into: store) }
            default: break
            }
        }
        .backgroundTask(.appRefresh(GmailBackground.id)) {
            await gmail.backgroundScanIfDue(into: store)
            GmailBackground.schedule()
        }
        .backgroundTask(.appRefresh(StatementBackground.id)) {
            await gmail.statementScanIfDue(into: store)
            StatementBackground.schedule()
        }
    }
}
