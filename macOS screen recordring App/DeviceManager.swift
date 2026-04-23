import AVFoundation
import Foundation

/// Enumerates video and audio input devices. We deliberately do NOT call any
/// `SCShareableContent` API here — doing so would re-trigger the macOS Screen
/// Recording TCC prompt on every app launch/activation. All screen-source
/// selection now goes through `SCContentSharingPicker`, which grants capture
/// access on a per-selection basis.
struct DeviceManager {
    func loadVideoDevices() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        .devices
        .map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadAudioDevices() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
