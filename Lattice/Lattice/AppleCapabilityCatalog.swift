import Foundation

/// The set of Apple platforms a capability can apply to.
enum ApplePlatform: String, CaseIterable {
    case iOS
    case macOS
    case watchOS
}

/// A single entitlement key/value pair to merge into the `.entitlements` plist.
struct EntitlementEntry: Equatable {
    let key: String
    let value: EntitlementValue
}

/// The shape of an entitlement value. Matches what plist serialization accepts.
enum EntitlementValue: Equatable {
    case string(String)
    case stringArray([String])
    case boolean(Bool)
    case placeholder(String) // "$(AppGroupIdentifier)" resolved at apply time

    /// The value as it should be written into the entitlements plist.
    var plistValue: Any {
        switch self {
        case .string(let s): return s
        case .stringArray(let a): return a
        case .boolean(let b): return b
        case .placeholder(let p): return p
        }
    }
}

/// A single Info.plist key/value pair.
///
/// `value` is `Any` because an Info.plist value may be a string, an array, a
/// boolean, a number, or a dictionary. To support deferred resolution of build-
/// parameters (e.g. `$(AppGroupIdentifier)`), the applicator (Task 4) inspects
/// the concrete type at apply time. The convention is:
///   - A `String` whose contents start with `$(` is a *placeholder* to be
///     resolved from the supplied parameters before writing.
///   - Any other value is written verbatim.
///
/// NOTE: Equatable only compares `key` (value is Any). This is intentional —
/// callers compare by key when checking presence.
struct PlistEntry: Equatable {
    let key: String
    let value: Any

    static func == (lhs: PlistEntry, rhs: PlistEntry) -> Bool {
        lhs.key == rhs.key
    }
}

/// A starter file the applicator writes into the project when a capability is applied.
/// Seed files are created only when missing — the applicator never overwrites user edits,
/// and removal never deletes them.
struct CapabilitySeedFile: Equatable {
    /// Path relative to the project root. Supports the `$(AppName)` placeholder.
    let relativePath: String
    /// File contents, written verbatim.
    let contents: String
}

/// A complete description of an Apple capability's file-side requirements.
/// Pure data — no I/O. The applicator consumes it.
struct AppleCapability: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let entitlements: [EntitlementEntry]
    let infoPlistKeys: [PlistEntry]
    let frameworks: [String]
    var seedFiles: [CapabilitySeedFile]
    let provisioningNotes: String?
    let applicablePlatforms: Set<ApplePlatform>
}

/// The single source of truth for supported capabilities.
/// Adding a capability = adding a static constant + an `all` entry.
enum AppleCapabilityCatalog {
    static let appGroups = AppleCapability(
        id: "app_groups",
        displayName: "App Groups",
        summary: "Share data between your app and its extensions via a shared container.",
        entitlements: [
            EntitlementEntry(
                key: "com.apple.security.application-groups",
                value: .placeholder("$(AppGroupIdentifier)")
            )
        ],
        infoPlistKeys: [],
        frameworks: [],
        seedFiles: [],
        provisioningNotes: "Create the App Group in the Apple Developer Portal (Identifiers → App Groups), then enable it under Xcode → Signing & Capabilities for your app and any extensions that share it.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let pushNotifications = AppleCapability(
        id: "push_notifications",
        displayName: "Push Notifications",
        summary: "Receive remote notifications via APNs.",
        entitlements: [
            EntitlementEntry(
                key: "aps-environment",
                value: .placeholder("$(APSEnvironment)")
            )
        ],
        infoPlistKeys: [
            PlistEntry(key: "UIBackgroundModes", value: ["remote-notification"])
        ],
        frameworks: ["UserNotifications.framework"],
        seedFiles: [],
        provisioningNotes: "Enable the Push Notifications capability in the Apple Developer Portal for your App ID, and upload an APNs authentication key (or certificate) at developer.apple.com → Account → Certificates, Identifiers & Profiles → Keys.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let storekit = AppleCapability(
        id: "storekit",
        displayName: "StoreKit",
        summary: "Sell in-app purchases and subscriptions using StoreKit 2.",
        entitlements: [],
        infoPlistKeys: [],
        frameworks: ["StoreKit.framework"],
        seedFiles: [],
        provisioningNotes: "Configure your in-app purchases and subscriptions in App Store Connect → Your App → In-App Purchases. No entitlement key is required, but the In-App Purchase capability must be enabled for your App ID in the Developer Portal.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let keychainSharing = AppleCapability(
        id: "keychain_sharing",
        displayName: "Keychain Sharing",
        summary: "Share keychain items between apps from the same team.",
        entitlements: [
            EntitlementEntry(
                key: "keychain-access-groups",
                value: .placeholder("$(KeychainAccessGroup)")
            )
        ],
        infoPlistKeys: [],
        frameworks: [],
        seedFiles: [],
        provisioningNotes: "Enable the Keychain Sharing capability in Xcode → Signing & Capabilities. The access group prefix $(AppIdentifierPrefix) is replaced at build time with your team's identifier.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let backgroundModes = AppleCapability(
        id: "background_modes",
        displayName: "Background Modes",
        summary: "Declare the background tasks your app needs to run.",
        entitlements: [],
        infoPlistKeys: [
            PlistEntry(key: "UIBackgroundModes", value: "$(UIBackgroundModes)")
        ],
        frameworks: [],
        seedFiles: [],
        provisioningNotes: nil,
        applicablePlatforms: [.iOS]
    )

    static let swiftdata = AppleCapability(
        id: "swiftdata",
        displayName: "SwiftData (Local Database)",
        summary: "Persist app data locally with SwiftData — models, relationships, and queries.",
        entitlements: [],
        infoPlistKeys: [],
        frameworks: ["SwiftData.framework"],
        seedFiles: [
            CapabilitySeedFile(
                relativePath: "$(AppName)/SampleData.swift",
                contents: """
                import Foundation
                import SwiftData

                // Starter model for SwiftData. Rename it, add properties, or add more
                // @Model classes — SwiftData persists them automatically once a
                // ModelContainer is attached (usually via .modelContainer(...) on the
                // App struct or your root view).
                @Model
                final class SampleItem {
                    var title: String
                    var detail: String
                    var createdAt: Date
                    var isFavorite: Bool

                    init(title: String, detail: String = "", createdAt: Date = .now, isFavorite: Bool = false) {
                        self.title = title
                        self.detail = detail
                        self.createdAt = createdAt
                        self.isFavorite = isFavorite
                    }
                }
                """
            )
        ],
        provisioningNotes: nil,
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let cloudkitSync = AppleCapability(
        id: "cloudkit_sync",
        displayName: "iCloud Sync (CloudKit)",
        summary: "Sync app data across the user's devices via iCloud (CloudKit), incl. SwiftData sync.",
        entitlements: [
            EntitlementEntry(
                key: "com.apple.developer.icloud-services",
                value: .stringArray(["CloudKit"])
            ),
            EntitlementEntry(
                key: "com.apple.developer.icloud-container-identifiers",
                value: .placeholder("$(iCloudContainerIdentifiers)")
            )
        ],
        infoPlistKeys: [
            PlistEntry(key: "UIBackgroundModes", value: ["remote-notification"])
        ],
        frameworks: ["CloudKit.framework"],
        seedFiles: [],
        provisioningNotes: "Enable iCloud (CloudKit) for your App ID in the Apple Developer Portal, then pick or create the container under Xcode → Signing & Capabilities → iCloud. Devices must be signed into iCloud for syncing to work.",
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let healthkit = AppleCapability(
        id: "healthkit",
        displayName: "HealthKit",
        summary: "Read and write health data — workouts, steps, heart rate, sleep, and more.",
        entitlements: [
            EntitlementEntry(
                key: "com.apple.developer.healthkit",
                value: .boolean(true)
            )
        ],
        infoPlistKeys: [
            PlistEntry(key: "NSHealthShareUsageDescription", value: "$(HealthShareUsageDescription)"),
            PlistEntry(key: "NSHealthUpdateUsageDescription", value: "$(HealthUpdateUsageDescription)")
        ],
        frameworks: ["HealthKit.framework"],
        seedFiles: [],
        provisioningNotes: "Enable HealthKit for your App ID in the Apple Developer Portal. The app must request user permission for each data type at runtime via HKHealthStore.requestAuthorization.",
        applicablePlatforms: [.iOS]
    )

    static let appIntents = AppleCapability(
        id: "app_intents",
        displayName: "Siri & Shortcuts (App Intents)",
        summary: "Expose app actions to Siri, Shortcuts, Spotlight, and the Action Button.",
        entitlements: [],
        infoPlistKeys: [
            PlistEntry(key: "NSSiriUsageDescription", value: "$(SiriUsageDescription)")
        ],
        frameworks: [],
        seedFiles: [
            CapabilitySeedFile(
                relativePath: "$(AppName)/SampleIntents.swift",
                contents: """
                import AppIntents

                // Starter App Intents. Each AppIntent is an action users can run from
                // Siri, Shortcuts, Spotlight, or the Action Button. Add more intents
                // or parameters as needed — they are discovered automatically.
                struct AddTaskIntent: AppIntent {
                    static var title: LocalizedStringResource = "Add Task"
                    static var description = IntentDescription("Adds a task to the app.")

                    @Parameter(title: "Task name")
                    var taskName: String

                    static var parameterSummary: some ParameterSummary {
                        Summary("Add \\(\\.$taskName)")
                    }

                    @MainActor
                    func perform() async throws -> some IntentResult & ProvidesDialog {
                        // TODO: insert the task into your data store (e.g. SwiftData).
                        return .result(dialog: "Added \\(taskName)")
                    }
                }

                struct OpenAppIntent: AppIntent {
                    static var title: LocalizedStringResource = "Open App"
                    static var openAppWhenRun = true

                    @MainActor
                    func perform() async throws -> some IntentResult {
                        return .result()
                    }
                }
                """
            )
        ],
        provisioningNotes: nil,
        applicablePlatforms: [.iOS, .macOS, .watchOS]
    )

    static let widgets = AppleCapability(
        id: "widgets",
        displayName: "Home Screen Widgets",
        summary: "Add a WidgetKit extension target with a starter widget for the Home Screen.",
        entitlements: [],
        infoPlistKeys: [],
        frameworks: ["WidgetKit.framework"],
        seedFiles: [
            CapabilitySeedFile(
                relativePath: "$(AppName)Widgets/$(AppName)WidgetsBundle.swift",
                contents: """
                import WidgetKit
                import SwiftUI

                // Starter widget. Add more Widget types to the bundle below, give them
                // timelines from your app's data (e.g. SwiftData via an app group), and
                // customize the view. Widgets reload on their own schedule.

                struct SampleEntry: TimelineEntry {
                    let date: Date
                }

                struct SampleProvider: TimelineProvider {
                    func placeholder(in context: Context) -> SampleEntry {
                        SampleEntry(date: .now)
                    }

                    func getSnapshot(in context: Context, completion: @escaping (SampleEntry) -> Void) {
                        completion(SampleEntry(date: .now))
                    }

                    func getTimeline(in context: Context, completion: @escaping (Timeline<SampleEntry>) -> Void) {
                        let entries = [SampleEntry(date: .now)]
                        completion(Timeline(entries: entries, policy: .atEnd))
                    }
                }

                struct SampleWidgetView: View {
                    var entry: SampleEntry

                    var body: some View {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.tint)
                            Text("Hello from the widget!")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.date, style: .time)
                                .font(.title3.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding()
                    }
                }

                struct SampleWidget: Widget {
                    var body: some WidgetConfiguration {
                        StaticConfiguration(kind: "SampleWidget", provider: SampleProvider.self) { entry in
                            SampleWidgetView(entry: entry)
                        }
                        .configurationDisplayName("Sample Widget")
                        .description("A starter widget you can customize.")
                        .supportedFamilies([.systemSmall, .systemMedium])
                    }
                }

                @main
                struct SampleWidgetBundle: WidgetBundle {
                    var body: some Widget {
                        SampleWidget()
                    }
                }
                """
            ),
            CapabilitySeedFile(
                relativePath: "$(AppName)Widgets/Info.plist",
                contents: """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>CFBundleDevelopmentRegion</key>
                    <string>$(DEVELOPMENT_LANGUAGE)</string>
                    <key>CFBundleDisplayName</key>
                    <string>Widgets</string>
                    <key>CFBundleExecutable</key>
                    <string>$(EXECUTABLE_NAME)</string>
                    <key>CFBundleIdentifier</key>
                    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
                    <key>CFBundleInfoDictionaryVersion</key>
                    <string>6.0</string>
                    <key>CFBundleName</key>
                    <string>$(PRODUCT_NAME)</string>
                    <key>CFBundlePackageType</key>
                    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
                    <key>CFBundleShortVersionString</key>
                    <string>1.0</string>
                    <key>CFBundleVersion</key>
                    <string>1</string>
                    <key>NSExtension</key>
                    <dict>
                        <key>NSExtensionPointIdentifier</key>
                        <string>com.apple.widgetkit-extension</string>
                    </dict>
                </dict>
                </plist>
                """
            ),
        ],
        provisioningNotes: "The widget extension is a separate target that archives together with the app — TestFlight uploads include it automatically.",
        applicablePlatforms: [.iOS, .macOS]
    )

    /// All supported capabilities, in display order.
    static let all: [AppleCapability] = [
        appGroups,
        pushNotifications,
        storekit,
        keychainSharing,
        backgroundModes,
        swiftdata,
        cloudkitSync,
        healthkit,
        appIntents,
        widgets,
    ]

    /// Look up a capability by id. Returns nil if unknown.
    static func capability(id: String) -> AppleCapability? {
        all.first { $0.id == id }
    }
}
