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

enum StreamChunk: Sendable {
    case textDelta(String)
    /// OpenAI-compatible providers may stream extended reasoning separately from `content`.
    case reasoningDelta(String)
    case toolCallAnnounced(index: Int, id: String, name: String)
    case done(stopReason: String, blocks: [Int: ContentBlock])
}

// MARK: - SSE Decodables (used by LLMService)

struct SSEEvent: Decodable {
    let type: String
    let index: Int?
    let content_block: SSEBlock?
    let delta: SSEDelta?
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
    case apiError(String)
    var errorDescription: String? {
        if case .apiError(let msg) = self { return APIErrorFormatting.friendlyMessage(from: msg) }
        return nil
    }
}
