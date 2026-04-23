@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import Foundation

struct DeviceManager {
    func loadScreenTargets() async throws -> [ScreenTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let displays = content.displays.map { display in
            ScreenTarget(
                id: "display-\(display.displayID)",
                name: displayName(for: display),
                kind: .display,
                frame: displayFrame(for: display)
            )
        }

        let windows = content.windows
            .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { window in
                let appName = window.owningApplication?.applicationName ?? "Window"
                let title = window.title?.isEmpty == false ? window.title! : "Untitled"
                return ScreenTarget(
                    id: "window-\(window.windowID)",
                    name: "\(appName) - \(title)",
                    kind: .window,
                    frame: window.frame
                )
            }

        return (displays + windows).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadVideoDevices() -> [CaptureDevice] {
        let discoveredDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices

        return discoveredDevices
            .map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadAudioDevices() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
            .map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func captureSelection(for target: ScreenTarget) async throws -> ScreenCaptureSelection {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch target.kind {
        case .display:
            guard let display = content.displays.first(where: { "display-\($0.displayID)" == target.id }) else {
                throw RecorderError.targetUnavailable
            }

            let excludedApps = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }

            return ScreenCaptureSelection(
                filter: SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []),
                contentRect: displayFrame(for: display),
                sourceSize: CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            )

        case .window:
            guard let window = content.windows.first(where: { "window-\($0.windowID)" == target.id }) else {
                throw RecorderError.targetUnavailable
            }

            return ScreenCaptureSelection(
                filter: SCContentFilter(desktopIndependentWindow: window),
                contentRect: window.frame,
                sourceSize: window.frame.size
            )
        }
    }

    func contentFilter(for target: ScreenTarget) async throws -> (SCContentFilter, CGRect) {
        let selection = try await captureSelection(for: target)
        return (selection.filter, selection.contentRect)
    }

    private func displayName(for display: SCDisplay) -> String {
        let screenName = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName

        return screenName.map { "\($0) Display" } ?? "Display \(display.displayID)"
    }

    private func displayFrame(for display: SCDisplay) -> CGRect {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) {
            return screen.frame
        }

        return CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
    }
}
