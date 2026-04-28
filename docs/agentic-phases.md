# Agentic Phases & System Prompt

The system prompt embedded in `AnthropicService` defines a structured, multi-phase workflow that Claude follows for every request. This document explains each phase, the rules Claude operates under, and how context injection modifies the sequence.

---

## Phase sequence

### PHASE 0 — Setup & CLI verification

Claude verifies that required CLI tools are available before doing anything else:

```bash
which xcodebuildmcp
which openspec
```

If either is missing, Claude surfaces the error to the user rather than proceeding.

### PHASE 1 — Project discovery

Claude explores the project folder to understand its structure:

```bash
find . -name "*.xcodeproj" -o -name "*.xcworkspace"
xcodebuildmcp list-schemes --project <path>
```

The discovered scheme name and project path are used in subsequent phases.

### PHASE 2 — Scaffold (conditional)

If no Xcode project exists, Claude creates one. This phase is skipped when a project is already present.

### PHASE 3 — Implement

Claude reads existing source files and makes the changes the user requested. This is the primary "coding" phase — writing Swift files, updating assets, modifying plists, etc.

### PHASE 4 — Build

```bash
xcodebuildmcp build --scheme <scheme> --project <path> [--simulator <udid>]
```

If the build fails, Claude attempts one autonomous fix (reads the error, modifies code), then rebuilds. If it fails again, the error is surfaced to the user.

### PHASE 5 — Launch (macOS)

For macOS targets, Claude runs the built `.app` bundle directly.

### PHASE 6 — UI automation (iOS)

For iOS targets:
1. Claude boots the selected simulator
2. Launches the app via `xcodebuildmcp`
3. Exercises the UI using automation APIs to validate the changes work

### PHASE 7 — Archive

Claude calls `openspec` to record the completed changes in the spec tracking system.

---

## Error escalation rules

The system prompt explicitly restricts Claude's retry behaviour:

1. **One fix attempt per error.** Claude may autonomously fix a build error once.
2. **Escalate on repeat.** If the same error recurs after the fix, Claude stops and tells the user what went wrong.
3. **No infinite loops.** Claude must not cycle endlessly on errors.

This prevents runaway tool-call chains that waste tokens and API credits.

---

## Context injection override

When `ChatContext.buildInfo` is non-nil, `AnthropicService` prepends a MANDATORY OVERRIDE block to the system prompt:

```
MANDATORY OVERRIDE — Do NOT run PHASE 0 or PHASE 1.
Use exactly the following values:
  Scheme:     MyApp
  Project:    /Users/hayden/Projects/MyApp/MyApp.xcodeproj
  Simulator:  <UDID>
```

Combined with the `[Known Build Configuration]` section in the user message prefix, this ensures Claude never re-discovers a project it has already built successfully in the same session.

---

## Rules embedded in the prompt

The system prompt also includes a set of standing rules:

| Rule | Detail |
|------|--------|
| **File paths must be absolute** | Relative paths in tool calls are forbidden |
| **Read before write** | Claude must read a file before modifying it |
| **Validate changes** | After writing, Claude must build (not just write) to confirm correctness |
| **Minimal scope** | Only change files relevant to the user's request |
| **No hallucinated APIs** | Claude must confirm APIs exist (via read_file or bash) before using them |

---

## How the prompt is structured internally

The system prompt is a multiline Swift string literal in `AnthropicService.swift`. It is concatenated with the context override at request time:

```swift
var systemPrompt = baseSystemPrompt  // ~348 lines

if let buildInfo = context.buildInfo {
    systemPrompt = mandatoryOverride(buildInfo) + "\n\n" + systemPrompt
}
```

The override is prepended, not appended, so it appears before the phase instructions and is harder to ignore.
