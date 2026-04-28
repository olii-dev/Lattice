# State Management & Concurrency

## State ownership

| State | Owner | Persistence |
|-------|-------|------------|
| Chat transcript (`items`) | `ChatViewModel` | Session only |
| Conversation history | `ChatViewModel` | Session only |
| Running task | `ChatViewModel` | Session only |
| Build config cache | `ChatViewModel` | Session only |
| Message queue | `ChatViewModel` | Session only |
| API key | `@AppStorage` | UserDefaults |
| Model selection | `@AppStorage` | UserDefaults |
| Simulator ID | `@AppStorage` | UserDefaults |
| Project path | `@AppStorage` | UserDefaults |
| Simulator list | `SimulatorStore` | Session only |

---

## @MainActor isolation

Both `ChatViewModel` and `SimulatorStore` are marked `@MainActor`. This means:

- All `@Published` mutations happen on the main thread — no DispatchQueue.main.async needed
- SwiftUI observes changes immediately without threading concerns
- Heavy work (network, process execution) is performed inside `Task { }` blocks, which run on the cooperative thread pool, and only write results back through `@MainActor`-isolated properties

---

## Task lifecycle

```swift
// Starting
agentTask = Task {
    do {
        try await agenticLoop(apiKey:context:)
    } catch is CancellationError { }
    catch { /* show error bubble */ }
    isRunning = false
}

// Stopping
agentTask?.cancel()
agentTask = nil
```

`Task` inherits the actor context of its creation site (here, `@MainActor`). The body may suspend and resume on other threads for async operations, but all property accesses go through the main actor.

---

## AsyncThrowingStream

`AnthropicService.stream()` wraps URLSession's async bytes API in an `AsyncThrowingStream`:

```swift
AsyncThrowingStream<StreamChunk, Error> { continuation in
    Task {
        for try await line in urlSession.bytes(for: request).lines {
            // parse SSE
            continuation.yield(.textDelta(...))
        }
        continuation.finish()
    }
}
```

The `for await chunk in service.stream(...)` loop in `agenticLoop` processes one chunk at a time. Because the loop runs on `@MainActor`, each `items` mutation is immediately visible to SwiftUI without additional synchronisation.

---

## Scroll synchronisation via changeCount

SwiftUI's `onChange` requires an `Equatable` value. Rather than making `[ChatItem]` drive scroll (expensive equality check), a simple `Int` counter is used:

```swift
var changeCount: Int = 0

// On any mutation:
changeCount += 1
```

ContentView:
```swift
.onChange(of: viewModel.changeCount) { _ in
    withAnimation(.easeOut(duration: 0.1)) {
        proxy.scrollTo("bottom")
    }
}
```

This fires on every content update — text deltas, new bubbles, tool results — keeping the view scrolled to the bottom throughout a streaming response.

---

## Message queuing

When `isRunning == true` and the user sends a new message:

```
messageQueue.append(QueuedMessage(text: text, context: context))
```

At each loop iteration where `stop_reason != "tool_use"`, the loop checks the queue:

```swift
if let queued = takeLatestQueuedMessage() {
    // mark skipped tool items
    conversationHistory.append(queued as user message)
    // continue loop
} else {
    break
}
```

`takeLatestQueuedMessage()` discards all queued messages except the last. This "supersede" strategy avoids the agent acting on stale intermediate instructions when the user has already moved on.

---

## Cancellation and rollback

If the task is cancelled mid-tool-execution:

1. `withTaskCancellationHandler` in `ToolExecutor` fires → `process.terminate()`
2. The `await executor.execute()` call returns
3. `Task.isCancelled` is checked immediately after
4. If cancelled: `conversationHistory` is truncated back to its pre-turn snapshot
5. `CancellationError` propagates up through the `agenticLoop`, caught silently

The history rollback prevents the conversation from containing a half-completed tool exchange that would confuse Claude on the next message.

---

## Simulator refresh concurrency

`SimulatorStore.refresh()` uses `withCheckedThrowingContinuation` to bridge `Process` (callback-based) into async/await:

```swift
func refresh() async {
    isLoading = true
    defer { isLoading = false }
    do {
        let json = try await runSimctl()
        let parsed = parse(json)
        simulators = parsed
    } catch {
        loadError = error.localizedDescription
    }
}
```

This runs on `@MainActor` but suspends during process execution, so the UI stays responsive.
