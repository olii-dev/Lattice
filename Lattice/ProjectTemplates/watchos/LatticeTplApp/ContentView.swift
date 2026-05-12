import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("LatticeTplApp")
                .font(.headline)
            Text("watchOS")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
