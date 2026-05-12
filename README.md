# Lattice

An autonomous Apple platform coding agent. Bring your own API key (Anthropic, OpenAI, or z.ai) and let Lattice build, run, and iterate on your Xcode projects.

## Open in Xcode

From the repository root, open the Xcode project (not the parent folder):

- **Path:** `Lattice/Lattice.xcodeproj`
- **Finder:** double-click `Lattice.xcodeproj`.
- **Terminal** (from the repo root): `open Lattice/Lattice.xcodeproj`
- **Cursor / VS Code:** right-click `Lattice.xcodeproj` → Reveal in Finder, then double-click it.

The **Lattice** scheme is checked in under `xcshareddata/xcschemes`, so Run (Cmd+R) works after clone without creating a scheme locally.

## Setup

1. Select the **Lattice** scheme and a **My Mac** destination.
2. Build and run (Cmd+R).
3. Enter your API key and choose a project folder in the app.

## Features

- Multi-provider support: Anthropic (Claude), OpenAI (GPT-5.x), z.ai (GLM)
- Agentic coding loop with bash, file read/write tools
- Xcode build & run via xcodebuildmcp
- iOS Simulator targeting
- Streaming responses with tool visibility
