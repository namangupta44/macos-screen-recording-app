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

enum OverlayShape: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle:
            return "Circle"
        case .roundedSquare:
            return "Rounded"
        case .square:
            return "Square"
        }
    }
}

enum OverlayBorderStyle: String, CaseIterable, Identifiable {
    case soft
    case studio
    case glow
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft:
            return "Soft"
        case .studio:
            return "Studio"
        case .glow:
            return "Glow"
        case .none:
            return "None"
        }
    }
}

struct OverlayLayout {
    var normalizedCenter: CGPoint
    var sizeFraction: CGFloat
    var shape: OverlayShape
    var borderStyle: OverlayBorderStyle
}

struct CursorEffectSettings {
    static let cursorScaleRange: ClosedRange<CGFloat> = 1.0...3.0
    static let zoomScaleRange: ClosedRange<CGFloat> = 1.25...3.0

    var cursorScale: CGFloat
    var isHighlightEnabled: Bool
    var isClickRingsEnabled: Bool
    var isZoomEnabled: Bool
    var zoomScale: CGFloat

    var hasEnabledEffects: Bool {
        cursorScale > 0 || isHighlightEnabled || isClickRingsEnabled || isZoomEnabled
    }
}

struct CursorFrameState {
    var normalizedLocation: CGPoint
    var leftClickProgress: CGFloat?
    var rightClickProgress: CGFloat?
    var settings: CursorEffectSettings
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

final class CursorStateStore {
    private let lock = NSLock()
    private var state: CursorFrameState?

    func update(_ state: CursorFrameState?) {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    func current() -> CursorFrameState? {
        lock.lock()
        let state = self.state
        lock.unlock()
        return state
    }
}
