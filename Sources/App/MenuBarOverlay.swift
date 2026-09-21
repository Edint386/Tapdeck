import AppKit
import CoreGraphics
import SwiftUI

/// Tapdeck's own menu bar icon, for when macOS gives the real status item no
/// slot.
///
/// Measured on this Mac: status items filled the bar from x = 1027 to the
/// screen's edge, so macOS parked Tapdeck's item at x = -1116, where it drew
/// nothing and a press did nothing. An app cannot claim a slot, so the icon is
/// drawn here instead — same size and position as the system's own items, read
/// from the window list — and clicking it drops a plain menu underneath, the
/// way a menu bar item does.
@MainActor
final class MenuBarOverlay: NSObject {
    private var window: IconWindow?

    var isShowing: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let window = IconWindow()
            window.contentView = NSHostingView(rootView: MenuBarOverlayIcon { [weak self] in
                self?.showMenu()
            })
            window.isReleasedWhenClosed = false
            self.window = window
        }
        reposition()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Match the other status items: same height, same row, just left of the
    /// leftmost one. Their geometry is read from the window list, because macOS
    /// offers no way to ask where the status area begins or how tall it is.
    func reposition() {
        guard let window, let screen = NSScreen.main else { return }
        var leftmost = screen.frame.maxX
        var height = NSStatusBar.system.thickness

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? Int, number != window.windowNumber,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 25,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let top = bounds["Y"] as? Double,
                  let itemHeight = bounds["Height"] as? Double, top <= 8 else { continue }
            leftmost = min(leftmost, CGFloat(x))
            height = max(height, CGFloat(itemHeight))
        }

        let width: CGFloat = 26
        let x = max(0, leftmost - width)
        window.setFrame(NSRect(x: x, y: screen.frame.maxY - height, width: width, height: height),
                        display: true)
    }

    /// A plain menu, the way every menu bar app works. A popover refused to
    /// open from a borderless window at this level.
    private func showMenu() {
        guard let view = window?.contentView else { return }
        let model = AppModels.shared.mixer
        model.refresh()

        let menu = NSMenu()
        for mix in model.mixes {
            let name = mix.name.trimmingCharacters(in: .whitespaces)
            let item = NSMenuItem(title: name.isEmpty ? "Unnamed mix" : name,
                                  action: #selector(toggleMix(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mix.id
            item.state = mix.isRunning ? .on : .off
            menu.addItem(item)
        }
        if !model.mixes.isEmpty { menu.addItem(.separator()) }

        for (title, selector) in [("Open Tapdeck", #selector(openWindow)),
                                  ("Settings…", #selector(openSettings)),
                                  ("Quit Tapdeck", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
    }

    @objc private func toggleMix(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let mix = AppModels.shared.mixer.mixes.first(where: { $0.id == id }) else { return }
        mix.toggleRunning()
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// A borderless window that can still take key, so the panel it opens
    /// reacts to clicks.
    private final class IconWindow: NSPanel {
        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 26, height: 24),
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        }

        override var canBecomeKey: Bool { true }
    }
}

/// The icon: the same symbol as the status item, filled while a mix runs.
private struct MenuBarOverlayIcon: View {
    let action: () -> Void
    @ObservedObject private var mixer = AppModels.shared.mixer

    var body: some View {
        Button(action: action) {
            Image(systemName: mixer.runningCount > 0 ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tapdeck")
    }
}
