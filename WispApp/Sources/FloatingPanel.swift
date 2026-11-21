import AppKit
import SwiftUI

/// A fixed canvas lets SwiftUI animate the notch without resizing a native window.
final class FloatingPanel: NSPanel {
    var interactionSize = CGSize.zero
    private var pointerTimer: Timer?

    func trackInteractiveRegion() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let region = NSRect(x: self.frame.midX - self.interactionSize.width / 2,
                                    y: self.frame.maxY - self.interactionSize.height,
                                    width: self.interactionSize.width, height: self.interactionSize.height)
                self.ignoresMouseEvents = !region.contains(NSEvent.mouseLocation)
            }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { pointerTimer?.invalidate() }

    init(contentView view: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
    }

    // This panel intentionally occupies the notch region above the visible frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Accept mouse events even when the app isn't active.
    override var canBecomeKey: Bool { true }
}
