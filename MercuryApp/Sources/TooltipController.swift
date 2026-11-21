import AppKit
import SwiftUI

// MARK: - Tooltip bubble (SwiftUI content inside the floating tooltip panel)

struct TooltipBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Tooltip controller

/// Shows labels below the notch, above its native window level.
@MainActor
final class TooltipController: ObservableObject {

    /// The toolbar's hosting NSView — used to convert SwiftUI `.global`
    /// (view-relative, top-left origin) coordinates to screen coordinates via
    /// AppKit, which is robust regardless of the panel's size/layout.
    weak var hostView: NSView?
    /// Kept for the fallback screen lookup.
    weak var hostPanel: NSPanel?

    private var tooltipPanel: NSPanel?
    private var hostingView: NSHostingView<TooltipBubble>?

    // MARK: Public API

    func show(text: String, buttonGlobalFrame: CGRect = .zero) {
        guard let hostPanel, let hostView else { return }
        ensurePanelExists()
        hostingView?.rootView = TooltipBubble(text: text)
        let size = measureTooltip(text: text)

        let local = NSRect(x: buttonGlobalFrame.minX,
                           y: hostView.isFlipped ? buttonGlobalFrame.minY : hostView.bounds.height - buttonGlobalFrame.maxY,
                           width: buttonGlobalFrame.width, height: buttonGlobalFrame.height)
        let button = hostPanel.convertToScreen(hostView.convert(local, to: nil))
        let screen = hostPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let shelfBottom = (hostPanel as? FloatingPanel).map {
            $0.frame.maxY - $0.interactionSize.height
        } ?? button.minY
        var x = button.midX - size.width / 2
        var y = min(button.minY, shelfBottom) - size.height - 6
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        tooltipPanel?.level = NSWindow.Level(rawValue: hostPanel.level.rawValue + 1)
        tooltipPanel?.setContentSize(size)
        tooltipPanel?.setFrameOrigin(NSPoint(x: x, y: y))
        tooltipPanel?.orderFrontRegardless()
    }

    func hide() {
        tooltipPanel?.orderOut(nil)
    }

    // MARK: Private

    private func ensurePanelExists() {
        guard tooltipPanel == nil else { return }

        let hosting = NSHostingView(rootView: TooltipBubble(text: ""))
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        self.hostingView = hosting

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true  // clicks pass through
        panel.contentView = hosting
        self.tooltipPanel = panel
    }

    /// Measures tooltip size using NSFont so we don't need another layout pass.
    private func measureTooltip(text: String) -> CGSize {
        let font  = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs = [NSAttributedString.Key.font: font]
        let ts    = (text as NSString).size(withAttributes: attrs)
        // horizontal: 10+10 padding; vertical: 6+6 padding; +4 safety margin each axis
        return CGSize(width: ceil(ts.width) + 24, height: ceil(ts.height) + 16)
    }
}
