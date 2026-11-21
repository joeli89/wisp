import SwiftUI

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No visible window — the floating toolbar is created by AppDelegate.
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = RecordingController()
    let tooltipController = TooltipController()
    let statusController = StatusController()
    let sourceFlyout = SourceFlyoutController()
    let cameraPreview = CameraPreviewController()
    let phonePreview = PhonePreviewController()
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.cameraPreview = cameraPreview
        controller.phonePreview = phonePreview

        let screen = preferredScreen()
        let notchWidth = screen.flatMap { screen -> CGFloat? in
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { return nil }
            return right.minX - left.maxX
        } ?? 190
        let toolbarView = ToolbarView(compactWidth: notchWidth + 4, notchHeight: screen?.safeAreaInsets.top ?? 0,
                                      onShelfSizeChange: { [weak self] size in
                                          DispatchQueue.main.async { self?.panel?.interactionSize = size }
                                      })
            .environmentObject(controller)
            .environmentObject(tooltipController)
            .environmentObject(statusController)
            .environmentObject(sourceFlyout)

        let hosting = NSHostingView(rootView: AnyView(toolbarView))
        hosting.sizingOptions = []
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)

        let panel = FloatingPanel(contentView: hosting)
        self.panel = panel

        let size = CGSize(width: 524, height: (screen?.safeAreaInsets.top ?? 0) + 540)
        panel.interactionSize = CGSize(width: notchWidth + 28, height: (screen?.safeAreaInsets.top ?? 0) + 20)
        positionPanel(panel, size: size)
        panel.orderFrontRegardless()
        panel.trackInteractiveRegion()

        NotificationCenter.default.addObserver(self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Give the tooltip controller references so it can convert
        // SwiftUI-global coordinates to screen coordinates via AppKit.
        tooltipController.hostPanel = panel
        tooltipController.hostView = hosting
        statusController.hostPanel = panel
        sourceFlyout.hostPanel = panel
        sourceFlyout.recording = controller
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionPanel(_ panel: FloatingPanel, size: CGSize) {
        guard let screen = preferredScreen() else { return }
        let top = screen.safeAreaInsets.top > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: top - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    @objc private func screenParametersChanged() {
        guard let panel else { return }
        positionPanel(panel, size: panel.frame.size)
    }

    /// Keep the app running even when all windows close (the panel is our UI).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
