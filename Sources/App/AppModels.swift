import Foundation

/// Models shared across the whole app.
///
/// SwiftUI's @StateObject alone is not reachable from the AppKit side (the menu
/// bar NSStatusItem), so ownership is gathered here instead.
@MainActor
final class AppModels {
    static let shared = AppModels()

    let recorder = Recorder()
    let audio = AudioEngineModel()
    let mixer = MixerModel()
    let menuBar = MenuBarController()

    private init() {}
}
