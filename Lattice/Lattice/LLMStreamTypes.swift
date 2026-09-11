import Foundation

// MARK: - Content blocks (used for conversation history)

struct ContentBlock {
    let type: String
    var text: String?
    var toolId: String?
    var toolName: String?
    var toolInputJSON: String?

    static func text(_ t: String) -> ContentBlock {
        ContentBlock(type: "text", text: t)
    }

    static func toolUse(id: String, name: String) -> ContentBlock {
        ContentBlock(type: "tool_use", toolId: id, toolName: name, toolInputJSON: "")
    }

    var parsedInput: [String: Any]? {
        guard let json = toolInputJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func toAPIDict() -> [String: Any] {
        switch type {
        case "text":
            return ["type": "text", "text": text ?? ""]
        case "tool_use":
            return [
                "type": "tool_use",
                "id": toolId ?? "",
                "name": toolName ?? "",
                "input": parsedInput ?? [:]
            ]
        default:
            return [:]
        }
    }

    private init(type: String, text: String? = nil, toolId: String? = nil,
                 toolName: String? = nil, toolInputJSON: String? = nil) {
        self.type = type
        self.text = text
        self.toolId = toolId
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
    }
}

func toolResultMessage(toolUseId: String, content: String, isError: Bool) -> [String: Any] {
    ["type": "tool_result", "tool_use_id": toolUseId, "content": content, "is_error": isError]
}

// MARK: - Stream events

struct LLMTokenUsage: Equatable {
    var inputTokens: Int?
    var outputTokens: Int?

    /// "1.2k in · 0.4k out" style caption; nil when nothing measurable arrived.
    var caption: String? {
        var parts: [String] = []
        if let inputTokens { parts.append("\(Self.formatCount(inputTokens)) in") }
        if let outputTokens { parts.append("\(Self.formatCount(outputTokens)) out") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatCount(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let thousands = Double(count) / 1_000
        let text = thousands >= 100
            ? String(Int(thousands.rounded()))
            : String(format: "%.1f", thousands)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) + "k" : text + "k"
    }
}

enum StreamChunk: Sendable {
    case textDelta(String)
    /// OpenAI-compatible providers may stream extended reasoning separately from `content`.
    case reasoningDelta(String)
    case toolCallAnnounced(index: Int, id: String, name: String)
    case done(stopReason: String, blocks: [Int: ContentBlock], usage: LLMTokenUsage?)
}

// MARK: - SSE Decodables (used by LLMService)

struct SSEEvent: Decodable {
    let type: String
    let index: Int?
    let content_block: SSEBlock?
    let delta: SSEDelta?
    /// Anthropic `message_delta` carries cumulative token usage at the top level.
    let usage: SSEUsagePayload?
    /// Anthropic `message_start` carries initial usage inside the message envelope.
    let message: SSEMessageMeta?
}

struct SSEMessageMeta: Decodable {
    let usage: SSEUsagePayload?
}

/// Union of the usage field shapes across providers (Anthropic + OpenAI-style).
struct SSEUsagePayload: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let prompt_tokens: Int?
    let completion_tokens: Int?

    var anthropicUsage: LLMTokenUsage {
        LLMTokenUsage(inputTokens: input_tokens, outputTokens: output_tokens)
    }

    var openAIUsage: LLMTokenUsage {
        LLMTokenUsage(inputTokens: prompt_tokens, outputTokens: completion_tokens)
    }
}

struct SSEBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
}

struct SSEDelta: Decodable {
    let type: String?
    let text: String?
    let partial_json: String?
    let stop_reason: String?
}

// MARK: - Errors

enum StreamError: LocalizedError {
    /// HTTP status code from the failing response when available; nil for
    /// provider-reported failures that never produced a usable HTTP status.
    case apiError(message: String, statusCode: Int?)

    var rawMessage: String {
        if case .apiError(let message, _) = self { return message }
        return "Unknown API error."
    }

    var statusCode: Int? {
        if case .apiError(_, let statusCode) = self { return statusCode }
        return nil
    }

    var errorDescription: String? {
        APIErrorFormatting.friendlyMessage(from: rawMessage)
    }
}
