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

    func showCutoutUnavailable(_ message: String) {
        guard removesBackground else { return }
        previewView?.showCutoutUnavailable(message)
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
    private let backgroundButton = CameraControlButton(title: "", target: nil, action: nil)
    private let controls = NSView()
    private let smaller = CameraControlButton(title: "", target: nil, action: nil)
    private let larger = CameraControlButton(title: "", target: nil, action: nil)
    private let shape = CameraControlButton(title: "", target: nil, action: nil)
    private let cameraTooltip = CameraTooltip()
    private let placeholder = NSTextField(wrappingLabelWithString: "Preparing cutout…")
    private var tracking: NSTrackingArea?
    private var dragStart: CGPoint?
    private var windowStart: CGPoint?
    var onSmaller: (() -> Void)?
    var onLarger: (() -> Void)?
    var onShape: (() -> Void)?
    var onRemoveBackground: (() -> Void)?
    var removesBackground = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.isHidden = removesBackground
            cutoutLayer.isHidden = !removesBackground
            cutoutLayer.contents = nil
            ring.isHidden = removesBackground
            placeholder.stringValue = "Preparing cutout…"
            placeholder.isHidden = !removesBackground
            controls.isHidden = false
            shape.isEnabled = !removesBackground
            backgroundButton.contentTintColor = removesBackground ? .systemGreen : .white
            backgroundButton.state = removesBackground ? .on : .off
            backgroundButton.setAccessibilityValue(removesBackground ? "On" : "Off")
            CATransaction.commit()
        }
    }

    func showCutout(_ image: CGImage) {
        guard removesBackground else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.isHidden = true
        cutoutLayer.contents = image
        CATransaction.commit()
    }
    func showCutoutUnavailable(_ message: String) {
        guard removesBackground else { return }
        cutoutLayer.contents = nil
        placeholder.stringValue = message
        placeholder.isHidden = false
        controls.isHidden = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var cornerFraction: CGFloat = 0.5 {
        didSet {
            shape.image = NSImage(systemSymbolName: cornerFraction == 0.5 ? "square" : "circle", accessibilityDescription: nil)
            shape.hoverText = cornerFraction == 0.5 ? "Rounded square" : "Circle"
            shape.setAccessibilityLabel(shape.hoverText)
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
    override func mouseExited(with event: NSEvent) {
        cameraTooltip.hide()
        if dragStart == nil && placeholder.isHidden { controls.isHidden = true }
    }
    override func mouseDown(with event: NSEvent) {
        cameraTooltip.hide()
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

        placeholder.alignment = .center
        placeholder.textColor = .white
        placeholder.font = .systemFont(ofSize: 12, weight: .medium)
        placeholder.drawsBackground = true
        placeholder.backgroundColor = .black.withAlphaComponent(0.75)
        placeholder.isHidden = true
        addSubview(placeholder)

        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        controls.layer?.cornerRadius = 16
        controls.isHidden = true
        addSubview(controls)
        for (button, symbol, title, action) in [
            (smaller, "minus", "Smaller camera", #selector(shrink)),
            (larger, "plus", "Larger camera", #selector(grow)),
            (shape, "square", "Rounded square", #selector(switchShape)),
            (backgroundButton, "person.and.background.dotted", "Weather man view", #selector(switchBackground))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.setAccessibilityLabel(title)
            button.hoverText = title
            button.onHover = { [weak self, weak button] text in
                guard let self else { return }
                if let text, let button, let window = self.window {
                    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
                    self.cameraTooltip.show(text, anchor: anchor, camera: window)
                } else {
                    self.cameraTooltip.hide()
                }
            }
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
        cameraTooltip.hide()
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
        placeholder.frame = CGRect(x: 8, y: bounds.midY - 20, width: bounds.width - 16, height: 48)
        controls.frame = CGRect(x: (bounds.width - 112) / 2, y: 10, width: 112, height: 32)
        for (index, button) in [smaller, larger, shape, backgroundButton].enumerated() {
            button.frame = CGRect(x: 4 + index * 26, y: 2, width: 26, height: 28)
        }
    }
}

private final class CameraControlButton: NSButton {
    var hoverText = "" {
        didSet { if isHovered { onHover?(hoverText) } }
    }
    var onHover: ((String?) -> Void)?
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(hoverText)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class CameraTooltip {
    private var panel: NSPanel?

    func show(_ text: String, anchor: CGRect, camera: NSWindow) {
        hide()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: ceil(label.frame.width) + 20, height: 26)
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        content.layer?.cornerRadius = 7
        label.setFrameOrigin(CGPoint(x: 10, y: (size.height - label.frame.height) / 2))
        content.addSubview(label)
        let tooltip = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        tooltip.backgroundColor = .clear
        tooltip.isOpaque = false
        tooltip.hasShadow = false
        tooltip.ignoresMouseEvents = true
        tooltip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tooltip.level = NSWindow.Level(rawValue: camera.level.rawValue + 1)
        tooltip.contentView = content
        let screen = (camera.screen?.visibleFrame ?? camera.frame).insetBy(dx: 6, dy: 6)
        let below = CGRect(x: anchor.midX - size.width / 2, y: camera.frame.minY - size.height - 6,
                           width: size.width, height: size.height)
        let candidates = [below,
            CGRect(x: camera.frame.maxX + 6, y: anchor.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: camera.frame.minX - size.width - 6, y: anchor.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: below.minX, y: camera.frame.maxY + 6, width: size.width, height: size.height)]
        for var frame in candidates {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
            guard screen.contains(frame), !frame.intersects(camera.frame) else { continue }
            tooltip.setFrame(frame, display: false)
            panel = tooltip
            camera.addChildWindow(tooltip, ordered: .above)
            tooltip.orderFrontRegardless()
            return
        }
    }

    func hide() {
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
}
