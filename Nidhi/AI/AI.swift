import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Multi-provider AI layer
//
// Opt-in, OFF by default. Most providers are cloud APIs — enabling them sends a *summary* of your
// finances (never raw statements) to that provider. Apple Intelligence (on-device) and a local
// Ollama keep everything on the device. Networking is hand-rolled URLSession (no third-party SDKs).

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case appleOnDevice, anthropic, openai, gemini, openRouter, ollamaCloud, ollamaLocal, azure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appleOnDevice: return "Apple Intelligence"
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .ollamaCloud: return "Ollama Cloud"
        case .ollamaLocal: return "Ollama (local)"
        case .azure: return "Azure OpenAI"
        }
    }
    /// True if the request leaves the device.
    var isCloud: Bool { self != .appleOnDevice && self != .ollamaLocal }
    var needsKey: Bool { ![.appleOnDevice, .ollamaLocal].contains(self) }
    var blurb: String {
        switch self {
        case .appleOnDevice: return "On-device (Private Cloud Compute when the OS offloads). Nothing stored; no key needed."
        case .ollamaLocal: return "Your own Ollama server on this network. Stays on your hardware; no key needed."
        case .anthropic: return "Cloud · uses your Anthropic API key."
        case .openai: return "Cloud · uses your OpenAI API key."
        case .gemini: return "Cloud · uses your Google AI Studio key."
        case .openRouter: return "Cloud · routes to many models via your OpenRouter key."
        case .ollamaCloud: return "Cloud · uses your Ollama Cloud key."
        case .azure: return "Cloud · your Azure OpenAI endpoint + deployment."
        }
    }
    var defaultModel: String {
        switch self {
        case .appleOnDevice: return "on-device"
        case .anthropic: return "claude-opus-4-8"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        case .openRouter: return "anthropic/claude-sonnet-4-6"
        case .ollamaCloud: return "gpt-oss:120b"
        case .ollamaLocal: return "llama3.1"
        case .azure: return ""   // deployment name
        }
    }
    var modelSuggestions: [String] {
        switch self {
        case .anthropic: return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .openai: return ["gpt-4o", "gpt-4o-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .openRouter: return ["anthropic/claude-sonnet-4-6", "openai/gpt-4o", "google/gemini-2.5-flash"]
        case .ollamaCloud: return ["gpt-oss:120b", "qwen3:235b"]
        case .ollamaLocal: return ["llama3.1", "qwen2.5", "mistral"]
        default: return []
        }
    }
}

enum AIError: LocalizedError {
    case notConfigured, unavailable(String), http(Int, String), empty
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add an API key for this provider in Settings first."
        case .unavailable(let m): return m
        case .http(let c, let m): return "AI error \(c): \(m.prefix(160))"
        case .empty: return "The model returned an empty response."
        }
    }
}

/// Manages the chosen provider/model + secret keys, and runs a unified completion across them all.
@MainActor
final class AIManager: ObservableObject {
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "ai_enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "ai_enabled") }
    }
    @Published var provider: AIProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai_provider") ?? "") ?? .appleOnDevice {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai_provider") }
    }
    @Published var ollamaBaseURL: String = UserDefaults.standard.string(forKey: "ai_ollama_url") ?? "http://localhost:11434" {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: "ai_ollama_url") }
    }
    @Published var azureEndpoint: String = UserDefaults.standard.string(forKey: "ai_azure_endpoint") ?? "" {
        didSet { UserDefaults.standard.set(azureEndpoint, forKey: "ai_azure_endpoint") }
    }
    @Published var azureAPIVersion: String = UserDefaults.standard.string(forKey: "ai_azure_apiver") ?? "2024-10-21" {
        didSet { UserDefaults.standard.set(azureAPIVersion, forKey: "ai_azure_apiver") }
    }
    @Published var testing = false
    @Published var testResult: String?

    func model(for p: AIProvider) -> String {
        UserDefaults.standard.string(forKey: "ai_model_\(p.rawValue)").flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
    }
    func setModel(_ m: String, for p: AIProvider) { UserDefaults.standard.set(m, forKey: "ai_model_\(p.rawValue)") }
    func key(for p: AIProvider) -> String? { Keychain.get("ai_key_\(p.rawValue)") }
    func setKey(_ k: String?, for p: AIProvider) { Keychain.set(k?.isEmpty == true ? nil : k, for: "ai_key_\(p.rawValue)") }

    /// Whether the current provider has everything it needs to run.
    var isConfigured: Bool {
        switch provider {
        case .appleOnDevice: return Self.appleAvailable
        case .ollamaLocal: return !ollamaBaseURL.isEmpty
        case .azure: return !(key(for: .azure) ?? "").isEmpty && !azureEndpoint.isEmpty && !model(for: .azure).isEmpty
        default: return !(key(for: provider) ?? "").isEmpty
        }
    }

    func reset() {
        enabled = false
        for p in AIProvider.allCases { setKey(nil, for: p) }
    }

    // MARK: unified completion
    func complete(system: String, user: String) async throws -> String {
        switch provider {
        case .appleOnDevice: return try await appleComplete(system: system, user: user)
        case .anthropic:     return try await anthropic(system: system, user: user)
        case .ollamaCloud, .ollamaLocal: return try await ollama(system: system, user: user)
        default:             return try await openAICompatible(system: system, user: user)
        }
    }

    func test() async {
        testing = true; testResult = nil
        do {
            let r = try await complete(system: "You are a helpful assistant. Reply in 4 words.", user: "Say hello.")
            testResult = "OK · \(r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))"
        } catch {
            testResult = "Failed · \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        testing = false
    }

    // MARK: Apple Intelligence (on-device / Private Cloud Compute managed by the OS)
    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
    private func appleComplete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content
        }
        #endif
        throw AIError.unavailable("Apple Intelligence needs iOS 26 on a supported device.")
    }

    // MARK: OpenAI-compatible (OpenAI, Gemini, OpenRouter, Azure)
    private func openAICompatible(system: String, user: String) async throws -> String {
        let m = model(for: provider)
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]
        switch provider {
        case .openai:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            headers["Authorization"] = "Bearer \(try requireKey())"
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            headers["Authorization"] = "Bearer \(try requireKey())"
        case .openRouter:
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            headers["Authorization"] = "Bearer \(try requireKey())"
        case .azure:
            let base = azureEndpoint.hasSuffix("/") ? String(azureEndpoint.dropLast()) : azureEndpoint
            guard !base.isEmpty, !m.isEmpty else { throw AIError.notConfigured }
            url = URL(string: "\(base)/openai/deployments/\(m)/chat/completions?api-version=\(azureAPIVersion)")!
            headers["api-key"] = try requireKey()
        default:
            throw AIError.notConfigured
        }
        let body: [String: Any] = ["model": m, "temperature": 0.4,
                                   "messages": [["role": "system", "content": system],
                                                ["role": "user", "content": user]]]
        let json = try await post(url, headers: headers, body: body)
        if let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any], let c = msg["content"] as? String { return c }
        throw AIError.empty
    }

    // MARK: Anthropic Messages API
    private func anthropic(system: String, user: String) async throws -> String {
        let headers = ["Content-Type": "application/json", "x-api-key": try requireKey(),
                       "anthropic-version": "2023-06-01"]
        let body: [String: Any] = ["model": model(for: .anthropic), "max_tokens": 1024, "system": system,
                                   "messages": [["role": "user", "content": user]]]
        let json = try await post(URL(string: "https://api.anthropic.com/v1/messages")!, headers: headers, body: body)
        if let content = json["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw AIError.empty
    }

    // MARK: Ollama (/api/chat) — cloud or local
    private func ollama(system: String, user: String) async throws -> String {
        let base: String
        var headers = ["Content-Type": "application/json"]
        if provider == .ollamaCloud { base = "https://ollama.com"; headers["Authorization"] = "Bearer \(try requireKey())" }
        else { base = ollamaBaseURL.hasSuffix("/") ? String(ollamaBaseURL.dropLast()) : ollamaBaseURL }
        let body: [String: Any] = ["model": model(for: provider), "stream": false,
                                   "messages": [["role": "system", "content": system],
                                                ["role": "user", "content": user]]]
        let json = try await post(URL(string: "\(base)/api/chat")!, headers: headers, body: body)
        if let msg = json["message"] as? [String: Any], let c = msg["content"] as? String, !c.isEmpty { return c }
        throw AIError.empty
    }

    // MARK: helpers
    private func requireKey() throws -> String {
        guard let k = key(for: provider), !k.isEmpty else { throw AIError.notConfigured }
        return k
    }
    private func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AIError.http(code, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
