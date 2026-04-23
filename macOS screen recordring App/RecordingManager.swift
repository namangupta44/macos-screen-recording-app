import AVFoundation
import AppKit
import Combine
import CoreMedia
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum RecorderError: LocalizedError {
    case targetUnavailable
    case cameraConfigurationFailed
    case microphoneConfigurationFailed
    case writerSetupFailed
    case videoAppendFailed
    case audioAppendFailed
    case noScreenFramesCaptured
    case saveCancelled

    var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            return "The selected display or window is no longer available."
        case .cameraConfigurationFailed:
            return "The camera session could not be configured."
        case .microphoneConfigurationFailed:
            return "The microphone session could not be configured."
        case .writerSetupFailed:
            return "The output file writer could not be created."
        case .videoAppendFailed:
            return "A video frame could not be written."
        case .audioAppendFailed:
            return "An audio sample could not be written."
        case .noScreenFramesCaptured:
            return "No screen frames were captured. Re-select the source and try again."
        case .saveCancelled:
            return "Save was cancelled."
        }
    }
}

private enum ScreenCaptureAccessState {
    case unknown
    case granted
    case denied
}

@MainActor
final class RecordingManager: ObservableObject {
    @Published var screenTargets: [ScreenTarget] = []
    @Published var cameraDevices: [CaptureDevice] = []
    @Published var microphoneDevices: [CaptureDevice] = []

    @Published var selectedTargetID: String?
    @Published var selectedCameraID: String?
    @Published var selectedMicrophoneID: String?
    @Published var webcamSizeFraction: Double

    @Published var isRecording = false
    @Published var elapsedTimeText = "00:00"
    @Published var statusMessage = "Ready."
    @Published var permissionMessage = ""
    @Published var lastOutputPath = ""
    @Published private(set) var hasScreenRecordingPermission = false
    @Published var previewImage: NSImage?
    @Published var previewMessage = "Choose a display and camera to see the recording preview."
    @Published var startDisabledReason = "Choose a display or window to record."
    @Published var screenCaptureDiagnostics = ""

    var webcamSizeLabel: String {
        "\(Int(webcamSizeFraction * 100))%"
    }

    var canStartRecording: Bool {
        !isRecording && hasSelectedSource && selectedCameraID != nil && selectedMicrophoneID != nil
    }

    var shouldShowPermissionActions: Bool {
        !isRecording && (needsScreenRecordingPermission || needsScreenRecordingPermissionForPreview || needsCameraPermission || needsMicrophonePermission)
    }

    var shouldShowGrantPermissionsButton: Bool {
        !isRecording && (needsCameraPermission || needsMicrophonePermission)
    }

    var canRevealLastRecording: Bool {
        !lastOutputPath.isEmpty
    }

    var shouldShowRelaunchButton: Bool {
        !isRecording && (needsScreenRecordingPermission || needsScreenRecordingPermissionForPreview)
    }

    var isUsingSystemPickedSource: Bool {
        selectedTarget == nil && selectedPickerSelection != nil
    }

    var hasSelectedScreenSource: Bool {
        hasSelectedSource
    }

    var screenSourcePickerLabel: String {
        if let summary = selectedSourceSummary.nilIfEmpty {
            return summary
        }

        if screenTargets.isEmpty {
            return "No screen source selected"
        }

        return "Main display will be selected automatically when available."
    }

    var selectedSourceSummary: String {
        if let selectedTarget {
            return selectedTarget.name
        }

        if let selectedPickerSourceName {
            return selectedPickerSourceName
        }

        return ""
    }

    var needsScreenRecordingPermissionForPreview: Bool {
        !permissionsManager.hasScreenRecordingAccess()
    }

    private let defaults = UserDefaults.standard
    private let deviceManager = DeviceManager()
    private let permissionsManager = PermissionsManager()
    private let cameraCaptureManager = CameraCaptureManager()
    private let overlayPanelManager = OverlayPanelManager()
    private let screenCaptureManager = ScreenCaptureManager()
    private let screenSourcePickerManager = ScreenSourcePickerManager()
    private let cameraFrameStore = LatestCameraFrameStore()
    private let previewCompositor = VideoCompositor()
    private lazy var pipeline: RecordingPipeline = {
        let pipeline = RecordingPipeline(
            cameraFrameStore: cameraFrameStore,
            overlayLayoutStore: overlayPanelManager.layoutStore
        )
        pipeline.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handlePipelineFailure(error)
            }
        }
        return pipeline
    }()

    private var elapsedTimer: Timer?
    private var previewTimer: Timer?
    private var recordingStartDate: Date?
    private let previewSize = CGSize(width: 960, height: 540)
    private var selectedPickerSelection: ScreenCaptureSelection?
    private var selectedPickerSourceName: String?
    private var screenCaptureAccessState: ScreenCaptureAccessState = .unknown
    private var shouldForceScreenTargetReloadOnActivation = false

    init() {
        webcamSizeFraction = defaults.object(forKey: "overlay.sizeFraction") as? Double ?? 0.18
        syncScreenRecordingPermissionState()
        configureScreenSourcePickerCallbacks()
    }

    func prepare() async {
        await refreshSources()
        await refreshPreview()
    }

    func applicationDidBecomeActive() async {
        let shouldForceReload = shouldForceScreenTargetReloadOnActivation
        shouldForceScreenTargetReloadOnActivation = false
        syncScreenRecordingPermissionState()
        await refreshSources(forceScreenTargetReload: shouldForceReload)
        await refreshPreview()
    }

    func refreshSources(forceScreenTargetReload: Bool = false) async {
        let cameras = deviceManager.loadVideoDevices()
        let microphones = deviceManager.loadAudioDevices()
        syncScreenRecordingPermissionState()

        cameraDevices = cameras
        microphoneDevices = microphones
        selectedCameraID = resolveSelection(current: selectedCameraID, candidates: cameras.map(\.id), key: "selected.camera")
        selectedMicrophoneID = resolveSelection(current: selectedMicrophoneID, candidates: microphones.map(\.id), key: "selected.microphone")
        screenCaptureDiagnostics = ""

        guard forceScreenTargetReload || shouldAttemptAutomaticScreenTargetRefresh else {
            screenTargets = []

            if selectedPickerSelection == nil {
                selectedTargetID = nil
            }

            hasScreenRecordingPermission = selectedPickerSelection != nil
            permissionMessage = buildPermissionMessage()
            updateStatusMessage(cameraDevices: cameras, microphoneDevices: microphones)
            updateStartDisabledReason()
            return
        }

        guard selectedPickerSelection != nil || permissionsManager.hasScreenRecordingAccess() else {
            screenCaptureAccessState = .denied
            hasScreenRecordingPermission = false
            screenTargets = []
            selectedTargetID = nil
            permissionMessage = buildPermissionMessage()
            updateStatusMessage(cameraDevices: cameras, microphoneDevices: microphones)
            updateStartDisabledReason()
            return
        }

        do {
            let targets = try await deviceManager.loadScreenTargets()
            screenTargets = targets
            if reconcileSystemPickedSource(with: targets) == false, selectedPickerSelection == nil {
                selectedTargetID = resolveTargetSelection(current: selectedTargetID, targets: targets)
            }
            screenCaptureAccessState = .granted
            hasScreenRecordingPermission = true
        } catch {
            let hasPickerSelection = selectedPickerSelection != nil
            screenTargets = []

            if !hasPickerSelection {
                selectedTargetID = nil
            }

            screenCaptureDiagnostics = describe(error)

            if isScreenCapturePermissionError(error) {
                screenCaptureAccessState = hasPickerSelection ? .granted : .denied
                hasScreenRecordingPermission = hasPickerSelection
            } else {
                hasScreenRecordingPermission = hasPickerSelection || screenCaptureAccessState == .granted
                permissionMessage = buildPermissionMessage()
                statusMessage = hasPickerSelection
                    ? "Using the system-picked source while the source list is unavailable."
                    : "The app could not load the display and window list."
                updateStartDisabledReason()
                return
            }
        }

        permissionMessage = buildPermissionMessage()
        updateStatusMessage(cameraDevices: cameras, microphoneDevices: microphones)
        updateStartDisabledReason()
    }

    func refreshPreview() async {
        stopPreviewTimer()
        previewImage = nil
        syncPreviewOverlayLayout()
        syncScreenRecordingPermissionState()

        guard !isRecording else { return }

        cameraCaptureManager.onVideoFrame = { [weak self] pixelBuffer, _ in
            self?.cameraFrameStore.update(pixelBuffer)
        }
        cameraCaptureManager.onAudioSampleBuffer = nil

        guard let selectedCameraID else {
            cameraCaptureManager.stopRunning()
            previewMessage = cameraDevices.isEmpty
                ? "Connect or enable a camera to see a preview."
                : "Choose a camera to see a preview."
            return
        }

        do {
            try cameraCaptureManager.configure(videoDeviceID: selectedCameraID, audioDeviceID: nil)
            cameraCaptureManager.startRunning()
        } catch {
            previewMessage = error.localizedDescription
            return
        }

        guard hasSelectedSource else {
            previewMessage = hasScreenRecordingPermission
                ? "Choose a display or window from the list, or use Choose Screen Source to see the composited preview."
                : "Enable Screen Recording for this app in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch this app."
            return
        }

        guard canCapturePreview else {
            previewMessage = screenRecordingRelaunchMessage()
            permissionMessage = buildPermissionMessage()
            updateStatusMessage()
            updateStartDisabledReason()
            return
        }

        previewMessage = "Loading preview..."
        if await capturePreviewFrame() {
            startPreviewTimer()
        }
    }

    func selectedTargetChanged() async {
        if selectedTargetID != nil {
            clearSystemPickedSource()
        }
        defaults.set(selectedTargetID, forKey: "selected.target")
        updateStartDisabledReason()
        await refreshPreview()
    }

    func selectedCameraChanged() async {
        defaults.set(selectedCameraID, forKey: "selected.camera")
        updateStartDisabledReason()
        await refreshPreview()
    }

    func selectedMicrophoneChanged() {
        defaults.set(selectedMicrophoneID, forKey: "selected.microphone")
        updateStartDisabledReason()
    }

    func webcamSizeChanged() async {
        defaults.set(webcamSizeFraction, forKey: "overlay.sizeFraction")
        syncPreviewOverlayLayout()
        _ = await capturePreviewFrame()
    }

    func requestPermissions() async {
        switch await permissionsManager.ensureAVPermissions() {
        case .granted:
            statusMessage = "Ready."
        case .denied(let message):
            permissionMessage = message
            statusMessage = "Permission missing."
        }

        await refreshSources(forceScreenTargetReload: true)
        await refreshPreview()
    }

    func openSystemSettings() {
        shouldForceScreenTargetReloadOnActivation = true
        permissionsManager.openSystemSettings()
    }

    func relaunchApplication() {
        permissionsManager.relaunchApplication()
    }

    func revealLastRecording() {
        guard canRevealLastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastOutputPath)])
    }

    func presentScreenSourcePicker() {
        statusMessage = "Opening the system source picker..."
        screenSourcePickerManager.present()
    }

    func startRecording() async {
        guard await ensurePermissions() else { return }
        guard selectedCameraID != nil else {
            statusMessage = "Choose a camera to continue."
            return
        }
        guard selectedMicrophoneID != nil else {
            statusMessage = "Choose a microphone to continue."
            return
        }

        let activeSelection: (selection: ScreenCaptureSelection, sourceName: String)

        do {
            activeSelection = try await currentCaptureSelection()
        } catch {
            applyScreenCaptureFailure(error, status: "Choose a display or window to record.")
            await refreshPreview()
            return
        }

        permissionMessage = ""
        statusMessage = "Preparing recording..."
        stopPreviewTimer()

        do {
            let outputURL = try await requestOutputURL()

            try cameraCaptureManager.configure(videoDeviceID: selectedCameraID, audioDeviceID: selectedMicrophoneID)
            cameraCaptureManager.onVideoFrame = { [weak self] pixelBuffer, _ in
                self?.cameraFrameStore.update(pixelBuffer)
            }
            cameraCaptureManager.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.pipeline.appendAudio(sampleBuffer)
            }

            try pipeline.start(outputURL: outputURL, outputSize: CGSize(width: 1920, height: 1080))

            screenCaptureManager.onScreenSampleBuffer = { [weak self] sampleBuffer in
                self?.pipeline.appendScreen(sampleBuffer)
            }

            cameraCaptureManager.startRunning()
            overlayPanelManager.show(
                session: cameraCaptureManager.session,
                contentRect: activeSelection.selection.contentRect,
                sizeFraction: webcamSizeFraction
            )
            try await screenCaptureManager.start(filter: activeSelection.selection.filter)

            defaults.set(selectedTargetID, forKey: "selected.target")
            defaults.set(selectedCameraID, forKey: "selected.camera")
            defaults.set(selectedMicrophoneID, forKey: "selected.microphone")

            isRecording = true
            statusMessage = "Recording..."
            screenCaptureAccessState = .granted
            hasScreenRecordingPermission = true
            screenCaptureDiagnostics = ""
            startElapsedTimer()
        } catch RecorderError.saveCancelled {
            statusMessage = "Ready."
        } catch {
            await cleanupAfterFailure(error)
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        statusMessage = "Finishing recording..."
        stopElapsedTimer()
        isRecording = false

        await screenCaptureManager.stop()
        overlayPanelManager.hide()
        cameraCaptureManager.stopRunning()

        do {
            let outputURL = try await pipeline.finish()
            lastOutputPath = outputURL.path
            statusMessage = "Saved \(outputURL.lastPathComponent)."
        } catch {
            statusMessage = error.localizedDescription
        }

        await refreshPreview()
    }

    private var selectedTarget: ScreenTarget? {
        screenTargets.first(where: { $0.id == selectedTargetID })
    }

    private var hasSelectedSource: Bool {
        selectedTarget != nil || selectedPickerSelection != nil
    }

    private var hasUsableScreenRecordingAccess: Bool {
        screenCaptureAccessState == .granted || selectedPickerSelection != nil
    }

    private var canCapturePreview: Bool {
        selectedPickerSelection != nil || permissionsManager.hasScreenRecordingAccess()
    }

    private var shouldAttemptAutomaticScreenTargetRefresh: Bool {
        screenCaptureAccessState != .denied
    }

    private var needsScreenRecordingPermission: Bool {
        screenCaptureAccessState == .denied && selectedPickerSelection == nil
    }

    private var needsCameraPermission: Bool {
        permissionsManager.permissionState(for: .video) != .authorized
    }

    private var needsMicrophonePermission: Bool {
        permissionsManager.permissionState(for: .audio) != .authorized
    }

    private func ensurePermissions() async -> Bool {
        statusMessage = "Checking camera and microphone permissions..."

        switch await permissionsManager.ensureAVPermissions() {
        case .granted:
            await refreshSources(forceScreenTargetReload: selectedPickerSelection == nil)
            permissionMessage = buildPermissionMessage()
            return true
        case .denied(let message):
            permissionMessage = buildPermissionMessage()

            if permissionMessage.isEmpty {
                permissionMessage = message
            }

            statusMessage = "Permission missing."
            await refreshSources(forceScreenTargetReload: true)
            return false
        }
    }

    private func buildPermissionMessage() -> String {
        var messages: [String] = []

        if needsScreenRecordingPermission {
            messages.append("Screen Recording is unavailable for this app right now. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then return and refresh or choose the source again.")
        }

        if permissionsManager.permissionState(for: .video) == .denied {
            messages.append("Enable Camera access in System Settings > Privacy & Security > Camera.")
        }

        if permissionsManager.permissionState(for: .audio) == .denied {
            messages.append("Enable Microphone access in System Settings > Privacy & Security > Microphone.")
        }

        return messages.joined(separator: " ")
    }

    private func syncScreenRecordingPermissionState() {
        if permissionsManager.hasScreenRecordingAccess() {
            screenCaptureAccessState = .granted
            hasScreenRecordingPermission = true
        } else if selectedPickerSelection != nil {
            screenCaptureAccessState = .granted
            hasScreenRecordingPermission = true
        } else {
            screenCaptureAccessState = .denied
            hasScreenRecordingPermission = false
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        recordingStartDate = Date()
        elapsedTimeText = "00:00"

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recordingStartDate = self.recordingStartDate else { return }
                let interval = Int(Date().timeIntervalSince(recordingStartDate))
                let minutes = interval / 60
                let seconds = interval % 60
                self.elapsedTimeText = String(format: "%02d:%02d", minutes, seconds)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartDate = nil
        elapsedTimeText = "00:00"
    }

    private func cleanupAfterFailure(_ error: Error) async {
        await screenCaptureManager.stop()
        overlayPanelManager.hide()
        cameraCaptureManager.stopRunning()
        pipeline.cancel()
        isRecording = false
        stopElapsedTimer()
        applyScreenCaptureFailure(error, status: error.localizedDescription)
        previewMessage = "Preview stopped because recording setup failed."
    }

    private func resolveSelection(current: String?, candidates: [String], key: String) -> String? {
        if let current, candidates.contains(current) {
            return current
        }

        if let stored = defaults.string(forKey: key), candidates.contains(stored) {
            return stored
        }

        return candidates.first
    }

    private func resolveTargetSelection(current: String?, targets: [ScreenTarget]) -> String? {
        let candidateIDs = targets.map(\.id)

        if let current, candidateIDs.contains(current) {
            return current
        }

        if let stored = defaults.string(forKey: "selected.target"), candidateIDs.contains(stored) {
            return stored
        }

        return preferredDefaultTarget(in: targets)?.id
    }

    private func preferredDefaultTarget(in targets: [ScreenTarget]) -> ScreenTarget? {
        let mainDisplayID = "display-\(CGMainDisplayID())"

        if let mainDisplay = targets.first(where: { $0.kind == .display && $0.id == mainDisplayID }) {
            return mainDisplay
        }

        if let display = targets.first(where: { $0.kind == .display }) {
            return display
        }

        return targets.first
    }

    private func requestOutputURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType.movie]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Recording-\(timestamp()).mov"
            panel.prompt = "Record"
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: RecorderError.saveCancelled)
                }
            }
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: .now)
    }

    private func startPreviewTimer() {
        stopPreviewTimer()

        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.capturePreviewFrame()
            }
        }
    }

    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    private func capturePreviewFrame() async -> Bool {
        guard !isRecording else { return false }

        do {
            let activeSelection = try await currentCaptureSelection()
            let configuration = SCStreamConfiguration()
            configuration.width = Int(previewSize.width)
            configuration.height = Int(previewSize.height)
            configuration.showsCursor = true

            let screenImage = try await SCScreenshotManager.captureImage(
                contentFilter: activeSelection.selection.filter,
                configuration: configuration
            )

            let overlay = currentPreviewOverlayLayout()
            let compositedImage = previewCompositor.previewImage(
                screenImage: screenImage,
                cameraPixelBuffer: cameraFrameStore.current(),
                overlay: overlay,
                outputSize: previewSize
            ) ?? screenImage

            previewImage = NSImage(cgImage: compositedImage, size: previewSize)
            previewMessage = "Live preview"
            screenCaptureAccessState = .granted
            hasScreenRecordingPermission = true
            screenCaptureDiagnostics = ""
            permissionMessage = buildPermissionMessage()
            updateStatusMessage()
            updateStartDisabledReason()
            return true
        } catch {
            stopPreviewTimer()
            previewImage = nil
            applyScreenCaptureFailure(error, status: error.localizedDescription)
            if isScreenCapturePermissionError(error) || !permissionsManager.hasScreenRecordingAccess() {
                previewMessage = screenRecordingRelaunchMessage()
            } else {
                previewMessage = error.localizedDescription
            }
            return false
        }
    }

    private func screenRecordingRelaunchMessage() -> String {
        "Screen Recording access is required to preview and record.\n\nIf the toggle is already ON in System Settings > Privacy & Security > Screen & System Audio Recording, macOS still requires this app to be relaunched for the change to take effect. Click Relaunch App below."
    }

    private func syncPreviewOverlayLayout() {
        var layout = overlayPanelManager.layoutStore.current()
        layout.sizeFraction = webcamSizeFraction
        overlayPanelManager.layoutStore.update(layout)
    }

    private func currentPreviewOverlayLayout() -> OverlayLayout {
        syncPreviewOverlayLayout()
        return overlayPanelManager.layoutStore.current()
    }

    private func updateStartDisabledReason() {
        if !hasSelectedSource {
            startDisabledReason = "Choose a display or window from the list, or use Choose Screen Source."
        } else if selectedCameraID == nil {
            startDisabledReason = "Choose a camera to continue."
        } else if selectedMicrophoneID == nil {
            startDisabledReason = "Choose a microphone to continue."
        } else {
            startDisabledReason = ""
        }
    }

    private func isScreenCapturePermissionError(_ error: Error) -> Bool {
        guard !permissionsManager.hasScreenRecordingAccess() else {
            return false
        }

        let description = describe(error).localizedLowercase
        return description.contains("declined")
            || description.contains("tcc")
            || description.contains("screen recording")
            || description.contains("display capture")
    }

    private func updateStatusMessage(
        cameraDevices: [CaptureDevice]? = nil,
        microphoneDevices: [CaptureDevice]? = nil
    ) {
        let cameras = cameraDevices ?? self.cameraDevices
        let microphones = microphoneDevices ?? self.microphoneDevices

        if !hasSelectedSource {
            if needsScreenRecordingPermission {
                statusMessage = "Choose Screen Source, or grant Screen Recording access and refresh the source list."
            } else if screenTargets.isEmpty {
                statusMessage = "Use Choose Screen Source, or refresh the source list."
            } else {
                statusMessage = "Choose a display or window to continue."
            }
            return
        }

        if hasSelectedSource {
            if cameras.isEmpty {
                statusMessage = "No camera devices are currently available."
            } else if microphones.isEmpty {
                statusMessage = "No microphone devices are currently available."
            } else {
                statusMessage = "Ready."
            }
            return
        }

    }

    private func currentCaptureSelection() async throws -> (selection: ScreenCaptureSelection, sourceName: String) {
        if let selectedTarget {
            return (try await deviceManager.captureSelection(for: selectedTarget), selectedTarget.name)
        }

        if let selectedPickerSelection {
            return (selectedPickerSelection, selectedPickerSourceName ?? "System-picked source")
        }

        throw RecorderError.targetUnavailable
    }

    private func configureScreenSourcePickerCallbacks() {
        screenSourcePickerManager.onSelection = { [weak self] filter in
            Task { @MainActor [weak self] in
                self?.applySystemPickedSource(filter)
            }
        }
        screenSourcePickerManager.onCancel = { [weak self] in
            Task { @MainActor [weak self] in
                self?.statusMessage = "Source picking was cancelled."
            }
        }
        screenSourcePickerManager.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyScreenCaptureFailure(error, status: "The system source picker could not be opened.")
            }
        }
    }

    private func applySystemPickedSource(_ filter: SCContentFilter) {
        selectedPickerSelection = selection(from: filter)
        selectedPickerSourceName = sourceName(for: filter)
        selectedTargetID = nil

        if let selectedPickerSelection {
            _ = reconcileSystemPickedSource(with: screenTargets, selection: selectedPickerSelection)
        }

        screenCaptureAccessState = .granted
        hasScreenRecordingPermission = true
        screenCaptureDiagnostics = ""
        permissionMessage = buildPermissionMessage()
        updateStatusMessage()
        updateStartDisabledReason()

        Task {
            await refreshPreview()
        }
    }

    private func clearSystemPickedSource() {
        selectedPickerSelection = nil
        selectedPickerSourceName = nil
    }

    @discardableResult
    private func reconcileSystemPickedSource(
        with targets: [ScreenTarget],
        selection: ScreenCaptureSelection? = nil
    ) -> Bool {
        guard let selection = selection ?? selectedPickerSelection else { return false }
        guard let matchedTarget = matchingTarget(for: selection, in: targets) else { return false }

        selectedTargetID = matchedTarget.id
        clearSystemPickedSource()
        return true
    }

    private func selection(from filter: SCContentFilter) -> ScreenCaptureSelection {
        let contentRect = filter.contentRect
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let sourceSize = CGSize(
            width: max(contentRect.width * scale, 1),
            height: max(contentRect.height * scale, 1)
        )

        return ScreenCaptureSelection(
            filter: filter,
            contentRect: contentRect,
            sourceSize: sourceSize
        )
    }

    private func sourceName(for filter: SCContentFilter) -> String {
        let contentRect = filter.contentRect

        switch filter.style {
        case .display:
            if let screenName = NSScreen.screens.first(where: {
                $0.frame.approximatelyEquals(to: contentRect)
            })?.localizedName {
                return "\(screenName) — Entire Display"
            }
            return "Entire Display"
        case .window:
            return "Selected Window"
        case .application:
            return "Selected Application"
        default:
            return "Selected Source"
        }
    }

    private func applyScreenCaptureFailure(_ error: Error, status: String) {
        screenCaptureDiagnostics = describe(error)

        if isScreenCapturePermissionError(error) {
            screenCaptureAccessState = .denied
            hasScreenRecordingPermission = false
        }

        permissionMessage = buildPermissionMessage()
        statusMessage = status
        updateStartDisabledReason()
    }

    private func handlePipelineFailure(_ error: Error) async {
        guard isRecording else { return }
        await cleanupAfterFailure(error)
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    private func matchingTarget(for selection: ScreenCaptureSelection, in targets: [ScreenTarget]) -> ScreenTarget? {
        let expectedKind: ScreenTarget.Kind?

        switch selection.filter.style {
        case .display:
            expectedKind = .display
        case .window:
            expectedKind = .window
        default:
            expectedKind = nil
        }

        return targets.first { target in
            guard let expectedKind else { return false }
            return target.kind == expectedKind && target.frame.approximatelyEquals(to: selection.contentRect)
        }
    }
}

private final class RecordingPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder.pipeline")
    private let cameraFrameStore: LatestCameraFrameStore
    private let overlayLayoutStore: OverlayLayoutStore
    private let compositor = VideoCompositor()

    var onFailure: ((Error) -> Void)?

    private var writer: AssetWriterManager?
    private var terminalError: Error?

    init(cameraFrameStore: LatestCameraFrameStore, overlayLayoutStore: OverlayLayoutStore) {
        self.cameraFrameStore = cameraFrameStore
        self.overlayLayoutStore = overlayLayoutStore
    }

    func start(outputURL: URL, outputSize: CGSize) throws {
        terminalError = nil
        writer = try AssetWriterManager(outputURL: outputURL, outputSize: outputSize)
    }

    func appendScreen(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.terminalError == nil else { return }
            guard let writer = self.writer, let screenPixelBuffer = sampleBuffer.imageBuffer else {
                return
            }

            do {
                try writer.appendVideo(
                    screenPixelBuffer: screenPixelBuffer,
                    cameraPixelBuffer: self.cameraFrameStore.current(),
                    overlay: self.overlayLayoutStore.current(),
                    at: sampleBuffer.presentationTimeStamp,
                    compositor: self.compositor
                )
            } catch {
                self.fail(with: error)
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.terminalError == nil else { return }

            do {
                try self.writer?.appendAudio(sampleBuffer)
            } catch {
                self.fail(with: error)
            }
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let terminalError = self.terminalError {
                    self.writer = nil
                    continuation.resume(throwing: terminalError)
                    return
                }

                guard let writer = self.writer else {
                    continuation.resume(throwing: RecorderError.writerSetupFailed)
                    return
                }

                writer.finish { result in
                    self.writer = nil
                    continuation.resume(with: result)
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.writer?.cancel()
            self.terminalError = nil
            self.writer = nil
        }
    }

    private func fail(with error: Error) {
        guard terminalError == nil else { return }

        terminalError = error
        writer?.cancel()
        let onFailure = onFailure

        DispatchQueue.main.async {
            onFailure?(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension CGRect {
    func approximatelyEquals(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
