@preconcurrency import ScreenCaptureKit
import AppKit
import Foundation

struct CaptureDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ScreenRecordingQuality: String, CaseIterable, Identifiable {
    case maximum
    case high
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum:
            return "Maximum"
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        }
    }

    var detail: String {
        switch self {
        case .maximum:
            return "Up to 4K source"
        case .high:
            return "Up to 1080p"
        case .medium:
            return "Up to 720p"
        case .low:
            return "Up to 480p"
        }
    }

    var maximumDimension: CGFloat {
        switch self {
        case .maximum:
            return 3840
        case .high:
            return 1920
        case .medium:
            return 1280
        case .low:
            return 854
        }
    }

    func outputSize(for sourceSize: CGSize) -> CGSize {
        Self.evenSizeFitting(sourceSize, maximumDimension: maximumDimension)
    }

    func videoBitRate(for outputSize: CGSize) -> Int {
        let pixelRatio = max(CGFloat(1), (outputSize.width * outputSize.height) / CGFloat(1920 * 1080))

        switch self {
        case .maximum:
            return min(80_000_000, max(20_000_000, Int(pixelRatio * 20_000_000)))
        case .high:
            return min(28_000_000, max(14_000_000, Int(pixelRatio * 14_000_000)))
        case .medium:
            return 8_000_000
        case .low:
            return 4_000_000
        }
    }

    static func evenSizeFitting(_ sourceSize: CGSize, maximumDimension: CGFloat) -> CGSize {
        let rawWidth = max(sourceSize.width, 2)
        let rawHeight = max(sourceSize.height, 2)
        let longest = max(rawWidth, rawHeight)
        let factor = min(1, maximumDimension / longest)
        let width = max(2, (rawWidth * factor).rounded(.down))
        let height = max(2, (rawHeight * factor).rounded(.down))

        let evenWidth = Int(width) - (Int(width) % 2)
        let evenHeight = Int(height) - (Int(height) % 2)
        return CGSize(width: max(2, evenWidth), height: max(2, evenHeight))
    }
}

enum CameraRecordingQuality: String, CaseIterable, Identifiable {
    case maximum
    case high
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum:
            return "Maximum"
        case .high:
            return "High"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        }
    }

    var detail: String {
        switch self {
        case .maximum:
            return "Best available"
        case .high:
            return "1080p if available"
        case .medium:
            return "720p if available"
        case .low:
            return "Lower bandwidth"
        }
    }
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
    var leftClick: CursorClickFrameState?
    var rightClick: CursorClickFrameState?
    var settings: CursorEffectSettings
}

struct CursorClickFrameState {
    var normalizedLocation: CGPoint
    var progress: CGFloat
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
