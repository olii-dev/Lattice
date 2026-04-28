# Data Models

## ChatItem (`Item.swift`)

The fundamental unit of the chat interface. Every message, AI response, and tool invocation is represented as a `ChatItem`.

```swift
struct ChatItem: Identifiable {
    let id: UUID
    var kind: Kind
}
```

### Kind enum

```swift
enum Kind {
    case user(String)
    case assistant(String, isStreaming: Bool)
    case tool(name: String, input: String, output: String?, isError: Bool, isRunning: Bool)
}
```

| Case | When created | Key fields |
|------|-------------|-----------|
| `.user` | User submits a message | The message text |
| `.assistant` | Claude starts a text response | Text (grows via streaming); `isStreaming` drives the cursor animation |
| `.tool` | Claude announces a tool call | `name`, `input` JSON preview, `output` (nil until execution completes), `isError`, `isRunning` |

### Mutation helpers

Because `ChatItem` is a value type in an array, mutations go through index-based setters on `ChatViewModel.items`:

| Method | Effect |
|--------|--------|
| `appendText(_:)` | Appends a streaming delta to `.assistant` text |
| `finalizeText()` | Clears `isStreaming = false` on an assistant message |
| `setToolInput(_:)` | Stores the full parsed input JSON and sets `isRunning = true` |
| `setToolResult(_:isError:)` | Stores output, clears `isRunning`, sets `isError` |

---

## ContentBlock (`AnthropicService.swift`)

Internal model used while accumulating an SSE stream. One `ContentBlock` corresponds to one element of the `content` array in the Anthropic response.

```swift
struct ContentBlock {
    let type: String           // "text" or "tool_use"
    var text: String?
    var toolId: String?
    var toolName: String?
    var toolInputJSON: String?
}
```

### Factory constructors

```swift
ContentBlock.text(_ text: String) -> ContentBlock
ContentBlock.toolUse(id: String, name: String) -> ContentBlock
```

### Computed properties

| Property | Returns |
|----------|---------|
| `parsedInput` | `[String: Any]?` — JSON-decoded tool input |
| `toAPIDict()` | `[String: Any]` — format expected by the Anthropic Messages API |

---

## SimulatorOption (`ContentView.swift`)

Represents one entry in the iOS simulator picker.

```swift
struct SimulatorOption: Identifiable, Hashable {
    let id: String      // UDID — used as the stable identifier
    let name: String    // e.g. "iPhone 16"
    let runtime: String // e.g. "iOS 18"
    var label: String { "\(name) (\(runtime))" }
}
```

Populated by `SimulatorStore` from `xcrun simctl list devices available -j`.

---

## BuildInfo (`ContentView.swift`)

Caches the result of the first successful "Build & Run" so subsequent runs skip project-discovery phases.

```swift
struct BuildInfo {
    var schemeName: String
    var projectPath: String
    var simulatorID: String?   // nil for macOS targets
}
```

Stored in `ChatViewModel.buildInfo`. Injected into `ChatContext` and ultimately into the system prompt as a "MANDATORY OVERRIDE" section that instructs Claude to use these values directly.

---

## ChatContext (`ContentView.swift`)

A snapshot of the current configuration settings passed into every `send()` call. It is value-type and `Equatable`, so `onChange` comparisons are cheap.

```swift
struct ChatContext: Equatable {
    let simulator: String?      // label string, for display in prompt
    let projectPath: String?    // absolute path to project folder
    let model: String           // model ID ("claude-opus-4-7", etc.)
    let buildInfo: BuildInfo?   // cached build config, if available
}
```

### `messagePrefix`

Computed property that formats all non-nil fields into a structured context block prepended to the user's message:

```
[Selected iOS Simulator]
iPhone 16 (iOS 18)

[Selected Project Path]
/Users/hayden/Projects/MyApp

[Known Build Configuration]
Scheme: MyApp | Path: /Users/hayden/Projects/MyApp/MyApp.xcodeproj | Simulator: <UDID>

[User Message]
Add a settings screen
```

---

## QueuedMessage (`ContentView.swift`)

Internal struct in `ChatViewModel` that buffers messages received while the agent is running.

```swift
struct QueuedMessage {
    let text: String
    let context: ChatContext
}
```

The queue holds at most a handful of entries; `takeLatestQueuedMessage()` clears the entire queue and returns only the last entry, discarding earlier ones.
