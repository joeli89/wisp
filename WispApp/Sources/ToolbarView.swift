import SwiftUI

// MARK: - Button frame preference key

/// Collects each button's frame in SwiftUI's .global coordinate space so the
/// TooltipController can position the floating tooltip panel next to it.
private struct ButtonFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - ToolbarView

/// Recording controls that expand from the top edge of the display.
/// The settings popover embeds the full configuration UI (ContentView).
struct ToolbarView: View {
    @EnvironmentObject var controller: RecordingController
    @EnvironmentObject var tooltipController: TooltipController
    @EnvironmentObject var statusController: StatusController
    @EnvironmentObject var sourceFlyout: SourceFlyoutController

    var compactWidth: CGFloat = 190
    var notchHeight: CGFloat = 0
    var onShelfSizeChange: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var insideShelf = false
    @State private var expandTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @State private var showSources = false
    @State private var showSettings = false
    @State private var showBackgrounds = false
    @State private var hovered: String?
    @State private var buttonFrames: [String: CGRect] = [:]

    var body: some View {
        notchShelf
        .frame(width: 524, height: notchHeight + 540, alignment: .top)
        .task { await controller.refreshDevices() }
        .onChange(of: showSettings) { _, _ in tooltipController.hide(); scheduleCollapse() }
        .onChange(of: showBackgrounds) { _, _ in tooltipController.hide(); scheduleCollapse() }
        .onChange(of: showSources) { _, _ in tooltipController.hide(); scheduleCollapse() }
        .onDisappear { collapseTask?.cancel(); expandTask?.cancel() }
        // Collect button frames reported from within the pill
        .onPreferenceChange(ButtonFrameKey.self) { buttonFrames = $0 }
        // Drive the floating tooltip panel on hover changes
        .onChange(of: hovered) { _, id in
            if !showSettings, !showBackgrounds, !showSources,
               let id, let frame = buttonFrames[id], let text = tipText(for: id) {
                tooltipController.show(text: text, buttonGlobalFrame: frame)
            } else {
                tooltipController.hide()
            }
        }
        // Drive the floating status panel (edge-aware, never clipped).
        .onChange(of: controller.status) { _, _ in syncStatus() }
        .onChange(of: controller.isRecording) { _, recording in
            syncStatus()
            if recording {
                expandTask?.cancel()
                collapseTask?.cancel()
                expanded = false
                showSettings = false
                showBackgrounds = false
                showSources = false
                tooltipController.hide()
            }
        }
        .onChange(of: controller.isCompressing) { _, _ in syncStatus() }
    }

    private func syncStatus() {
        if showStatus {
            statusController.show(controller.status)
        } else {
            statusController.hide()
        }
    }

    // MARK: - Tooltip label map

    private func tipText(for id: String) -> String? {
        switch id {
        case "record":   return controller.isRecording ? "Stop recording" : "Record"
        case "camera":   return controller.enableCamera ? "Camera on" : "Camera off"
        case "mic":      return controller.enableMicrophone ? "Mic on" : "Mic off"
        case "bg":       return "Background"
        case "settings": return "Settings"
        case "folder":   return "Show in Finder"
        default:         return nil
        }
    }

    // MARK: - Pill

    private var shelfExpanded: Bool { expanded && !controller.isRecording }

    private var notchShelf: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            if controller.isRecording {
                HStack(spacing: 14) {
                    Text(controller.elapsedString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if controller.enableMicrophone {
                        MicrophonePulse(level: controller.microphoneLevel)
                    }
                    recordButton
                }
                .frame(height: 44)
            } else {
                Button {
                    collapseTask?.cancel()
                    expandTask?.cancel()
                    expanded.toggle()
                    if !expanded { showSources = false }
                } label: {
                    HStack(spacing: 12) {
                        if controller.isRecording || controller.isCompressing {
                            Text(controller.isRecording ? controller.elapsedString : "SAVING \(Int(controller.compressionProgress * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                        } else {
                            WispDotMark()
                                .scaleEffect(0.78)
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse Wisp controls" : "Expand Wisp controls")

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        if controller.isCompressing {
                            compressingIndicator
                        } else {
                            recordButton
                        }
                        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 24)
                        sourceButton
                        cameraToggleButton
                        micToggleButton
                        backgroundSwatchButton
                        iconButton("gearshape", id: "settings") { showSettings.toggle() }
                            .popover(isPresented: $showSettings, arrowEdge: .top) {
                                ContentView()
                                    .environmentObject(controller)
                                    .followsSystemAppearance()
                            }
                        if controller.lastOutputURL != nil { revealButton }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    if showSources {
                        SourceChooserView(dismiss: { showSources = false })
                            .environmentObject(controller)
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }
                }
                .frame(width: showSources ? 456 : 396, height: showSources ? 406 : 80, alignment: .top)
                .offset(y: expanded ? 0 : -16)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            }
        }
        .frame(width: shelfExpanded ? (showSources ? 480 : 420) : compactWidth + 24,
               height: notchHeight + (controller.isRecording ? 44 : 20 + (shelfExpanded ? (showSources ? 406 : 80) : 0)), alignment: .top)
        .background(.black)
        .clipShape(NotchOutline(bottomRadius: shelfExpanded ? 20 : 12))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { inside in
            insideShelf = inside
            guard !controller.isRecording else { return }
            collapseTask?.cancel()
            expandTask?.cancel()
            if inside {
                expandTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    expanded = true
                }
            } else {
                scheduleCollapse()
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            onShelfSizeChange(size)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9), value: showSources)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controller.isRecording)
        .animation(reduceMotion ? nil : (expanded
            ? .spring(response: 0.52, dampingFraction: 0.62)
            : .spring(response: 0.34, dampingFraction: 1)), value: expanded)
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        guard !insideShelf, !showSettings, !showBackgrounds, !showSources else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            tooltipController.hide()
            expanded = false
        }
    }

    /// Show the status card only for actionable messages (not idle / recording).
    private var showStatus: Bool {
        !controller.isRecording &&
        !controller.isCompressing &&          // the pill's ring already shows this
        controller.status != "Ready." &&
        !controller.status.isEmpty
    }

    // MARK: - Subviews

    private var recordButton: some View {
        Button {
            Task {
                if controller.isRecording { await controller.stop() }
                else if !controller.isCompressing { await controller.start() }
            }
        } label: {
            ZStack {
                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.red)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isRecording ? "Stop recording" : "Start recording")
        .onHover { inside in hovered = inside ? "record" : nil }
        .scaleEffect(hovered == "record" ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "record"))
    }

    /// Expands the visual source chooser inside the notch.
    private var sourceButton: some View {
        let symbol: String
        switch controller.captureSource {
        case .display: symbol = "display"
        case .window:  symbol = "macwindow"
        case .phone:   symbol = "iphone"
        }
        return Button {
            showSources.toggle()
            expanded = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(hovered == "source" || showSources ? 1.0 : 0.65))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .onHover { inside in
            hovered = inside ? "source" : nil

        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "source"))
    }

    private var cameraToggleButton: some View {
        Button {
            controller.enableCamera.toggle()
        } label: {
            Image(systemName: controller.enableCamera ? "video.fill" : "video.slash.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(
                    controller.enableCamera
                        ? (hovered == "camera" ? 1.0 : 0.85)
                        : (hovered == "camera" ? 0.7 : 0.4)
                ))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .onHover { inside in hovered = inside ? "camera" : nil }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "camera"))
    }

    private var micToggleButton: some View {
        Button {
            controller.enableMicrophone.toggle()
        } label: {
            Image(systemName: controller.enableMicrophone ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(
                    controller.enableMicrophone
                        ? (hovered == "mic" ? 1.0 : 0.85)
                        : (hovered == "mic" ? 0.7 : 0.4)
                ))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .onHover { inside in hovered = inside ? "mic" : nil }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "mic"))
    }

    /// Accented "Show in Finder" CTA shown once a recording exists.
    private var revealButton: some View {
        Button {
            controller.revealLastRecording()
        } label: {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)

                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? "folder" : nil }
        .scaleEffect(hovered == "folder" ? 1.1 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "folder"))
    }

    /// Clear "processing" state shown in place of the record button while the
    /// recording is being compressed — a progress ring with the % inside plus
    /// a "Saving" caption, so it's obvious the file isn't ready yet.
    private var compressingIndicator: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, controller.compressionProgress))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: controller.compressionProgress)
                Text("\(Int(controller.compressionProgress * 100))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            }
            .frame(width: 40, height: 40)

            Text("Saving")
                .font(.system(size: 8, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.orange.opacity(0.9))
        }
        .frame(width: 42)
        .help("Compressing recording…")
    }

    private var backgroundSwatchButton: some View {
        Button {
            showBackgrounds.toggle()
        } label: {
            controller.background.swatch
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(hovered == "bg" ? 0.6 : 0.3), lineWidth: 1)
                )
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? "bg" : nil }
        .scaleEffect(hovered == "bg" ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .popover(isPresented: $showBackgrounds, arrowEdge: .top) {
            backgroundPopover
                .followsSystemAppearance()
        }
        .background(frameTracker(id: "bg"))
    }

    private var backgroundPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background").font(.headline)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
            var options: [BackgroundOption] {
                var list = BackgroundOption.presets
                if controller.background.id == "custom" { list.append(controller.background) }
                return list
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(options) { option in
                    let selected = controller.background.id == option.id
                    Button {
                        controller.background = option
                    } label: {
                        option.swatch
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.primary.opacity(0.2),
                                        lineWidth: selected ? 2.5 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isRecording)
                }
            }

            HStack {
                Spacer()
                Button("Custom image…") { controller.chooseBackgroundImage() }
                    .disabled(controller.isRecording)
            }

            Text("Layout").font(.headline)
                .padding(.top, 6)
            Picker("", selection: $controller.layout) {
                ForEach(FrameLayout.allCases) { l in
                    Text(l.rawValue).tag(l)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(controller.isRecording || controller.background.isNone)
            Text(controller.background.isNone
                 ? "No background: the recording is the whole video."
                 : controller.layout == .fullWidth
                    ? "A 16:9 presentation frame with the recording centred."
                    : "The frame wraps the recording with a small margin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func iconButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(hovered == id ? 1.0 : 0.65))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? id : nil }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: id))
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }

    /// Returns a transparent background view that reports this button's frame
    /// (in SwiftUI .global / window-relative coordinates) via ButtonFrameKey.
    private func frameTracker(id: String) -> some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: ButtonFrameKey.self,
                            value: [id: geo.frame(in: .global)])
        }
    }
}

private struct WispDotMark: View {
    private let glyphs = [
        ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
        ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        ["11110", "10001", "10001", "11110", "10000", "10000", "10000"]
    ]

    var body: some View {
        Canvas { context, _ in
            for (letter, rows) in glyphs.enumerated() {
                for (row, bits) in rows.enumerated() {
                    for (column, bit) in bits.enumerated() where bit == "1" {
                        let dot = CGRect(x: CGFloat(letter * 6 + column) * 2,
                                         y: CGFloat(row) * 2, width: 1.4, height: 1.4)
                        context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.9)))
                    }
                }
            }
        }
        .frame(width: CGFloat(glyphs.count * 12 - 2), height: 14)
        .accessibilityLabel("Wisp")
    }
}

private struct NotchOutline: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = 12
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let radius = min(bottomRadius, (right - left) / 2, (rect.height - shoulder) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                          control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: rect.maxY),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - radius),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct MicrophonePulse: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Capsule()
                    .fill(level > 0.02 ? Color.green.opacity(0.85) : Color.white.opacity(0.3))
                    .frame(width: 2, height: 3 + CGFloat(level) * (index == 1 ? 11 : 7))
            }
        }
        .frame(width: 10, height: 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input")
        .accessibilityValue(level > 0.02 ? "Receiving audio" : "Quiet")
        .help("Microphone input")
    }
}
