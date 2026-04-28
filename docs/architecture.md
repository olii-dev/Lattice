# Architecture

## Component map

```
DevClawApp.swift          ← @main entry point
└── ContentView.swift     ← Root SwiftUI view + two ViewModels
    ├── ChatViewModel     ← Agentic loop, conversation state, message queuing
    ├── SimulatorStore    ← iOS simulator discovery via xcrun simctl
    ├── AnthropicService  ← Anthropic API client, SSE streaming, tool definitions
    ├── ToolExecutor      ← bash / read_file / write_file execution
    └── UI views
        ├── messageList       ← Scrolling chat bubbles and tool cards
        ├── inputBar          ← TextField + Send/Stop button
        ├── SettingsPanel     ← Inspector: API key, model, simulator, project folder
        ├── SetupPrompt       ← Overlay shown before API key is entered
        └── ProjectFolderPrompt ← Overlay shown after API key but before project selected
```

## Data flow

```
User types message
       │
       ▼
ChatViewModel.send(text:)
       │
       ├─ Append ChatItem.user to items[]
       ├─ Append to conversationHistory (with context injection)
       │
       ▼
ChatViewModel.agenticLoop()   ←────────────────────────────────────────┐
       │                                                                │
       ├─ AnthropicService.stream()  ──► SSE chunks arrive             │
       │       │                                                        │
       │       ├─ textDelta  → update/create AssistantBubble           │
       │       ├─ toolCallAnnounced → create ToolCard (running)        │
       │       └─ done(stopReason, blocks)                             │
       │                                                                │
       ├─ If stopReason == "tool_use":                                  │
       │       │                                                        │
       │       ├─ ToolExecutor.execute(name:input:) for each tool      │
       │       ├─ Update ToolCard with result                          │
       │       ├─ Append tool_result to conversationHistory            │
       │       └─ Loop ─────────────────────────────────────────────────┘
       │
       └─ If stopReason != "tool_use":
               ├─ Check messageQueue for pending user messages
               ├─ If queued: inject latest message, loop ──────────────────┘
               └─ If empty: break — agent turn complete
```

## File responsibilities

| File | Lines | Responsibility |
|------|-------|----------------|
| `DevClawApp.swift` | ~10 | App entry point, WindowGroup |
| `Item.swift` | ~35 | `ChatItem` data model |
| `AnthropicService.swift` | ~490 | API client, SSE parser, tool schema definitions, system prompt |
| `ToolExecutor.swift` | ~110 | Process spawning, file I/O, PATH enrichment |
| `ContentView.swift` | ~1,024 | ViewModels, all SwiftUI views, settings, build/run flow |

## Concurrency model

All ViewModels are `@MainActor` — state mutations happen on the main thread and automatically propagate to SwiftUI. Heavy work (API streaming, process execution) runs inside `Task { }` blocks on the cooperative thread pool. Cancellation flows through Swift's structured concurrency: `Task.cancel()` sets the cancellation flag; `withTaskCancellationHandler` ensures in-flight `Process` instances are terminated.

## Persistence

All user preferences use `@AppStorage`, which writes to `UserDefaults`. There is no local database or file-based persistence beyond what the agent writes to the user's project directory.

| Key | Type | Purpose |
|-----|------|---------|
| `anthropicAPIKey` | String | Anthropic credentials |
| `selectedSimulatorID` | String | Last chosen simulator UDID |
| `selectedProjectPath` | String | Last chosen project folder |
| `selectedModel` | String | Last chosen model ID |
