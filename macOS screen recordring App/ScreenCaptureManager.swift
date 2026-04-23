@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

/// Wraps a single `SCStream` so it can feed both the live preview and the
/// recording pipeline simultaneously. The stream is started from an
/// `SCContentFilter` provided by `SCContentSharingPicker`, which is what
/// actually grants capture access on macOS 14+, so we never have to touch
/// `SCShareableContent` or `CGPreflightScreenCaptureAccess` anywhere in the
/// app. That's what keeps the system TCC prompt from reappearing.
final class ScreenCaptureManager: NSObject {
    /// Called on a background queue for every completed frame. Used by the
    /// preview pipeline.
    var onPreviewPixelBuffer: ((CVPixelBuffer) -> Void)?

    /// Called on a background queue for every completed frame. Used by the
    /// recording pipeline while a recording is in progress.
    var onRecordingSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called on the main queue if the stream stops unexpectedly.
    var onStreamError: ((Error) -> Void)?

    /// The `contentRect` of the currently active filter, in points. Useful for
    /// positioning the webcam overlay panel over the captured content.
    private(set) var currentContentRect: CGRect = .zero

    /// The pixel dimensions of the current stream output.
    private(set) var currentOutputSize: CGSize = .zero

    var isRunning: Bool { stream != nil }

    private let queue = DispatchQueue(label: "recorder.screen.output", qos: .userInteractive)
    private var stream: SCStream?
    private var currentFilter: SCContentFilter?

    func start(filter: SCContentFilter) async throws {
        await stop()

        let outputSize = Self.outputSize(for: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        self.stream = stream
        self.currentFilter = filter
        self.currentContentRect = filter.contentRect
        self.currentOutputSize = outputSize
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.currentFilter = nil
        self.currentContentRect = .zero
        self.currentOutputSize = .zero

        do {
            try await stream.stopCapture()
        } catch {
        }
    }

    private static func outputSize(for filter: SCContentFilter) -> CGSize {
        let rect = filter.contentRect
        let scale = max(filter.pointPixelScale, 1)
        let rawWidth = rect.width * CGFloat(scale)
        let rawHeight = rect.height * CGFloat(scale)

        // Cap at 1080p for reasonable perf; compositor will letterbox to a
        // 1920x1080 recording canvas anyway.
        let maxDimension: CGFloat = 1920
        let longest = max(rawWidth, rawHeight, 1)
        let factor = min(1, maxDimension / longest)
        let width = max(2, (rawWidth * factor).rounded(.down))
        let height = max(2, (rawHeight * factor).rounded(.down))

        // `SCStreamConfiguration.width/height` must be even for h.264.
        let evenWidth = Int(width) - (Int(width) % 2)
        let evenHeight = Int(height) - (Int(height) % 2)
        return CGSize(width: max(2, evenWidth), height: max(2, evenHeight))
    }
}

extension ScreenCaptureManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard Self.isComplete(sampleBuffer) else { return }

        if let pixelBuffer = sampleBuffer.imageBuffer {
            onPreviewPixelBuffer?(pixelBuffer)
        }

        onRecordingSampleBuffer?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let callback = onStreamError
        self.stream = nil
        self.currentFilter = nil
        self.currentContentRect = .zero
        self.currentOutputSize = .zero

        DispatchQueue.main.async {
            callback?(error)
        }
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first,
            let statusValue = first[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusValue)
        else {
            return false
        }

        return status == .complete
    }
}
