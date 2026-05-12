import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("LatticeTplApp")
                .font(.title2.weight(.semibold))
            Text("Created from Lattice (macOS)")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 200)
    }
}

#Preview {
    ContentView()
}
