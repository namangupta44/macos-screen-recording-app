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

struct PermissionsManager {
    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

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
            return .denied("Camera permission was denied. Grant access in System Settings > Privacy & Security > Camera.")
        }

        let microphoneGranted = await requestAVAccess(for: .audio)
        guard microphoneGranted else {
            return .denied("Microphone permission was denied. Grant access in System Settings > Privacy & Security > Microphone.")
        }

        return .granted
    }

    func openSystemSettings() {
        if let securityPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(securityPaneURL)
            return
        }

        let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(systemSettingsURL)
    }

    func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        let bundleURL = Bundle.main.bundleURL

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            NSApp.terminate(nil)
        }
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
