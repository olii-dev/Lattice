# AnthropicService

`AnthropicService` is the API client responsible for all communication with Anthropic. It lives in `AnthropicService.swift` and is instantiated once inside `ChatViewModel`.

## Endpoint

```
POST https://api.anthropic.com/v1/messages
```

## Request headers

| Header | Value |
|--------|-------|
| `x-api-key` | User's API key from settings |
| `Content-Type` | `application/json` |
| `anthropic-version` | `2023-06-01` |

## Request body

```json
{
  "model": "<selected model ID>",
  "max_tokens": 10000,
  "stream": true,
  "system": "<system prompt>",
  "tools": [...],
  "messages": [...]
}
```

The `messages` array is the full `conversationHistory` accumulated in `ChatViewModel`. Nothing is truncated or summarized — the entire session history is sent on every request.

---

## Tool definitions

Three tools are declared in the request body. Claude may call any of them; `ToolExecutor` handles actual execution.

### `bash`

Execute a shell command and return combined stdout + stderr.

```json
{
  "name": "bash",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "Shell command to execute" }
    },
    "required": ["command"]
  }
}
```

### `read_file`

Read the full text of a file.

```json
{
  "name": "read_file",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Absolute or relative file path" }
    },
    "required": ["path"]
  }
}
```

### `write_file`

Write or overwrite a file, creating intermediate directories as needed.

```json
{
  "name": "write_file",
  "input_schema": {
    "type": "object",
    "properties": {
      "path":    { "type": "string", "description": "Destination file path" },
      "content": { "type": "string", "description": "File content to write" }
    },
    "required": ["path", "content"]
  }
}
```

---

## System prompt

The system prompt is a detailed, multi-phase instruction set embedded in each request. It does not come from the user; it is hardcoded in `AnthropicService`.

### Phases

| Phase | Name | What Claude does |
|-------|------|-----------------|
| 0 | Setup & CLI verification | Confirm `xcodebuildmcp` and `openspec` are installed |
| 1 | Project discovery | Find `.xcodeproj`/`.xcworkspace`, list schemes |
| 2 | Scaffold (if needed) | Create a new Xcode project if none exists |
| 3 | Implement | Make code changes the user requested |
| 4 | Build | Run `xcodebuildmcp build` with discovered scheme |
| 5 | Launch (macOS) | Run the built macOS app |
| 6 | UI automation (iOS) | Launch on simulator, interact via `xcodebuildmcp` UI APIs |
| 7 | Archive | Record completed changes via `openspec` |

### Context injection override

When `ChatContext.buildInfo` is set, the service prepends a **MANDATORY OVERRIDE** section to the system prompt:

```
MANDATORY OVERRIDE — Skip PHASE 0 and PHASE 1.
Use exactly:
  Scheme:     <schemeName>
  Project:    <projectPath>
  Simulator:  <simulatorID>
```

This forces Claude past discovery directly to PHASE 4, cutting seconds off each subsequent build.

### Error escalation rules

The prompt instructs Claude to:
1. Attempt one autonomous fix per error
2. If the same error appears again after the fix, stop and surface it to the user
3. Never enter infinite retry loops

---

## Streaming (`stream()`)

```swift
func stream(
    messages: [[String: Any]],
    apiKey: String,
    context: ChatContext
) -> AsyncThrowingStream<StreamChunk, Error>
```

Returns an `AsyncThrowingStream` the caller iterates with `for await chunk in service.stream(...)`.

### StreamChunk enum

```swift
enum StreamChunk: Sendable {
    case textDelta(String)
    case toolCallAnnounced(index: Int, id: String, name: String)
    case done(stopReason: String, blocks: [Int: ContentBlock])
}
```

| Case | When yielded | Payload |
|------|-------------|---------|
| `.textDelta` | Each `content_block_delta` SSE event with type `text_delta` | The incremental text |
| `.toolCallAnnounced` | Each `content_block_start` SSE event with type `tool_use` | SSE index, tool ID, tool name |
| `.done` | `message_stop` SSE event | `stop_reason` from `message_delta`, map of all accumulated `ContentBlock`s keyed by SSE index |

### SSE parsing

The stream reads raw bytes from `URLSession.shared.bytes(for:)`, splits on newlines, and filters lines beginning with `data: `. Each line is JSON-decoded. The parser maintains a mutable dictionary `[Int: ContentBlock]` keyed by the SSE `index` field. Events processed:

| SSE event type | Action |
|---------------|--------|
| `content_block_start` | Insert new `ContentBlock` at index; yield `.toolCallAnnounced` if tool_use |
| `content_block_delta` (text_delta) | Append delta to block's `.text`; yield `.textDelta` |
| `content_block_delta` (input_json_delta) | Append JSON fragment to block's `.toolInputJSON` |
| `message_delta` | Capture `stop_reason` |
| `message_stop` | Yield `.done` with stop_reason and blocks map |

---

## Non-streaming completion (`complete()`)

```swift
func complete(
    prompt: String,
    apiKey: String
) async throws -> String
```

Used for one-shot tasks that don't need streaming — specifically the post-build extraction prompt that asks Claude to return a JSON object with scheme/path/simulator. `max_tokens` is capped at 512 for this call.

---

## Error handling

| Condition | Behaviour |
|-----------|----------|
| HTTP status != 200 | Throws `StreamError.apiError(message)` with message parsed from response body |
| JSON parse failure on an SSE event | Silently skips the event; stream continues |
| Network error from URLSession | Propagates as thrown error; caught by `agenticLoop` |
