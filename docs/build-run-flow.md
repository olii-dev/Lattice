# Build & Run Flow

The "Build & Run" button triggers a special agentic run that builds and launches the project. It is distinct from a normal chat message in two ways: it uses a hidden prompt (no user bubble), and on completion it extracts and caches build configuration for future runs.

---

## Trigger conditions

The button is visible only when `selectedProjectPath` is non-empty, and disabled while the agent is already running or the API key is missing:

```swift
if !selectedProjectPath.isEmpty {
    Button(action: buildAndRun) { ... }
    .disabled(!canBuildAndRun)
}
```

---

## buildAndRun()

```
1. Record buildRunStartIndex = viewModel.items.count
2. Set isBuildRun = true
3. Compose hidden prompt:
   - If buildInfo != nil → "Build and run using the known build configuration in context."
   - Otherwise         → "Build and run the project. Discover the project and scheme, then build and launch it."
4. Call viewModel.send(text:prompt, apiKey:..., context:chatContext, showUserBubble: false)
```

The `showUserBubble: false` flag suppresses the user bubble so the transcript starts directly with Claude's first response, making the build feel like an autonomous action rather than a chat exchange.

`chatContext` includes `buildInfo` when it is non-nil. This causes `AnthropicService` to inject the MANDATORY OVERRIDE section into the system prompt, skipping project-discovery phases entirely.

---

## During the run

The agentic loop runs normally. The user will see:
- ToolCards for `bash` calls (xcodebuildmcp commands, xcrun, etc.)
- ToolCards for any `read_file` or `write_file` calls Claude makes during the build
- An assistant bubble with Claude's summary once the build finishes

---

## Post-build extraction

Triggered by `.onChange(of: viewModel.isRunning)` when it transitions from `true` to `false` and `isBuildRun` is true:

```swift
.onChange(of: viewModel.isRunning) { running in
    if !running && isBuildRun {
        isBuildRun = false
        extractBuildInfo()
    }
}
```

### extractBuildInfo()

1. Collect all `ChatItem`s from `buildRunStartIndex` onward
2. Build a summary string of tool inputs and brief outputs from those items
3. Send to `AnthropicService.complete()` (non-streaming, max 512 tokens):

```
From the following tool calls, extract the build configuration used.
Return only JSON: {"schemeName":"...","projectPath":"...","simulatorID":"..."}
If no simulator was used, omit simulatorID.

<tool summary>
```

4. Parse the JSON response
5. Populate `viewModel.buildInfo` with the extracted values

### On failure

If the JSON cannot be parsed, or if `complete()` throws, `buildInfo` stays nil. The next build will run full discovery again. This is a silent fallback — no error is shown to the user.

---

## BuildInfo caching

Once `buildInfo` is set, it persists for the session:

- Injected into every `ChatContext`
- Formatted into `messagePrefix` as "[Known Build Configuration]"
- Forces Claude to use the cached scheme/path/simulator
- Cleared when `selectedProjectPath` changes (via `onChange` in ContentView)

This means the first build discovers the project once; all subsequent builds in the same session go straight to building.

---

## Phase sequence with cached build info

```
Without cache:                    With cache (MANDATORY OVERRIDE):
  PHASE 0 — verify CLIs             PHASE 4 — build (directly)
  PHASE 1 — discover project        PHASE 5/6 — launch
  PHASE 4 — build
  PHASE 5/6 — launch
```
