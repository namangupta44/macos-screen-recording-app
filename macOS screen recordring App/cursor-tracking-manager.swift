import AppKit
import Foundation

@MainActor
final class CursorTrackingManager {
    private let stateStore: CursorStateStore
    private var contentRect: CGRect = .zero
    private var settings = CursorEffectSettings(
        cursorScale: 1.5,
        isHighlightEnabled: true,
        isClickRingsEnabled: true,
        isZoomEnabled: false,
        zoomScale: 2.0
    )
    private var timer: Timer?
    private var previousLeftButtonDown = false
    private var previousRightButtonDown = false
    private var lastLeftClick: TrackedCursorClick?
    private var lastRightClick: TrackedCursorClick?
    private var smoothedLocation: CGPoint?

    private let pulseDuration: TimeInterval = 0.55
    private let smoothing: CGFloat = 0.35

    init(stateStore: CursorStateStore) {
        self.stateStore = stateStore
    }

    func start(contentRect: CGRect, settings: CursorEffectSettings) {
        stop()
        self.contentRect = contentRect
        self.settings = settings
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    func updateSettings(_ settings: CursorEffectSettings) {
        self.settings = settings
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        contentRect = .zero
        previousLeftButtonDown = false
        previousRightButtonDown = false
        lastLeftClick = nil
        lastRightClick = nil
        smoothedLocation = nil
        stateStore.update(nil)
    }

    private func sample() {
        guard settings.hasEnabledEffects, contentRect.width > 0, contentRect.height > 0 else {
            stateStore.update(nil)
            return
        }

        let now = Date()
        let leftButtonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let rightButtonDown = CGEventSource.buttonState(.hidSystemState, button: .right)

        let mouseLocation = NSEvent.mouseLocation
        guard contentRect.contains(mouseLocation) else {
            stateStore.update(nil)
            previousLeftButtonDown = leftButtonDown
            previousRightButtonDown = rightButtonDown
            return
        }

        let rawLocation = CGPoint(
            x: ((mouseLocation.x - contentRect.minX) / contentRect.width).clamped(to: 0...1),
            y: ((mouseLocation.y - contentRect.minY) / contentRect.height).clamped(to: 0...1)
        )
        let location = smoothedLocation.map { previous in
            CGPoint(
                x: previous.x + ((rawLocation.x - previous.x) * smoothing),
                y: previous.y + ((rawLocation.y - previous.y) * smoothing)
            )
        } ?? rawLocation
        smoothedLocation = location

        if leftButtonDown && !previousLeftButtonDown {
            lastLeftClick = TrackedCursorClick(date: now, normalizedLocation: location)
        }
        if rightButtonDown && !previousRightButtonDown {
            lastRightClick = TrackedCursorClick(date: now, normalizedLocation: location)
        }

        previousLeftButtonDown = leftButtonDown
        previousRightButtonDown = rightButtonDown

        stateStore.update(
            CursorFrameState(
                normalizedLocation: location,
                leftClick: clickState(for: lastLeftClick, now: now),
                rightClick: clickState(for: lastRightClick, now: now),
                settings: settings
            )
        )
    }

    private func clickState(for click: TrackedCursorClick?, now: Date) -> CursorClickFrameState? {
        guard settings.isClickRingsEnabled, let click else { return nil }

        let elapsed = now.timeIntervalSince(click.date)
        guard elapsed >= 0, elapsed <= pulseDuration else { return nil }
        return CursorClickFrameState(
            normalizedLocation: click.normalizedLocation,
            progress: CGFloat(elapsed / pulseDuration).clamped(to: 0...1)
        )
    }
}

private struct TrackedCursorClick {
    var date: Date
    var normalizedLocation: CGPoint
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
