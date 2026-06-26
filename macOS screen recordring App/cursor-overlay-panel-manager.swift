import AppKit
import Combine
import SwiftUI

@MainActor
final class CursorOverlayPanelState: ObservableObject {
    @Published var frameState: CursorFrameState?
    @Published var contentSize: CGSize = .zero
}

@MainActor
final class CursorOverlayPanelManager {
    private let stateStore: CursorStateStore
    private let state = CursorOverlayPanelState()
    private let queue = DispatchQueue(label: "recorder.cursor.overlay", qos: .userInteractive)
    private var panel: NSPanel?
    private var renderTimer: DispatchSourceTimer?
    private var isSystemCursorHidden = false
    private var isShowing = false
    private var activeOverlaySessionID = 0

    init(stateStore: CursorStateStore) {
        self.stateStore = stateStore
    }

    func show(contentRect: CGRect) {
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        activeOverlaySessionID += 1
        isShowing = true
        state.contentSize = contentRect.size

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: CursorOverlayView(state: state))
        panel.setFrame(contentRect, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        startRenderTimer(sessionID: activeOverlaySessionID)
    }

    func hide() {
        activeOverlaySessionID += 1
        isShowing = false
        renderTimer?.cancel()
        renderTimer = nil
        panel?.orderOut(nil)
        state.frameState = nil
        setSystemCursorHidden(false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func startRenderTimer(sessionID: Int) {
        renderTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let frameState = self.stateStore.current()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isShowing, sessionID == self.activeOverlaySessionID else { return }
                self.state.frameState = frameState
                self.setSystemCursorHidden(frameState != nil)
            }
        }
        renderTimer = timer
        timer.resume()
    }

    private func setSystemCursorHidden(_ hidden: Bool) {
        guard hidden != isSystemCursorHidden else { return }

        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }

        isSystemCursorHidden = hidden
    }
}

private struct CursorOverlayView: View {
    @ObservedObject var state: CursorOverlayPanelState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if let frameState = state.frameState, state.contentSize.width > 0, state.contentSize.height > 0 {
                cursorEffects(for: frameState, in: state.contentSize)
            }
        }
        .frame(width: state.contentSize.width, height: state.contentSize.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cursorEffects(for frameState: CursorFrameState, in size: CGSize) -> some View {
        let minDimension = min(size.width, size.height)
        let point = displayPoint(for: frameState.normalizedLocation, in: size)

        if frameState.settings.isHighlightEnabled {
            let radius = minDimension * 0.035
            Circle()
                .fill(Color(red: 1.0, green: 0.82, blue: 0.16).opacity(0.22))
                .overlay(
                    Circle()
                        .stroke(Color(red: 1.0, green: 0.74, blue: 0.08).opacity(0.82), lineWidth: max(3, radius * 0.08))
                )
                .frame(width: radius * 2, height: radius * 2)
                .position(point)
        }

        if let click = frameState.leftClick {
            clickRing(for: click, in: size, color: Color(red: 1.0, green: 0.72, blue: 0.06))
        }

        if let click = frameState.rightClick {
            clickRing(for: click, in: size, color: Color(red: 0.26, green: 0.78, blue: 1.0))
        }

        cursorShape(settings: frameState.settings, minDimension: minDimension)
            .position(cursorShapeCenter(hotspot: point, settings: frameState.settings, minDimension: minDimension))
    }

    private func clickRing(for click: CursorClickFrameState, in size: CGSize, color: Color) -> some View {
        let progress = click.progress.clamped(to: 0...1)
        let scale = max(0.65, min(size.width, size.height) / 720)
        let radius = (22 + (58 * progress)) * scale
        let lineWidth = max(4, 8 * (1 - progress) * scale)

        return Circle()
            .stroke(color.opacity(1 - progress), lineWidth: lineWidth)
            .frame(width: radius * 2, height: radius * 2)
            .position(displayPoint(for: click.normalizedLocation, in: size))
    }

    private func cursorShape(settings: CursorEffectSettings, minDimension: CGFloat) -> some View {
        let metrics = cursorMetrics(settings: settings, minDimension: minDimension)

        return CursorPointerShape()
            .fill(Color.white.opacity(0.96))
            .overlay(
                CursorPointerShape()
                    .stroke(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.92), lineWidth: max(2, metrics.height * 0.052))
            )
            .shadow(color: .black.opacity(0.28), radius: max(2, metrics.height * 0.055), x: max(1, metrics.height * 0.028), y: -max(1, metrics.height * 0.028))
            .frame(width: metrics.width, height: metrics.height)
    }

    private func cursorShapeCenter(hotspot: CGPoint, settings: CursorEffectSettings, minDimension: CGFloat) -> CGPoint {
        let metrics = cursorMetrics(settings: settings, minDimension: minDimension)
        return CGPoint(
            x: hotspot.x + ((metrics.width / 2) - metrics.hotspot.x),
            y: hotspot.y + ((metrics.height / 2) - metrics.hotspot.y)
        )
    }

    private func cursorMetrics(settings: CursorEffectSettings, minDimension: CGFloat) -> CursorOverlayMetrics {
        let height = max(28, minDimension * 0.044 * settings.cursorScale)
        let designSize = CGSize(width: 32, height: 36)
        let scale = height / designSize.height
        return CursorOverlayMetrics(
            width: designSize.width * scale,
            height: height,
            hotspot: CGPoint(x: 5 * scale, y: 2 * scale)
        )
    }

    private func displayPoint(for normalizedLocation: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * normalizedLocation.x,
            y: size.height * (1 - normalizedLocation.y)
        )
    }
}

private struct CursorPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 32
        let scaleY = rect.height / 36

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x * scaleX), y: rect.minY + (y * scaleY))
        }

        var path = Path()
        path.move(to: p(5, 2))
        path.addLine(to: p(5, 31))
        path.addLine(to: p(13.4, 22.6))
        path.addLine(to: p(18.2, 34))
        path.addLine(to: p(24.2, 31.5))
        path.addLine(to: p(19.5, 20.6))
        path.addLine(to: p(31, 20.6))
        path.closeSubpath()
        return path
    }
}

private struct CursorOverlayMetrics {
    let width: CGFloat
    let height: CGFloat
    let hotspot: CGPoint
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
