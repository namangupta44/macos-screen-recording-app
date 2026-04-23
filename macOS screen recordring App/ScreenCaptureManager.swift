@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

final class ScreenCaptureManager: NSObject {
    var onScreenSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "recorder.screen.output")
    private var stream: SCStream?

    func start(filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
        }
        self.stream = nil
    }
}

extension ScreenCaptureManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard isComplete(sampleBuffer) else { return }
        onScreenSampleBuffer?(sampleBuffer)
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
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
