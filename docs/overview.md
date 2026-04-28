# AgentSwift — Application Overview

AgentSwift is a native macOS application that acts as an autonomous AI coding agent for Apple platform development. The user describes what they want built or changed, and the app drives Claude (via the Anthropic API) to discover the Xcode project, implement code changes, build the app, launch it on a simulator or macOS, and validate the result through UI automation — all without leaving the chat interface.

## What it does

- Accepts free-form prompts ("add a dark mode toggle to the settings screen")
- Orchestrates a multi-phase agentic workflow via Claude
- Executes shell commands, reads and writes source files
- Builds the project with `xcodebuildmcp`
- Launches the built app on a chosen iOS simulator or macOS
- Validates behavior through UI automation
- Caches build configuration so subsequent runs skip re-discovery

## What it is not

AgentSwift is not a general-purpose chat client. It is a tightly scoped tool for Apple platform development. The system prompt instructs Claude to follow a specific phase sequence and error-escalation strategy rather than free-form conversation.

## External dependencies

The agent relies on two npm-installed CLIs that must be available on PATH at runtime:

| CLI | Purpose |
|-----|---------|
| `xcodebuildmcp` | Build, launch, and UI-automate Xcode projects |
| `openspec` | Spec tracking and change management |

Both are expected under Homebrew paths (`/opt/homebrew/bin`) or standard locations. `ToolExecutor` enriches PATH automatically before spawning processes.

## Technology stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 5.9+ |
| UI framework | SwiftUI |
| Concurrency | Swift async/await, AsyncThrowingStream |
| Persistence | UserDefaults via @AppStorage |
| API | Anthropic Messages API (SSE streaming) |
| Process execution | Foundation `Process` API |

## Minimum requirements

- macOS 26.1+
- Xcode installed
- Node.js / npm with `xcodebuildmcp` and `openspec`
- Anthropic API key
