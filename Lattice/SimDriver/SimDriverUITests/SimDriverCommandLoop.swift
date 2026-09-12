import XCTest

/// Lattice's simulator driver: a single long-running UI test that executes a queue
/// of commands from a shared JSONL file and appends JSONL results, letting the
/// Lattice app drive the simulator (launch, tap, type, swipe) like a user.
///
/// Communication layout (created by the controller):
///   <dir>/commands.jsonl   — controller appends one command JSON per line
///   <dir>/results.jsonl    — driver appends one result JSON per command
///   <dir>/driver-ready     — created by the driver once the loop starts
final class SimDriverCommandLoop: XCTestCase {

    private struct Command: Decodable {
        let id: String
        let action: String
        var bundleID: String?
        var x: Double?
        var y: Double?
        var elementType: String?
        var label: String?
        var text: String?
        var direction: String?
    }

    private struct Result: Encodable {
        let id: String
        let ok: Bool
        var detail: String?
    }

    /// Exits when no commands arrive for this long (safety valve for orphans).
    private static let idleTimeout: TimeInterval = 600
    /// Hard cap on a single session regardless of activity.
    private static let maxSessionDuration: TimeInterval = 3600
    /// How long element queries wait before reporting "not found".
    private static let elementQueryTimeout: TimeInterval = 3

    func testCommandLoop() throws {
        let dir = commandDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let commandsURL = dir.appendingPathComponent("commands.jsonl")
        let resultsURL = dir.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: commandsURL.path) {
            FileManager.default.createFile(atPath: commandsURL.path, contents: nil)
        }
        FileManager.default.createFile(atPath: resultsURL.path, contents: nil)

        // Readiness marker for the controller.
        try? Data("ready".utf8).write(to: dir.appendingPathComponent("driver-ready"), options: .atomic)

        let resultsHandle = try FileHandle(forWritingTo: resultsURL)
        defer { try? resultsHandle.close() }

        let commandsHandle = try FileHandle(forReadingFrom: commandsURL)
        var readOffset: UInt64 = 0
        var pendingBuffer = Data()
        var currentApp = XCUIApplication()
        var lastActivity = Date()
        let sessionStart = Date()
        var sessionExpired = false

        loop: while true {
            // Drain any newly appended command bytes.
            let size = (try? FileManager.default.attributesOfItem(atPath: commandsURL.path))?[.size] as? UInt64 ?? 0
            if size > readOffset {
                commandsHandle.seek(toFileOffset: readOffset)
                let chunk = commandsHandle.readDataToEndOfFile()
                readOffset = size
                pendingBuffer.append(chunk)
                lastActivity = Date()
            }

            while let (jsonData, remainder) = popLine(pendingBuffer) {
                pendingBuffer = remainder
                guard let command = try? JSONDecoder().decode(Command.self, from: jsonData) else {
                    append(Result(id: "unknown", ok: false, detail: "Unparseable command"), to: resultsHandle)
                    continue
                }
                if command.action == "stop" {
                    append(Result(id: command.id, ok: true, detail: nil), to: resultsHandle)
                    break loop
                }
                let result = execute(command: command, app: currentApp, setCurrentApp: { currentApp = $0 })
                append(result, to: resultsHandle)
                lastActivity = Date()
            }

            if Date().timeIntervalSince(lastActivity) > Self.idleTimeout
                || Date().timeIntervalSince(sessionStart) > Self.maxSessionDuration {
                sessionExpired = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = sessionExpired
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("driver-ready"))
    }

    // MARK: - Command execution

    private func execute(
        command: Command,
        app: XCUIApplication,
        setCurrentApp: @escaping (XCUIApplication) -> Void
    ) -> Result {
        // No XCUI call throws in Swift, so the switch runs in a plain scope block.
        do {
            switch command.action {
            case "launch":
                guard let bundleID = command.bundleID, !bundleID.isEmpty else {
                    return Result(id: command.id, ok: false, detail: "launch requires bundleID")
                }
                let target = XCUIApplication(bundleIdentifier: bundleID)
                target.launch()
                setCurrentApp(target)
                return Result(id: command.id, ok: true, detail: "Launched \(bundleID)")

            case "terminate":
                let target = command.bundleID.map { XCUIApplication(bundleIdentifier: $0) } ?? app
                target.terminate()
                return Result(id: command.id, ok: true, detail: "Terminated")

            case "tap":
                guard let x = command.x, let y = command.y else {
                    return Result(id: command.id, ok: false, detail: "tap requires x and y (0-1 normalized)")
                }
                let clamped = CGVector(dx: min(max(x, 0), 1), dy: min(max(y, 0), 1))
                app.coordinate(withNormalizedOffset: clamped).tap()
                return Result(id: command.id, ok: true, detail: "Tapped (\(clamped.dx), \(clamped.dy))")

            case "tap_element", "tapElement":
                guard let label = command.label, !label.isEmpty else {
                    return Result(id: command.id, ok: false, detail: "tap_element requires label")
                }
                let queries = elementQueries(app: app, elementType: command.elementType, label: label)
                for query in queries {
                    if query.element.waitForExistence(timeout: Self.elementQueryTimeout) {
                        query.element.tap()
                        return Result(id: command.id, ok: true, detail: "Tapped \(query.description)")
                    }
                }
                return Result(id: command.id, ok: false, detail: "No element matching “\(label)” found")

            case "type":
                guard let text = command.text else {
                    return Result(id: command.id, ok: false, detail: "type requires text")
                }
                app.typeText(text)
                return Result(id: command.id, ok: true, detail: "Typed \(text.count) characters")

            case "swipe":
                switch command.direction?.lowercased() {
                case "up": app.swipeUp()
                case "down": app.swipeDown()
                case "left": app.swipeLeft()
                case "right": app.swipeRight()
                default:
                    return Result(id: command.id, ok: false, detail: "swipe requires direction up/down/left/right")
                }
                return Result(id: command.id, ok: true, detail: "Swiped \(command.direction ?? "")")

            case "home":
                XCUIDevice.shared.press(.home)
                return Result(id: command.id, ok: true, detail: "Pressed home")

            default:
                return Result(id: command.id, ok: false, detail: "Unknown action “\(command.action)”")
            }
        }
    }

    private struct ElementQuery {
        let element: XCUIElement
        let description: String
    }

    private func elementQueries(app: XCUIApplication, elementType: String?, label: String) -> [ElementQuery] {
        var queries: [ElementQuery] = []
        switch elementType?.lowercased() {
        case "button":
            queries.append(ElementQuery(element: app.buttons[label], description: "button “\(label)”"))
        case "text":
            queries.append(ElementQuery(element: app.staticTexts[label], description: "text “\(label)”"))
        case "textfield":
            queries.append(ElementQuery(element: app.textFields[label], description: "textfield “\(label)”"))
        default:
            break
        }
        // Generic fallbacks (any element type carrying the label).
        queries.append(ElementQuery(element: app.descendants(matching: .any)[label], description: "any element “\(label)”"))
        return queries
    }

    // MARK: - File plumbing

    /// Shared directory for a given simulator; the controller derives the same path.
    static func commandDirectory(udid: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-simdriver-\(udid)", isDirectory: true)
    }

    private func commandDirectory() -> URL {
        let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "shared"
        return Self.commandDirectory(udid: udid)
    }

    private func popLine(_ data: Data) -> (Data, Data)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = data[data.startIndex..<newline]
        let rest = data[data.index(after: newline)...]
        return (line, rest)
    }

    private func append(_ result: Result, to handle: FileHandle) {
        guard let line = try? JSONEncoder().encode(result) else { return }
        handle.seekToEndOfFile()
        handle.write(line)
        handle.write(Data("\n".utf8))
    }
}
