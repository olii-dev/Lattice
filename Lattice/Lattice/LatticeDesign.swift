import SwiftUI

// MARK: - Design tokens

/// Canonical values for the whole app. New UI should use these instead of raw
/// numbers so spacing, corners, and surfaces stay consistent.
enum LatticeDesign {
    /// Corner radii: cards (transcript/hub), panels (sheets/forms), controls (chips, inputs).
    enum Radius {
        static let card: CGFloat = 18
        static let panel: CGFloat = 14
        static let control: CGFloat = 10
    }

    /// Spacing scale: tight → relaxed.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Border opacities used for hairline strokes on translucent surfaces.
    enum Stroke {
        static let subtle: Double = 0.08
        static let soft: Double = 0.14
    }
}

// MARK: - Card

/// Unified card surface: translucent fill, hairline stroke, standard radius.
struct LatticeCardStyle: ViewModifier {
    var radius: CGFloat = LatticeDesign.Radius.panel
    var fillOpacity: Double = 0.04
    var strokeOpacity: Double = LatticeDesign.Stroke.subtle

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps content in the standard Lattice card surface.
    func latticeCard(
        radius: CGFloat = LatticeDesign.Radius.panel,
        fillOpacity: Double = 0.04,
        strokeOpacity: Double = LatticeDesign.Stroke.subtle
    ) -> some View {
        modifier(LatticeCardStyle(radius: radius, fillOpacity: fillOpacity, strokeOpacity: strokeOpacity))
    }
}

// MARK: - Chip

/// Unified pill chip: caption text + optional icon, used for phase chips,
/// platform badges, and status labels.
struct LatticeChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, LatticeDesign.Spacing.m)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Empty state

/// Standard empty-state block: large icon, headline, and one supporting line.
struct LatticeEmptyState: View {
    let systemImage: String
    let title: String
    var caption: String?
    var maxWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: maxWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, LatticeDesign.Spacing.xl)
    }
}
