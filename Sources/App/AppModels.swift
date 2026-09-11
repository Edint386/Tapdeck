import Foundation

/// アプリ全体で共有するモデル。
///
/// SwiftUI の @StateObject だけだと AppKit 側（メニューバーの NSStatusItem）から
/// 触れないため、所有をここに集約する。
@MainActor
final class AppModels {
    static let shared = AppModels()

    let recorder = Recorder()
    let audio = AudioEngineModel()
    let mixer = MixerModel()
    let menuBar = MenuBarController()

    private init() {}
}
