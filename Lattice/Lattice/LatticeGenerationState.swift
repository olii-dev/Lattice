import Combine
import Foundation

/// Shared across the main window and Settings so AI controls can lock while a reply streams.
@MainActor
final class LatticeGenerationState: ObservableObject {
    @Published var isGenerating = false
}
