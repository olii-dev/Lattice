import AppKit
import SwiftUI

/// Atmospheric window background shared by the project hub, main chat, and Settings.
struct LatticeWindowBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.07, green: 0.07, blue: 0.09)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }

            if !reduceMotion {
                RadialGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )
                RadialGradient(
                    colors: [Color.teal.opacity(colorScheme == .dark ? 0.12 : 0.1), .clear],
                    center: .bottomTrailing,
                    startRadius: 40,
                    endRadius: 520
                )
                LinearGradient(
                    colors: [
                        Color.purple.opacity(colorScheme == .dark ? 0.08 : 0.05),
                        .clear,
                        Color.blue.opacity(colorScheme == .dark ? 0.06 : 0.04),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottom
                )
            }
        }
    }
}
