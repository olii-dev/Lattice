# ChatViewModel

`ChatViewModel` is the brain of the application. It owns all conversation state, drives the agentic loop, manages tool execution, and handles message queuing. It is declared `@MainActor final class` and conforms to `ObservableObject`.

## Published properties

| Property | Type | Purpose |
|----------|------|---------|
| `items` | `[ChatItem]` | The chat transcript rendered in the message list |
| `isRunning` | `Bool` | True while the agent task is active; gates UI buttons |
| `changeCount` | `Int` | Incremented on every mutation to trigger auto-scroll |

## Private state

| Property | Type | Purpose |
|----------|------|---------|
| `conversationHistory` | `[[String: Any]]` | Anthropic-format message array sent with each API call |
| `agentTask` | `Task<Void, Never>?` | The current running task; cancellable via `stop()` |
| `messageQueue` | `[QueuedMessage]` | Buffer for messages sent while the agent is busy |
| `service` | `AnthropicService` | API client (one instance per ViewModel) |
| `executor` | `ToolExecutor` | Tool runner (one instance per ViewModel) |
| `buildInfo` | `BuildInfo?` | Cached build configuration from last successful build |

---

## send(text:apiKey:context:showUserBubble:)

The entry point for all user-initiated messages, including hidden "Build & Run" messages.

1. Optionally appends a `ChatItem.user` bubble (skipped for build prompts)
2. Appends to `conversationHistory` with context injection via `contextualizedMessage()`
3. If `isRunning`, stores in `messageQueue` and returns — the running loop will pick it up
4. If idle, sets `isRunning = true`, creates `agentTask`, calls `agenticLoop()`

---

## agenticLoop(apiKey:context:)

The core async loop. Runs until Claude stops requesting tools and there are no queued messages.

```
loop:
  1. stream() → process chunks
  2. if stop_reason != "tool_use":
       a. check messageQueue
       b. if queued → inject latest, continue loop
       c. if empty  → break
  3. execute tools
  4. append tool_results to conversationHistory
  5. goto loop
```

### Step 1 — Streaming

For each `StreamChunk`:

| Chunk | Action |
|-------|--------|
| `.textDelta(text)` | If last item is a streaming assistant message, `appendText(text)`. Otherwise create a new `ChatItem.assistant("", isStreaming: true)` then append. |
| `.toolCallAnnounced(index, id, name)` | Create `ChatItem.tool(name:..., isRunning: true)`. Store `(index → itemIndex)` in a local map so the result can be matched back later. |
| `.done(stopReason, blocks)` | Finalize any open assistant message. For each block with `type == "tool_use"`, call `setToolInput` on the corresponding ToolCard to display the pretty-printed input JSON. Store `stopReason` for the next decision. |

### Step 2 — Queue check

When `stopReason != "tool_use"`, the agent has finished its current turn. `takeLatestQueuedMessage()` is called:

- Clears the entire queue
- Returns the last entry
- Any skipped intermediate messages are marked "Skipped because a newer message arrived"

If a queued message exists, it is appended to `conversationHistory` and the loop continues. This lets the user interrupt the agent mid-task.

### Step 3 — Tool execution

Tool calls are extracted from `finishedBlocks`, sorted by SSE index (preserving order), then executed sequentially:

```swift
for (index, block) in sortedBlocks where block.type == "tool_use" {
    let (output, isError) = await executor.execute(
        name: block.toolName ?? "",
        input: block.parsedInput ?? [:]
    )
    // update ToolCard
    // check for cancellation → rollback conversationHistory if cancelled
    // append to toolResults array
}
```

After all tools run, a single `"user"` message is appended to `conversationHistory` containing all `tool_result` blocks:

```json
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "...", "content": "...", "is_error": false },
    ...
  ]
}
```

### Cancellation handling

At two points inside the tool-execution loop, the code checks `Task.isCancelled`. If cancelled mid-loop:
- The in-progress tool's `tool_result` is not appended to history
- The partial `conversationHistory` additions from the current turn are rolled back to their pre-turn state
- The function returns via `CancellationError` (caught silently in the outer do-catch)

### Error handling

```swift
do {
    try await agenticLoop(...)
} catch is CancellationError {
    // silent — user hit Stop
} catch {
    items.append(ChatItem(kind: .assistant("Error: \(error)", isStreaming: false)))
}
isRunning = false
```

---

## stop()

```swift
func stop() {
    agentTask?.cancel()
    agentTask = nil
    messageQueue.removeAll()
    isRunning = false
}
```

Cancels the task immediately. `ToolExecutor` terminates any running process via `withTaskCancellationHandler`.

---

## clear()

Wipes `items` and `conversationHistory`. Also clears `buildInfo` if the project path was changed (handled in ContentView via `onChange`).

---

## contextualizedMessage(text:context:)

Builds the string appended to `conversationHistory` as the user's message. If `context.messagePrefix` is non-nil, it is prepended:

```
[Selected iOS Simulator]
iPhone 16 (iOS 18)

[Selected Project Path]
/Users/hayden/Projects/MyApp

[Known Build Configuration]
Scheme: MyApp | Path: /Users/.../MyApp.xcodeproj | Simulator: <UDID>

[User Message]
Add a settings screen
```

If there is no context (no simulator, no project path, no build info), only the raw text is sent.

---

## takeLatestQueuedMessage()

```swift
private func takeLatestQueuedMessage() -> QueuedMessage? {
    guard !messageQueue.isEmpty else { return nil }
    let latest = messageQueue.last
    messageQueue.removeAll()
    return latest
}
```

Deliberately discards all queued messages except the last. The design assumption is that the user's most recent message supersedes all earlier ones sent during the same agent turn.

---

# SimulatorStore

`@MainActor final class SimulatorStore: ObservableObject` handles iOS simulator discovery. It is separate from `ChatViewModel` because its lifecycle is tied to the Settings panel, not the conversation.

## Published properties

| Property | Type | Purpose |
|----------|------|---------|
| `simulators` | `[SimulatorOption]` | List rendered in the simulator picker |
| `isLoading` | `Bool` | Shows a spinner in the settings panel |
| `loadError` | `String?` | Shown below the picker on failure |

## refresh()

Spawns `/usr/bin/xcrun simctl list devices available -j` and parses the JSON output:

```json
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
      { "name": "iPhone 16", "udid": "...", "isAvailable": true }
    ]
  }
}
```

Runtime keys are transformed: `com.apple.CoreSimulator.SimRuntime.iOS-18-0` → `iOS 18 0` → `iOS 18`. Results are sorted by runtime descending, then name ascending.

Called once on app launch via `.task { simulatorStore.refresh() }`, and again whenever the user taps the refresh button in the settings panel.
