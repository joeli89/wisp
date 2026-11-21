import AppKit
import AVFoundation

/// A floating, draggable circular self-view that shows the live webcam feed —
/// so the user always knows the camera is capturing them (Loom-style).
/// Uses the capture preview normally, or the shared transparent frames in cutout mode.
@MainActor
final class CameraPreviewController: NSObject, NSWindowDelegate {
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenLayoutChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenLayoutChanged() { settleInsideScreen() }

    var onPlacementChanged: ((CGRect) -> Void)?
    var onShapeChanged: ((CGFloat) -> Void)?
    var onRemoveBackgroundChanged: ((Bool) -> Void)?
    private(set) var removesBackground = false

    func showCutout(_ image: CGImage) {
        guard removesBackground else { return }
        previewView?.showCutout(image)
    }

    private func toggleBackground() {
        removesBackground.toggle()
        previewView?.removesBackground = removesBackground
        panel?.hasShadow = !removesBackground
        onRemoveBackgroundChanged?(removesBackground)
    }
    private(set) var cornerFraction: CGFloat = 0.5
    private var springTimer: Timer?

    private func resizeBubble(by step: Int) {
        guard let panel else { return }
        let sizes: [CGFloat] = [120, 160, 220, 280]
        let index = sizes.firstIndex(of: diameter) ?? 1
        diameter = sizes[min(sizes.count - 1, max(0, index + step))]
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                              width: diameter, height: diameter), display: true)
        previewView?.setSizeButtons(smaller: diameter > sizes[0], larger: diameter < sizes.last!)
        settleInsideScreen()
        publishPlacement()
    }

    private func toggleShape() {
        cornerFraction = cornerFraction == 0.5 ? 0.22 : 0.5
        previewView?.cornerFraction = cornerFraction
        onShapeChanged?(cornerFraction)
    }

    static func constrainedOrigin(_ frame: CGRect, within bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
                y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height)))
    }

    private func settleInsideScreen() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        springTimer?.invalidate()
        let start = panel.frame.origin
        let target = Self.constrainedOrigin(panel.frame, within: screen.visibleFrame.insetBy(dx: 8, dy: 8))
        guard start != target else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(target)
            return
        }
        let began = Date()
        springTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { timer.invalidate(); return }
                let t = Date().timeIntervalSince(began)
                let amount = 1 - exp(-10 * t) * cos(15 * t)
                panel.setFrameOrigin(CGPoint(x: start.x + (target.x - start.x) * amount,
                                             y: start.y + (target.y - start.y) * amount))
                if t >= 0.65 { panel.setFrameOrigin(target); timer.invalidate(); self.springTimer = nil }
            }
        }
    }

    var normalizedFrame: CGRect? {
        guard let panel, let screen = panel.screen else { return nil }
        let bounds = screen.frame
        return CGRect(x: (panel.frame.minX - bounds.minX) / bounds.width,
                      y: (panel.frame.minY - bounds.minY) / bounds.height,
                      width: panel.frame.width / bounds.width,
                      height: panel.frame.height / bounds.height)
    }

    func windowDidMove(_ notification: Notification) { publishPlacement() }
    func windowDidResize(_ notification: Notification) { publishPlacement() }

    private func publishPlacement() {
        if let frame = normalizedFrame { onPlacementChanged?(frame) }
    }
    private var panel: NSPanel?
    private var previewView: CameraPreviewView?

    /// Diameter of the circular bubble in points.
    var diameter: CGFloat = 160

    /// Show the preview for a given capture session. Idempotent.
    func show(session: AVCaptureSession) {
        ensurePanel()
        previewView?.attach(session: session)
        panel?.orderFrontRegardless()
        settleInsideScreen()
        publishPlacement()
    }

    func hide() {
        springTimer?.invalidate()
        springTimer = nil
        panel?.orderOut(nil)
        previewView?.detach()
    }

    // MARK: - Setup

    private func ensurePanel() {
        guard panel == nil else { return }

        let view = CameraPreviewView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        self.previewView = view
        view.onSmaller = { [weak self] in self?.resizeBubble(by: -1) }
        view.onLarger = { [weak self] in self?.resizeBubble(by: 1) }
        view.onShape = { [weak self] in self?.toggleShape() }
        view.onRemoveBackground = { [weak self] in self?.toggleBackground() }
        view.onDragStarted = { [weak self] in self?.springTimer?.invalidate() }
        view.onDragEnded = { [weak self] in self?.settleInsideScreen() }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.title = "Camera preview"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        // Default position: lower-left of the main screen (typical self-view spot).
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vis.minX + 32, y: vis.minY + 32))
        }
        self.panel = panel
        panel.delegate = self
    }
}

// MARK: - Preview view (circular, mirrored)

/// NSView hosting an AVCaptureVideoPreviewLayer, masked to a circle with a ring.
final class CameraPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let ring = CAShapeLayer()
    private let cutoutLayer = CALayer()
    private let backgroundButton = NSButton(title: "", target: nil, action: nil)
    private let controls = NSView()
    private let smaller = NSButton(title: "", target: nil, action: nil)
    private let larger = NSButton(title: "", target: nil, action: nil)
    private let shape = NSButton(title: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var windowStart: CGPoint?
    var onSmaller: (() -> Void)?
    var onLarger: (() -> Void)?
    var onShape: (() -> Void)?
    var onRemoveBackground: (() -> Void)?
    var removesBackground = false {
        didSet {
            previewLayer.isHidden = removesBackground
            cutoutLayer.isHidden = !removesBackground
            cutoutLayer.contents = nil
            ring.isHidden = removesBackground
            shape.isEnabled = !removesBackground
            backgroundButton.contentTintColor = removesBackground ? .systemGreen : .white
            backgroundButton.state = removesBackground ? .on : .off
            let label = removesBackground ? "Restore camera background" : "Remove camera background"
            backgroundButton.toolTip = label
            backgroundButton.setAccessibilityLabel(label)
        }
    }

    func showCutout(_ image: CGImage) {
        guard removesBackground else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutoutLayer.contents = image
        CATransaction.commit()
    }
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var cornerFraction: CGFloat = 0.5 {
        didSet {
            shape.image = NSImage(systemSymbolName: cornerFraction == 0.5 ? "square" : "circle", accessibilityDescription: nil)
            shape.setAccessibilityLabel(cornerFraction == 0.5 ? "Use rounded square camera" : "Use circular camera")
            needsLayout = true
        }
    }

    func setSizeButtons(smaller enabledSmall: Bool, larger enabledLarge: Bool) {
        smaller.isEnabled = enabledSmall
        larger.isEnabled = enabledLarge
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { controls.isHidden = false }
    override func mouseExited(with event: NSEvent) { if dragStart == nil { controls.isHidden = true } }
    override func mouseDown(with event: NSEvent) {
        onDragStarted?()
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        controls.isHidden = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart, let window else { return }
        let point = NSEvent.mouseLocation
        var origin = CGPoint(x: windowStart.x + point.x - dragStart.x, y: windowStart.y + point.y - dragStart.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? window.screen {
            let frame = CGRect(origin: origin, size: window.frame.size)
            let constrained = CameraPreviewController.constrainedOrigin(frame, within: screen.visibleFrame.insetBy(dx: 8, dy: 8))
            origin.x = constrained.x + (origin.x - constrained.x) * 0.18
            origin.y = constrained.y + (origin.y - constrained.y) * 0.18
        }
        window.setFrameOrigin(origin)
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        windowStart = nil
        onDragEnded?()
        controls.isHidden = !bounds.contains(convert(event.locationInWindow, from: nil))
    }
    @objc private func shrink() { onSmaller?() }
    @objc private func grow() { onLarger?() }
    @objc private func switchShape() { onShape?() }
    @objc private func switchBackground() { onRemoveBackground?() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        previewLayer.videoGravity = .resizeAspectFill
        // Mirror like a selfie so it matches the composited recording.
        if previewLayer.connection?.isVideoMirroringSupported == true {
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = true
        }
        layer?.addSublayer(previewLayer)
        cutoutLayer.contentsGravity = .resizeAspectFill
        cutoutLayer.masksToBounds = true
        cutoutLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        cutoutLayer.isHidden = true
        layer?.addSublayer(cutoutLayer)

        // White ring around the bubble.
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 3
        layer?.addSublayer(ring)

        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        controls.layer?.cornerRadius = 16
        controls.isHidden = true
        addSubview(controls)
        for (button, symbol, title, action) in [
            (smaller, "minus", "Smaller camera", #selector(shrink)),
            (larger, "plus", "Larger camera", #selector(grow)),
            (shape, "square", "Use rounded square camera", #selector(switchShape)),
            (backgroundButton, "person.crop.rectangle", "Remove camera background", #selector(switchBackground))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.setAccessibilityLabel(title)
            button.toolTip = title
            button.isBordered = false
            button.contentTintColor = .white
            button.target = self
            button.action = action
            controls.addSubview(button)
        }
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        if previewLayer.connection?.isVideoMirroringSupported == true {
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = true
        }
    }

    func detach() {
        previewLayer.session = nil
    }

    override func layout() {
        super.layout()
        let d = min(bounds.width, bounds.height)
        // Circular mask.
        let radius = d * cornerFraction
        previewLayer.frame = bounds
        cutoutLayer.frame = bounds
        previewLayer.cornerRadius = radius
        previewLayer.masksToBounds = true
        // Ring path, inset by half the line width so it isn't clipped.
        let inset = ring.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        ring.path = CGPath(roundedRect: rect, cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil)
        ring.frame = bounds
        controls.frame = CGRect(x: (bounds.width - 112) / 2, y: 10, width: 112, height: 32)
        for (index, button) in [smaller, larger, shape, backgroundButton].enumerated() {
            button.frame = CGRect(x: 4 + index * 26, y: 2, width: 26, height: 28)
        }
    }
}
