import AppKit
import SwiftUI
import ScreenCaptureKit

struct SourceChooserView: View {
    @EnvironmentObject var controller: RecordingController
    let dismiss: () -> Void
    @State private var previews: [CGDirectDisplayID: CGImage] = [:]
    @State private var unavailablePreviews: Set<CGDirectDisplayID> = []

    @State private var windows: [SCWindow] = []
    @State private var windowPreviews: [CGWindowID: CGImage] = [:]
    @State private var windowMessage = "Loading windows…"

    private struct DisplayItem: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
        let resolution: String
        let number: Int
    }

    private var displays: [DisplayItem] {
        controller.displays.enumerated().map { index, display in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            return DisplayItem(id: display.displayID,
                               name: screen?.localizedName ?? "Display \(index + 1)",
                               frame: screen?.frame ?? CGRect(x: index * 1920, y: 0, width: display.width, height: display.height),
                               resolution: "\(display.width) × \(display.height)", number: index + 1)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Record").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Done", action: dismiss)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }

            NativeSourceSegments(selection: sourceSelection)
                .frame(width: 320, height: 30)

            switch controller.captureSource {
            case .display:
                VStack(spacing: 12) {
                    if displays.isEmpty {
                        Text("No screens available")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(height: 200)
                    } else {
                        screenMap
                    }
                    VStack(spacing: 3) {
                        Text(selectedName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(selectedDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(height: 32)
                }
            case .window:
                windowChooser
            case .phone:
                phoneChooser
            }

        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: 456, height: 326, alignment: .top)
        .task { await controller.refreshDisplays() }
        .task(id: previewDisplayIDs) { await updatePreviews() }
        .task(id: controller.captureSource) {
            if controller.captureSource == .window { await updateWindows() }
        }
        .onDisappear {
            previews.removeAll()
            unavailablePreviews.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task { await controller.refreshDisplays() }
        }
        .disabled(controller.isRecording)
    }

    private var sourceSelection: Binding<CaptureSource> {
        Binding(get: { controller.captureSource }, set: { source in
            switch source {
            case .display: controller.selectDisplaySource()
            case .window:
                controller.captureSource = .window
                controller.status = "Ready."
            case .phone: controller.selectPhoneSource()
            }
        })
    }

    private var previewDisplayIDs: [CGDirectDisplayID] {
        controller.captureSource == .display ? controller.displays.map(\.displayID) : []
    }

    private var windowChooser: some View {
        ScrollView {
            if windows.isEmpty {
                Text(windowMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 210)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(windows, id: \.windowID) { window in
                    let selected = controller.pickedWindowID == window.windowID
                    Button { controller.selectWindow(window) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            ZStack(alignment: .topTrailing) {
                                Color(white: 0.08)
                                if let image = windowPreviews[window.windowID] {
                                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.white, Color.accentColor).padding(6)
                                }
                            }
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected ? Color.accentColor : .white.opacity(0.2), lineWidth: selected ? 3 : 1)
                            }
                            Text(window.title ?? "Untitled window").font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(window.owningApplication?.applicationName ?? "Application")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(3)
        }.frame(height: 244)
    }

    @MainActor
    private func updateWindows() async {
        do {
            while !Task.isCancelled {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard !Task.isCancelled else { return }
                windows = content.windows.filter {
                    $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 &&
                    $0.owningApplication != nil &&
                    $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                    $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                }.sorted { $0.windowID < $1.windowID }
                windowMessage = "No windows available"
                let ids = Set(windows.map(\.windowID))
                windowPreviews = windowPreviews.filter { ids.contains($0.key) }
                for window in windows {
                    guard !Task.isCancelled else { return }
                    let config = SCStreamConfiguration()
                    let scale = min(1, 400 / max(window.frame.width, window.frame.height))
                    config.width = max(2, Int(window.frame.width * scale))
                    config.height = max(2, Int(window.frame.height * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    guard !Task.isCancelled else { return }
                    windowPreviews[window.windowID] = image
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            guard !Task.isCancelled else { return }
            windowMessage = "Windows unavailable. Check Screen Recording access in System Settings."
        }
    }

    private var phoneChooser: some View {
        VStack(spacing: 14) {
            if controller.phones.isEmpty {
                Image(systemName: "iphone")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Connect your iPhone via USB")
                    .font(.system(size: 12, weight: .medium))
                Text("Unlock it and tap Trust to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.phones, id: \.uniqueID) { phone in
                            Button {
                                controller.selectPhoneSource(phone.uniqueID)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "iphone")
                                    Text(phone.localizedName)
                                    Spacer()
                                    if controller.selectedPhoneID == phone.uniqueID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .font(.system(size: 12))
                                .padding(12)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
            Button("Refresh") { controller.refreshPhones() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 244)
    }

    @MainActor
    private func updatePreviews() async {
        let ids = Set(previewDisplayIDs)
        previews = previews.filter { ids.contains($0.key) }
        unavailablePreviews = []
        guard !ids.isEmpty else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled else { return }
            let excluded = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier ||
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let screens = content.displays.filter { ids.contains($0.displayID) }
            while !Task.isCancelled {
                for display in screens {
                    guard !Task.isCancelled else { return }
                    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = min(1, 640 / Double(max(display.width, display.height)))
                    config.width = max(2, Int(Double(display.width) * scale))
                    config.height = max(2, Int(Double(display.height) * scale))
                    config.showsCursor = false
                    do {
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        guard !Task.isCancelled else { return }
                        previews[display.displayID] = image
                        unavailablePreviews.remove(display.displayID)
                    } catch {
                        guard !Task.isCancelled else { return }
                        previews.removeValue(forKey: display.displayID)
                        unavailablePreviews.insert(display.displayID)
                    }
                }
                try await Task.sleep(for: .milliseconds(800))
            }
        } catch {
            guard !Task.isCancelled else { return }
            previews.removeAll()
            unavailablePreviews = ids
        }
    }

    private var selectedName: String {
        if controller.captureSource != .display { return controller.sourceDescription }
        return displays.first { $0.id == controller.selectedDisplayID }?.name ?? "Choose a screen"
    }

    private var selectedDetail: String {
        if controller.captureSource != .display { return "Click a screen above to record the whole display" }
        return displays.first { $0.id == controller.selectedDisplayID }.map {
            "\($0.resolution) · Screen \($0.number) selected"
        } ?? "Screens follow your desktop arrangement"
    }

    private var screenMap: some View {
        GeometryReader { geometry in
            let items = displays
            let bounds = items.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min((geometry.size.width - 16) / max(1, bounds.width),
                            (geometry.size.height - 16) / max(1, bounds.height))
            let offsetX = (geometry.size.width - bounds.width * scale) / 2
            let offsetY = (geometry.size.height - bounds.height * scale) / 2
            ForEach(items) { display in
                let selected = controller.captureSource == .display && controller.selectedDisplayID == display.id
                Button {
                    controller.selectDisplaySource(display.id)
                } label: {
                    ZStack(alignment: .topLeading) {
                        Color(white: 0.08)
                        if let preview = previews[display.id] {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: unavailablePreviews.contains(display.id) ? "eye.slash" : "display")
                                Text(unavailablePreviews.contains(display.id) ? "Preview unavailable" : "Loading…")
                                    .font(.system(size: 8))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        HStack(spacing: 4) {
                            Text("\(display.number)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Selected")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(selected ? Color.accentColor : .black.opacity(0.75), in: Capsule())
                        .padding(4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.3), lineWidth: selected ? 3 : 1)
                    }
                    .shadow(color: selected ? Color.accentColor.opacity(0.35) : .clear, radius: 5)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .frame(width: max(16, display.frame.width * scale - 5),
                       height: max(16, display.frame.height * scale - 5))
                .position(x: offsetX + (display.frame.midX - bounds.minX) * scale,
                          y: offsetY + (bounds.maxY - display.frame.midY) * scale)
                .accessibilityLabel("Screen \(display.number), \(display.name), \(display.resolution)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(display.name) — \(display.resolution)")
            }
        }
        .frame(height: 200)
    }
}

private struct NativeSourceSegments: NSViewRepresentable {
    @Binding var selection: CaptureSource
    private static let sources: [CaptureSource] = [.display, .window, .phone]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Full Screen", "Window", "iPhone"],
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.select(_:)))
        control.segmentStyle = .roundRect
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = Self.sources.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: NativeSourceSegments
        init(_ parent: NativeSourceSegments) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) {
            guard NativeSourceSegments.sources.indices.contains(sender.selectedSegment) else { return }
            parent.selection = NativeSourceSegments.sources[sender.selectedSegment]
        }
    }
}
