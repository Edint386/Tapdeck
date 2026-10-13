import AppKit
import SwiftUI

@main
struct TapdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @ObservedObject private var recorder = AppModels.shared.recorder
    @ObservedObject private var audio = AppModels.shared.audio
    @ObservedObject private var mixer = AppModels.shared.mixer
    @ObservedObject private var menuBar = AppModels.shared.menuBar
    @ObservedObject private var settings = AppModels.shared.settings

    var body: some Scene {
        Window("Tapdeck", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(audio)
                .environmentObject(mixer)
                .environmentObject(menuBar)
                .environmentObject(settings)
                .appLanguage()
        }
        // Resizable in both directions, down to a size where nothing clips.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView()
                .environmentObject(audio)
                .environmentObject(settings)
                .appLanguage()
        }
    }
}

/// Brings up the menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The driver only remembers its devices while Core Audio keeps running.
        // After a restart — a reboot, or reinstalling the driver — it is back to
        // the single default device, so hand it the saved list again before
        // any mix tries to play into one of them.
        try? VirtualDeviceConfiguration.load().push()
        AppModels.shared.mixer.refresh()

        AppModels.shared.menuBar.install()
    }

    /// Closing the window does not quit: a mixer is meant to be left running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The mixes (the engine itself) and screen recording (one of its consumers).
/// Device management and diagnostics live in Settings.
struct ContentView: View {
    var body: some View {
        TabView {
            MixerPanelView()
                .tabItem { Label("Mixer", systemImage: "slider.vertical.3") }
            RecorderPanelView()
                .tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .padding(.top, 6)
    }
}
