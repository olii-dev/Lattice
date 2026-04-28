# AgentSwift Documentation

Technical documentation for the AgentSwift macOS application.

## Documents

| Document | Contents |
|----------|---------|
| [overview.md](overview.md) | What the app does, tech stack, external dependencies |
| [architecture.md](architecture.md) | Component map, data flow diagram, file responsibilities, concurrency model |
| [data-models.md](data-models.md) | ChatItem, ContentBlock, SimulatorOption, BuildInfo, ChatContext, QueuedMessage |
| [anthropic-service.md](anthropic-service.md) | API endpoint, tool definitions, system prompt, SSE streaming, error handling |
| [tool-executor.md](tool-executor.md) | bash, read_file, write_file — execution, PATH enrichment, cancellation |
| [view-model.md](view-model.md) | ChatViewModel agentic loop, SimulatorStore, message queuing, context injection |
| [ui-guide.md](ui-guide.md) | Root layout, messageList, inputBar, toolbar, SettingsPanel, overlays, chat item views |
| [build-run-flow.md](build-run-flow.md) | Build & Run button trigger, post-build extraction, BuildInfo caching |
| [agentic-phases.md](agentic-phases.md) | Phase 0–7 sequence, error escalation rules, context injection override |
| [state-and-concurrency.md](state-and-concurrency.md) | @MainActor isolation, Task lifecycle, AsyncThrowingStream, scroll sync, cancellation rollback |

## Quick orientation

The app's core loop is:

```
User message → ChatViewModel.send()
                    → agenticLoop()
                          → AnthropicService.stream()    (SSE from Anthropic API)
                          → ToolExecutor.execute()        (bash / file I/O)
                          → loop until no more tool_use
```

All UI state lives in `ChatViewModel.items: [ChatItem]`. Every streaming text delta, tool announcement, and tool result updates this array on the main actor, triggering SwiftUI re-renders.

The system prompt in `AnthropicService` defines a multi-phase workflow (discover → implement → build → launch → validate). `BuildInfo` caching skips the discovery phases after the first successful build.
