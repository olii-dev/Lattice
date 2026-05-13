import Foundation

// MARK: - Model context budgets (input tokens; conservative defaults)

enum LatticeContextLimits {

    /// Approximate total input context window for the selected model.
    static func inputTokenBudget(modelId: String, providerRaw: String) -> Int {
        let m = modelId.lowercased()
        let p = (LLMProvider(rawValue: providerRaw) ?? .anthropic)

        switch p {
        case .anthropic:
            if m.contains("opus") { return 200_000 }
            if m.contains("sonnet") { return 200_000 }
            if m.contains("haiku") { return 200_000 }
            return 200_000
        case .openAI:
            if m.contains("gpt-5") || m.contains("gpt-4.1") || m.contains("gpt-4o") { return 272_000 }
            if m.contains("o3") || m.contains("o4") || m.contains("o1") { return 200_000 }
            return 128_000
        case .zai:
            if m.contains("128k") { return 128_000 }
            if m.contains("glm-5") || m.contains("glm-4.7") { return 200_000 }
            return 131_000
        }
    }
}

// MARK: - Token heuristics (no provider tokenizer; tuned slightly above byte÷4)

enum LatticeContextEstimator {

    /// UTF-8 text → approximate tokens (English + JSON heavy; slightly conservative vs raw ÷4).
    static func approximateTokensFromText(_ text: String) -> Int {
        let n = text.utf8.count
        guard n > 0 else { return 0 }
        return max(1, (n * 10) >> 2) // ×2.5 vs bytes
    }

    /// Serialized API history → approximate tokens (JSON adds overhead).
    static func approximateChatHistoryTokens(for history: [[String: Any]]) -> Int {
        guard JSONSerialization.isValidJSONObject(history),
              let data = try? JSONSerialization.data(withJSONObject: history)
        else { return 0 }
        let base = max(0, data.count)
        return max(0, (base * 11) >> 2) // ×2.75
    }
}
