import Foundation

/// Archives the project and uploads the build to App Store Connect (TestFlight)
/// using an App Store Connect API key. Auth follows the documented
/// `xcodebuild -exportArchive` authentication flags.
enum TestFlightPublisher {

    // MARK: - Credentials

    struct Credentials: Equatable {
        let keyPath: URL
        let keyID: String
        let issuerID: String
    }

    enum PublishError: LocalizedError {
        case missingCredentials
        case missingScheme
        case noArchivesProduced
        case commandFailed(step: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Add your App Store Connect API key first (Key ID, Issuer ID, and the .p8 file)."
            case .missingScheme:
                return "No scheme was selected."
            case .noArchivesProduced:
                return "The archive step finished but produced no archive. Check the log for signing errors."
            case .commandFailed(let step, let detail):
                return "\(step) failed.\n\n\(detail)"
            }
        }
    }

    private static let keyIDDefaultsKey = "latticeASCKeyID"
    private static let issuerIDDefaultsKey = "latticeASCIssuerID"

    private static var keysDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lattice/AppStoreConnect", isDirectory: true)
    }

    /// Copies the .p8 into Application Support (mode 0600) and stores the identifiers.
    static func storeKey(from sourceURL: URL, keyID: String, issuerID: String) throws {
        let trimmedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIssuer = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyID.isEmpty, !trimmedIssuer.isEmpty else {
            throw PublishError.missingCredentials
        }
        let fm = FileManager.default
        try fm.createDirectory(at: keysDirectory, withIntermediateDirectories: true)
        let destination = keysDirectory.appendingPathComponent("AuthKey_\(trimmedKeyID).p8")
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceURL, to: destination)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        UserDefaults.standard.set(trimmedKeyID, forKey: keyIDDefaultsKey)
        UserDefaults.standard.set(trimmedIssuer, forKey: issuerIDDefaultsKey)
    }

    static func loadCredentials() -> Credentials? {
        let defaults = UserDefaults.standard
        guard let keyID = defaults.string(forKey: keyIDDefaultsKey),
              let issuerID = defaults.string(forKey: issuerIDDefaultsKey),
              !keyID.isEmpty, !issuerID.isEmpty
        else { return nil }
        let keyPath = keysDirectory.appendingPathComponent("AuthKey_\(keyID).p8")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return nil }
        return Credentials(keyPath: keyPath, keyID: keyID, issuerID: issuerID)
    }

    static func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: keyIDDefaultsKey)
        UserDefaults.standard.removeObject(forKey: issuerIDDefaultsKey)
        try? FileManager.default.removeItem(at: keysDirectory)
    }

    // MARK: - Export options (pure, testable)

    /// Builds the export options plist for a TestFlight upload.
    static func exportOptionsPlistData(teamID: String, destination: PublishDestination) throws -> Data {
        let options: [String: Any] = [
            "method": "app-store-connect",
            "destination": "upload",
            "signingStyle": "automatic",
            "uploadSymbols": true,
            "teamID": teamID,
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: options, format: .xml, options: 0
        )
        return plist
    }

    // MARK: - Commands (pure, testable)

    static func archiveArguments(
        target: String,
        scheme: String,
        destination: PublishDestination,
        archivePath: URL,
        teamID: String
    ) -> [String] {
        var args = ["archive", target, "-scheme", scheme, "-configuration", "Release"]
        args += ["-destination", destination.xcodebuildDestination]
        args += ["-archivePath", archivePath.path]
        args += ["-allowProvisioningUpdates"]
        args += ["DEVELOPMENT_TEAM=\(teamID)"]
        return args
    }

    static func uploadArguments(
        archivePath: URL,
        exportOptionsPath: URL,
        exportPath: URL,
        credentials: Credentials
    ) -> [String] {
        var args = ["-exportArchive", "-archivePath", archivePath.path]
        args += ["-exportOptionsPlist", exportOptionsPath.path]
        args += ["-exportPath", exportPath.path]
        args += ["-allowProvisioningUpdates"]
        args += ["-authenticationKeyPath", credentials.keyPath.path]
        args += ["-authenticationKeyID", credentials.keyID]
        args += ["-authenticationKeyIssuerID", credentials.issuerID]
        return args
    }

    // MARK: - Execution

    enum PublishDestination: String, CaseIterable, Identifiable {
        case ios
        case macOS

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ios: "iPhone / iPad"
            case .macOS: "Mac"
            }
        }

        var xcodebuildDestination: String {
            switch self {
            case .ios: "generic/platform=iOS"
            case .macOS: "generic/platform=macOS"
            }
        }
    }

    /// Streams each output line through `onLine` while the tool runs.
    private static func runXcodebuild(
        arguments: [String],
        projectRoot: URL?,
        onLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
                process.arguments = arguments
                if let projectRoot {
                    process.currentDirectoryURL = projectRoot
                }
                process.environment = SimulatorBuildRunner.subprocessEnvironment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                var buffer = Data()
                let bufferLock = NSLock()

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    bufferLock.lock()
                    buffer.append(chunk)
                    // Emit complete lines as they arrive.
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        bufferLock.unlock()
                        if let text = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            onLine(text)
                        }
                        bufferLock.lock()
                    }
                    bufferLock.unlock()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Int32(-1))
                    return
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                bufferLock.lock()
                if !buffer.isEmpty,
                   let text = String(data: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    onLine(text)
                }
                bufferLock.unlock()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Archives the project and uploads it to App Store Connect (TestFlight).
    /// Returns a human-readable summary on success.
    static func publish(
        projectRoot: URL,
        scheme: String,
        destination: PublishDestination,
        teamID: String,
        onLine: @escaping (String) -> Void
    ) async throws -> String {
        guard let credentials = loadCredentials() else {
            throw PublishError.missingCredentials
        }
        guard !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublishError.missingScheme
        }
        guard !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublishError.commandFailed(
                step: "Signing",
                detail: "No development team set. Add your Team ID in the sheet or Lattice Settings."
            )
        }

        let target: String
        if projectRoot.pathExtension == "xcodeproj" {
            target = "-project \(projectRoot.path)"
        } else if let workspace = findWorkspace(in: projectRoot) {
            target = "-workspace \(workspace.path)"
        } else {
            target = "-project \(projectRoot.path)"
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let archivePath = workDir.appendingPathComponent("LatticeUpload.xcarchive")
        let exportOptionsPath = workDir.appendingPathComponent("exportOptions.plist")
        let exportPath = workDir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportPath, withIntermediateDirectories: true)
        try exportOptionsPlistData(teamID: teamID, destination: destination)
            .write(to: exportOptionsPath, options: .atomic)

        onLine("Archiving (\(destination.label))…")
        let archiveStatus = try await runXcodebuild(
            arguments: archiveArguments(
                target: target, scheme: scheme, destination: destination,
                archivePath: archivePath, teamID: teamID
            ),
            projectRoot: projectRoot,
            onLine: onLine
        )
        guard archiveStatus == 0 else {
            throw PublishError.commandFailed(step: "Archive", detail: "See the log above (exit \(archiveStatus)).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archivePath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PublishError.noArchivesProduced
        }
        onLine("Archive created. Uploading to App Store Connect…")

        let uploadStatus = try await runXcodebuild(
            arguments: uploadArguments(
                archivePath: archivePath,
                exportOptionsPath: exportOptionsPath,
                exportPath: exportPath,
                credentials: credentials
            ),
            projectRoot: projectRoot,
            onLine: onLine
        )
        guard uploadStatus == 0 else {
            throw PublishError.commandFailed(step: "Upload", detail: "See the log above (exit \(uploadStatus)).")
        }

        try? FileManager.default.removeItem(at: workDir)
        return "Build uploaded. It will appear in App Store Connect → TestFlight within a few minutes."
    }

    private static func findWorkspace(in projectRoot: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: projectRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.first { $0.pathExtension == "xcworkspace" && !$0.lastPathComponent.hasPrefix("project") }
    }
}
