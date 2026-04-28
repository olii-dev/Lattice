# UI Guide

The entire UI is defined in `ContentView.swift`. It uses SwiftUI with an inspector (sidebar) for settings.

---

## Root layout

```
Window
├── VStack
│   ├── messageList          — scrollable transcript
│   ├── Divider
│   └── inputBar             — text field + send/stop button
├── Toolbar
│   ├── Build & Run          — visible only when project path is set
│   ├── Settings toggle
│   └── Clear chat
├── Inspector (SettingsPanel)
└── Overlays
    ├── SetupPrompt          — shown when API key is missing
    └── ProjectFolderPrompt  — shown when project path is missing
```

---

## messageList

A `ScrollView` containing a `LazyVStack` of `ChatItemView`s, with a zero-height spacer anchored as `"bottom"`. When `viewModel.changeCount` changes, the scroll view animates to this anchor:

```swift
.onChange(of: viewModel.changeCount) { _ in
    withAnimation(.easeOut(duration: 0.1)) {
        proxy.scrollTo("bottom")
    }
}
```

`LazyVStack` ensures only visible rows are rendered, keeping performance acceptable for long sessions.

---

## inputBar

An `HStack` containing:

- **TextField** — `axis: .vertical`, min 1 line, max 8 lines. Bound to `@State var inputText`. `onSubmit` fires on Return; Cmd+Return is also wired as a keyboard shortcut.
- **Send / Stop button** — Toggles between a "stop" icon (when running with no input text) and a filled arrow-up icon (when there is text to send). Disabled when `apiKey` is empty.

The button action:
- If `isRunning && inputText.isEmpty` → calls `viewModel.stop()`
- Otherwise → calls `sendMessage()` which calls `viewModel.send(...)`

---

## Toolbar

### Build & Run button

```swift
if !selectedProjectPath.isEmpty {
    Button(action: buildAndRun) {
        Label("Build & Run", systemImage: "play.fill")
    }
    .disabled(!canBuildAndRun)
}
```

Hidden entirely until a project path is selected. Disabled while the agent is running or the API key is empty.

`canBuildAndRun`:
```swift
private var canBuildAndRun: Bool {
    !apiKey.isEmpty && !selectedProjectPath.isEmpty && !viewModel.isRunning
}
```

### Settings toggle

Toggles the `showSettingsPanel` bool, which shows/hides the `.inspector` panel.

Icon changes: `sidebar.trailing` (open) ↔ `sidebar.right` (closed).

### Clear button

Calls `viewModel.clear()`. Disabled when `viewModel.items.isEmpty || viewModel.isRunning`.

---

## Chat item views

### UserBubble

Right-aligned bubble with accent color background and white text. An 80pt leading `Spacer` creates the asymmetric layout. Rounded corners (16pt radius), padding 10/14.

### AssistantBubble

Left-aligned with a `sparkle` system image icon. Three states:

| State | Display |
|-------|---------|
| `isStreaming && text.isEmpty` | `ProgressView()` spinner |
| `isStreaming && !text.isEmpty` | Text + animated blinking cursor (2×12pt `Rectangle`) |
| `!isStreaming` | Text only, selectable |

Text is `.textSelection(.enabled)` so users can copy AI responses.

### ToolCard

An expandable card with:

**Header** (always visible):
- Tool icon (`terminal.fill`, `doc.text`, `square.and.pencil`, or `wrench` for unknown tools)
- Tool name in monospaced bold caption
- One-line input preview in secondary color
- Right side: `ProgressView` (while running) or checkmark/xmark status icon, plus a chevron

**Body** (expanded when `isExpanded == true`):
- Scrollable text view, max 240pt height
- Monospace font, small size
- Border color: `.red` on error, `.secondary` on success

Tapping anywhere on the header toggles `isExpanded`. Cards start collapsed.

**Input display format** by tool:
| Tool | Format |
|------|--------|
| `bash` | `$ <command>` |
| `read_file` | `cat <path>` |
| `write_file` | `→ <path>` |
| other | raw JSON |

---

## SettingsPanel

Shown as an `.inspector` panel on the trailing side of the window. Contains four sections:

### 1. Anthropic API Key

`SecureField` bound to `@AppStorage("anthropicAPIKey")`. Help text beneath: "Stored in UserDefaults".

### 2. Model Selection

`Picker` with two options:
- Claude Opus 4.7 (`claude-opus-4-7`)
- Claude Sonnet 4.6 (`claude-sonnet-4-6`)

Bound to `@AppStorage("selectedModel")`. The selected value is read at send time, not baked in at launch.

### 3. iOS Simulator

`Picker` of `SimulatorOption` values from `simulatorStore.simulators`. A refresh button (arrow.clockwise) triggers `simulatorStore.refresh()`.

If `loadError` is set, it appears in red below the picker. If no simulators are loaded yet, a help note explains Xcode must be installed.

On change: if the newly selected ID no longer appears in the fetched list, `selectedSimulatorID` is cleared.

### 4. Project Folder

- **Choose Folder** button: opens `NSOpenPanel` configured for directory selection only (no file selection, no multiple selection). Sets `selectedProjectPath` and clears `viewModel.buildInfo` so the next build re-discovers the project.
- **Clear** button: clears `selectedProjectPath` and `viewModel.buildInfo`.
- Path display: monospaced text, `.textSelection(.enabled)`.

---

## Overlay views

### SetupPrompt

Shown when `apiKey.isEmpty && viewModel.items.isEmpty`. Overlaid on the centre of the message list.

```
[key icon]
Add your Anthropic API key to start
[Open Settings button]
```

Tapping "Open Settings" sets `showSettingsPanel = true`.

### ProjectFolderPrompt

Shown when `!apiKey.isEmpty && selectedProjectPath.isEmpty && viewModel.items.isEmpty`. Overlaid on the centre of the message list.

```
[folder icon]
Choose a project folder to start
[Choose Folder button]
```

Tapping "Choose Folder" opens the same `NSOpenPanel` used in the settings panel.
