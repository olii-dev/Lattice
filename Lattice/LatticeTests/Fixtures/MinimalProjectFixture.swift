import Foundation

/// Creates an on-disk minimal Xcode project fixture derived from `PbxprojFixtures.iosTemplate`.
///
/// Used by `CapabilityApplicatorTests` so that applicator tests exercise the real file I/O
/// (pbxproj reads/writes, entitlements plist creation, Info.plist merging) hermetically in a
/// unique temp directory per test. Each test creates its own fixture and tears it down.
enum MinimalProjectFixture {
    /// Creates a temp dir containing `LatticeTplApp.xcodeproj/project.pbxproj` (from the template)
    /// and an empty source group folder `LatticeTplApp/` matching the template's group path.
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let projDir = dir.appendingPathComponent("LatticeTplApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try PbxprojFixtures.iosTemplate.write(
            to: projDir.appendingPathComponent("project.pbxproj"),
            atomically: true,
            encoding: .utf8
        )
        // Source group folder matching the template's group path (`path = LatticeTplApp;`).
        let srcDir = dir.appendingPathComponent("LatticeTplApp", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes the temp dir created by `make()`. Safe to call multiple times; ignores errors.
    static func tearDown(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
