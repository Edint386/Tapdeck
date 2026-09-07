import SwiftUI

@main
struct TapdeckApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        Window("Tapdeck", id: "main") {
            ContentView()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)
    }
}
