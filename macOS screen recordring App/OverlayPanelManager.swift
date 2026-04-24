import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayPanelState: ObservableObject {
    @Published var isMinimized: Bool
    @Published var isHovering: Bool = false
    @Published var sizeFraction: CGFloat
    @Published var normalDiameter: CGFloat
    @Published var shape: OverlayShape
    @Published var borderStyle: OverlayBorderStyle

    init(
        isMinimized: Bool,
        sizeFraction: CGFloat,
        normalDiameter: CGFloat,
        shape: OverlayShape,
        borderStyle: OverlayBorderStyle
    ) {
        self.isMinimized = isMinimized
        self.sizeFraction = sizeFraction
        self.normalDiameter = normalDiameter
        self.shape = shape
        self.borderStyle = borderStyle
    }
}

@MainActor
final class OverlayPanelManager {
    private enum DefaultsKey {
        static let centerX = "overlay.centerX"
        static let centerY = "overlay.centerY"
        static let sizeFraction = "overlay.sizeFraction"
        static let minimized = "overlay.minimized"
        static let shape = "overlay.shape"
        static let borderStyle = "overlay.borderStyle"
    }

    static let minimizedDiameter: CGFloat = 40
    static let sizeFractionRange: ClosedRange<CGFloat> = 0.12...0.36
    static let sizeStep: CGFloat = 0.02

    static func clampedSizeFraction(_ value: CGFloat) -> CGFloat {
        value.clamped(to: sizeFractionRange)
    }

    private let defaults = UserDefaults.standard
    private var session: AVCaptureSession?
    private var contentRect: CGRect = .zero
    private var sizeFraction: CGFloat = 0.18
    private var panel: NSPanel?
    private var frameObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    let layoutStore: OverlayLayoutStore
    let state: OverlayPanelState
    var onSizeFractionChanged: ((CGFloat) -> Void)?
    var onNormalizedCenterChanged: ((CGPoint) -> Void)?

    init() {
        let savedX = defaults.object(forKey: DefaultsKey.centerX) as? Double ?? 0.84
        let savedY = defaults.object(forKey: DefaultsKey.centerY) as? Double ?? 0.2
        let savedSize = Self.clampedSizeFraction(CGFloat(defaults.object(forKey: DefaultsKey.sizeFraction) as? Double ?? 0.18))
        let savedMinimized = defaults.bool(forKey: DefaultsKey.minimized)
        let savedShape = OverlayShape(rawValue: defaults.string(forKey: DefaultsKey.shape) ?? "") ?? .circle
        let savedBorderStyle = OverlayBorderStyle(rawValue: defaults.string(forKey: DefaultsKey.borderStyle) ?? "") ?? .soft

        self.sizeFraction = savedSize
        self.state = OverlayPanelState(
            isMinimized: savedMinimized,
            sizeFraction: savedSize,
            normalDiameter: 150,
            shape: savedShape,
            borderStyle: savedBorderStyle
        )
        self.layoutStore = OverlayLayoutStore(
            layout: OverlayLayout(
                normalizedCenter: CGPoint(x: savedX, y: savedY),
                sizeFraction: savedSize,
                shape: savedShape,
                borderStyle: savedBorderStyle
            )
        )

        observeState()
    }

    func show(session: AVCaptureSession, contentRect: CGRect, sizeFraction: CGFloat) {
        self.session = session
        self.contentRect = contentRect
        let clampedSizeFraction = Self.clampedSizeFraction(sizeFraction)
        self.sizeFraction = clampedSizeFraction
        state.sizeFraction = clampedSizeFraction
        state.normalDiameter = overlayDiameter(for: clampedSizeFraction)

        var layout = layoutStore.current()
        layout.sizeFraction = clampedSizeFraction
        state.shape = layout.shape
        state.borderStyle = layout.borderStyle
        layoutStore.update(layout)
        persist(layout)

        let panel = panel ?? makePanel()
        let hosting = DraggableHostingView(
            rootView: OverlayPanelView(
                session: session,
                state: state,
                minimizedDiameter: Self.minimizedDiameter,
                onSizeChange: { [weak self] newSizeFraction in
                    self?.updateSizeFraction(newSizeFraction, notify: true)
                }
            )
        )
        panel.contentView = hosting
        panel.setFrame(
            frameForOverlay(isMinimized: state.isMinimized, center: layout.normalizedCenter),
            display: true
        )
        panel.orderFrontRegardless()
        self.panel = panel

        observePanelMoves()
    }

    func updateSizeFraction(_ newSizeFraction: CGFloat) {
        updateSizeFraction(newSizeFraction, notify: false)
    }

    func updateNormalizedCenter(_ newCenter: CGPoint, notify: Bool = false) {
        guard contentRect != .zero || panel == nil else { return }

        let clampedCenter = CGPoint(
            x: newCenter.x.clamped(to: 0.02...0.98),
            y: newCenter.y.clamped(to: 0.02...0.98)
        )
        var layout = layoutStore.current()
        layout.normalizedCenter = clampedCenter
        layoutStore.update(layout)
        persist(layout)

        if let panel, contentRect != .zero {
            panel.setFrame(
                frameForOverlay(isMinimized: state.isMinimized, center: clampedCenter),
                display: true
            )
        }

        if notify {
            onNormalizedCenterChanged?(clampedCenter)
        }
    }

    func updateShape(_ shape: OverlayShape) {
        state.shape = shape
        var layout = layoutStore.current()
        layout.shape = shape
        layoutStore.update(layout)
        persist(layout)
    }

    func updateBorderStyle(_ borderStyle: OverlayBorderStyle) {
        state.borderStyle = borderStyle
        var layout = layoutStore.current()
        layout.borderStyle = borderStyle
        layoutStore.update(layout)
        persist(layout)
    }

    func hide() {
        panel?.orderOut(nil)
        removeFrameObserver()
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Let AppKit draw the shadow from the alpha mask of our content so
        // the drop shadow hugs the selected shape instead of being clipped to
        // the rectangular panel bounds.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    // MARK: - Observers

    private func observeState() {
        state.$isMinimized
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] minimized in
                self?.handleMinimizedChanged(minimized)
            }
            .store(in: &cancellables)
    }

    private func observePanelMoves() {
        removeFrameObserver()
        guard let panel else { return }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLayoutFromPanelFrame()
            }
        }
    }

    private func removeFrameObserver() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
    }

    // MARK: - State transitions

    private func handleMinimizedChanged(_ isMinimized: Bool) {
        defaults.set(isMinimized, forKey: DefaultsKey.minimized)

        guard let panel else { return }
        let layout = layoutStore.current()
        let frame = frameForOverlay(isMinimized: isMinimized, center: layout.normalizedCenter)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func updateSizeFraction(_ newSizeFraction: CGFloat, notify: Bool) {
        let clampedSizeFraction = Self.clampedSizeFraction(newSizeFraction)
        sizeFraction = clampedSizeFraction
        state.sizeFraction = clampedSizeFraction
        state.normalDiameter = overlayDiameter(for: clampedSizeFraction)

        var layout = layoutStore.current()
        layout.sizeFraction = clampedSizeFraction
        layoutStore.update(layout)
        persist(layout)

        if let panel, contentRect != .zero {
            let frame = frameForOverlay(isMinimized: state.isMinimized, center: layout.normalizedCenter)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        }

        if notify {
            onSizeFractionChanged?(clampedSizeFraction)
        }
    }

    private func updateLayoutFromPanelFrame() {
        guard let panel, contentRect != .zero else { return }

        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let normalizedX = ((center.x - contentRect.minX) / contentRect.width).clamped(to: 0.05...0.95)
        let normalizedY = ((center.y - contentRect.minY) / contentRect.height).clamped(to: 0.05...0.95)

        var layout = layoutStore.current()
        layout.normalizedCenter = CGPoint(x: normalizedX, y: normalizedY)
        layoutStore.update(layout)
        persist(layout)
        onNormalizedCenterChanged?(layout.normalizedCenter)
    }

    // MARK: - Geometry

    private func overlayDiameter(for sizeFraction: CGFloat) -> CGFloat {
        max(128, min(contentRect.width, contentRect.height) * sizeFraction)
    }

    private func frameForOverlay(isMinimized: Bool, center: CGPoint) -> CGRect {
        let diameter = isMinimized ? Self.minimizedDiameter : overlayDiameter(for: sizeFraction)
        let absoluteCenter = CGPoint(
            x: contentRect.minX + (contentRect.width * center.x),
            y: contentRect.minY + (contentRect.height * center.y)
        )

        return CGRect(
            x: absoluteCenter.x - (diameter / 2),
            y: absoluteCenter.y - (diameter / 2),
            width: diameter,
            height: diameter
        )
    }

    private func persist(_ layout: OverlayLayout) {
        defaults.set(layout.normalizedCenter.x, forKey: DefaultsKey.centerX)
        defaults.set(layout.normalizedCenter.y, forKey: DefaultsKey.centerY)
        defaults.set(layout.sizeFraction, forKey: DefaultsKey.sizeFraction)
        defaults.set(layout.shape.rawValue, forKey: DefaultsKey.shape)
        defaults.set(layout.borderStyle.rawValue, forKey: DefaultsKey.borderStyle)
    }
}

// MARK: - Hosting view that forwards clicks to window drag

/// Custom NSHostingView that lets the user grab empty regions of the overlay
/// and drag the whole panel around. SwiftUI `Button`s inside still receive
/// their own clicks because `mouseDown` is dispatched to the hit-tested
/// subview first; only events that bubble up to this view start a drag.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - SwiftUI content

private struct OverlayPanelView: View {
    let session: AVCaptureSession
    @ObservedObject var state: OverlayPanelState
    let minimizedDiameter: CGFloat
    let onSizeChange: (CGFloat) -> Void

    var body: some View {
        ZStack {
            if state.isMinimized {
                minimizedView
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                expandedView
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(
            width: state.isMinimized ? minimizedDiameter : state.normalDiameter,
            height: state.isMinimized ? minimizedDiameter : state.normalDiameter
        )
        .animation(.easeOut(duration: 0.2), value: state.isMinimized)
        .animation(.easeOut(duration: 0.16), value: state.normalDiameter)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                state.isHovering = hovering
            }
        }
    }

    // MARK: Expanded

    private var expandedView: some View {
        ZStack {
            CameraPreviewView(session: session)
                .clipShape(OverlayFrameShape(overlayShape: state.shape))
                .overlay {
                    if state.borderStyle != .none {
                        OverlayFrameShape(overlayShape: state.shape)
                            .stroke(
                                state.borderStyle.panelBorderColor,
                                lineWidth: state.borderStyle.panelBorderWidth
                            )
                            .shadow(
                                color: state.borderStyle.panelShadowColor,
                                radius: state.borderStyle.panelShadowRadius,
                                x: 0,
                                y: 2
                            )
                    }
                }

            OverlayFrameShape(overlayShape: state.shape)
                .fill(Color.black.opacity(state.isHovering ? 0.18 : 0))
                .allowsHitTesting(false)

            if state.isHovering {
                hoverChrome
                    .transition(.opacity)
            }
        }
    }

    private var hoverChrome: some View {
        VStack {
            HStack(spacing: 8) {
                OverlayChip(icon: "arrow.up.left.and.arrow.down.right", label: "Move")
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                OverlayIconButton(
                    icon: "minus",
                    help: "Hide webcam"
                ) {
                    state.isMinimized = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Spacer(minLength: 0)

            OverlaySizeControls(
                label: "\(Int(state.sizeFraction * 100))%",
                canDecrease: state.sizeFraction > OverlayPanelManager.sizeFractionRange.lowerBound,
                canIncrease: state.sizeFraction < OverlayPanelManager.sizeFractionRange.upperBound,
                decrease: {
                    onSizeChange(state.sizeFraction - OverlayPanelManager.sizeStep)
                },
                increase: {
                    onSizeChange(state.sizeFraction + OverlayPanelManager.sizeStep)
                }
            )
            .padding(.bottom, 10)
        }
    }

    // MARK: Minimized

    private var minimizedView: some View {
        Button {
            state.isMinimized = false
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.18, green: 0.18, blue: 0.22),
                                Color(red: 0.06, green: 0.06, blue: 0.09)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)

                Image(systemName: "video.fill")
                    .font(.system(size: minimizedDiameter * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                if state.isHovering {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                        .transition(.opacity)
                }
            }
            .frame(width: minimizedDiameter, height: minimizedDiameter)
        }
        .buttonStyle(.plain)
        .help("Show webcam")
    }
}

// MARK: - Chrome pieces

private struct OverlayFrameShape: Shape {
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

private struct OverlayIconButton: View {
    let icon: String
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(hovering ? 0.85 : 0.65))
                Circle()
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct OverlaySizeControls: View {
    let label: String
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            OverlayIconButton(
                icon: "minus",
                help: "Make webcam smaller",
                isEnabled: canDecrease,
                action: decrease
            )

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 34)

            OverlayIconButton(
                icon: "plus",
                help: "Make webcam larger",
                isEnabled: canIncrease,
                action: increase
            )
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct OverlayChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - Camera preview NSView

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.previewLayer.session = session
    }
}

private final class PreviewNSView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVCaptureVideoPreviewLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    // The preview layer is an opaque NSView, which by default swallows mouse
    // events and blocks the window's `isMovableByWindowBackground` handling.
    // Forward the click straight into a native window drag so users can grab
    // the live video feed itself and drag the overlay around.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

private extension OverlayBorderStyle {
    var panelBorderColor: Color {
        switch self {
        case .soft:
            return .white.opacity(0.72)
        case .studio:
            return .white.opacity(0.95)
        case .glow:
            return Color(red: 0.45, green: 0.78, blue: 1.0).opacity(0.95)
        case .none:
            return .clear
        }
    }

    var panelBorderWidth: CGFloat {
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

    var panelShadowColor: Color {
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

    var panelShadowRadius: CGFloat {
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
