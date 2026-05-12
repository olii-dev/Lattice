import SwiftUI

@main
struct LatticeApp: App {
    @StateObject private var simulatorStore = SimulatorStore()
    @StateObject private var generationState = LatticeGenerationState()
    @StateObject private var consoleStore = LatticeConsoleStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                simulatorStore: simulatorStore,
                generationState: generationState,
                consoleStore: consoleStore
            )
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Project Hub…") {
                    NotificationCenter.default.post(
                        name: .latticeOpenWelcomeHub,
                        object: nil
                    )
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .latticeOpenSettingsWindow,
                        object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Build") {
                Button("Build & Run") {
                    NotificationCenter.default.post(
                        name: .latticeRunOnSimulator,
                        object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("Lattice Settings", id: "lattice-settings") {
            AccountSettingsView(simulatorStore: simulatorStore, generationState: generationState)
        }
        .defaultSize(width: 560, height: 520)
    }
}
