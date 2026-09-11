import SwiftUI

@main
struct TapdeckApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var audio = AudioEngineModel()
    @StateObject private var mixer = MixerModel()

    var body: some Scene {
        Window("Tapdeck", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(audio)
                .environmentObject(mixer)
        }
        .windowResizability(.contentSize)
    }
}

/// ミキサー（＝エンジンの本体）、デバイス状態、画面収録（＝エンジンの利用者）。
struct ContentView: View {
    var body: some View {
        TabView {
            MixerPanelView()
                .tabItem { Label("ミキサー", systemImage: "slider.vertical.3") }
            AudioPanelView()
                .tabItem { Label("デバイス", systemImage: "waveform") }
            RecorderPanelView()
                .tabItem { Label("画面収録", systemImage: "record.circle") }
        }
        .frame(width: 496)
        .padding(.top, 6)
    }
}
