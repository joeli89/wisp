import AppKit
import SwiftUI

@MainActor
final class NotchPointerState: ObservableObject {
    @Published var isInside = false
}

/// A fixed canvas lets SwiftUI animate the notch without resizing a native window.
final class FloatingPanel: NSPanel {
    var interactionSize = CGSize.zero
    var compactInteractionSize = CGSize.zero
    var usesCompactInteractionRegion = true
    var pointerState: NotchPointerState?
    private var pointerTimer: Timer?

    func trackInteractiveRegion() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let size = self.usesCompactInteractionRegion ? self.compactInteractionSize : self.interactionSize
                let region = NSRect(x: self.frame.midX - size.width / 2,
                                    y: self.frame.maxY - size.height,
                                    width: size.width, height: size.height)
                let mouse = NSEvent.mouseLocation
                let localPoint = CGPoint(x: mouse.x - region.minX, y: region.maxY - mouse.y)
                let outline = NotchOutline(bottomRadius: size.width > 300 ? 20 : 12)
                let isInside = outline.path(in: CGRect(origin: .zero, size: size)).contains(localPoint)
                self.ignoresMouseEvents = !isInside
                if self.pointerState?.isInside != isInside {
                    self.pointerState?.isInside = isInside
                }
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
