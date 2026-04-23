@preconcurrency import ScreenCaptureKit
import Foundation

@MainActor
final class ScreenSourcePickerManager: NSObject, @preconcurrency SCContentSharingPickerObserver {
    var onSelection: ((SCContentFilter) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let picker = SCContentSharingPicker.shared

    override init() {
        super.init()
        picker.add(self)
        picker.maximumStreamCount = 1
        applyConfiguration()
    }

    deinit {
        picker.remove(self)
    }

    func present() {
        applyConfiguration()
        picker.isActive = true
        picker.present()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        picker.isActive = false
        onCancel?()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        picker.isActive = false
        onSelection?(filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        picker.isActive = false
        onError?(error)
    }

    private func applyConfiguration() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        configuration.allowsChangingSelectedContent = true
        picker.defaultConfiguration = configuration
    }
}
