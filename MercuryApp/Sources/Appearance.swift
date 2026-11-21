import AppKit
import SwiftUI

// MARK: - System appearance for popovers
//
// Popovers presented from the floating glass toolbar don't reliably pick up
// the system Light/Dark setting: AppKit-backed controls (segmented pickers,
// group boxes, the popover backdrop) can come up dark while SwiftUI text
// resolves light — black text on a dark sheet. `.followsSystemAppearance()`
// pins both the popover's window appearance and SwiftUI's colour scheme to
// what System Settings says, and re-evaluates when the user toggles it.

/// True when macOS is in Dark mode (the system-wide setting, independent of
/// any appearance the app or window may have inherited).
private func systemPrefersDark() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}

private final class AppearanceObserver: ObservableObject {
    @Published var isDark = systemPrefersDark()
    private var token: NSObjectProtocol?

    init() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            self?.isDark = systemPrefersDark()
        }
    }

    deinit {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
    }
}

/// Sets the hosting window's `appearance` so AppKit controls match `isDark`.
private struct WindowAppearanceSetter: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.isDark = isDark
        view.apply()
    }

    final class Probe: NSView {
        var isDark = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
    }
}

private struct FollowsSystemAppearance: ViewModifier {
    @StateObject private var observer = AppearanceObserver()

    func body(content: Content) -> some View {
        content
            .background(WindowAppearanceSetter(isDark: observer.isDark).frame(width: 0, height: 0))
            .colorScheme(observer.isDark ? .dark : .light)
    }
}

extension View {
    /// Make a popover (or any presented content) follow the system
    /// Light/Dark setting for both AppKit controls and SwiftUI colours.
    func followsSystemAppearance() -> some View {
        modifier(FollowsSystemAppearance())
    }
}
