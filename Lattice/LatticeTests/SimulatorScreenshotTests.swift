import Testing
import Foundation
@testable import Lattice

@Suite struct SimulatorScreenshotTests {

    @Test func emptyUDIDFailsWithFriendlyError() async {
        do {
            _ = try await SimulatorScreenshot.capture(deviceUDID: "   ")
            #expect(Bool(false), "expected failure for empty UDID")
        } catch let error as SimulatorScreenshot.CaptureError {
            #expect(error.localizedDescription.contains("No simulator"))
        } catch {
            #expect(Bool(false), "unexpected error type: \(error)")
        }
    }

    @Test func invalidUDIDFailsGracefully() async {
        // xcrun simctl rejects unknown UDIDs; the wrapper must surface a
        // non-crashing error either way.
        do {
            _ = try await SimulatorScreenshot.capture(deviceUDID: "lattice-invalid-udid-\(UUID().uuidString)")
            #expect(Bool(false), "expected failure for invalid UDID")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}
