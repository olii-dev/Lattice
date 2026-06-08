import Foundation

struct SimulatorOption: Identifiable, Hashable {
    let id: String
    let name: String
    let runtime: String

    var label: String {
        "\(name) (\(runtime))"
    }

    enum RunPlatformFilter {
        case iOS
        case watchOS
    }

    /// Classify from the human-readable runtime string produced by `SimulatorStore` (e.g. "iOS 26", "watchOS 26").
    func matches(filter: RunPlatformFilter) -> Bool {
        let r = runtime.lowercased()
        switch filter {
        case .iOS:
            return r.contains("ios") && !r.contains("watch")
        case .watchOS:
            return r.contains("watchos") || r.contains("watch os")
        }
    }
}

struct ConnectedDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: String

    var label: String {
        "\(name) (\(platform))"
    }

    /// Physical Apple Watch devices report a watchOS version in the platform string from `xctrace list devices`.
    var isAppleWatch: Bool {
        platform.lowercased().contains("watch")
    }

    /// SF Symbol for menus / context bar (watch vs iPhone/iPad).
    var menuSymbolName: String {
        isAppleWatch ? "applewatch" : "iphone.gen3"
    }
}

/// Where local Build & Run sends `xcodebuild` and how the product is launched.
enum LatticeLocalRunDestination: String, CaseIterable, Identifiable {
    case iOSSimulator
    case iOSDevice
    case watchOSSimulator
    case macOS

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .iOSSimulator: return "iOS Simulator"
        case .iOSDevice: return "Connected iPhone/iPad"
        case .watchOSSimulator: return "watchOS Simulator"
        case .macOS: return "My Mac (macOS)"
        }
    }

    var toolbarSummary: String {
        switch self {
        case .iOSSimulator: return "iOS"
        case .iOSDevice: return "Device"
        case .watchOSSimulator: return "watchOS"
        case .macOS: return "Mac"
        }
    }
}

extension Set where Element == LatticeLocalRunDestination {
    static var allRunDestinations: Set<LatticeLocalRunDestination> {
        Set(LatticeLocalRunDestination.allCases)
    }
}





