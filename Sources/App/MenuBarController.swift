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
    /// other apps have filled it macOS allocates no slot and parks the item's
    /// window off screen — measured at x = -1116. The item is never removed by
    /// Tapdeck; macOS decides, and an app cannot claim a slot. So the item is
    /// kept, the placement is rechecked whenever that could change, and the UI
    /// explains how to free room.
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
                .environmentObject(AppModels.shared.mixer)
                .environmentObject(AppModels.shared.settings))

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

        // Room can appear when another app's item goes away or the screen
        // arrangement changes. Both moments are notifications, so no polling.
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.retryPlacement() }
                .store(in: &cancellables)
        }
    }

    /// Ask for a slot again when one may have appeared. Re-creating the item is
    /// the only way to ask; while it is placed, nothing is touched.
    private func retryPlacement() {
        guard AppSettings.shared.showsMenuBarItem, statusItem != nil, !isPlaced else { return }
        hideItem()
        showItem()
    }

    private func showItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Lets macOS remember the position across launches.
        item.autosaveName = "dev.kosuke.Tapdeck.menuBarItem"
        item.isVisible = true
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

    // MARK: - Floating panel

    /// The same controls in a small window that floats above other apps.
    ///
    /// When the menu bar has no free slot, macOS never places the item:
    /// measured, it sits at x = -1116 and a press on it opens nothing. Tools
    /// that tidy the menu bar cannot show what was never placed, so this is
    /// the way to reach the mixes without the main window.
    private var panel: NSPanel?

    func toggleMiniPanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if panel == nil {
            let hosting = NSHostingController(
                rootView: MenuBarPanelView()
                    .environmentObject(AppModels.shared.mixer)
                    .environmentObject(AppModels.shared.settings))
            let panel = NSPanel(contentViewController: hosting)
            panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            panel.title = "Tapdeck"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.center()
            self.panel = panel
        }
        AppModels.shared.mixer.refresh()
        panel?.orderFrontRegardless()
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
