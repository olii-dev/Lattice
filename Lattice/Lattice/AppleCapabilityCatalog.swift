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

/// A complete description of an Apple capability's file-side requirements.
/// Pure data — no I/O. The applicator consumes it.
struct AppleCapability: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let entitlements: [EntitlementEntry]
    let infoPlistKeys: [PlistEntry]
    let frameworks: [String]
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
        provisioningNotes: nil,
        applicablePlatforms: [.iOS]
    )

    /// All supported capabilities, in display order.
    static let all: [AppleCapability] = [
        appGroups,
        pushNotifications,
        storekit,
        keychainSharing,
        backgroundModes,
    ]

    /// Look up a capability by id. Returns nil if unknown.
    static func capability(id: String) -> AppleCapability? {
        all.first { $0.id == id }
    }
}
