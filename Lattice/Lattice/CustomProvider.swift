import Combine
import Foundation
import SwiftUI

/// A user-configured provider reachable over an OpenAI-compatible or
/// Anthropic-compatible chat API at an arbitrary base URL.
struct CustomProvider: Identifiable, Codable, Equatable {
    enum ProtocolKind: String, Codable, CaseIterable, Identifiable {
        case openAICompatible
        case anthropicCompatible

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAICompatible: "OpenAI-compatible"
            case .anthropicCompatible: "Anthropic-compatible"
            }
        }
    }

    let id: UUID
    var name: String
    var baseURL: String
    var protocolKind: ProtocolKind
    var modelIDs: [String]
    /// Whether image attachments may be sent (user-confirmed; most local text models cannot).
    var supportsImages: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        protocolKind: ProtocolKind = .openAICompatible,
        modelIDs: [String] = [],
        supportsImages: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.protocolKind = protocolKind
        self.modelIDs = modelIDs
        self.supportsImages = supportsImages
    }

    var selectionID: String { "custom:\(id.uuidString)" }

    var modelOptions: [LLMModelOption] {
        modelIDs.map { LLMModelOption(id: $0, label: $0, supportsImages: supportsImages) }
    }

    var defaultModel: String { modelIDs.first ?? "" }

    /// Chat-completions endpoint for OpenAI-compatible providers; messages endpoint
    /// for Anthropic-compatible ones. Normalizes a bare base URL.
    func chatEndpointURL() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var base = trimmed
        if base.hasSuffix("/") { base.removeLast() }
        switch protocolKind {
        case .openAICompatible:
            if base.hasSuffix("/chat/completions") { return URL(string: base) }
            return URL(string: base + "/chat/completions")
        case .anthropicCompatible:
            if base.hasSuffix("/messages") { return URL(string: base) }
            return URL(string: base + "/v1/messages")
        }
    }

    /// Model-list endpoint used by the "Fetch models" button.
    func modelsListURL() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var base = trimmed
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { return URL(string: base + "/models") }
        switch protocolKind {
        case .openAICompatible:
            return URL(string: base + "/v1/models")
        case .anthropicCompatible:
            return URL(string: base + "/v1/models")
        }
    }
}

// MARK: - Presets

extension CustomProvider {
    /// One-tap templates so non-developers can connect common providers without
    /// knowing what a base URL is.
    struct Preset: Identifiable, Equatable {
        let id: String
        let name: String
        let baseURL: String
        let protocolKind: ProtocolKind
        let hint: String
        let systemImage: String
    }

    static let presets: [Preset] = [
        Preset(
            id: "ollama", name: "Ollama (on this Mac)",
            baseURL: "http://localhost:11434/v1", protocolKind: .openAICompatible,
            hint: "Free and private — runs AI models locally. No key needed.",
            systemImage: "desktopcomputer"
        ),
        Preset(
            id: "lmstudio", name: "LM Studio (on this Mac)",
            baseURL: "http://localhost:1234/v1", protocolKind: .openAICompatible,
            hint: "Free and private — uses models you downloaded in LM Studio.",
            systemImage: "desktopcomputer"
        ),
        Preset(
            id: "openrouter", name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1", protocolKind: .openAICompatible,
            hint: "One key for hundreds of different AI models.",
            systemImage: "arrow.triangle.branch"
        ),
        Preset(
            id: "groq", name: "Groq",
            baseURL: "https://api.groq.com/openai/v1", protocolKind: .openAICompatible,
            hint: "Extremely fast open models.",
            systemImage: "bolt.fill"
        ),
        Preset(
            id: "deepseek", name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1", protocolKind: .openAICompatible,
            hint: "Budget-friendly coding models.",
            systemImage: "water.waves"
        ),
        Preset(
            id: "mistral", name: "Mistral",
            baseURL: "https://api.mistral.ai/v1", protocolKind: .openAICompatible,
            hint: "European AI lab with open models.",
            systemImage: "wind"
        ),
        Preset(
            id: "xai", name: "xAI (Grok)",
            baseURL: "https://api.x.ai/v1", protocolKind: .openAICompatible,
            hint: "Grok models from xAI.",
            systemImage: "x.squareroot"
        ),
    ]
}

// MARK: - Persistence

/// Persists the user's custom providers and exposes them reactively.
@MainActor
final class CustomProviderStore: ObservableObject {
    static let shared = CustomProviderStore()

    @Published private(set) var providers: [CustomProvider]

    private static let storageKey = "latticeCustomProvidersV1"

    private init() {
        providers = Self.readFromDefaults()
    }

    func add(_ provider: CustomProvider) {
        providers.append(provider)
        persist()
    }

    func update(_ provider: CustomProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        persist()
    }

    func remove(id: UUID) {
        providers.removeAll { $0.id == id }
        persist()
    }

    func provider(selectionID: String) -> CustomProvider? {
        guard selectionID.hasPrefix("custom:") else { return nil }
        let raw = String(selectionID.dropFirst("custom:".count))
        return providers.first { $0.id.uuidString == raw }
    }

    func provider(id: UUID) -> CustomProvider? {
        providers.first { $0.id == id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func readFromDefaults() -> [CustomProvider] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([CustomProvider].self, from: data)) ?? []
    }
}

// MARK: - Model discovery

enum CustomProviderModelFetcher {
    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fetches available model ids from the provider's models endpoint.
    static func fetchModelIDs(for provider: CustomProvider, apiKey: String) async throws -> [String] {
        guard let url = provider.modelsListURL() else {
            throw FetchError(message: "That base URL doesn't look right. Check it and try again.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        switch provider.protocolKind {
        case .openAICompatible:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicCompatible:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError(
                message: "The provider answered with \(http.statusCode). "
                    + (body.isEmpty ? "" : "\n\n\(body.prefix(300))")
            )
        }
        return parseModelIDs(data: data)
    }

    /// Parses both OpenAI-style `{"data":[{"id":...}]}` and Anthropic-style
    /// `{"data":[{"id":...}]}` / `{"models":[{"id":...}]}` responses.
    static func parseModelIDs(data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let containers: [[String: Any]] =
            (object["data"] as? [[String: Any]])
            ?? (object["models"] as? [[String: Any]])
            ?? []
        let ids = containers.compactMap { entry -> String? in
            if let id = entry["id"] as? String, !id.isEmpty { return id }
            if let name = entry["name"] as? String, !name.isEmpty { return name }
            return nil
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
