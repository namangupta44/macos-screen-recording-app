import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recordingManager: RecordingManager

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
                .background(SidebarBackground())

            Divider()

            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MainBackground())
        }
        .frame(minWidth: 980, minHeight: 640)
        .task {
            await recordingManager.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recordingManager.applicationDidBecomeActive() }
        }
        .onChange(of: recordingManager.selectedCameraID) { _, _ in
            recordingManager.selectedCameraChanged()
        }
        .onChange(of: recordingManager.selectedMicrophoneID) { _, _ in
            recordingManager.selectedMicrophoneChanged()
        }
        .onChange(of: recordingManager.webcamSizeFraction) { _, _ in
            recordingManager.webcamSizeChanged()
        }
        .onChange(of: recordingManager.webcamShape) { _, _ in
            recordingManager.webcamShapeChanged()
        }
        .onChange(of: recordingManager.webcamBorderStyle) { _, _ in
            recordingManager.webcamBorderStyleChanged()
        }
        .onChange(of: recordingManager.cursorHighlightEnabled) { _, _ in
            recordingManager.cursorEffectsChanged()
        }
        .onChange(of: recordingManager.cursorScale) { _, _ in
            recordingManager.cursorScaleChanged()
        }
        .onChange(of: recordingManager.cursorClickRingsEnabled) { _, _ in
            recordingManager.cursorEffectsChanged()
        }
        .onChange(of: recordingManager.cursorZoomEnabled) { _, _ in
            recordingManager.cursorEffectsChanged()
        }
        .onChange(of: recordingManager.cursorZoomScale) { _, _ in
            recordingManager.cursorZoomScaleChanged()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
                .padding(.horizontal, 20)
                .padding(.top, 40)
                .padding(.bottom, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sourceCard
                    cameraCard
                    microphoneCard
                    webcamLookCard
                    cursorEffectsCard

                    if recordingManager.needsAVPermissionsPrompt {
                        permissionsCard
                    }

                    if !recordingManager.permissionMessage.isEmpty {
                        permissionMessageBlock
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.35, blue: 0.42),
                                     Color(red: 0.93, green: 0.12, blue: 0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: .red.opacity(0.35), radius: 8, x: 0, y: 3)

                Image(systemName: "record.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recorder")
                    .font(.system(size: 15, weight: .semibold))
                Text("Facecam overlay · ready")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourceCard: some View {
        SettingsCard(
            icon: "rectangle.on.rectangle",
            iconTint: .blue,
            title: "Screen Source"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let name = recordingManager.pickedSourceName {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13, weight: .semibold))
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        Text("No source chosen")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    recordingManager.presentScreenSourcePicker()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: recordingManager.hasPickedSource ? "arrow.triangle.2.circlepath" : "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(recordingManager.hasPickedSource ? "Change Source" : "Choose Source")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SidebarButtonStyle(tint: recordingManager.hasPickedSource ? .secondary : .blue))
                .disabled(recordingManager.isRecording)
            }
        }
    }

    private var cameraCard: some View {
        SettingsCard(icon: "video.fill", iconTint: .purple, title: "Camera") {
            if recordingManager.cameraDevices.isEmpty {
                emptyRow(text: "No cameras available")
            } else {
                Picker("", selection: $recordingManager.selectedCameraID) {
                    ForEach(recordingManager.cameraDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(recordingManager.isRecording)
            }
        }
    }

    private var microphoneCard: some View {
        SettingsCard(icon: "mic.fill", iconTint: .orange, title: "Microphone") {
            if recordingManager.microphoneDevices.isEmpty {
                emptyRow(text: "No microphones available")
            } else {
                Picker("", selection: $recordingManager.selectedMicrophoneID) {
                    ForEach(recordingManager.microphoneDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(recordingManager.isRecording)
            }
        }
    }

    private var webcamLookCard: some View {
        SettingsCard(icon: "square.on.circle", iconTint: .teal, title: "Webcam Look") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Overlay scale")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(recordingManager.webcamSizeLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                }

                Slider(
                    value: $recordingManager.webcamSizeFraction,
                    in: Double(OverlayPanelManager.sizeFractionRange.lowerBound)...Double(OverlayPanelManager.sizeFractionRange.upperBound),
                    step: 0.01
                )
                    .controlSize(.small)
                    .tint(.red)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shape")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $recordingManager.webcamShape) {
                        ForEach(OverlayShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HStack(spacing: 10) {
                    Text("Border")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Picker("", selection: $recordingManager.webcamBorderStyle) {
                        ForEach(OverlayBorderStyle.allCases) { borderStyle in
                            Text(borderStyle.title).tag(borderStyle)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 118)
                }

                Button {
                    recordingManager.resetPreviewOverlayPosition()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Reset Position")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SidebarButtonStyle(tint: .secondary))
            }
        }
    }

    private var cursorEffectsCard: some View {
        SettingsCard(icon: "cursorarrow.motionlines", iconTint: .pink, title: "Cursor Effects") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cursor size")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(recordingManager.cursorScaleLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    }

                    Slider(
                        value: $recordingManager.cursorScale,
                        in: Double(CursorEffectSettings.cursorScaleRange.lowerBound)...Double(CursorEffectSettings.cursorScaleRange.upperBound),
                        step: 0.1
                    )
                    .controlSize(.small)
                    .tint(.pink)
                }

                Toggle(isOn: $recordingManager.cursorHighlightEnabled) {
                    Label("Highlight cursor", systemImage: "circle")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $recordingManager.cursorClickRingsEnabled) {
                    Label("Click rings", systemImage: "smallcircle.filled.circle")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $recordingManager.cursorZoomEnabled) {
                    Label("Follow zoom", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Zoom scale")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(recordingManager.cursorZoomScaleLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    }

                    Slider(
                        value: $recordingManager.cursorZoomScale,
                        in: Double(CursorEffectSettings.zoomScaleRange.lowerBound)...Double(CursorEffectSettings.zoomScaleRange.upperBound),
                        step: 0.25
                    )
                    .controlSize(.small)
                    .tint(.pink)
                    .disabled(!recordingManager.cursorZoomEnabled)
                }
                .opacity(recordingManager.cursorZoomEnabled ? 1 : 0.45)
            }
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 13, weight: .semibold))
                Text("Permissions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Text("Camera and microphone access is required to record.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await recordingManager.requestAVPermissions() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Grant Access")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SidebarButtonStyle(tint: .yellow))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.yellow.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var permissionMessageBlock: some View {
        Text(recordingManager.permissionMessage)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func emptyRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main area

    private var mainArea: some View {
        VStack(spacing: 0) {
            titleBar

            previewArea
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 20)

            Divider()

            bottomBar
        }
    }

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview")
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if recordingManager.isRecording {
                recordingPill
            } else if recordingManager.hasPickedSource {
                readyPill
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }

    private var subtitleText: String {
        if recordingManager.isRecording {
            return "Recording in progress · webcam overlay is live."
        } else if recordingManager.hasPickedSource {
            return "Live preview of your composition."
        } else {
            return "Pick a display or window to compose your recording."
        }
    }

    private var readyPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text("Ready")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.green.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.green.opacity(0.25), lineWidth: 0.5))
        .foregroundStyle(.green)
    }

    private var recordingPill: some View {
        HStack(spacing: 6) {
            PulsingDot()
            Text("REC")
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Text("·")
                .foregroundStyle(.secondary)
            Text(recordingManager.elapsedTimeText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.red.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.red.opacity(0.3), lineWidth: 0.5))
        .foregroundStyle(.red)
    }

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 6)

            if let previewImage = recordingManager.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if recordingManager.canPositionWebcamInPreview {
                    PreviewOverlayDragLayer(
                        normalizedCenter: recordingManager.overlayNormalizedCenter,
                        sizeFraction: CGFloat(recordingManager.webcamSizeFraction),
                        shape: recordingManager.webcamShape,
                        borderStyle: recordingManager.webcamBorderStyle
                    ) { displayPoint, displaySize in
                        recordingManager.updatePreviewOverlayCenter(
                            displayPoint: displayPoint,
                            in: displaySize
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                emptyPreview
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPreview: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 82, height: 82)
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: 82, height: 82)
                Image(systemName: recordingManager.hasPickedSource ? "display" : "rectangle.on.rectangle.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 6) {
                Text(recordingManager.hasPickedSource ? "Starting preview…" : "No source selected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(recordingManager.previewMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if !recordingManager.hasPickedSource {
                Button {
                    recordingManager.presentScreenSourcePicker()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Choose Screen Source")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(24)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            statusBlock

            Spacer()

            if recordingManager.canRevealLastRecording {
                Button {
                    recordingManager.revealLastRecording()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text("Reveal Last")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            }

            recordButton
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(recordingManager.statusMessage)
                    .font(.system(size: 12, weight: .medium))
            }
            if !recordingManager.lastOutputPath.isEmpty {
                Text(URL(fileURLWithPath: recordingManager.lastOutputPath).lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !recordingManager.startDisabledReason.isEmpty && !recordingManager.isRecording {
                Text(recordingManager.startDisabledReason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusDotColor: Color {
        if recordingManager.isRecording { return .red }
        if recordingManager.canStartRecording { return .green }
        return .orange
    }

    private var recordButton: some View {
        Group {
            if recordingManager.isRecording {
                Button {
                    Task { await recordingManager.stopRecording() }
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white)
                            .frame(width: 12, height: 12)
                        Text("Stop Recording")
                            .font(.system(size: 13, weight: .semibold))
                        Text(recordingManager.elapsedTimeText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                .buttonStyle(RecordButtonStyle(kind: .stop))
                .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    Task { await recordingManager.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                        Text("Start Recording")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                .buttonStyle(RecordButtonStyle(kind: .start))
                .keyboardShortcut(.defaultAction)
                .disabled(!recordingManager.canStartRecording)
            }
        }
    }
}

private struct PreviewOverlayDragLayer: View {
    let normalizedCenter: CGPoint
    let sizeFraction: CGFloat
    let shape: OverlayShape
    let borderStyle: OverlayBorderStyle
    let onMove: (CGPoint, CGSize) -> Void

    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let side = min(size.width, size.height) * sizeFraction
            let center = CGPoint(
                x: size.width * normalizedCenter.x,
                y: size.height * (1 - normalizedCenter.y)
            )

            OverlayPreviewShape(overlayShape: shape)
                .fill(Color.white.opacity(isHovering ? 0.05 : 0.001))
                .overlay {
                    if borderStyle != .none {
                        OverlayPreviewShape(overlayShape: shape)
                            .stroke(
                                borderStyle.previewBorderColor,
                                lineWidth: borderStyle.previewBorderWidth
                            )
                            .shadow(
                                color: borderStyle.previewShadowColor,
                                radius: borderStyle.previewShadowRadius,
                                x: 0,
                                y: 2
                            )
                    }
                }
                .overlay {
                    if isHovering {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: max(12, side * 0.12), weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(8)
                            .background(.black.opacity(0.48), in: Circle())
                    }
                }
                .overlay {
                    PreviewOverlayDragSurface(
                        shape: shape,
                        center: center,
                        onHoverChanged: { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isHovering = hovering
                            }
                        },
                        onMove: { displayPoint in
                            onMove(displayPoint, size)
                        }
                    )
                }
                .frame(width: side, height: side)
                .position(center)
                .help("Drag to position webcam")
        }
    }
}

private struct PreviewOverlayDragSurface: NSViewRepresentable {
    let shape: OverlayShape
    let center: CGPoint
    let onHoverChanged: (Bool) -> Void
    let onMove: (CGPoint) -> Void

    func makeNSView(context: Context) -> PreviewOverlayDragSurfaceView {
        let view = PreviewOverlayDragSurfaceView()
        view.overlayShape = shape
        view.centerPoint = center
        view.onHoverChanged = onHoverChanged
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: PreviewOverlayDragSurfaceView, context: Context) {
        nsView.overlayShape = shape
        nsView.centerPoint = center
        nsView.onHoverChanged = onHoverChanged
        nsView.onMove = onMove
    }
}

private final class PreviewOverlayDragSurfaceView: NSView {
    var overlayShape: OverlayShape = .circle
    var centerPoint: CGPoint = .zero
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onMove: (CGPoint) -> Void = { _ in }

    private var dragStartWindowPoint: CGPoint?
    private var dragStartCenter: CGPoint?
    private var isHoveringShape = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, shapeContains(point) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWindowPoint = event.locationInWindow
        dragStartCenter = centerPoint
        setHovering(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWindowPoint, let dragStartCenter else { return }

        onMove(
            CGPoint(
                x: dragStartCenter.x + event.locationInWindow.x - dragStartWindowPoint.x,
                y: dragStartCenter.y + dragStartWindowPoint.y - event.locationInWindow.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWindowPoint = nil
        dragStartCenter = nil
        updateHoverState(for: event)
    }

    private func updateHoverState(for event: NSEvent) {
        setHovering(shapeContains(convert(event.locationInWindow, from: nil)))
    }

    private func setHovering(_ hovering: Bool) {
        guard isHoveringShape != hovering else { return }
        isHoveringShape = hovering
        onHoverChanged(hovering)
    }

    private func shapeContains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }

        switch overlayShape {
        case .circle:
            let radiusX = bounds.width / 2
            let radiusY = bounds.height / 2
            guard radiusX > 0, radiusY > 0 else { return false }
            let normalizedX = (point.x - bounds.midX) / radiusX
            let normalizedY = (point.y - bounds.midY) / radiusY
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1
        case .roundedSquare:
            let radius = min(bounds.width, bounds.height) * 0.22
            return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(point)
        case .square:
            return true
        }
    }
}

private struct OverlayPreviewShape: Shape {
    let overlayShape: OverlayShape

    func path(in rect: CGRect) -> Path {
        switch overlayShape {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedSquare:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.22)
        case .square:
            return Path(rect)
        }
    }
}

private extension OverlayBorderStyle {
    var previewBorderColor: Color {
        switch self {
        case .soft:
            return .white.opacity(0.74)
        case .studio:
            return .white.opacity(0.95)
        case .glow:
            return Color(red: 0.45, green: 0.78, blue: 1.0).opacity(0.95)
        case .none:
            return .clear
        }
    }

    var previewBorderWidth: CGFloat {
        switch self {
        case .soft:
            return 2
        case .studio:
            return 4
        case .glow:
            return 3
        case .none:
            return 0
        }
    }

    var previewShadowColor: Color {
        switch self {
        case .soft:
            return .black.opacity(0.24)
        case .studio:
            return .black.opacity(0.32)
        case .glow:
            return Color(red: 0.2, green: 0.65, blue: 1.0).opacity(0.5)
        case .none:
            return .clear
        }
    }

    var previewShadowRadius: CGFloat {
        switch self {
        case .soft:
            return 6
        case .studio:
            return 8
        case .glow:
            return 12
        case .none:
            return 0
        }
    }
}

// MARK: - Reusable building blocks

private struct SettingsCard<Content: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 20, height: 20)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.3)
                Spacer(minLength: 0)
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint == .secondary ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundFill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private func backgroundFill(pressed: Bool) -> Color {
        if tint == .secondary {
            return Color.primary.opacity(pressed ? 0.10 : 0.06)
        }
        return tint.opacity(pressed ? 0.75 : 0.9)
    }

    private var borderColor: Color {
        tint == .secondary ? Color.primary.opacity(0.12) : Color.clear
    }
}

private struct RecordButtonStyle: ButtonStyle {
    enum Kind { case start, stop }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(gradient(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: shadowColor.opacity(isEnabled ? 0.35 : 0), radius: 10, x: 0, y: 4)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private func gradient(pressed: Bool) -> LinearGradient {
        let colors: [Color]
        switch kind {
        case .start:
            colors = pressed
                ? [Color(red: 0.93, green: 0.12, blue: 0.28), Color(red: 0.78, green: 0.08, blue: 0.22)]
                : [Color(red: 1.0, green: 0.35, blue: 0.42), Color(red: 0.93, green: 0.12, blue: 0.28)]
        case .stop:
            colors = pressed
                ? [Color(red: 0.26, green: 0.26, blue: 0.30), Color(red: 0.16, green: 0.16, blue: 0.20)]
                : [Color(red: 0.34, green: 0.34, blue: 0.38), Color(red: 0.22, green: 0.22, blue: 0.26)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var shadowColor: Color {
        kind == .start ? .red : .black
    }
}

private struct PulsingDot: View {
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(.red.opacity(0.4), lineWidth: 4)
                    .scaleEffect(animating ? 2.2 : 1)
                    .opacity(animating ? 0 : 0.8)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
    }
}

private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MainBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
        .environmentObject(RecordingManager())
}
