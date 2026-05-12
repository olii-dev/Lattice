# Lattice

An autonomous Apple platform coding agent. Bring your own API key (Anthropic, OpenAI, or z.ai) and let Lattice build, run, and iterate on your Xcode projects.

## Setup

1. Open `Lattice/Lattice.xcodeproj` in Xcode
2. Build and run (Cmd+R)
3. Enter your API key and select a project folder

## Features

- Multi-provider support: Anthropic (Claude), OpenAI (GPT-5.x), z.ai (GLM)
- Agentic coding loop with bash, file read/write tools
- Xcode build & run via xcodebuildmcp
- iOS Simulator targeting
- Streaming responses with tool visibility
