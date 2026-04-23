import AVFoundation
import Foundation

final class CameraCaptureManager: NSObject {
    let session = AVCaptureSession()

    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "recorder.camera.session")
    private let videoQueue = DispatchQueue(label: "recorder.camera.video")
    private let audioQueue = DispatchQueue(label: "recorder.camera.audio")

    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?

    private lazy var audioDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    )

    override init() {
        super.init()

        session.beginConfiguration()
        session.sessionPreset = .high

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        // Force a stable, well-defined PCM format out of the mic. Without
        // this, AVCaptureAudioDataOutput hands us whatever the device is
        // currently producing — which can change sample rate / channel
        // count / float vs int between recording sessions (especially when
        // we detach and re-attach the audio input between preview and
        // recording). That causes the AVAssetWriter's AAC encoder to
        // prime on one format and then get fed another on the next run,
        // which is audible as heavy distortion / pitch shift on every
        // recording after the first.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
    }

    func configure(videoDeviceID: String?, audioDeviceID: String?) throws {
        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            if let currentVideoInput {
                session.removeInput(currentVideoInput)
                self.currentVideoInput = nil
            }

            if let currentAudioInput {
                session.removeInput(currentAudioInput)
                self.currentAudioInput = nil
            }

            if let videoDevice = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video,
                position: .unspecified
            ).devices.first(where: { $0.uniqueID == videoDeviceID }) ?? AVCaptureDevice.default(for: .video) {
                let input = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(input) else {
                    throw RecorderError.cameraConfigurationFailed
                }
                session.addInput(input)
                currentVideoInput = input
            }

            if let audioDeviceID,
               let audioDevice = audioDiscoverySession.devices.first(where: { $0.uniqueID == audioDeviceID }) ?? AVCaptureDevice.default(for: .audio) {
                let input = try AVCaptureDeviceInput(device: audioDevice)
                guard session.canAddInput(input) else {
                    throw RecorderError.microphoneConfigurationFailed
                }
                session.addInput(input)
                currentAudioInput = input
            }
        }
    }

    func startRunning() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopRunning() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput, let pixelBuffer = sampleBuffer.imageBuffer {
            onVideoFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
        } else if output === audioOutput {
            onAudioSampleBuffer?(sampleBuffer)
        }
    }
}
