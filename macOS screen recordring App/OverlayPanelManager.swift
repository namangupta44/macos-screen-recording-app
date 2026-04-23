import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class OverlayPanelManager {
    private enum DefaultsKey {
        static let centerX = "overlay.centerX"
        static let centerY = "overlay.centerY"
        static let sizeFraction = "overlay.sizeFraction"
    }

    private let defaults = UserDefaults.standard
    private var session: AVCaptureSession?
    private var contentRect: CGRect = .zero
    private var panel: NSPanel?
    private var dragOrigin: CGPoint?

    let layoutStore: OverlayLayoutStore

    init() {
        let savedX = defaults.object(forKey: DefaultsKey.centerX) as? Double ?? 0.84
        let savedY = defaults.object(forKey: DefaultsKey.centerY) as? Double ?? 0.2
        let savedSize = defaults.object(forKey: DefaultsKey.sizeFraction) as? Double ?? 0.18

        layoutStore = OverlayLayoutStore(
            layout: OverlayLayout(
                normalizedCenter: CGPoint(x: savedX, y: savedY),
                sizeFraction: savedSize
            )
        )
    }

    func show(session: AVCaptureSession, contentRect: CGRect, sizeFraction: CGFloat) {
        self.session = session
        self.contentRect = contentRect

        var layout = layoutStore.current()
        layout.sizeFraction = sizeFraction
        layoutStore.update(layout)
        persist(layout)

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: overlayView(sizeFraction: sizeFraction))
        panel.setFrame(frameForOverlay(sizeFraction: sizeFraction, center: layout.normalizedCenter), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        dragOrigin = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func overlayView(sizeFraction: CGFloat) -> OverlayPanelView {
        OverlayPanelView(
            session: session ?? AVCaptureSession(),
            size: overlayDiameter(for: sizeFraction),
            onDragChanged: { [weak self] translation in
                self?.handleDragChanged(translation)
            },
            onDragEnded: { [weak self] in
                self?.handleDragEnded()
            }
        )
    }

    private func handleDragChanged(_ translation: CGSize) {
        guard let panel else { return }

        if dragOrigin == nil {
            dragOrigin = panel.frame.origin
        }

        guard let dragOrigin else { return }

        let nextOrigin = CGPoint(
            x: dragOrigin.x + translation.width,
            y: dragOrigin.y - translation.height
        )

        panel.setFrameOrigin(nextOrigin)
        updateLayoutFromPanelFrame()
    }

    private func handleDragEnded() {
        dragOrigin = nil
        snapToNearestCornerIfNeeded()
        updateLayoutFromPanelFrame()
    }

    private func snapToNearestCornerIfNeeded() {
        guard let panel, contentRect != .zero else { return }

        let threshold: CGFloat = 42
        var frame = panel.frame
        let minX = contentRect.minX
        let maxX = contentRect.maxX - frame.width
        let minY = contentRect.minY
        let maxY = contentRect.maxY - frame.height

        if abs(frame.minX - minX) < threshold { frame.origin.x = minX }
        if abs(frame.minX - maxX) < threshold { frame.origin.x = maxX }
        if abs(frame.minY - minY) < threshold { frame.origin.y = minY }
        if abs(frame.minY - maxY) < threshold { frame.origin.y = maxY }

        panel.setFrame(frame, display: true, animate: true)
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
    }

    private func overlayDiameter(for sizeFraction: CGFloat) -> CGFloat {
        max(150, min(contentRect.width, contentRect.height) * sizeFraction)
    }

    private func frameForOverlay(sizeFraction: CGFloat, center: CGPoint) -> CGRect {
        let diameter = overlayDiameter(for: sizeFraction)
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
    }
}

private struct OverlayPanelView: View {
    let session: AVCaptureSession
    let size: CGFloat
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        CameraPreviewView(session: session)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 4)
            }
            .shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 8)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDragChanged(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
            .background(Color.clear)
    }
}

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
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
