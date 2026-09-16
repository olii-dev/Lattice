import Testing
import Foundation
@testable import Lattice

@Suite struct CustomProviderTests {

    // MARK: - Endpoint building

    @Test func buildsOpenAIChatEndpointFromBaseURL() {
        let provider = CustomProvider(
            name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
            protocolKind: .openAICompatible
        )
        #expect(provider.chatEndpointURL()?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    }

    @Test func normalizesTrailingSlashAndExistingSuffix() {
        let withSlash = CustomProvider(name: "X", baseURL: "http://localhost:1234/v1/", protocolKind: .openAICompatible)
        #expect(withSlash.chatEndpointURL()?.absoluteString == "http://localhost:1234/v1/chat/completions")

        let alreadySuffixed = CustomProvider(
            name: "X", baseURL: "http://localhost:1234/v1/chat/completions",
            protocolKind: .openAICompatible
        )
        #expect(alreadySuffixed.chatEndpointURL()?.absoluteString == "http://localhost:1234/v1/chat/completions")
    }

    @Test func buildsAnthropicMessagesEndpoint() {
        let provider = CustomProvider(
            name: "Proxy", baseURL: "https://my-proxy.dev",
            protocolKind: .anthropicCompatible
        )
        #expect(provider.chatEndpointURL()?.absoluteString == "https://my-proxy.dev/v1/messages")
    }

    @Test func emptyBaseURLYieldsNilEndpoints() {
        let provider = CustomProvider(name: "X", baseURL: "   ", protocolKind: .openAICompatible)
        #expect(provider.chatEndpointURL() == nil)
        #expect(provider.modelsListURL() == nil)
    }

    // MARK: - Model list parsing

    @Test func parsesOpenAIStyleModelList() {
        let json = #"{"data":[{"id":"llama-3"},{"id":"mistral-7b"}]}"#
        let ids = CustomProviderModelFetcher.parseModelIDs(data: Data(json.utf8))
        #expect(ids == ["llama-3", "mistral-7b"])
    }

    @Test func parsesAnthropicAndNameShapedModelLists() {
        let anthropic = #"{"data":[{"id":"claude-sonnet-5","display_name":"Sonnet"}]}"#
        #expect(CustomProviderModelFetcher.parseModelIDs(data: Data(anthropic.utf8)) == ["claude-sonnet-5"])

        let nameShaped = #"{"models":[{"name":"model-a"},{"name":"model-b"}]}"#
        #expect(CustomProviderModelFetcher.parseModelIDs(data: Data(nameShaped.utf8)) == ["model-a", "model-b"])
    }

    @Test func parsesGarbageAsEmptyAndDeduplicates() {
        #expect(CustomProviderModelFetcher.parseModelIDs(data: Data("not json".utf8)) == [])

        let dupes = #"{"data":[{"id":"m"},{"id":"m"},{"id":"m2"}]}"#
        #expect(CustomProviderModelFetcher.parseModelIDs(data: Data(dupes.utf8)) == ["m", "m2"])
    }

    // MARK: - Selection ids and model options

    @Test func selectionIDAndModelOptions() {
        let provider = CustomProvider(
            name: "Local", baseURL: "http://localhost:11434/v1",
            protocolKind: .openAICompatible,
            modelIDs: ["llama-3", "qwen-2"],
            supportsImages: true
        )
        #expect(provider.selectionID.hasPrefix("custom:"))
        #expect(provider.modelOptions.count == 2)
        #expect(provider.modelOptions[0].supportsImages)
        #expect(provider.defaultModel == "llama-3")
    }

    // MARK: - Model selection migration

    @Test func migrationResetsRemovedModels() {
        let suite = UserDefaults(suiteName: "lattice-test-migration-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.string(forKey: "name") ?? "") }

        suite.set("anthropic", forKey: "selectedProvider")
        suite.set("claude-sonnet-4-6", forKey: "selectedModel")
        LLMModelSelectionMigration.migrateStoredSelection(defaults: suite)
        #expect(suite.string(forKey: "selectedModel") == "claude-sonnet-5")

        suite.set("openAI", forKey: "selectedProvider")
        suite.set("gpt-4o", forKey: "selectedModel")
        LLMModelSelectionMigration.migrateStoredSelection(defaults: suite)
        #expect(suite.string(forKey: "selectedModel") == "gpt-5.6-terra")
    }

    @Test func migrationKeepsValidSelectionsAndLeavesCustomAlone() {
        let suite = UserDefaults(suiteName: "lattice-test-migration-\(UUID().uuidString)")!

        suite.set("zai", forKey: "selectedProvider")
        suite.set("glm-5.3-flash", forKey: "selectedModel")
        LLMModelSelectionMigration.migrateStoredSelection(defaults: suite)
        #expect(suite.string(forKey: "selectedModel") == "glm-5.3-flash")

        suite.set("custom:ABC-123", forKey: "selectedProvider")
        suite.set("whatever-model", forKey: "selectedModel")
        LLMModelSelectionMigration.migrateStoredSelection(defaults: suite)
        #expect(suite.string(forKey: "selectedModel") == "whatever-model")
    }

    // MARK: - 2026+ catalog integrity

    @Test func catalogsContainOnlyCurrentGenerations() {
        let bannedIDs = [
            "gpt-4o", "gpt-4.1", "gpt-5", "gpt-5.1", "gpt-5.4", "gpt-5.5",
            "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-opus-4-7", "claude-haiku-4-5",
            "glm-4.5", "glm-4.6", "glm-4.7", "glm-5", "glm-5.1",
        ]
        for provider in LLMProvider.allCases {
            #expect(!provider.models.isEmpty, "\(provider.rawValue) catalog is empty")
            #expect(provider.models.contains(where: { $0.id == provider.defaultModel }))
            for model in provider.models {
                #expect(!bannedIDs.contains(model.id), "\(model.id) is a pre-2026 model")
            }
        }
        // Vision flags
        #expect(LLMProvider.zai.models.first(where: { $0.id == "glm-5.3-flash" })?.supportsImages == true)
        #expect(LLMProvider.zai.models.first(where: { $0.id == "glm-5.3" })?.supportsImages == false)
    }
}
