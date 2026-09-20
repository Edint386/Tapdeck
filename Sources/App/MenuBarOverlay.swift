import AppKit
import CoreGraphics
import SwiftUI

/// Tapdeck's own icon drawn into the menu bar, for when macOS gives the real
/// status item no slot.
///
/// Measured on this Mac: status items already filled the strip right of the
/// notch from x = 1027 to the screen's edge, so macOS parked Tapdeck's item at
/// x = -1116 where it can neither be seen nor clicked. An app cannot claim a
/// slot, so this window draws the icon itself, beside the notch, above
/// everything, on every Space.
@MainActor
final class MenuBarOverlay {
    private var window: NSPanel?
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    var isShowing: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 26, height: 22),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: MenuBarOverlayIcon(action: onClick))
            panel.isReleasedWhenClosed = false
            window = panel
        }
        reposition()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Sit at the left end of the status items, so nothing is covered.
    ///
    /// The other items' positions are read from the window list, because macOS
    /// offers no way to ask where the status area begins. On a notched display
    /// that leftmost point can fall behind the notch; the icon is drawn there
    /// anyway rather than on top of another app's icon.
    func reposition() {
        guard let window, let screen = NSScreen.main else { return }
        let bar = screen.frame
        let size = window.frame.size
        let thickness = NSStatusBar.system.thickness
        let y = bar.maxY - thickness + (thickness - size.height) / 2

        let ownNumber = window.windowNumber
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        var leftmost = bar.maxX
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? Int, number != ownNumber,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 25,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let top = bounds["Y"] as? Double,
                  // Status items hug the top of the screen; other windows at
                  // this level (panels, overlays) do not.
                  top <= 8 else { continue }
            leftmost = min(leftmost, CGFloat(x))
        }

        let x = max(0, leftmost - size.width - 6)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The icon itself: the same symbol as the status item, filled while a mix runs.
private struct MenuBarOverlayIcon: View {
    let action: () -> Void
    @ObservedObject private var mixer = AppModels.shared.mixer

    var body: some View {
        Button(action: action) {
            Image(systemName: mixer.runningCount > 0 ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tapdeck — macOS had no room in the menu bar, so this is Tapdeck's own icon")
    }
}
