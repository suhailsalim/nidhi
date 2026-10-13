import SwiftUI

// MARK: - Sync status line (shared by Connect sheet & Accounts)
struct SyncStatus: View {
    let phase: SyncManager.Phase
    var body: some View {
        switch phase {
        case .idle: EmptyView()
        case .working(let m):
            HStack(spacing: 8) { ProgressView().tint(Zen.accentDeep); Text(m).font(.caption).foregroundStyle(Zen.ink2) }
        case .success(let n):
            Label(n > 0 ? "Synced \(n) new transaction\(n == 1 ? "" : "s")" : "Up to date",
                  systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Zen.greenDeep)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Zen.caution)
        }
    }
}

// MARK: - Bank-sync settings (Setu Account Aggregator)
struct BankSyncSettingsView: View {
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var store: Store
    @State private var secret: String = Keychain.get("setu_client_secret") ?? ""
    @State private var sandbox: Bool = SetuConfig.load().baseURL != SetuConfig.prodBase

    var body: some View {
        Form {
            Section("Setu credentials") {
                Toggle("Setu sandbox endpoint", isOn: $sandbox)
                    .onChange(of: sandbox) { _, v in sync.config.baseURL = v ? SetuConfig.sandboxBase : SetuConfig.prodBase }
                LabeledTextField("Base URL", text: $sync.config.baseURL)
                LabeledTextField("Client ID", text: $sync.config.clientId)
                SecureField("Client secret", text: $secret)
                LabeledTextField("Product instance ID", text: $sync.config.productInstanceId)
                LabeledTextField("Redirect scheme", text: $sync.config.redirectScheme)
            }
            Section {
                LabeledTextField("Mobile (AA-linked)", text: $sync.phone, keyboard: .phonePad)
            } header: {
                Text("Your account")
            } footer: {
                Text("Used to create the consent request. You'll approve access in your Account Aggregator app (OneMoney, Finvu, etc.) — Nidhi never sees your bank password. No Setu account yet? Use Import statement or add accounts manually.")
            }

            Section {
                Button {
                    sync.config.baseURL = sandbox ? SetuConfig.sandboxBase : SetuConfig.prodBase
                    sync.setSecret(secret); sync.saveConfig()
                    sync.sync(into: store)
                } label: {
                    Label(sync.isWorking ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isWorking)
                SyncStatus(phase: sync.phase)
            }
        }
        .scrollContentBackground(.hidden).background(ZenBackground())
        .navigationTitle("Bank sync")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { sync.setSecret(secret); sync.saveConfig() }
    }
}

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    init(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) {
        self.label = label; self._text = text; self.keyboard = keyboard
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Zen.ink2)
            Spacer()
            TextField("", text: $text).multilineTextAlignment(.trailing)
                .keyboardType(keyboard).autocorrectionDisabled().textInputAutocapitalization(.never)
        }
    }
}
