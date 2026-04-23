@preconcurrency import ScreenCaptureKit
import AppKit
import Foundation

struct CaptureDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ScreenCaptureSelection {
    let filter: SCContentFilter
    let contentRect: CGRect
    let sourceSize: CGSize
}

struct OverlayLayout {
    var normalizedCenter: CGPoint
    var sizeFraction: CGFloat
}

final class OverlayLayoutStore {
    private let lock = NSLock()
    private var layout: OverlayLayout

    init(layout: OverlayLayout) {
        self.layout = layout
    }

    func update(_ layout: OverlayLayout) {
        lock.lock()
        self.layout = layout
        lock.unlock()
    }

    func current() -> OverlayLayout {
        lock.lock()
        let layout = self.layout
        lock.unlock()
        return layout
    }
}

final class LatestCameraFrameStore {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    func update(_ pixelBuffer: CVPixelBuffer?) {
        lock.lock()
        self.pixelBuffer = pixelBuffer
        lock.unlock()
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        let pixelBuffer = self.pixelBuffer
        lock.unlock()
        return pixelBuffer
    }
}
