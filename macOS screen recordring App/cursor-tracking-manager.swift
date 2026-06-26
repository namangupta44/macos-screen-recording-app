import AppKit
import Foundation

final class CursorTrackingManager {
    private let stateStore: CursorStateStore
    private let queue = DispatchQueue(label: "recorder.cursor.tracking", qos: .userInteractive)

    private var contentRect: CGRect = .zero
    private var settings = CursorEffectSettings(
        cursorScale: 1.5,
        isHighlightEnabled: true,
        isClickRingsEnabled: true,
        isZoomEnabled: false,
        zoomScale: 2.0
    )
    private var timer: DispatchSourceTimer?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var isTracking = false
    private var previousLeftButtonDown = false
    private var previousRightButtonDown = false
    private var lastLeftClick: TrackedCursorClick?
    private var lastRightClick: TrackedCursorClick?

    private let pulseDuration: TimeInterval = 0.55

    init(stateStore: CursorStateStore) {
        self.stateStore = stateStore
    }

    func start(contentRect: CGRect, settings: CursorEffectSettings) {
        queue.async { [weak self] in
            guard let self else { return }

            self.stopLocked()
            self.contentRect = contentRect
            self.settings = settings
            self.isTracking = true
            self.sample()
            self.startTimerLocked()
        }

        installClickMonitors()
    }

    func updateSettings(_ settings: CursorEffectSettings) {
        queue.async { [weak self] in
            guard let self else { return }

            self.settings = settings
            self.sample()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }

        removeClickMonitors()
    }

    private func startTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        isTracking = false
        contentRect = .zero
        previousLeftButtonDown = false
        previousRightButtonDown = false
        lastLeftClick = nil
        lastRightClick = nil
        stateStore.update(nil)
    }

    private func installClickMonitors() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.removeClickMonitorsOnMain()

            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            self.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }
            self.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleMouseDown(event)
            }
        }
    }

    private func removeClickMonitors() {
        DispatchQueue.main.async { [weak self] in
            self?.removeClickMonitorsOnMain()
        }
    }

    private func removeClickMonitorsOnMain() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        queue.async { [weak self] in
            guard let self, self.isTracking else { return }

            switch event.type {
            case .leftMouseDown:
                self.registerClick(isLeftButton: true)
            case .rightMouseDown:
                self.registerClick(isLeftButton: false)
            default:
                break
            }
        }
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

        if leftButtonDown && !previousLeftButtonDown {
            registerClick(isLeftButton: true, now: now, normalizedLocation: rawLocation)
        }
        if rightButtonDown && !previousRightButtonDown {
            registerClick(isLeftButton: false, now: now, normalizedLocation: rawLocation)
        }

        previousLeftButtonDown = leftButtonDown
        previousRightButtonDown = rightButtonDown

        publishState(now: now, normalizedLocation: rawLocation)
    }

    private func registerClick(isLeftButton: Bool) {
        let now = Date()
        let mouseLocation = NSEvent.mouseLocation
        guard contentRect.contains(mouseLocation) else { return }

        let normalizedLocation = CGPoint(
            x: ((mouseLocation.x - contentRect.minX) / contentRect.width).clamped(to: 0...1),
            y: ((mouseLocation.y - contentRect.minY) / contentRect.height).clamped(to: 0...1)
        )

        registerClick(isLeftButton: isLeftButton, now: now, normalizedLocation: normalizedLocation)
        publishState(now: now, normalizedLocation: normalizedLocation)
    }

    private func registerClick(isLeftButton: Bool, now: Date, normalizedLocation: CGPoint) {
        let click = TrackedCursorClick(date: now, normalizedLocation: normalizedLocation)
        if isLeftButton {
            lastLeftClick = click
            previousLeftButtonDown = true
        } else {
            lastRightClick = click
            previousRightButtonDown = true
        }
    }

    private func publishState(now: Date, normalizedLocation: CGPoint) {
        stateStore.update(
            CursorFrameState(
                normalizedLocation: normalizedLocation,
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
