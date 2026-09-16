import CryptoKit
import Foundation

// MARK: - Command protocol (mirrored by SimDriver/SimDriverUITests/SimDriverCommandLoop.swift)

struct SimulatorCommand: Encodable, Equatable {
    let id: String
    let action: String
    var bundleID: String? = nil
    var x: Double? = nil
    var y: Double? = nil
    var elementType: String? = nil
    var label: String? = nil
    var text: String? = nil
    var direction: String? = nil
}

struct SimulatorDriverResult: Decodable, Equatable {
    let id: String
    let ok: Bool
    var detail: String?
}

// MARK: - Coordinator

/// Manages the SimDriver UI-test process for each simulator: builds the runner
/// once per (Xcode, runtime) pair, keeps a session alive, and shuttles commands
/// and results through shared JSONL files.
actor SimulatorDriverCoordinator {

    static let shared = SimulatorDriverCoordinator()

    private struct Session {
        let process: Process
        let directory: URL
        let commandsHandle: FileHandle
        var resultsOffset: UInt64
    }

    private var sessions: [String: Session] = [:]

    enum DriverError: LocalizedError {
        case bundledProjectMissing
        case runnerNotBuilt(String)
        case sessionStartTimedOut
        case commandTimedOut(String)
        case notLaunched

        var errorDescription: String? {
            switch self {
            case .bundledProjectMissing:
                return "The simulator driver project is missing from the app bundle."
            case .runnerNotBuilt(let detail):
                return "Could not build the simulator driver.\n\n\(detail)"
            case .sessionStartTimedOut:
                return "The simulator driver did not start in time. Try running the app again."
            case .commandTimedOut(let action):
                return "The simulator did not respond to “\(action)” in time."
            case .notLaunched:
                return "No simulator driver session is running."
            }
        }
    }

    // MARK: - Commands

    /// Sends one command and waits for its result. Starts a session lazily.
    func send(_ command: SimulatorCommand, udid: String, timeout: TimeInterval = 45) async throws -> SimulatorDriverResult {
        let session = try await ensureSession(udid: udid)
        let line = try JSONEncoder().encode(command)
        session.commandsHandle.seekToEndOfFile()
        session.commandsHandle.write(line)
        session.commandsHandle.write(Data("\n".utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try pollResult(id: command.id, session: &sessions[udid]!) {
                return result
            }
            // If the runner died, surface that instead of polling forever.
            if !session.process.isRunning, resultCount(in: session.directory) == 0 {
                throw DriverError.sessionStartTimedOut
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DriverError.commandTimedOut(command.action)
    }

    /// Ends the session for a simulator (stop command + process teardown).
    func endSession(udid: String) {
        guard let session = sessions.removeValue(forKey: udid) else { return }
        if session.process.isRunning {
            let stop = SimulatorCommand(id: UUID().uuidString, action: "stop")
            if let line = try? JSONEncoder().encode(stop) {
                session.commandsHandle.seekToEndOfFile()
                session.commandsHandle.write(line)
                session.commandsHandle.write(Data("\n".utf8))
            }
            // Give the loop a moment to exit cleanly, then hard-stop.
            let deadline = Date().addingTimeInterval(3)
            while session.process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if session.process.isRunning {
                session.process.terminate()
            }
        }
        try? session.commandsHandle.close()
    }

    // MARK: - Session lifecycle

    private func ensureSession(udid: String) async throws -> Session {
        if let existing = sessions[udid], existing.process.isRunning {
            return existing
        }
        sessions.removeValue(forKey: udid)
        return try await startSession(udid: udid)
    }

    private func startSession(udid: String) async throws -> Session {
        let runner = try await prepareRunner(udid: udid)
        guard let xctestrun = Self.findXctestrun(in: runner.deletingLastPathComponent()) else {
            throw DriverError.runnerNotBuilt("No .xctestrun file next to \(runner.lastPathComponent).")
        }

        let dir = Self.commandDirectory(udid: udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let commandsURL = dir.appendingPathComponent("commands.jsonl")
        let resultsURL = dir.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: commandsURL.path, contents: nil)
        try? Data().write(to: resultsURL, options: .atomic)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("driver-ready"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", "platform=iOS Simulator,id=\(udid)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let commandsHandle = try FileHandle(forWritingTo: commandsURL)
        process.terminationHandler = { _ in
            try? commandsHandle.close()
        }
        try process.run()

        var session = Session(
            process: process,
            directory: dir,
            commandsHandle: commandsHandle,
            resultsOffset: 0
        )
        sessions[udid] = session

        // Wait for the driver loop to signal readiness.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("driver-ready").path) {
                session.resultsOffset = 0
                sessions[udid] = session
                return session
            }
            if !process.isRunning {
                throw DriverError.sessionStartTimedOut
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        process.terminate()
        sessions.removeValue(forKey: udid)
        throw DriverError.sessionStartTimedOut
    }

    private func pollResult(id: String, session: inout Session) throws -> SimulatorDriverResult? {
        let resultsURL = session.directory.appendingPathComponent("results.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: resultsURL.path))?[.size] as? UInt64 ?? 0
        guard size > session.resultsOffset else { return nil }
        let handle = try FileHandle(forReadingFrom: resultsURL)
        defer { try? handle.close() }
        handle.seek(toFileOffset: session.resultsOffset)
        let chunk = handle.readDataToEndOfFile()
        session.resultsOffset = size

        var buffer = chunk
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if let result = try? JSONDecoder().decode(SimulatorDriverResult.self, from: Data(lineData)),
               result.id == id {
                return result
            }
        }
        return nil
    }

    private func resultCount(in directory: URL) -> Int {
        let url = directory.appendingPathComponent("results.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    // MARK: - Runner build cache

    /// Builds (or reuses) the driver runner for the given simulator. The cache key
    /// covers the Xcode build version and the device's runtime, so runner binaries
    /// are rebuilt only when either changes.
    func prepareRunner(udid: String) async throws -> URL {
        let project = try Self.bundledProjectURL()
        let key = Self.cacheKey(udid: udid, xcodeVersion: Self.xcodeBuildVersion(), runtimeID: Self.runtimeID(udid: udid))
        let cacheDir = Self.cacheRoot().appendingPathComponent(key, isDirectory: true)
        let runnerURL = cacheDir
            .appendingPathComponent("Build/Products/Debug-iphonesimulator/SimDriverUITests-Runner.app")

        if FileManager.default.fileExists(atPath: runnerURL.path) {
            return runnerURL
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "build-for-testing",
            "-project", project.path,
            "-scheme", "SimDriverUITests",
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-derivedDataPath", cacheDir.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = SimulatorBuildRunner.subprocessEnvironment
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: runnerURL.path) else {
            let detail = String(data: output, encoding: .utf8)?
                .split(separator: "\n")
                .suffix(15)
                .joined(separator: "\n") ?? ""
            throw DriverError.runnerNotBuilt(detail)
        }
        return runnerURL
    }

    // MARK: - Paths (internal for tests)

    nonisolated static func bundledProjectURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "SimDriver", withExtension: nil) else {
            throw DriverError.bundledProjectMissing
        }
        return url
    }

    nonisolated static func cacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lattice/SimDriver", isDirectory: true)
    }

    /// Stable cache key: SHA-256 digest of Xcode version + runtime (deterministic
    /// across launches, unlike `Hasher`), so the runner is rebuilt only when either changes.
    nonisolated static func cacheKey(udid: String, xcodeVersion: String, runtimeID: String) -> String {
        let digest = SHA256.hash(data: Data("\(xcodeVersion)|\(runtimeID)".utf8))
            .prefix(5)
            .map { String(format: "%02x", $0) }
            .joined()
        return "driver-\(String(udid.prefix(8)))-\(digest)"
    }

    nonisolated static func xcodeBuildVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "unknown"
        }
    }

    nonisolated static func runtimeID(udid: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "-j", "devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: Any]
            else { return "unknown" }
            for (runtime, list) in devices {
                if let entries = list as? [[String: Any]],
                   entries.contains(where: { ($0["udid"] as? String) == udid }) {
                    _ = text // keep decoder simple; the runtime key is enough
                    return runtime
                }
            }
            return "unknown"
        } catch {
            return "unknown"
        }
    }

    nonisolated static func commandDirectory(udid: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-simdriver-\(udid)", isDirectory: true)
    }

    private nonisolated static func findXctestrun(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )) ?? []
        return contents.first { $0.pathExtension == "xctestrun" }
    }
}
