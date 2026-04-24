import AVFoundation
import Foundation

final class AssetWriterManager {
    let outputURL: URL
    let outputSize: CGSize

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor

    private var sourceStartTime: CMTime?
    private var appendedVideoFrameCount = 0
    private var primedAudioFormat: CMFormatDescription?

    init(outputURL: URL, outputSize: CGSize) throws {
        self.outputURL = outputURL
        self.outputSize = outputSize

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        // Use AAC so AVAssetWriter handles sample-rate / channel-count /
        // bit-depth conversion for us. If we ask for Linear PCM here, the
        // writer does *no* conversion and the input sample buffers must
        // match the output settings byte-for-byte — otherwise the audio
        // gets reinterpreted as the wrong format and comes out distorted.
        // AVCaptureAudioDataOutput on macOS hands us 32-bit float,
        // non-interleaved buffers at the device's native sample rate, so
        // encoding to AAC is both safer and what we actually want.
        var audioChannelLayout = AudioChannelLayout()
        audioChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let channelLayoutData = Data(
            bytes: &audioChannelLayout,
            count: MemoryLayout<AudioChannelLayout>.size
        )

        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: channelLayoutData
            ]
        )
        audioInput.expectsMediaDataInRealTime = true

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputSize.width,
                kCVPixelBufferHeightKey as String: outputSize.height
            ]
        )

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.writerSetupFailed
        }

        writer.add(videoInput)
        writer.add(audioInput)
    }

    func appendVideo(
        screenPixelBuffer: CVPixelBuffer,
        cameraPixelBuffer: CVPixelBuffer?,
        overlay: OverlayLayout,
        cursor: CursorFrameState?,
        at time: CMTime,
        compositor: VideoCompositor
    ) throws {
        if sourceStartTime == nil {
            guard writer.startWriting() else {
                throw writer.error ?? RecorderError.writerSetupFailed
            }

            writer.startSession(atSourceTime: .zero)
            sourceStartTime = time
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        guard let sourceStartTime, let pool = pixelBufferAdaptor.pixelBufferPool else {
            throw RecorderError.writerSetupFailed
        }

        let presentationTime = CMTimeSubtract(time, sourceStartTime)
        guard presentationTime.isValid, CMTimeCompare(presentationTime, .zero) >= 0 else {
            throw RecorderError.videoAppendFailed
        }

        var renderedPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &renderedPixelBuffer)

        guard let renderedPixelBuffer else {
            throw RecorderError.writerSetupFailed
        }

        compositor.render(
            screenPixelBuffer: screenPixelBuffer,
            cameraPixelBuffer: cameraPixelBuffer,
            overlay: overlay,
            cursor: cursor,
            into: renderedPixelBuffer,
            outputSize: outputSize
        )

        if !pixelBufferAdaptor.append(renderedPixelBuffer, withPresentationTime: presentationTime) {
            throw writer.error ?? RecorderError.videoAppendFailed
        }

        appendedVideoFrameCount += 1
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard audioInput.isReadyForMoreMediaData else { return }
        guard let sourceStartTime else { return }
        guard sampleBuffer.presentationTimeStamp >= sourceStartTime else { return }

        // Lock the audio format to the first buffer we accept. Any later
        // buffer that arrives with a different ASBD (different sample
        // rate, channel count, or sample format) would poison the AAC
        // encoder mid-stream and come out distorted, so drop it instead.
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if let primedAudioFormat {
            if !CMFormatDescriptionEqual(primedAudioFormat, otherFormatDescription: formatDescription) {
                return
            }
        } else {
            primedAudioFormat = formatDescription
        }

        guard let adjustedBuffer = sampleBuffer.offsettingTime(by: sourceStartTime) else {
            throw RecorderError.audioAppendFailed
        }

        if !audioInput.append(adjustedBuffer) {
            throw writer.error ?? RecorderError.audioAppendFailed
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard appendedVideoFrameCount > 0 else {
            cancel()
            completion(.failure(RecorderError.noScreenFramesCaptured))
            return
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()

        writer.finishWriting {
            if let error = self.writer.error {
                completion(.failure(error))
            } else {
                completion(.success(self.outputURL))
            }
        }
    }

    func cancel() {
        writer.cancelWriting()
    }
}

private extension CMSampleBuffer {
    var presentationTimeStamp: CMTime {
        CMSampleBufferGetPresentationTimeStamp(self)
    }

    func offsettingTime(by startTime: CMTime) -> CMSampleBuffer? {
        let sampleCount = max(1, CMSampleBufferGetNumSamples(self))
        var timingInfo = Array(repeating: CMSampleTimingInfo(), count: sampleCount)
        var actualCount = 0

        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: timingInfo.count,
            arrayToFill: &timingInfo,
            entriesNeededOut: &actualCount
        )

        guard timingStatus == noErr else { return nil }

        for index in 0..<actualCount {
            timingInfo[index].presentationTimeStamp = CMTimeSubtract(timingInfo[index].presentationTimeStamp, startTime)
            timingInfo[index].decodeTimeStamp = CMTimeSubtract(timingInfo[index].decodeTimeStamp, startTime)
        }

        var adjustedBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: actualCount,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )

        guard copyStatus == noErr else { return nil }
        return adjustedBuffer
    }
}
