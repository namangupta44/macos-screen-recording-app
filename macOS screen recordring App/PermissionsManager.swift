import AppKit
import AVFoundation
import Foundation

enum PermissionCheckResult {
    case granted
    case denied(String)
}

enum CapturePermissionState {
    case authorized
    case notDetermined
    case denied
}

/// Handles **only** camera and microphone permissions. Screen-recording
/// permission is handled entirely by `SCContentSharingPicker` — calling
/// `CGPreflightScreenCaptureAccess()` or `SCShareableContent` anywhere in the
/// app would re-fire the macOS TCC prompt even after the picker already
/// granted access, so we intentionally stay away from both.
struct PermissionsManager {
    func permissionState(for mediaType: AVMediaType) -> CapturePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func ensureAVPermissions() async -> PermissionCheckResult {
        let cameraGranted = await requestAVAccess(for: .video)
        guard cameraGranted else {
            return .denied("Camera permission is required. Enable it in System Settings > Privacy & Security > Camera, then try again.")
        }

        let microphoneGranted = await requestAVAccess(for: .audio)
        guard microphoneGranted else {
            return .denied("Microphone permission is required. Enable it in System Settings > Privacy & Security > Microphone, then try again.")
        }

        return .granted
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func requestAVAccess(for mediaType: AVMediaType) async -> Bool {
        switch permissionState(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied:
            return false
        }
    }
}
