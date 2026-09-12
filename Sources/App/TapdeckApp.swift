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

/// Brings up the menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModels.shared.menuBar.install()
    }

    /// Closing the window does not quit: a mixer is meant to be left running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The mixer (the engine itself), device status, and screen recording (one of
/// the engine's consumers).
struct ContentView: View {
    var body: some View {
        TabView {
            MixerPanelView()
                .tabItem { Label("Mixer", systemImage: "slider.vertical.3") }
            AudioPanelView()
                .tabItem { Label("Devices", systemImage: "waveform") }
            RecorderPanelView()
                .tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 536)
        .padding(.top, 6)
    }
}
