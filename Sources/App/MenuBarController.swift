import AppKit
import Combine
import SwiftUI

/// メニューバーの常駐項目。
///
/// SwiftUI の MenuBarExtra は、この構成（swiftc で組んだバンドル、Window シーンと
/// 併存）では項目が作られなかったため、AppKit の NSStatusItem で直接組む。
/// 動作状態に応じてアイコンを変えられる利点もある。
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {

    /// メニューバーに場所を確保できたか。
    ///
    /// ノッチ付きの画面では項目を置ける範囲が狭く、他アプリで埋まっていると
    /// macOS はスロットを割り当てず、項目のウインドウを画面外へ追いやる。
    /// エラーにはならないので、こちらで検知して利用者に伝える。
    @Published private(set) var isPlaced = true

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol(isRunning: false)
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.toolTip = "Tapdeck"
        if item.button?.image == nil {
            // シンボルが取れない環境向けの保険。幅ゼロだと項目が見えなくなる。
            item.button?.title = "Tapdeck"
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView()
                .environmentObject(AppModels.shared.mixer))

        // 送出中はアイコンを塗りつぶして、ひと目で分かるようにする。
        AppModels.shared.mixer.$isRunning
            .removeDuplicates()
            .sink { [weak self] running in
                self?.statusItem?.button?.image = Self.symbol(isRunning: running)
                self?.statusItem?.button?.image?.isTemplate = true
            }
            .store(in: &cancellables)

        // 配置は即座には決まらないので、少し置いてから確かめる。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPlacement()
        }
    }

    /// 置き場所が無いと、ウインドウがメニューバーの外（負の座標）へ追いやられる。
    private func checkPlacement() {
        guard let frame = statusItem?.button?.window?.frame else { return }
        isPlaced = frame.origin.y >= 0
    }

    private static func symbol(isRunning: Bool) -> NSImage? {
        NSImage(systemSymbolName: isRunning ? "waveform.circle.fill" : "waveform.circle",
                accessibilityDescription: "Tapdeck")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            AppModels.shared.mixer.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
