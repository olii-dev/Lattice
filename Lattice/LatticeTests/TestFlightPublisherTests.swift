import Testing
import Foundation
@testable import Lattice

@Suite struct TestFlightPublisherTests {

    @Test func exportOptionsPlistHasUploadMethodAndTeam() throws {
        let data = try TestFlightPublisher.exportOptionsPlistData(teamID: "ABC1234567", destination: .ios)
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any])
        #expect(plist["method"] as? String == "app-store-connect")
        #expect(plist["destination"] as? String == "upload")
        #expect(plist["signingStyle"] as? String == "automatic")
        #expect(plist["teamID"] as? String == "ABC1234567")
        #expect(plist["uploadSymbols"] as? Bool == true)
    }

    @Test func archiveArgumentsAreWellFormed() throws {
        let archive = URL(fileURLWithPath: "/tmp/out.xcarchive")
        let args = TestFlightPublisher.archiveArguments(
            target: "-project /path/App.xcodeproj",
            scheme: "App",
            destination: .ios,
            archivePath: archive,
            teamID: "TEAMID1234"
        )
        #expect(args.contains("archive"))
        #expect(args.contains("-project /path/App.xcodeproj"))
        #expect(args.firstIndex(of: "-scheme").map { args[$0 + 1] == "App" } == true)
        #expect(args.firstIndex(of: "-destination").map { args[$0 + 1] == "generic/platform=iOS" } == true)
        #expect(args.contains("-allowProvisioningUpdates"))
        #expect(args.contains("DEVELOPMENT_TEAM=TEAMID1234"))
    }

    @Test func uploadArgumentsCarryAuthenticationFlags() throws {
        let credentials = TestFlightPublisher.Credentials(
            keyPath: URL(fileURLWithPath: "/tmp/AuthKey_ABC.p8"),
            keyID: "ABC",
            issuerID: "ISSUER-UUID"
        )
        let args = TestFlightPublisher.uploadArguments(
            archivePath: URL(fileURLWithPath: "/tmp/a.xcarchive"),
            exportOptionsPath: URL(fileURLWithPath: "/tmp/exportOptions.plist"),
            exportPath: URL(fileURLWithPath: "/tmp/export"),
            credentials: credentials
        )
        #expect(args.contains("-exportArchive"))
        #expect(args.firstIndex(of: "-authenticationKeyPath").map { args[$0 + 1].hasSuffix(".p8") } == true)
        #expect(args.firstIndex(of: "-authenticationKeyID").map { args[$0 + 1] == "ABC" } == true)
        #expect(args.firstIndex(of: "-authenticationKeyIssuerID").map { args[$0 + 1] == "ISSUER-UUID" } == true)
    }

    @Test func destinationValuesMatchXcodebuildSyntax() {
        #expect(TestFlightPublisher.PublishDestination.ios.xcodebuildDestination == "generic/platform=iOS")
        #expect(TestFlightPublisher.PublishDestination.macOS.xcodebuildDestination == "generic/platform=macOS")
    }

    @Test func loadCredentialsReturnsNilWhenUnset() {
        // No credentials stored in the test runner's defaults → nil, no crash.
        if UserDefaults.standard.string(forKey: "latticeASCKeyID") == nil {
            #expect(TestFlightPublisher.loadCredentials() == nil)
        }
    }
}
