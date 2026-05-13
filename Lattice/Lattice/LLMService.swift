import Foundation

// MARK: - Provider types

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case zai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .zai: "z.ai"
        }
    }

    var models: [(id: String, label: String)] {
        switch self {
        case .anthropic: [
            ("claude-opus-4-7", "Claude Opus 4.7"),
            ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
            ("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5"),
            ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
        ]
        case .openAI: [
            ("gpt-5.4", "GPT-5.4"),
            ("gpt-5.4-mini", "GPT-5.4 Mini"),
            ("gpt-5.4-nano", "GPT-5.4 Nano"),
            ("gpt-5.1", "GPT-5.1"),
            ("gpt-5", "GPT-5"),
            ("gpt-4.1", "GPT-4.1"),
            ("gpt-4o", "GPT-4o"),
            ("gpt-4o-mini", "GPT-4o mini"),
        ]
        case .zai: [
            ("glm-4.7-flash", "GLM-4.7 Flash"),
            ("glm-4.5-flash", "GLM-4.5 Flash"),
            ("glm-4.5-air", "GLM-4.5 Air"),
            ("glm-4.7", "GLM-4.7"),
            ("glm-4.7-flashx", "GLM-4.7 FlashX"),
            ("glm-4.6", "GLM-4.6"),
            ("glm-4.5", "GLM-4.5"),
            ("glm-4.5-x", "GLM-4.5 X"),
            ("glm-4.5-airx", "GLM-4.5 AirX"),
            ("glm-4-32b-0414-128k", "GLM-4 32B 128K"),
            ("glm-5", "GLM-5"),
            ("glm-5-turbo", "GLM-5 Turbo"),
            ("glm-5.1", "GLM-5.1"),
        ]
        }
    }

    var defaultModel: String {
        models.first?.id ?? ""
    }

    var endpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .zai: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!
        }
    }
}

// MARK: - Unified streaming service

struct LLMService {
    private static let providerOverloadMaxAttempts = 4
    private static let providerOverloadRetryDelayNanoseconds: UInt64 = 15 * 1_000_000_000

    private static func shouldRetryAfterTransientProviderFailure(_ error: Error) -> Bool {
        if let e = error as? StreamError, case .apiError(let raw) = e {
            let t = raw.lowercased()
            if t.contains("1305") { return true }
            if t.contains("overloaded") { return true }
            if t.contains("temporarily overloaded") { return true }
            if t.contains("rate_limit") || t.contains("rate limit") { return true }
        }
        let d = error.localizedDescription.lowercased()
        return d.contains("1305")
            || d.contains("overloaded")
            || d.contains("temporarily overloaded")
            || d.contains("rate_limit")
            || d.contains("rate limit")
    }

    private static let latticeToolDefinitions: [[String: Any]] = [
        [
            "name": "bash",
            "description": "Execute a bash shell command and return stdout + stderr.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The bash command to run."]
                ],
                "required": ["command"]
            ]
        ],
        [
            "name": "read_file",
            "description": "Read and return the full text content of a file.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute or relative path to the file."]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": "write_file",
            "description": "Write text content to a file, creating or overwriting it.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path where the file should be written."],
                    "content": ["type": "string", "description": "Text content to write."]
                ],
                "required": ["path", "content"]
            ]
        ]
    ]

    private var tools: [[String: Any]] { Self.latticeToolDefinitions }

    private var openAITools: [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool["name"] as Any,
                    "description": tool["description"] as Any,
                    "parameters": tool["input_schema"] as Any
                ]
            ]
        }
    }

    /// OpenAI-compatible chat completions URL. z.ai depends on `ChatContext.zaiUseCodingEndpoint` for Coding Plan vs pay-as-you-go.
    private func openAIChatCompletionsURL(provider: LLMProvider, context: ChatContext) -> URL {
        switch provider {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .zai:
            if context.zaiUseCodingEndpoint {
                return URL(string: "https://api.z.ai/api/coding/paas/v4/chat/completions")!
            }
            return URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!
        case .anthropic:
            return LLMProvider.anthropic.endpoint
        }
    }

    private func openAIChatCompletionsURL(provider: LLMProvider, zaiUseCodingEndpoint: Bool) -> URL {
        switch provider {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .zai:
            if zaiUseCodingEndpoint {
                return URL(string: "https://api.z.ai/api/coding/paas/v4/chat/completions")!
            }
            return URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!
        case .anthropic:
            return LLMProvider.anthropic.endpoint
        }
    }

    func stream(
        messages: [[String: Any]],
        apiKey: String,
        context: ChatContext
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let provider = LLMProvider(rawValue: context.provider) ?? .anthropic
        switch provider {
        case .anthropic:
            return streamAnthropic(messages: messages, apiKey: apiKey, context: context)
        case .openAI, .zai:
            return streamOpenAI(messages: messages, apiKey: apiKey, context: context, provider: provider)
        }
    }

    // MARK: - Anthropic streaming

    private func streamAnthropic(
        messages: [[String: Any]],
        apiKey: String,
        context: ChatContext
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for attempt in 1...Self.providerOverloadMaxAttempts {
                    do {
                    var request = URLRequest(url: LLMProvider.anthropic.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 240
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body: [String: Any] = [
                        "model": context.model,
                        "max_tokens": 16384,
                        "stream": true,
                        "system": [[
                            "type": "text",
                            "text": Self.latticeSystemPrompt(for: context),
                            "cache_control": ["type": "ephemeral"]
                        ]],
                        "tools": tools,
                        "messages": messages
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let msg = parseAnthropicError(data) ?? "HTTP \(http.statusCode)"
                        throw StreamError.apiError(msg)
                    }

                    var blocks: [Int: ContentBlock] = [:]
                    var stopReason = "end_turn"

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(SSEEvent.self, from: data)
                        else { continue }

                        switch event.type {
                        case "content_block_start":
                            guard let cb = event.content_block else { break }
                            let idx = event.index ?? 0
                            switch cb.type {
                            case "text":
                                blocks[idx] = .text("")
                            case "tool_use":
                                let id = cb.id ?? ""
                                let name = cb.name ?? ""
                                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                                blocks[idx] = .toolUse(id: id, name: name)
                                continuation.yield(.toolCallAnnounced(index: idx, id: id, name: name))
                            default: break
                            }

                        case "content_block_delta":
                            let idx = event.index ?? 0
                            guard let delta = event.delta else { break }
                            switch delta.type {
                            case "text_delta":
                                guard let t = delta.text else { break }
                                let existingText = blocks[idx]?.text ?? ""
                                blocks[idx]?.text = existingText + t
                                continuation.yield(.textDelta(t))
                            case "input_json_delta":
                                guard let p = delta.partial_json else { break }
                                let existingJSON = blocks[idx]?.toolInputJSON ?? ""
                                blocks[idx]?.toolInputJSON = existingJSON + p
                            default: break
                            }

                        case "message_delta":
                            if let r = event.delta?.stop_reason { stopReason = r }

                        default: break
                        }
                    }

                    continuation.yield(.done(stopReason: stopReason, blocks: blocks))
                    continuation.finish()
                    return
                    } catch {
                    let canRetry = attempt < Self.providerOverloadMaxAttempts
                        && Self.shouldRetryAfterTransientProviderFailure(error)
                    if canRetry {
                        try await Task.sleep(nanoseconds: Self.providerOverloadRetryDelayNanoseconds)
                        continue
                    }
                    continuation.finish(throwing: error)
                    return
                }
                }
            }
        }
    }

    // MARK: - OpenAI / z.ai streaming

    /// z.ai documents `max_tokens` only. OpenAI's newer models reject `max_tokens` in favor of `max_completion_tokens`.
    private func chatCompletionOutputLimitFields(model: String, provider: LLMProvider) -> [String: Any] {
        guard provider == .openAI else {
            return ["max_tokens": 16_384]
        }
        let m = model.lowercased()
        if m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            return ["max_completion_tokens": 16_384]
        }
        return ["max_tokens": 16_384]
    }

    private func openAIReasoningFragment(from delta: [String: Any]) -> String? {
        if let s = delta["reasoning"] as? String, !s.isEmpty { return s }
        if let s = delta["reasoning_content"] as? String, !s.isEmpty { return s }
        if let obj = delta["reasoning"] as? [String: Any] {
            if let s = obj["text"] as? String, !s.isEmpty { return s }
            if let s = obj["content"] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private func streamOpenAI(
        messages: [[String: Any]],
        apiKey: String,
        context: ChatContext,
        provider: LLMProvider
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for attempt in 1...Self.providerOverloadMaxAttempts {
                    do {
                    var request = URLRequest(url: openAIChatCompletionsURL(provider: provider, context: context))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 240
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    let openAIMessages = convertToOpenAIMessages(messages, context: context)
                    var body: [String: Any] = [
                        "model": context.model,
                        "stream": true,
                        "tools": openAITools,
                        "messages": openAIMessages
                    ]
                    for (k, v) in chatCompletionOutputLimitFields(model: context.model, provider: provider) {
                        body[k] = v
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        throw StreamError.apiError(msg)
                    }

                    var blocks: [Int: ContentBlock] = [:]
                    var toolCallIndex = 0
                    var stopReason = "end_turn"

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }
                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let choice = choices.first,
                              let delta = choice["delta"] as? [String: Any]
                        else { continue }

                        if let reason = choice["finish_reason"] as? String, reason == "tool_calls" {
                            stopReason = "tool_use"
                        } else if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                            stopReason = reason
                        }

                        if let reasoningFragment = openAIReasoningFragment(from: delta), !reasoningFragment.isEmpty {
                            continuation.yield(.reasoningDelta(reasoningFragment))
                        }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            if blocks[0] == nil { blocks[0] = .text("") }
                            let existingContent = blocks[0]?.text ?? ""
                            blocks[0]?.text = existingContent + content
                            continuation.yield(.textDelta(content))
                        }

                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                let idx = tc["index"] as? Int ?? toolCallIndex
                                if let fn = tc["function"] as? [String: Any] {
                                    if let name = fn["name"] as? String, !name.isEmpty {
                                        let id = tc["id"] as? String ?? "call_\(idx)"
                                        blocks[idx + 1] = .toolUse(id: id, name: name)
                                        continuation.yield(.toolCallAnnounced(index: idx + 1, id: id, name: name))
                                        toolCallIndex = idx + 1
                                    }
                                    if let args = fn["arguments"] as? String, !args.isEmpty {
                                        let existingArgs = blocks[idx + 1]?.toolInputJSON ?? ""
                                        blocks[idx + 1]?.toolInputJSON = existingArgs + args
                                    }
                                }
                            }
                        }
                    }

                    continuation.yield(.done(stopReason: stopReason, blocks: blocks))
                    continuation.finish()
                    return
                    } catch {
                    let canRetry = attempt < Self.providerOverloadMaxAttempts
                        && Self.shouldRetryAfterTransientProviderFailure(error)
                    if canRetry {
                        try await Task.sleep(nanoseconds: Self.providerOverloadRetryDelayNanoseconds)
                        continue
                    }
                    continuation.finish(throwing: error)
                    return
                }
                }
            }
        }
    }

    private func convertToOpenAIMessages(_ messages: [[String: Any]], context: ChatContext) -> [[String: Any]] {
        var result: [[String: Any]] = [
            ["role": "system", "content": Self.latticeSystemPrompt(for: context)]
        ]

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }

            if role == "user" {
                if let content = msg["content"] as? String {
                    result.append(["role": "user", "content": content])
                } else if let content = msg["content"] as? [[String: Any]] {
                    // Could be tool_result messages -- convert to OpenAI format
                    var toolResults: [[String: Any]] = []
                    var textParts: [String] = []

                    for block in content {
                        let type = block["type"] as? String ?? ""
                        if type == "tool_result" {
                            let toolCallId = block["tool_use_id"] as? String ?? ""
                            let output = block["content"] as? String ?? ""
                            toolResults.append([
                                "role": "tool",
                                "tool_call_id": toolCallId,
                                "content": output
                            ])
                        } else if type == "text" {
                            textParts.append(block["text"] as? String ?? "")
                        }
                    }

                    for tr in toolResults { result.append(tr) }
                    if !textParts.isEmpty {
                        result.append(["role": "user", "content": textParts.joined(separator: "\n")])
                    }
                }
            } else if role == "assistant" {
                if let content = msg["content"] as? String {
                    result.append(["role": "assistant", "content": content])
                } else if let content = msg["content"] as? [[String: Any]] {
                    var text = ""
                    var toolCalls: [[String: Any]] = []

                    for block in content {
                        let type = block["type"] as? String ?? ""
                        if type == "text" {
                            text += block["text"] as? String ?? ""
                        } else if type == "tool_use" {
                            let id = block["id"] as? String ?? ""
                            let name = block["name"] as? String ?? ""
                            let input = block["input"] as? [String: Any] ?? [:]
                            let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                            let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                            toolCalls.append([
                                "id": id,
                                "type": "function",
                                "function": ["name": name, "arguments": argsStr]
                            ])
                        }
                    }

                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    if !text.isEmpty { assistantMsg["content"] = text }
                    if !toolCalls.isEmpty { assistantMsg["tool_calls"] = toolCalls }
                    result.append(assistantMsg)
                }
            }
        }

        return result
    }

    // MARK: - System prompt

    /// Shared instruction block (Anthropic `system` vs OpenAI first `system` message).
    static func latticeSystemPrompt(for context: ChatContext) -> String {
        var prompt = """
        You are Lattice, an autonomous Apple platform coding agent. You have bash, \
        file read, and file write tools.

        Use xcodebuildmcp for all Xcode build, launch, and UI automation operations. \
        Never use raw xcodebuild, xcrun, or simctl directly.

        WORKFLOW:
        1. Discover the project: xcodebuildmcp macos discover-projects --directory <dir>
        2. List schemes: xcodebuildmcp macos list-schemes --project-path <path>
        3. Implement changes using read_file and write_file
        4. Build: choose destination using ACTIVE CONTEXT. Use simulator/device/mac destination flags that match the selected run target.
        5. On build errors: fix and rebuild. Never skip a red build.

        RULES:
        - Read source files before editing to understand current state.
        - Keep changes minimal and surgical.
        - After writing code, always build to verify.
        - When an error occurs, you get ONE attempt to fix it. If it fails again, escalate to the user.
        - Never default to a simulator when a device or My Mac destination is provided in ACTIVE CONTEXT.
        - Reply in plain text only. Do not use markdown syntax at all.
        - Never output markdown symbols for formatting, including: *, #, _, `, >, -, or numbered list prefixes.
        - Write short compact paragraphs with minimal whitespace.
        - For apps created from Lattice’s “New project” flow, bundle identifiers follow com.lattice.<lowercased product slug> unless the user or Xcode project already specifies a different bundle ID. Prefer that pattern when you invent or adjust bundle IDs for those projects.

        SWIFTUI AND NATIVE UI (follow Human Interface Guidelines):
        - Prefer standard SwiftUI containers and controls: NavigationStack or NavigationSplitView, Form, List, Section, toolbar items, Menu, Button(role:), Toggle, LabeledContent, GroupBox.
        - Prefer semantic styles over fixed styling: Font.body / title / headline; foregroundStyle(.primary) and .secondary; default padding; reserve explicit point sizes only for icons or tight toolbars.
        - Use SF Symbols with hierarchical or palette rendering where appropriate; avoid custom emoji-styled icons for system actions.
        - Use Color.accentColor and system semantic colors; do not hard-code blues/grays that fight system appearance or Dark Mode.
        - Use materials (ultraThinMaterial, etc.) sparingly—one layer or Apple-standard patterns—not stacked full-window blur-on-blur.
        - Support Dynamic Type: avoid clipping text; prefer multiline titles where needed.
        - When generating new screens, default to unadorned layouts that read as system UI before adding decoration.
        """

        if let prefix = context.messagePrefix {
            prompt += "\n\nACTIVE CONTEXT:\n\(prefix)"
        }

        if let info = context.buildInfo {
            prompt += """

            KNOWN BUILD CONFIG (skip discovery):
            - Project path: \(info.projectPath)
            - Scheme: \(info.schemeName)
            \(info.simulatorID.map { "- Simulator ID: \($0)" } ?? "")
            Go directly to build.
            """
        }

        return prompt
    }

    /// Rough token cost for Lattice instructions (system) plus tool schemas (what each API call carries besides `messages`).
    static func approximateLatticeInstructionPayloadTokens(context: ChatContext) -> (system: Int, tools: Int) {
        let sys = latticeSystemPrompt(for: context)
        let systemTokens = LatticeContextEstimator.approximateTokensFromText(sys)
        let toolBytes = (try? JSONSerialization.data(withJSONObject: latticeToolDefinitions))?.count ?? 0
        let toolsTokens = max(80, (toolBytes * 11) >> 2)
        return (systemTokens, toolsTokens)
    }

    private func systemPrompt(context: ChatContext) -> String {
        Self.latticeSystemPrompt(for: context)
    }

    // MARK: - Helpers

    private func parseAnthropicError(_ data: Data) -> String? {
        struct E: Decodable { struct D: Decodable { let message: String }; let error: D }
        return try? JSONDecoder().decode(E.self, from: data).error.message
    }

    func complete(
        prompt: String,
        apiKey: String,
        model: String,
        provider: LLMProvider,
        zaiUseCodingEndpoint: Bool = true,
        maxOutputTokens: Int = 512
    ) async throws -> String {
        let cap = min(8192, max(64, maxOutputTokens))
        switch provider {
        case .anthropic:
            return try await completeAnthropic(prompt: prompt, apiKey: apiKey, model: model, maxTokens: cap)
        case .openAI, .zai:
            return try await completeOpenAI(
                prompt: prompt,
                apiKey: apiKey,
                model: model,
                provider: provider,
                zaiUseCodingEndpoint: zaiUseCodingEndpoint,
                maxTokens: cap
            )
        }
    }

    private func completeAnthropic(prompt: String, apiKey: String, model: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: LLMProvider.anthropic.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.apiError(parseAnthropicError(data) ?? "HTTP \(http.statusCode)")
        }

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.content.first(where: { $0.type == "text" })?.text ?? ""
    }

    private func completeOpenAI(
        prompt: String,
        apiKey: String,
        model: String,
        provider: LLMProvider,
        zaiUseCodingEndpoint: Bool,
        maxTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: openAIChatCompletionsURL(provider: provider, zaiUseCodingEndpoint: zaiUseCodingEndpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [["role": "user", "content": prompt]]
        ]
        let m = model.lowercased()
        if provider == .openAI, m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.apiError(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.choices.first?.message?.content ?? ""
    }
}
