import AppKit
import SwiftUI

@main
struct TapdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @ObservedObject private var recorder = AppModels.shared.recorder
    @ObservedObject private var audio = AppModels.shared.audio
    @ObservedObject private var mixer = AppModels.shared.mixer
    @ObservedObject private var menuBar = AppModels.shared.menuBar

    var body: some Scene {
        Window("Tapdeck", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(audio)
                .environmentObject(mixer)
                .environmentObject(menuBar)
        }
        .windowResizability(.contentSize)
    }
}

/// メニューバーの常駐項目を立ち上げる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModels.shared.menuBar.install()
    }

    /// ウインドウを閉じても終了しない。ミキサーは出しっぱなしで使うため。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        .frame(width: 536)
        .padding(.top, 6)
    }
}
