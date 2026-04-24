import AppKit
import AVFoundation
import Foundation

enum PermissionCheckResult {
    case granted
    case denied(String)
}

enum CapturePermissionState: Equatable {
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
        let microphoneGranted = await requestAVAccess(for: .audio)

        if cameraGranted && microphoneGranted {
            return .granted
        }

        var missingPermissions: [String] = []
        if !cameraGranted {
            missingPermissions.append("Camera")
        }
        if !microphoneGranted {
            missingPermissions.append("Microphone")
        }

        if missingPermissions.count == 1, let missingPermission = missingPermissions.first {
            return .denied("\(missingPermission) permission is required. Enable access in System Settings > Privacy & Security, then try again.")
        }

        return .denied("\(missingPermissions.joined(separator: " and ")) permissions are required. Enable access in System Settings > Privacy & Security, then try again.")
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
