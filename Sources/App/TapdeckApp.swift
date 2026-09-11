import SwiftUI

@main
struct TapdeckApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var audio = AudioEngineModel()

    var body: some Scene {
        Window("Tapdeck", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(audio)
        }
        .windowResizability(.contentSize)
    }
}

/// オーディオ（＝エンジンの本体）と画面収録（＝その利用者）を分けて見せる。
struct ContentView: View {
    var body: some View {
        TabView {
            AudioPanelView()
                .tabItem { Label("オーディオ", systemImage: "waveform") }
            RecorderPanelView()
                .tabItem { Label("画面収録", systemImage: "record.circle") }
        }
        .frame(width: 496)
        .padding(.top, 6)
    }
}
