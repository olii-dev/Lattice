# ToolExecutor

`ToolExecutor` (`ToolExecutor.swift`) is responsible for running the three tools Claude can call: `bash`, `read_file`, and `write_file`. It has no stored state and is instantiated once inside `ChatViewModel`.

## Interface

```swift
func execute(name: String, input: [String: Any]) async -> (output: String, isError: Bool)
```

Always returns — never throws. Errors are returned as `(output: <message>, isError: true)` so the caller can surface them to Claude as a `tool_result` with `is_error: true`.

---

## bash

Spawns `/bin/bash -c "<command>"` using `Foundation.Process`.

### PATH enrichment

Before launching, `ToolExecutor` builds a custom `PATH` by merging Homebrew locations with the existing environment:

```
/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:<inherited PATH>
```

This ensures `xcodebuildmcp`, `openspec`, and other npm-installed CLIs are found on both Intel and Apple Silicon Macs.

### Output capture

Both stdout and stderr are captured via `Pipe` and merged into a single string. If the process exits with a non-zero status code, `isError` is set to `true`.

### Cancellation

```swift
withTaskCancellationHandler {
    // await process completion
} onCancel: {
    process.terminate()
}
```

If the enclosing Swift `Task` is cancelled while a process is running, `Process.terminate()` is called immediately, and the continuation is resumed with whatever partial output was captured.

### Implementation detail

Output is read after the process finishes (not streamed line by line). For long-running commands (large builds), this means the ToolCard stays in "running" state until the process exits.

---

## read_file

```swift
case "read_file":
    let path = input["path"] as? String ?? ""
    let content = try String(contentsOfFile: path, encoding: .utf8)
    return (content, false)
```

Reads the entire file at once. Returns the raw text. On failure (file not found, permission denied, invalid encoding) returns the error's `localizedDescription` with `isError: true`.

---

## write_file

```swift
case "write_file":
    let path    = input["path"]    as? String ?? ""
    let content = input["content"] as? String ?? ""
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
    return ("Written to \(path)", false)
```

Creates intermediate directories so Claude can write to paths that don't yet exist. Writes atomically (to a temp file, then renames) for crash safety.

---

## Unknown tool

Any tool name that isn't `bash`, `read_file`, or `write_file` returns:

```
("Unknown tool: <name>", true)
```

This is a safety net; in practice Claude is constrained to the three defined tools by the request schema.
