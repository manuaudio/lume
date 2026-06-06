import SwiftUI

struct ContentView: View {
    @State private var clicks = 0
    var body: some View {
        VStack(spacing: 16) {
            Text("Lume").font(.largeTitle.bold())
            Text("Clicks register immediately: \(clicks)")
                .foregroundStyle(.secondary)
            Button("Click me") { clicks += 1 }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
