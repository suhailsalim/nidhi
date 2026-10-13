import SwiftUI

// MARK: - AI settings (provider, keys, model)
struct AISettingsView: View {
    @EnvironmentObject var ai: AIManager
    @State private var keyText = ""
    @State private var modelText = ""
    @State private var loadedProvider: AIProvider?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $ai.enabled) { Label("Enable AI features", systemImage: "sparkles") }
            } footer: {
                Text("Off by default. When on, AI insights send an **aggregate summary** of your finances (totals, category sums, goals) — never raw transactions, account or card numbers — to the selected provider. Apple Intelligence and a local Ollama keep everything on your device.")
            }

            Section("Provider") {
                Picker("Provider", selection: $ai.provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                Text(ai.provider.blurb).font(.caption).foregroundStyle(Zen.ink3)
                if ai.provider.isCloud {
                    Label("Cloud — your summary leaves the device", systemImage: "cloud").font(.caption).foregroundStyle(Zen.caution)
                } else {
                    Label("On-device — nothing leaves your phone", systemImage: "lock.shield").font(.caption).foregroundStyle(Zen.greenDeep)
                }
            }

            if ai.provider == .appleOnDevice {
                Section { Label(AIManager.appleAvailable ? "Available on this device" : "Needs iOS 26 on a supported device",
                                systemImage: AIManager.appleAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(AIManager.appleAvailable ? Zen.greenDeep : Zen.caution) }
            } else {
                if ai.provider.needsKey {
                    Section("API key") {
                        SecureField("Paste your \(ai.provider.label) key", text: $keyText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save key") { ai.setKey(keyText, for: ai.provider) }.disabled(keyText.isEmpty)
                        if ai.key(for: ai.provider) != nil { Label("Key saved in Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(Zen.greenDeep) }
                    }
                }
                if ai.provider == .ollamaLocal {
                    Section("Server") { LabeledField(label: "Base URL", placeholder: "http://localhost:11434", text: $ai.ollamaBaseURL) }
                }
                if ai.provider == .azure {
                    Section("Azure") {
                        LabeledField(label: "Endpoint", placeholder: "https://xxx.openai.azure.com", text: $ai.azureEndpoint)
                        LabeledField(label: "API version", placeholder: "2024-10-21", text: $ai.azureAPIVersion)
                    }
                }
                Section("Model") {
                    TextField(ai.provider == .azure ? "Deployment name" : "Model id", text: $modelText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: modelText) { _, v in ai.setModel(v, for: ai.provider) }
                    if !ai.provider.modelSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ai.provider.modelSuggestions, id: \.self) { m in
                                    Button(m) { modelText = m; ai.setModel(m, for: ai.provider) }
                                        .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(Zen.accent)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button { Task { await ai.test() } } label: {
                    HStack { Label("Test connection", systemImage: "bolt.horizontal"); Spacer()
                        if ai.testing { ProgressView() } }
                }.disabled(ai.testing || !ai.isConfigured)
                if let r = ai.testResult {
                    Text(r).font(.caption).foregroundStyle(r.hasPrefix("OK") ? Zen.greenDeep : Zen.caution)
                }
            }
        }
        .zenForm().navigationTitle("AI").navigationBarTitleDisplayMode(.inline)
        .onAppear { syncFields() }
        .onChange(of: ai.provider) { _, _ in syncFields() }
    }

    private func syncFields() {
        keyText = ""
        modelText = ai.model(for: ai.provider)
        loadedProvider = ai.provider
    }
}

// MARK: - AI insights surface (used on the Insights tab)
struct AIInsightsCard: View {
    @EnvironmentObject var ai: AIManager
    @EnvironmentObject var store: Store
    @State private var running: AIInsightKind?
    @State private var result: String?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Zen.accentDeep)
                Text("AI insights").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Spacer()
                Text(ai.provider.label).font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
            }

            if !ai.isConfigured {
                Text("Pick a provider in Settings → AI to get tailored insights. Apple Intelligence runs on-device.")
                    .font(.caption).foregroundStyle(Zen.ink3)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(AIInsightKind.allCases) { k in
                        Button { run(k) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: k.symbol).font(.caption)
                                Text(k.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if running == k { ProgressView().controlSize(.mini) }
                            }
                            .padding(.horizontal, 11).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular.tint(Zen.accent.opacity(0.14)), in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain).foregroundStyle(Zen.ink).disabled(running != nil)
                    }
                }
                if let errorText { Label(errorText, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Zen.caution) }
                if let result {
                    Divider().overlay(Zen.track)
                    Text(LocalizedStringKey(result)).font(.caption).foregroundStyle(Zen.ink2).textSelection(.enabled)
                    Text("AI-generated · verify important numbers.").font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).zenCard(tinted: Zen.accent, 24)
    }

    private func run(_ k: AIInsightKind) {
        running = k; result = nil; errorText = nil
        Task {
            do { result = try await ai.complete(system: AIInsights.system, user: AIInsights.userPrompt(k, store: store)) }
            catch { errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            running = nil
        }
    }
}
