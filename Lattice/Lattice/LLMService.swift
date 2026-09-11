import Foundation
import UniformTypeIdentifiers

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

    var models: [LLMModelOption] {
        switch self {
        case .anthropic: [
            .init(id: "claude-fable-5-1", label: "Claude Fable 5.1", supportsImages: true),
            .init(id: "claude-opus-5", label: "Claude Opus 5", supportsImages: true),
            .init(id: "claude-sonnet-5", label: "Claude Sonnet 5", supportsImages: true),
        ]
        case .openAI: [
            .init(id: "gpt-6-astra", label: "GPT-6 Astra", supportsImages: true),
            .init(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", supportsImages: true),
            .init(id: "gpt-5.6-terra", label: "GPT-5.6 Terra", supportsImages: true),
            .init(id: "gpt-5.6-luna", label: "GPT-5.6 Luna", supportsImages: true),
        ]
        case .zai: [
            .init(id: "glm-5.3-flash", label: "GLM-5.3 Flash", supportsImages: true),
            .init(id: "glm-5.3", label: "GLM-5.3", supportsImages: false),
            .init(id: "glm-5.2", label: "GLM-5.2", supportsImages: false),
        ]
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5"
        case .openAI: "gpt-5.6-terra"
        case .zai: "glm-5.3-flash"
        }
    }

    var endpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .zai: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!
        }
    }
}

struct LLMModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let supportsImages: Bool
}

/// Resets the stored model selection when it no longer exists in the provider's
/// catalog (e.g. after pruning pre-2026 models). Unknown provider ids (custom
/// providers) are left alone.
enum LLMModelSelectionMigration {
    static func migrateStoredSelection(defaults: UserDefaults = .standard) {
        guard let provider = LLMProvider(
            rawValue: defaults.string(forKey: "selectedProvider") ?? "anthropic"
        ) else { return }
        let stored = defaults.string(forKey: "selectedModel") ?? ""
        guard !provider.models.contains(where: { $0.id == stored }) else { return }
        defaults.set(provider.defaultModel, forKey: "selectedModel")
    }
}

// MARK: - Unified streaming service

struct LLMService {
    private static let providerOverloadMaxAttempts = 4
    private static let providerOverloadRetryDelayNanoseconds: UInt64 = 15 * 1_000_000_000

    /// HTTP statuses transient enough to warrant an automatic retry.
    /// 529 = Anthropic "overloaded_error", 408 = request timeout, 429 = rate limited.
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504, 529]

    /// Network-layer failures worth retrying (mid-stream drops, dead connections).
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
    ]

    static func shouldRetryAfterTransientProviderFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }
        // Fall back to body-text markers only inside provider error payloads —
        // never against arbitrary error descriptions, where substrings like
        // "1305" or "1234" can match unrelated content.
        guard let e = error as? StreamError, case .apiError(let raw, let statusCode) = e else {
            return false
        }
        // A concrete status decides on its own; body markers only matter when no
        // usable HTTP status was captured.
        if let statusCode {
            return retryableStatusCodes.contains(statusCode)
        }
        let t = raw.lowercased()
        if t.contains("1305") { return true }
        if t.contains("1234") { return true }
        if t.contains("overloaded") { return true }
        if t.contains("temporarily overloaded") { return true }
        if t.contains("internal network failure") { return true }
        if t.contains("rate_limit") || t.contains("rate limit") { return true }
        return false
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
        ],
        [
            "name": "web_search",
            "description": "Search the public web for current information and return a ranked list of results with titles, domains, URLs, and snippets.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to search for on the web."],
                    "max_results": ["type": "integer", "description": "How many search results to return. Default 5, maximum 8."],
                    "preferred_domains": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Domains to rank higher when relevant, such as developer.apple.com or openai.com."
                    ],
                    "restrict_to_domains": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "If provided, search only within these domains."
                    ]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "fetch_webpage",
            "description": "Fetch a webpage by URL and return cleaned plain-text content plus lightweight metadata for reading docs or articles.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The http or https URL to fetch."],
                    "max_characters": ["type": "integer", "description": "Maximum number of characters to return. Default 12000, maximum 20000."]
                ],
                "required": ["url"]
            ]
        ],
        [
            "name": "add_capability",
            "description": "Add an Apple capability to the current project. Updates entitlements, Info.plist, and project build settings correctly and idempotently. Always use this instead of hand-editing entitlements or project.pbxproj for capabilities.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "enum": ["app_groups", "push_notifications", "storekit", "keychain_sharing", "background_modes"],
                        "description": "The capability to add."
                    ],
                    "parameters": [
                        "type": "object",
                        "description": "Capability-specific values. app_groups: AppGroupIdentifier (array of group ids, e.g. [\"group.com.example.app\"]). push_notifications: APSEnvironment ('development' or 'production'). background_modes: UIBackgroundModes (array, e.g. ['audio','remote-notification']). keychain_sharing: KeychainAccessGroup (string). storekit: none. swiftdata: none. cloudkit_sync: iCloudContainerIdentifiers (optional array of container ids; omit for the default container). healthkit: HealthShareUsageDescription + HealthUpdateUsageDescription (plain-language strings required by the App Store). app_intents: SiriUsageDescription (string). widgets: none.",
                        "properties": [:]
                    ]
                ],
                "required": ["capability"]
            ]
        ],
        [
            "name": "remove_capability",
            "description": "Remove an Apple capability from the current project. Strips the capability's entitlement and Info.plist keys safely without affecting other capabilities.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "enum": ["app_groups", "push_notifications", "storekit", "keychain_sharing", "background_modes"],
                        "description": "The capability to remove."
                    ]
                ],
                "required": ["capability"]
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
        if let custom = context.customProvider {
            switch custom.protocolKind {
            case .anthropicCompatible:
                return streamAnthropic(
                    messages: messages, apiKey: apiKey, context: context,
                    endpointURLOverride: custom.chatEndpointURL()
                )
            case .openAICompatible:
                return streamOpenAI(
                    messages: messages, apiKey: apiKey, context: context,
                    provider: .openAI, baseURLOverride: custom.chatEndpointURL()
                )
            }
        }
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
        context: ChatContext,
        endpointURLOverride: URL? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for attempt in 1...Self.providerOverloadMaxAttempts {
                    do {
                    var request = URLRequest(url: endpointURLOverride ?? LLMProvider.anthropic.endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 240
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if context.claudeSubscriptionAuth {
                        // Subscription OAuth (claude setup-token / Pro or Max login).
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                    } else if !apiKey.isEmpty {
                        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
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
                        "messages": convertToAnthropicMessages(messages)
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let msg = parseAnthropicError(data) ?? "HTTP \(http.statusCode)"
                        throw StreamError.apiError(message: msg, statusCode: http.statusCode)
                    }

                    var blocks: [Int: ContentBlock] = [:]
                    var stopReason = "end_turn"
                    var usage = LLMTokenUsage(inputTokens: nil, outputTokens: nil)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(SSEEvent.self, from: data)
                        else { continue }

                        switch event.type {
                        case "message_start":
                            if let inputTokens = event.message?.usage?.input_tokens {
                                usage.inputTokens = inputTokens
                            }
                        case "message_delta":
                            if let r = event.delta?.stop_reason { stopReason = r }
                            if let outputTokens = event.usage?.output_tokens {
                                usage.outputTokens = outputTokens
                            }
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

                        default: break
                        }
                    }

                    continuation.yield(.done(
                        stopReason: stopReason,
                        blocks: blocks,
                        usage: (usage.inputTokens != nil || usage.outputTokens != nil) ? usage : nil
                    ))
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
        if m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
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
        provider: LLMProvider,
        baseURLOverride: URL? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for attempt in 1...Self.providerOverloadMaxAttempts {
                    do {
                    var request = URLRequest(
                        url: baseURLOverride ?? openAIChatCompletionsURL(provider: provider, context: context)
                    )
                    request.httpMethod = "POST"
                    request.timeoutInterval = 240
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let openAIMessages = convertToOpenAIMessages(messages, context: context)
                    var body: [String: Any] = [
                        "model": context.model,
                        "stream": true,
                        "stream_options": ["include_usage": true],
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
                        throw StreamError.apiError(message: msg, statusCode: http.statusCode)
                    }

                    var blocks: [Int: ContentBlock] = [:]
                    var toolCallIndex = 0
                    var stopReason = "end_turn"
                    var usage = LLMTokenUsage(inputTokens: nil, outputTokens: nil)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }
                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Usage arrives in a final chunk with empty choices; capture before
                        // the choices guard so that chunk isn't skipped.
                        if let usagePayload = chunk["usage"] as? [String: Any] {
                            if let input = usagePayload["prompt_tokens"] as? Int { usage.inputTokens = input }
                            if let output = usagePayload["completion_tokens"] as? Int { usage.outputTokens = output }
                        }

                        guard let choices = chunk["choices"] as? [[String: Any]],
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

                    continuation.yield(.done(
                        stopReason: stopReason,
                        blocks: blocks,
                        usage: (usage.inputTokens != nil || usage.outputTokens != nil) ? usage : nil
                    ))
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
                    var toolResults: [[String: Any]] = []
                    var contentBlocks: [[String: Any]] = []

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
                            contentBlocks.append([
                                "type": "text",
                                "text": block["text"] as? String ?? ""
                            ])
                        } else if type == "local_image",
                                  let imageBlock = openAIImageContentBlock(from: block) {
                            contentBlocks.append(imageBlock)
                        }
                    }

                    for tr in toolResults { result.append(tr) }
                    if contentBlocks.count == 1,
                       let onlyBlock = contentBlocks.first,
                       onlyBlock["type"] as? String == "text" {
                        result.append(["role": "user", "content": onlyBlock["text"] as? String ?? ""])
                    } else if !contentBlocks.isEmpty {
                        result.append(["role": "user", "content": contentBlocks])
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

                    guard !text.isEmpty || !toolCalls.isEmpty else { continue }
                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    if !text.isEmpty {
                        assistantMsg["content"] = text
                    } else if !toolCalls.isEmpty {
                        assistantMsg["content"] = NSNull()
                    }
                    if !toolCalls.isEmpty { assistantMsg["tool_calls"] = toolCalls }
                    result.append(assistantMsg)
                }
            }
        }

        return result
    }

    private func convertToAnthropicMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }

            if let content = msg["content"] as? String {
                result.append(["role": role, "content": content])
                continue
            }

            guard let content = msg["content"] as? [[String: Any]] else { continue }
            var convertedBlocks: [[String: Any]] = []

            for block in content {
                let type = block["type"] as? String ?? ""
                switch type {
                case "text":
                    convertedBlocks.append([
                        "type": "text",
                        "text": block["text"] as? String ?? ""
                    ])
                case "tool_use":
                    convertedBlocks.append(block)
                case "tool_result":
                    convertedBlocks.append(block)
                case "local_image":
                    if let imageBlock = anthropicImageContentBlock(from: block) {
                        convertedBlocks.append(imageBlock)
                    }
                default:
                    continue
                }
            }

            if !convertedBlocks.isEmpty {
                result.append(["role": role, "content": convertedBlocks])
            }
        }

        return result
    }

    private func openAIImageContentBlock(from block: [String: Any]) -> [String: Any]? {
        guard let payload = encodedImagePayload(from: block) else { return nil }
        return [
            "type": "image_url",
            "image_url": [
                "url": "data:\(payload.mimeType);base64,\(payload.base64)"
            ]
        ]
    }

    private func anthropicImageContentBlock(from block: [String: Any]) -> [String: Any]? {
        guard let payload = encodedImagePayload(from: block) else { return nil }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": payload.mimeType,
                "data": payload.base64
            ]
        ]
    }

    private func encodedImagePayload(from block: [String: Any]) -> (mimeType: String, base64: String)? {
        guard let path = block["path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let explicitMime = (block["mime_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredMime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let mimeType = explicitMime?.isEmpty == false
            ? explicitMime!
            : (inferredMime ?? "image/png")

        return (mimeType, data.base64EncodedString())
    }

    // MARK: - System prompt

    /// Shared instruction block (Anthropic `system` vs OpenAI first `system` message).
    static func latticeSystemPrompt(for context: ChatContext) -> String {
        var prompt = """
        You are Lattice, an autonomous Apple platform coding agent. You have bash, \
        file read, file write, web search, and webpage fetch tools.

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
        - Use web_search when the user asks for current information, API updates, documentation, or anything likely to have changed recently.
        - When searching for technical guidance or APIs, pass preferred_domains or restrict_to_domains so official documentation and primary sources are prioritised.
        - If a result snippet is not enough, use fetch_webpage on the most relevant result to read the source before acting on it.
        - For technical questions, compare the query against at least one primary source when possible instead of trusting a generic snippet.
        - Never default to a simulator when a device or My Mac destination is provided in ACTIVE CONTEXT.
        - Reply in plain text only. Do not use markdown syntax at all.
        - Never output markdown symbols for formatting, including: *, #, _, `, >, -, or numbered list prefixes.
        - Write short compact paragraphs with minimal whitespace.
        - For apps created from Lattice’s “New project” flow, bundle identifiers follow com.lattice.<lowercased product slug> unless the user or Xcode project already specifies a different bundle ID. Prefer that pattern when you invent or adjust bundle IDs for those projects.
        - Always keep track of the active bundle identifier from ACTIVE CONTEXT. If you create a new app target, adjust project identity, or touch signing-related files, preserve that bundle identifier unless the user explicitly asks to change it.
        - When the user asks for an Apple capability, use the add_capability tool. Supported capabilities: app_groups, push_notifications, storekit, keychain_sharing, background_modes, swiftdata, cloudkit_sync, healthkit, app_intents, widgets. The tool handles entitlements, Info.plist keys, seed files, extension targets, and project build settings correctly and idempotently.
        - Never hand-write or hand-edit .entitlements files or entitlement-related project.pbxproj entries. Always use add_capability / remove_capability instead.
        - swiftdata adds a starter @Model file (SampleData.swift). When it is active, persist user data with SwiftData: define @Model classes, attach .modelContainer(...) to the App or root view, and use @Query in views instead of inventing custom JSON/file storage.
        - cloudkit_sync enables the iCloud (CloudKit) entitlements. When the user wants synced data, pair it with SwiftData using ModelConfiguration with cloudKitDatabase: .private(...) or .automatic, and tell the user iCloud provisioning steps from the tool's manual steps.
        - healthkit requires HealthShareUsageDescription and HealthUpdateUsageDescription parameters — write clear, specific plain-language strings based on what the app actually does with health data. When active, gate all HKHealthStore usage behind HKHealthStore.isHealthDataAvailable() and request authorization per data type.
        - app_intents adds a starter AppIntents file (SampleIntents.swift). When active, define real AppIntents for the app's core actions so they appear in Siri, Shortcuts, and Spotlight.
        - widgets scaffolds a WidgetKit extension target with a starter widget bundle. When active, customize the widget views and timelines in the Widgets folder instead of creating new targets by hand, and share app data with widgets via App Groups (add the app_groups capability when needed).
        - For capabilities outside the supported list (Widgets, Live Activities, Associated Domains, etc.), use the web_search tool to find the correct entitlement and plist keys, then explain to the user what manual steps are needed. Do not hand-write entitlements for unsupported capabilities.
        - After add_capability returns manual steps, relay them to the user verbatim so they can complete provisioning in the Apple Developer Portal or Xcode.
        - If a valid Xcode project already exists, edit that project in place. Do not invent a second app scaffold or hand-roll a fresh project structure beside it.
        - Do not hand-write or replace project.pbxproj just to scaffold a new app when a Lattice template project already exists. Prefer editing the source files, plist, entitlements, and asset catalog inside the existing project.
        - Default to the current Apple OS generation for the active platform unless the user explicitly asks for older compatibility:
          iPhone/iPad work uses iOS 26, watch work uses watchOS 26, and Mac work uses macOS 26.
        - If ACTIVE CONTEXT, the selected run target, or the existing project clearly indicates a platform, follow that platform and keep generated code aligned to its OS 26 APIs and conventions.
        - Do not quietly fall back to older deployment targets like iOS 17/18, watchOS 10/11, or macOS 14/15 unless the user explicitly asks for them.
        - Use modern Swift and modern platform APIs. Avoid old UIKit/AppKit lifecycle patterns, SceneDelegate/AppDelegate boilerplate, deprecated navigation APIs, or legacy code structure unless the user explicitly asks for that.

        SWIFTUI AND NATIVE UI (follow Human Interface Guidelines):
        - Prefer standard SwiftUI containers and controls: NavigationStack or NavigationSplitView, Form, List, Section, toolbar items, Menu, Button(role:), Toggle, LabeledContent, GroupBox.
        - Prefer semantic styles over fixed styling: Font.body / title / headline; foregroundStyle(.primary) and .secondary; default padding; reserve explicit point sizes only for icons or tight toolbars.
        - Use SF Symbols with hierarchical or palette rendering where appropriate; avoid custom emoji-styled icons for system actions.
        - Use Color.accentColor and system semantic colors; do not hard-code blues/grays that fight system appearance or Dark Mode.
        - Use materials (ultraThinMaterial, etc.) sparingly and correctly. Liquid Glass and similar materials belong primarily in controls and navigation chrome, not as a blanket content background or stacked blur-on-blur effect.
        - Support Dynamic Type: avoid clipping text; prefer multiline titles where needed.
        - Respect Apple layout guidance: clear visual hierarchy, strong alignment, readable spacing, and controls that sit above content instead of competing with it.
        - Prefer layouts that feel immediately Apple-native before adding any decoration.
        - Default to building complete native app flows, not isolated demo screens.
        - When you create a new feature, include the surrounding product structure it needs to feel real: navigation, screen titles, toolbar actions, settings entry points, previews or sample data, and sensible empty/loading/error states.
        - For iPhone apps, strongly prefer polished Apple-style patterns such as TabView for top-level destinations, NavigationStack for drill-in flows, Forms for settings and data entry, Lists/Sections for structured content, and sheets for focused subflows.
        - Favor simple, durable app architecture over novelty: stable models, clear state ownership, reusable small views, and local sample content when backend/data work is not yet defined.
        - First drafts should feel like usable app starts with multiple coherent surfaces, not a single placeholder screen.
        - Aim for a premium native result, not just a technically working scaffold: strong spacing rhythm, clear hierarchy, calm color usage, good empty states, thoughtful onboarding when relevant, and polished first-run sample content.
        - Generated apps should feel designed for the App Store, with coherent navigation and visually intentional screens rather than placeholder stacks of controls.
        - Pick a clear visual direction for each app and carry it consistently across screens: typography hierarchy, spacing scale, surface treatment, icon style, and accent usage should feel intentional and related.
        - Avoid bland scaffolding UI. Do not ship screens that are just default VStack piles, plain forms with no hierarchy, oversized rounded rectangles everywhere, or generic cards repeated without structure.
        - For dashboards and home screens, create focal areas, grouped sections, strong section hierarchy, and one obvious primary area instead of flat repeated tiles.
        - Prefer polished native composition over over-styling: excellent layout, hierarchy, spacing, information architecture, and motion matter more than adding extra decoration.
        - Think in Apple-standard screen anatomy: clear title area, purposeful toolbar actions, strong primary content region, appropriate secondary sections, and breathing room around grouped content.
        - Use fewer, better surfaces. Avoid filling every screen with cards, outlines, tinted backgrounds, shadows, and capsules at the same time.
        - Navigation must feel native. Use a small number of stable top-level destinations, clear nouns for tabs, and predictable drill-in flows.
        - Settings, creation flows, and detail screens should usually feel closer to Apple apps like Settings, Reminders, Notes, Fitness, or Journal than to a generic startup dashboard.
        - Lists and forms should communicate hierarchy through sectioning, labels, spacing, alignment, and accessories, not through excessive custom decoration.
        - Use accent color intentionally and sparingly. Important actions, selection state, and a few focal highlights should carry the accent; the whole interface should not be tinted.
        - Prefer system spacing and grouping that makes scanning easy. Avoid cramped controls, edge-to-edge clutter, and giant empty areas with weak hierarchy.
        - Use motion and transitions in a restrained native way. Avoid gimmicky animations; prefer subtle state changes, sheets, navigation transitions, and polished progressive disclosure.
        - When a screen needs emphasis, create it through information hierarchy, spacing, and one premium focal component rather than by styling every element loudly.
        - Default to an Apple-standard quality bar: if a generated screen would look obviously below the design level of a modern first-party Apple app, refine it before finishing.
        - Use modern SwiftUI state and data flow. Prefer @State, @Binding, @Observable, environment values, and small reusable views over massive single-file views, global mutable state, or legacy ObservableObject boilerplate unless the project already uses it consistently.
        - Before finalizing UI work, explicitly self-check for these anti-patterns and revise the result if any are true:
          too many cards
          weak hierarchy
          generic dashboard
          flat spacing
          over-tinted UI
          settings screen disguised as a home screen
        - Before finalizing any new app or feature UI, self-check:
          Does the information hierarchy read clearly at a glance?
          Does the navigation structure feel native and stable?
          Does the interface use system patterns instead of ad hoc custom widgets?
          Is the accent/material usage restrained and intentional?
          Would this look like a credible App Store-ready first draft instead of a prototype?

        DELIVERY BAR FOR NEW APPS:
        - If the user asks for a new app, the default expectation is a real first build pass, not just a plan, shell, or placeholder.
        - In the first meaningful implementation turn, aim to leave the project with a working multi-screen v1 that feels coherent and usable.
        - Make reasonable product decisions yourself when the user has not specified every detail. Do not stop to ask broad exploratory questions if you can infer a sensible answer.
        - Do not spend the whole turn listing file structures, restating requirements, or describing what you are about to do. Build the app.
        - A good first pass usually includes real top-level navigation, at least a few meaningful screens, sample data, empty states, loading/error treatment where needed, and one clear primary surface that matches the product idea.
        - If backend or API details are unspecified, prefer a polished local-first implementation with believable sample content over a half-wired shell waiting on future services.
        - If the request is broad, favor completeness and product cohesion over perfection. A smaller but finished app is better than a larger but half-baked one.

        RESPONSE STYLE:
        - Be concise and product-builder oriented, not chatty.
        - Visible user-facing prose should read like a short director update, not a running agent log.
        - Lead with the outcome in one plain sentence, then use one or two short readable paragraphs at most.
        - Prefer calm editorial phrasing over exhaustive inventories.
        - Summarize what matters to the user; do not narrate every micro-step you took.
        - Keep tool chatter, implementation detail, and repetitive self-narration out of the main answer body.
        - If you need user input, ask only for the specific blocking decision.
        - End every completed reply with this exact plain-text footer block so the app can render it separately:
          Director summary:
          Built: <short sentence or omit if not relevant>
          Changed: <short sentence or omit if not relevant>
          Needs your input: <short sentence or omit if not relevant>
          App name: <current app name or omit if unknown>
          App concept: <one short product sentence or omit if unknown>
          App surfaces: <comma-separated list of core screens/surfaces or omit if unknown>
          App navigation: <short phrase describing the current navigation structure or omit if unknown>
          Design direction: <short phrase describing the app's visual/product direction or omit if unknown>
          Open issues: <comma-separated list of unresolved product or build issues or omit if none>
          Phase: <Idea|Plan|Build|Verify|Polish>
        - Omit any footer line whose value would be empty.
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
        maxOutputTokens: Int = 512,
        customProvider: CustomProvider? = nil,
        claudeSubscriptionAuth: Bool = false
    ) async throws -> String {
        let cap = min(8192, max(64, maxOutputTokens))
        if let custom = customProvider {
            switch custom.protocolKind {
            case .anthropicCompatible:
                return try await completeAnthropic(
                    prompt: prompt, apiKey: apiKey, model: model, maxTokens: cap,
                    endpointURLOverride: custom.chatEndpointURL()
                )
            case .openAICompatible:
                return try await completeOpenAI(
                    prompt: prompt, apiKey: apiKey, model: model,
                    provider: .openAI, zaiUseCodingEndpoint: zaiUseCodingEndpoint, maxTokens: cap,
                    baseURLOverride: custom.chatEndpointURL()
                )
            }
        }
        switch provider {
        case .anthropic:
            return try await completeAnthropic(
                prompt: prompt, apiKey: apiKey, model: model, maxTokens: cap,
                claudeSubscriptionAuth: claudeSubscriptionAuth
            )
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

    private func completeAnthropic(
        prompt: String,
        apiKey: String,
        model: String,
        maxTokens: Int,
        endpointURLOverride: URL? = nil,
        claudeSubscriptionAuth: Bool = false
    ) async throws -> String {
        var request = URLRequest(url: endpointURLOverride ?? LLMProvider.anthropic.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if claudeSubscriptionAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.apiError(
                message: parseAnthropicError(data) ?? "HTTP \(http.statusCode)",
                statusCode: http.statusCode
            )
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
        maxTokens: Int,
        baseURLOverride: URL? = nil
    ) async throws -> String {
        var request = URLRequest(
            url: baseURLOverride ?? openAIChatCompletionsURL(provider: provider, zaiUseCodingEndpoint: zaiUseCodingEndpoint)
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [["role": "user", "content": prompt]]
        ]
        let m = model.lowercased()
        if provider == .openAI, m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.apiError(
                message: String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)",
                statusCode: http.statusCode
            )
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
