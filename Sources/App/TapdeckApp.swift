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
        }
        // Resizable in both directions, down to a size where nothing clips.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView()
                .environmentObject(audio)
                .environmentObject(settings)
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

    /// The same start and stop controls in the Dock menu. macOS decides whether
    /// a menu bar item gets a slot, and on a full menu bar it gets none, so
    /// this is the way in that always works.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let panelItem = NSMenuItem(title: "Mixes Panel", action: #selector(showMiniPanel(_:)), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
        menu.addItem(.separator())
        for mix in AppModels.shared.mixer.mixes {
            let name = mix.name.trimmingCharacters(in: .whitespaces)
            let item = NSMenuItem(title: mix.isRunning ? "Stop \(name.isEmpty ? "the unnamed mix" : name)"
                                                       : "Start \(name.isEmpty ? "the unnamed mix" : name)",
                                  action: #selector(toggleMix(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mix.id
            item.state = mix.isRunning ? .on : .off
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func showMiniPanel(_ sender: Any?) {
        AppModels.shared.menuBar.toggleMiniPanel()
    }

    @objc private func toggleMix(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let mix = AppModels.shared.mixer.mixes.first(where: { $0.id == id }) else { return }
        mix.toggleRunning()
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
