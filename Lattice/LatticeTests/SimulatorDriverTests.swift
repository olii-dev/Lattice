import Testing
import Foundation
@testable import Lattice

@Suite struct SimulatorDriverProtocolTests {

    @Test func commandEncodesTheDriverWireShape() throws {
        let command = SimulatorCommand(
            id: "abc", action: "tap", x: 0.5, y: 0.25, label: nil, text: nil
        )
        let data = try JSONEncoder().encode(command)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "abc")
        #expect(json["action"] as? String == "tap")
        #expect(json["x"] as? Double == 0.5)
        #expect(json["y"] as? Double == 0.25)
        // Absent optionals must not serialize (driver decodes them as missing).
        #expect(json["label"] == nil)
        #expect(json["bundleID"] == nil)
    }

    @Test func resultDecodesFromDriver() throws {
        let json = #"{"id":"abc","ok":true,"detail":"Tapped the Save button"}"#
        let result = try JSONDecoder().decode(SimulatorDriverResult.self, from: Data(json.utf8))
        #expect(result.id == "abc")
        #expect(result.ok)
        #expect(result.detail?.contains("Save") == true)
    }

    @Test func cacheKeyIsStableAndRuntimeScoped() {
        let a = SimulatorDriverCoordinator.cacheKey(udid: "UDID-123456", xcodeVersion: "Xcode 16.0", runtimeID: "iOS-26-1")
        let b = SimulatorDriverCoordinator.cacheKey(udid: "UDID-123456", xcodeVersion: "Xcode 16.0", runtimeID: "iOS-26-1")
        let c = SimulatorDriverCoordinator.cacheKey(udid: "UDID-123456", xcodeVersion: "Xcode 16.0", runtimeID: "iOS-18-0")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hasPrefix("driver-UDID-123-"))
    }

    @Test func commandDirectoryScopedByUDID() {
        let a = SimulatorDriverCoordinator.commandDirectory(udid: "u1")
        let b = SimulatorDriverCoordinator.commandDirectory(udid: "u2")
        #expect(a != b)
        #expect(a.lastPathComponent == "lattice-simdriver-u1")
    }
}

@Suite struct ToolResultScreenshotTests {

    @Test func toolResultWithoutScreenshotHasStringContent() {
        let message = toolResultMessage(toolUseId: "t1", content: "Done.", isError: false)
        #expect(message["content"] as? String == "Done.")
        #expect(message["type"] as? String == "tool_result")
    }

    @Test func toolResultWithScreenshotEmbedsImageBlock() throws {
        let png = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-test-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let message = toolResultMessage(toolUseId: "t1", content: "Tapped.", isError: false, screenshotPath: png.path)
        let blocks = try #require(message["content"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "text")
        let image = blocks.first(where: { ($0["type"] as? String) == "image" })
        #expect(image != nil)
        let source = try #require(image?["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    }

    @Test func erroredToolResultIgnoresScreenshot() throws {
        let png = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-test-\(UUID().uuidString).png")
        try Data([0x00]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let message = toolResultMessage(toolUseId: "t1", content: "Failed.", isError: true, screenshotPath: png.path)
        #expect(message["content"] as? String == "Failed.")
    }
}

@Suite struct SimulatorUseToolTests {

    @Test func missingActionFails() async {
        let executor = ToolExecutor(simulatorUDID: "fake-udid")
        let (output, isError) = await executor.execute(name: "simulator_use", input: [:])
        #expect(isError)
        #expect(output.contains("action"))
    }

    @Test func missingSimulatorFailsWithGuidance() async {
        let executor = ToolExecutor(simulatorUDID: nil)
        let (output, isError) = await executor.execute(
            name: "simulator_use", input: ["action": "launch"]
        )
        #expect(isError)
        #expect(output.localizedCaseInsensitiveContains("simulator"))
    }

    @Test func waitActionSucceedsWithoutDriver() async {
        let executor = ToolExecutor(simulatorUDID: "fake-udid")
        let (output, isError) = await executor.execute(
            name: "simulator_use", input: ["action": "wait", "duration": 0.05]
        )
        #expect(!isError)
        #expect(output.contains("Waited"))
    }
}
