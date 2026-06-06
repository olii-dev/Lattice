import AppKit
import Foundation

// MARK: - Errors

enum SimulatorBuildRunnerError: LocalizedError {
    case noXcodeProject(in: String)
    case listSchemesFailed(String)
    case noSchemes
    case xcodebuildFailed(exitCode: Int32, output: String)
    case noBuiltApp
    case missingBundleId
    case processLaunch(String)
    /// Raised before `xcodebuild` when the destination volume reports critically low free space.
    case insufficientDiskSpace(availableDescription: String, minimumDescription: String, volumePath: String)
    case xcodeApplicationMissing

    var errorDescription: String? {
        switch self {
        case .noXcodeProject(let dir):
            return "No .xcodeproj or .xcworkspace found in \(dir)."
        case .listSchemesFailed(let msg):
            return "Could not list schemes: \(msg)"
        case .noSchemes:
            return "No schemes found for this project."
        case .xcodebuildFailed(let code, let output):
            var message = "xcodebuild failed (exit \(code)).\n\(output)"
            if output.contains("No space left on device") {
                message += "\n\nThis usually means the disk (or the volume used for DerivedData) is full. Empty Trash, remove old Xcode DerivedData (~/Library/Developer/Xcode/DerivedData), Simulator data, or large downloads, then try again."
            }
            if output.localizedCaseInsensitiveContains("requires a development team")
                || output.localizedCaseInsensitiveContains("No signing certificate")
                || output.localizedCaseInsensitiveContains("provisioning profile")
            {
                message += "\n\nSigning setup is missing for this target. In Xcode, open the app target -> Signing & Capabilities, choose your Team, ensure a matching bundle identifier, and plug in/unlock the device with Developer Mode enabled. Then run Build & Run again."
            }
            return message
        case .noBuiltApp:
            return "Build finished but no .app was found under DerivedData."
        case .missingBundleId:
            return "Could not read CFBundleIdentifier from the built app."
        case .processLaunch(let msg):
            return msg
        case .insufficientDiskSpace(let available, let minimum, let volumePath):
            return "Not enough free disk space to run an Xcode build on the volume containing DerivedData (\(volumePath)). About \(available) is available; Lattice suggests at least \(minimum) free for typical iOS builds. Free space on your Mac or move the project to a volume with more room, then try again."
        case .xcodeApplicationMissing:
            return "Could not find Xcode. Install it from the Mac App Store, or ensure Xcode is in /Applications with bundle ID com.apple.dt.Xcode."
        }
    }
}

// MARK: - Locator + list

enum XcodeBuildTarget {
    case workspace(URL)
    case project(URL)

    var listArguments: [String] {
        switch self {
        case .workspace(let url):
            return ["-list", "-json", "-workspace", url.path]
        case .project(let url):
            return ["-list", "-json", "-project", url.path]
        }
    }

    var buildPrefix: [String] {
        switch self {
        case .workspace(let url):
            return ["-workspace", url.path]
        case .project(let url):
            return ["-project", url.path]
        }
    }
}

enum SimulatorBuildRunner {
    private static let xcodebuild = "/usr/bin/xcodebuild"

    /// Conservative floor before invoking `xcodebuild` (iOS builds often need far more at peak).
    private static let minimumFreeBytesBeforeBuild: Int64 = 512 * 1024 * 1024

    private static let subprocessEnvironment: [String: String] = {
        let standard = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let merged = (standard + existing.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, p in
                if !acc.contains(p) { acc.append(p) }
            }
            .joined(separator: ":")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = merged
        return env
    }()

    /// Prefer Xcode’s DerivedData under the user home (same convention as Xcode, usually on the main APFS volume with ample space). Falls back to the system temporary directory if that folder cannot be created (e.g. permissions).
    private static func makeEmptyDerivedDataDirectory() throws -> URL {
        let fm = FileManager.default
        let xcodeDerivedRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)

        do {
            try fm.createDirectory(at: xcodeDerivedRoot, withIntermediateDirectories: true)
            let derived = xcodeDerivedRoot.appendingPathComponent("LatticePlay-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: derived, withIntermediateDirectories: true)
            do {
                try assertEnoughDiskSpace(forBuildArtifactsAt: derived)
                return derived
            } catch {
                try? fm.removeItem(at: derived)
                throw error
            }
        } catch let error as SimulatorBuildRunnerError {
            throw error
        } catch {
            let derived = fm.temporaryDirectory.appendingPathComponent("LatticeDerived-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: derived, withIntermediateDirectories: true)
            do {
                try assertEnoughDiskSpace(forBuildArtifactsAt: derived)
                return derived
            } catch {
                try? fm.removeItem(at: derived)
                throw error
            }
        }
    }

    private static func assertEnoughDiskSpace(forBuildArtifactsAt url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values.volumeAvailableCapacityForImportantUsage else { return }

        guard free >= minimumFreeBytesBeforeBuild else {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let availableDescription = formatter.string(fromByteCount: free)
            let minimumDescription = formatter.string(fromByteCount: minimumFreeBytesBeforeBuild)
            throw SimulatorBuildRunnerError.insufficientDiskSpace(
                availableDescription: availableDescription,
                minimumDescription: minimumDescription,
                volumePath: url.path
            )
        }
    }

    static func resolveXcodeTarget(projectRoot: URL) throws -> XcodeBuildTarget {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw SimulatorBuildRunnerError.noXcodeProject(in: projectRoot.path)
        }

        if projectRoot.pathExtension == "xcodeproj" {
            return .project(projectRoot)
        }
        if projectRoot.pathExtension == "xcworkspace" {
            return .workspace(projectRoot)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let workspaces = contents.filter { $0.pathExtension == "xcworkspace" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let ws = workspaces.first {
            return .workspace(ws)
        }

        let projects = contents.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let proj = projects.first {
            return .project(proj)
        }

        throw SimulatorBuildRunnerError.noXcodeProject(in: projectRoot.path)
    }

    @MainActor
    static func openProjectInXcode(projectRoot: URL) async throws {
        let target = try resolveXcodeTarget(projectRoot: projectRoot)
        let fileURL: URL
        switch target {
        case .workspace(let url):
            fileURL = url
        case .project(let url):
            fileURL = url
        }

        guard let xcodeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            throw SimulatorBuildRunnerError.xcodeApplicationMissing
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: xcodeURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func listSchemes(target: XcodeBuildTarget) async throws -> [String] {
        let (out, err, status) = await runProcess(executable: xcodebuild, arguments: target.listArguments, directory: nil)
        guard status == 0 else {
            throw SimulatorBuildRunnerError.listSchemesFailed((err + "\n" + out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SimulatorBuildRunnerError.listSchemesFailed("Invalid JSON from xcodebuild -list")
        }

        if let workspace = root["workspace"] as? [String: Any],
           let schemes = workspace["schemes"] as? [String] {
            return schemes
        }
        if let project = root["project"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes
        }

        throw SimulatorBuildRunnerError.listSchemesFailed("No schemes key in xcodebuild -list output")
    }

    static func showBuildSettings(
        target: XcodeBuildTarget,
        scheme: String,
        projectRoot: URL
    ) async throws -> String {
        var args = target.buildPrefix
        args += ["-scheme", scheme, "-showBuildSettings"]
        let (out, err, status) = await runProcess(executable: xcodebuild, arguments: args, directory: projectRoot.path)
        let combined = [out, err].joined(separator: "\n")
        guard status == 0, !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimulatorBuildRunnerError.listSchemesFailed("Unable to inspect build settings for scheme \(scheme).")
        }
        return combined
    }

    static func detectSupportedRunDestinations(
        projectRoot: URL,
        buildInfo: BuildInfo?
    ) async throws -> Set<LatticeLocalRunDestination> {
        let xcodeTarget = try resolveXcodeTarget(projectRoot: projectRoot)
        let schemes = try await listSchemes(target: xcodeTarget)
        guard let scheme = pickScheme(schemes: schemes, buildInfo: buildInfo, projectRoot: projectRoot, xcodeTarget: xcodeTarget) else {
            return [.macOS]
        }
        let settings = try await showBuildSettings(target: xcodeTarget, scheme: scheme, projectRoot: projectRoot)
        let lines = settings.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var platformTokens: Set<String> = []
        var sdkRootTokens: Set<String> = []
        for line in lines {
            guard let idx = line.firstIndex(of: "=") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "SUPPORTED_PLATFORMS" || key == "PLATFORM_NAME" || key == "EFFECTIVE_PLATFORM_NAME" {
                for token in value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }) where !token.isEmpty {
                    platformTokens.insert(String(token))
                }
            }
            if key == "SDKROOT" {
                sdkRootTokens.insert(value)
            }
        }

        let joined = (platformTokens.union(sdkRootTokens)).joined(separator: " ")
        var supported: Set<LatticeLocalRunDestination> = []
        if joined.contains("iphoneos") || joined.contains("iphonesimulator") || joined.contains("ios") {
            supported.insert(.iOSSimulator)
            supported.insert(.iOSDevice)
        }
        if joined.contains("watchsimulator") || joined.contains("watchos") {
            supported.insert(.watchOSSimulator)
        }
        if joined.contains("macosx") || joined.contains("macos") {
            supported.insert(.macOS)
        }
        return supported.isEmpty ? [.macOS] : supported
    }

    static func discoverDevelopmentTeams(
        projectRoot: URL,
        buildInfo: BuildInfo?
    ) async throws -> [String] {
        let xcodeTarget = try resolveXcodeTarget(projectRoot: projectRoot)
        let schemes = try await listSchemes(target: xcodeTarget)
        guard let scheme = pickScheme(schemes: schemes, buildInfo: buildInfo, projectRoot: projectRoot, xcodeTarget: xcodeTarget) else {
            return []
        }
        let settings = try await showBuildSettings(target: xcodeTarget, scheme: scheme, projectRoot: projectRoot)
        let lines = settings.split(separator: "\n")
        var teams: Set<String> = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("DEVELOPMENT_TEAM") else { continue }
            guard let idx = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value != "YES", value != "NO" {
                teams.insert(value)
            }
        }
        return teams.sorted()
    }

    static func pickScheme(
        schemes: [String],
        buildInfo: BuildInfo?,
        projectRoot: URL,
        xcodeTarget: XcodeBuildTarget
    ) -> String? {
        guard !schemes.isEmpty else { return nil }

        let targetPath: String
        switch xcodeTarget {
        case .workspace(let u): targetPath = u.path
        case .project(let u): targetPath = u.path
        }

        if let info = buildInfo,
           pathsMatch(info.projectPath, targetPath),
           schemes.contains(info.schemeName) {
            return info.schemeName
        }

        let folderName = projectRoot.lastPathComponent
        if let match = schemes.first(where: { $0.caseInsensitiveCompare(folderName) == .orderedSame }) {
            return match
        }

        return schemes.first
    }

    private static func pathsMatch(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
            || a == b
            || (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    // MARK: - Run

    /// Builds for the selected destination and installs/launches locally. Does not use the LLM or chat.
    static func run(
        projectRoot: URL,
        destination: LatticeLocalRunDestination,
        simulatorUDID: String?,
        buildInfo: BuildInfo?,
        developmentTeam: String? = nil,
        bundleIdentifierOverride: String? = nil,
        /// Full xcodebuild stdout+stderr (trimmed) for local consoles / diagnostics.
        buildLogHandler: ((String) -> Void)? = nil
    ) async throws -> String {
        let xcodeTarget = try resolveXcodeTarget(projectRoot: projectRoot)
        let schemes = try await listSchemes(target: xcodeTarget)
        guard let scheme = pickScheme(schemes: schemes, buildInfo: buildInfo, projectRoot: projectRoot, xcodeTarget: xcodeTarget) else {
            throw SimulatorBuildRunnerError.noSchemes
        }

        let derived = try makeEmptyDerivedDataDirectory()

        defer {
            try? FileManager.default.removeItem(at: derived)
        }

        let simUDID: String
        let xcodeDestination: String
        let sdkFragment: String

        switch destination {
        case .iOSSimulator:
            guard let u = simulatorUDID, !u.isEmpty else {
                throw SimulatorBuildRunnerError.processLaunch("Select an iOS simulator for Build & Run.")
            }
            simUDID = u
            xcodeDestination = "platform=iOS Simulator,id=\(u)"
            sdkFragment = "iphonesimulator"
            await prepareSimulatorForLaunch(simUDID)
        case .iOSDevice:
            guard let u = simulatorUDID, !u.isEmpty else {
                throw SimulatorBuildRunnerError.processLaunch("Select a connected iPhone/iPad for Build & Run.")
            }
            simUDID = u
            xcodeDestination = "id=\(u)"
            sdkFragment = "iphoneos"
        case .watchOSSimulator:
            guard let u = simulatorUDID, !u.isEmpty else {
                throw SimulatorBuildRunnerError.processLaunch("Select a watchOS simulator for Build & Run.")
            }
            simUDID = u
            xcodeDestination = "platform=watchOS Simulator,id=\(u)"
            sdkFragment = "watchsimulator"
            await prepareSimulatorForLaunch(simUDID)
        case .macOS:
            simUDID = ""
            xcodeDestination = "platform=macOS"
            sdkFragment = "macosx"
        }

        var buildArgs = xcodeTarget.buildPrefix
        buildArgs += [
            "-scheme", scheme,
            "-destination", xcodeDestination,
            "-derivedDataPath", derived.path,
            "-configuration", "Debug",
            "CODE_SIGNING_ALLOWED=YES",
            "build",
        ]
        let team = developmentTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !team.isEmpty {
            buildArgs.insert("DEVELOPMENT_TEAM=\(team)", at: buildArgs.count - 1)
        }
        let bundleOverride = bundleIdentifierOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !bundleOverride.isEmpty {
            buildArgs.insert("PRODUCT_BUNDLE_IDENTIFIER=\(bundleOverride)", at: buildArgs.count - 1)
        }

        let (buildOut, buildErr, code) = await runProcess(
            executable: xcodebuild,
            arguments: buildArgs,
            directory: projectRoot.path
        )
        let combined = [buildOut, buildErr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let buildLogHandler {
            await MainActor.run {
                buildLogHandler(combined)
            }
        }
        guard code == 0 else {
            throw SimulatorBuildRunnerError.xcodebuildFailed(exitCode: code, output: combined)
        }

        let appURL = try findBuiltApp(derivedData: derived, sdkFragment: sdkFragment)
        let bundleId = try bundleIdentifier(of: appURL)

        switch destination {
        case .iOSSimulator, .watchOSSimulator:
            let (_, installErr, installCode) = await runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "install", simUDID, appURL.path],
                directory: nil
            )
            guard installCode == 0 else {
                throw SimulatorBuildRunnerError.processLaunch("simctl install failed: \(installErr)")
            }

            let (launchOut, launchErr, launchCode) = await runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "launch", simUDID, bundleId],
                directory: nil
            )
            guard launchCode == 0 else {
                throw SimulatorBuildRunnerError.processLaunch("simctl launch failed: \(launchErr)\n\(launchOut)")
            }
            let tail = combined.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "Launched \(bundleId) on simulator \(simUDID) (scheme \(scheme)).\n\(tail)"
        case .iOSDevice:
            let (_, installErr, installCode) = await runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["devicectl", "device", "install", "app", "--device", simUDID, appURL.path],
                directory: nil
            )
            guard installCode == 0 else {
                throw SimulatorBuildRunnerError.processLaunch("devicectl install failed: \(installErr)")
            }

            let (launchOut, launchErr, launchCode) = await runProcess(
                executable: "/usr/bin/xcrun",
                arguments: ["devicectl", "device", "process", "launch", "--device", simUDID, bundleId],
                directory: nil
            )
            guard launchCode == 0 else {
                throw SimulatorBuildRunnerError.processLaunch("devicectl launch failed: \(launchErr)\n\(launchOut)")
            }
            let tail = combined.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "Launched \(bundleId) on device \(simUDID) (scheme \(scheme)).\n\(tail)"
        case .macOS:
            guard NSWorkspace.shared.open(appURL) else {
                throw SimulatorBuildRunnerError.processLaunch("Could not open built app at \(appURL.path)")
            }
            let tail = combined.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "Built \(bundleId) for macOS and opened \(appURL.lastPathComponent) (scheme \(scheme)).\n\(tail)"
        }
    }

    private static func findBuiltApp(derivedData: URL, sdkFragment: String) throws -> URL {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        guard FileManager.default.fileExists(atPath: products.path) else {
            throw SimulatorBuildRunnerError.noBuiltApp
        }

        // macOS `.app` bundles usually live at `Build/Products/Debug/App.app` without `macosx` in the path.
        if sdkFragment == "macosx" {
            return try findMacOSBuiltApp(products: products)
        }

        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: products, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                let path = url.path
                let matchesSDK: Bool
                if sdkFragment == "iphonesimulator" {
                    matchesSDK = path.contains("iphonesimulator") || path.contains("iPhoneSimulator")
                } else {
                    matchesSDK = path.contains(sdkFragment)
                }
                guard matchesSDK else { continue }
                let parent = url.deletingLastPathComponent().path
                if parent.contains(".app/") { continue }
                candidates.append(url)
            }
        }

        guard let app = candidates.sorted(by: { $0.path.count < $1.path.count }).first else {
            throw SimulatorBuildRunnerError.noBuiltApp
        }
        return app
    }

    /// Picks the host `.app` after a macOS `xcodebuild` (paths rarely contain the substring `macosx`).
    private static func findMacOSBuiltApp(products: URL) throws -> URL {
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: products, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                let parent = url.deletingLastPathComponent().path
                if parent.contains(".app/") { continue }
                candidates.append(url)
            }
        }
        guard !candidates.isEmpty else {
            throw SimulatorBuildRunnerError.noBuiltApp
        }

        func score(_ url: URL) -> Int {
            let p = url.path
            var s = 0
            if p.contains("/Debug/") || p.contains("/Debug-") { s += 100 }
            if p.localizedCaseInsensitiveContains("macosx") { s += 40 }
            if p.contains("/Release/") || p.contains("/Release-") { s += 20 }
            return s
        }

        let sorted = candidates.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            return a.path.count < b.path.count
        }
        return sorted[0]
    }

    private static func bundleIdentifier(of app: URL) throws -> String {
        // Standard bundles (macOS/iOS/watchOS) store Info.plist at `App.app/Contents/Info.plist`.
        let plistURLs = [
            app.appendingPathComponent("Contents/Info.plist"),
            app.appendingPathComponent("Info.plist"),
        ]
        for plist in plistURLs {
            guard FileManager.default.fileExists(atPath: plist.path),
                  let dict = NSDictionary(contentsOf: plist) as? [String: Any],
                  let bid = dict["CFBundleIdentifier"] as? String,
                  !bid.isEmpty
            else { continue }
            return bid
        }
        throw SimulatorBuildRunnerError.missingBundleId
    }

    private static func prepareSimulatorForLaunch(_ simUDID: String) async {
        _ = await runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", simUDID],
            directory: nil
        )
        _ = await runProcess(
            executable: "/usr/bin/open",
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", simUDID],
            directory: nil
        )
        _ = await runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", simUDID, "-b"],
            directory: nil
        )
    }

    // MARK: - Subprocess (no waitUntilExit — terminationHandler + continuation)

    private static func runProcess(executable: String, arguments: [String], directory: String?) async -> (stdout: String, stderr: String, status: Int32) {
        await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var hasResumed = false
            func resumeOnce(_ value: (String, String, Int32)) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }

            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                proc.environment = subprocessEnvironment
                if let directory {
                    proc.currentDirectoryURL = URL(fileURLWithPath: directory)
                }

                let base = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LatticeSub-\(UUID().uuidString)", isDirectory: false)
                let outURL = URL(fileURLWithPath: base.path + ".out.log")
                let errURL = URL(fileURLWithPath: base.path + ".err.log")
                FileManager.default.createFile(atPath: outURL.path, contents: nil)
                FileManager.default.createFile(atPath: errURL.path, contents: nil)

                var outHandle: FileHandle?
                var errHandle: FileHandle?

                proc.terminationHandler = { process in
                    try? outHandle?.close()
                    try? errHandle?.close()
                    let outStr = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                    let errStr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)
                    resumeOnce((outStr, errStr, process.terminationStatus))
                }

                do {
                    outHandle = try FileHandle(forWritingTo: outURL)
                    errHandle = try FileHandle(forWritingTo: errURL)
                    proc.standardOutput = outHandle
                    proc.standardError = errHandle
                    proc.standardInput = FileHandle.nullDevice
                    try proc.run()
                } catch {
                    try? outHandle?.close()
                    try? errHandle?.close()
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.removeItem(at: errURL)
                    resumeOnce(("", error.localizedDescription, -1))
                }
            }
        }
    }
}
