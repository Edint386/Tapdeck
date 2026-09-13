import AppKit
import Combine
import SwiftUI

/// The menu bar item.
///
/// SwiftUI's MenuBarExtra never created an item in this setup — a bundle built
/// with swiftc, alongside a Window scene — so this uses AppKit's NSStatusItem
/// directly. It also makes the icon easy to change with the running state.
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {

    /// Whether the menu bar found room for the item.
    ///
    /// A notched display leaves only a narrow strip for status items, and once
    /// other apps have filled it macOS allocates no slot and pushes the item's
    /// window off screen. Nothing reports an error, so detect it here and tell
    /// the user.
    @Published private(set) var isPlaced = true

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    /// Set up the popover and the icon updates once, then show or hide the item
    /// as the setting changes.
    func install() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView()
                .environmentObject(AppModels.shared.mixer))

        // Fill the icon while any mix is running so the state is obvious at a
        // glance.
        AppModels.shared.mixer.$runningCount
            .map { $0 > 0 }
            .removeDuplicates()
            .sink { [weak self] running in
                self?.statusItem?.button?.image = Self.symbol(isRunning: running)
                self?.statusItem?.button?.image?.isTemplate = true
            }
            .store(in: &cancellables)

        AppSettings.shared.$showsMenuBarItem
            .removeDuplicates()
            .sink { [weak self] shows in
                shows ? self?.showItem() : self?.hideItem()
            }
            .store(in: &cancellables)
    }

    private func showItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol(isRunning: false)
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.toolTip = "Tapdeck"
        if item.button?.image == nil {
            // Fallback for when the symbol is unavailable: a zero-width item
            // would be invisible.
            item.button?.title = "Tapdeck"
        }
        item.button?.image = Self.symbol(isRunning: AppModels.shared.mixer.runningCount > 0)
        item.button?.image?.isTemplate = true
        statusItem = item

        // Placement is not settled immediately, so check a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkPlacement()
        }
    }

    private func hideItem() {
        guard let item = statusItem else { return }
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        // Hidden on purpose, so there is nothing to warn about.
        isPlaced = true
    }

    /// With no room, the window is pushed outside the menu bar to a negative
    /// coordinate.
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
