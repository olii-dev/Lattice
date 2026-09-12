import Foundation

/// Captures simulator screenshots for the visual feedback loop: the running app's
/// current frame becomes an image attachment the model can see and iterate on.
enum SimulatorScreenshot {
    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Captures a PNG of the given simulator's screen to a temp file and returns it.
    static func capture(deviceUDID: String) async throws -> URL {
        let udid = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CaptureError(message: "No simulator is selected. Pick a run target first.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-screenshot-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting so large stderr cannot wedge on a full pipe buffer.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            let detail = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CaptureError(
                message: detail.isEmpty
                    ? "Screenshot failed (exit code \(process.terminationStatus)). Is the simulator running?"
                    : detail
            )
        }
        return url
    }
}
