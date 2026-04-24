import AVFoundation
import AppKit
import Combine
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum RecorderError: LocalizedError {
    case sourceNotSelected
    case cameraConfigurationFailed
    case microphoneConfigurationFailed
    case writerSetupFailed
    case videoAppendFailed
    case audioAppendFailed
    case noScreenFramesCaptured
    case saveCancelled
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotSelected:
            return "Choose a screen or window to record first."
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
        case .streamFailed(let message):
            return "The screen capture stream stopped: \(message)"
        }
    }
}

@MainActor
final class RecordingManager: ObservableObject {
    // MARK: - UI state
    @Published var cameraDevices: [CaptureDevice] = []
    @Published var microphoneDevices: [CaptureDevice] = []
    @Published var selectedCameraID: String?
    @Published var selectedMicrophoneID: String?
    @Published var webcamSizeFraction: Double
    @Published var webcamShape: OverlayShape = .circle
    @Published var webcamBorderStyle: OverlayBorderStyle = .soft
    @Published var overlayNormalizedCenter: CGPoint = CGPoint(x: 0.84, y: 0.2)
    @Published var cursorScale = 1.5
    @Published var cursorHighlightEnabled = true
    @Published var cursorClickRingsEnabled = true
    @Published var cursorZoomEnabled = false
    @Published var cursorZoomScale = 2.0

    @Published var isRecording = false
    @Published var elapsedTimeText = "00:00"
    @Published var statusMessage = "Click Choose Screen Source to begin."
    @Published var permissionMessage = ""
    @Published var lastOutputPath = ""

    @Published var previewImage: NSImage?
    @Published var previewMessage = "Click Choose Screen Source to see a live preview."
    @Published var pickedSourceName: String?

    // MARK: - Computed
    var webcamSizeLabel: String { "\(Int(webcamSizeFraction * 100))%" }
    var cursorScaleLabel: String { "\(Int(cursorScale * 100))%" }
    var cursorZoomScaleLabel: String { String(format: "%.1fx", cursorZoomScale) }
    var canPositionWebcamInPreview: Bool { previewImage != nil && selectedCameraID != nil }

    var hasPickedSource: Bool { pickedSelection != nil }

    var canStartRecording: Bool {
        !isRecording && hasPickedSource && selectedCameraID != nil && selectedMicrophoneID != nil
    }

    var canRevealLastRecording: Bool { !lastOutputPath.isEmpty }

    var startDisabledReason: String {
        if !hasPickedSource { return "Click Choose Screen Source to pick a display or window." }
        if selectedCameraID == nil { return "Choose a camera to continue." }
        if selectedMicrophoneID == nil { return "Choose a microphone to continue." }
        return ""
    }

    var needsAVPermissionsPrompt: Bool {
        !isRecording && (needsCameraPermission || needsMicrophonePermission)
    }

    // MARK: - Collaborators
    private let defaults = UserDefaults.standard
    private let deviceManager = DeviceManager()
    private let permissionsManager = PermissionsManager()
    private let cameraCaptureManager = CameraCaptureManager()
    private let overlayPanelManager = OverlayPanelManager()
    private let screenCaptureManager = ScreenCaptureManager()
    private let screenSourcePickerManager = ScreenSourcePickerManager()
    private let cameraFrameStore = LatestCameraFrameStore()
    private let cursorStateStore = CursorStateStore()
    private lazy var cursorTrackingManager = CursorTrackingManager(stateStore: cursorStateStore)
    private lazy var previewRenderer: PreviewRenderPipeline = {
        let renderer = PreviewRenderPipeline(
            cameraFrameStore: cameraFrameStore,
            overlayLayoutStore: overlayPanelManager.layoutStore,
            cursorStateStore: cursorStateStore,
            outputSize: previewCanvasSize
        )
        renderer.onImage = { [weak self] image in
            Task { @MainActor [weak self] in
                self?.publishPreviewImage(image)
            }
        }
        return renderer
    }()

    private lazy var pipeline: RecordingPipeline = {
        let pipeline = RecordingPipeline(
            cameraFrameStore: cameraFrameStore,
            overlayLayoutStore: overlayPanelManager.layoutStore,
            cursorStateStore: cursorStateStore
        )
        pipeline.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handlePipelineFailure(error)
            }
        }
        return pipeline
    }()

    // MARK: - Private state
    private var pickedSelection: ScreenCaptureSelection?
    private var elapsedTimer: Timer?
    private var recordingStartDate: Date?
    private let previewCanvasSize = CGSize(width: 1280, height: 720)
    private let recordingCanvasSize = CGSize(width: 1920, height: 1080)

    // MARK: - Lifecycle

    init() {
        let savedSize = CGFloat(defaults.object(forKey: "overlay.sizeFraction") as? Double ?? 0.18)
        webcamSizeFraction = Double(OverlayPanelManager.clampedSizeFraction(savedSize))
        cursorScale = Double(Self.clampedCursorScale(CGFloat(defaults.object(forKey: "cursor.scale") as? Double ?? 1.5)))
        cursorHighlightEnabled = defaults.object(forKey: "cursor.highlightEnabled") as? Bool ?? true
        cursorClickRingsEnabled = defaults.object(forKey: "cursor.clickRingsEnabled") as? Bool ?? true
        cursorZoomEnabled = defaults.object(forKey: "cursor.zoomEnabled") as? Bool ?? false
        cursorZoomScale = Double(Self.clampedCursorZoomScale(CGFloat(defaults.object(forKey: "cursor.zoomScale") as? Double ?? 2.0)))
        let initialLayout = overlayPanelManager.layoutStore.current()
        webcamShape = initialLayout.shape
        webcamBorderStyle = initialLayout.borderStyle
        overlayNormalizedCenter = initialLayout.normalizedCenter
        configureOverlayCallbacks()
        configureCameraCallbacks()
        configureScreenCaptureCallbacks()
        configureScreenSourcePickerCallbacks()
    }

    func prepare() async {
        reloadDevices()
        startCameraPreviewIfPossible()
        refreshStatus()
    }

    func applicationDidBecomeActive() async {
        // IMPORTANT: no SCShareableContent / Preflight / SCContentSharingPicker
        // calls here. Anything that touches those APIs while we lack TCC will
        // re-fire the macOS Screen Recording prompt on every single activation.
        reloadDevices()
        startCameraPreviewIfPossible()
    }

    // MARK: - Device handling

    private func reloadDevices() {
        cameraDevices = deviceManager.loadVideoDevices()
        microphoneDevices = deviceManager.loadAudioDevices()

        selectedCameraID = resolveSelection(
            current: selectedCameraID,
            candidates: cameraDevices.map(\.id),
            key: "selected.camera"
        )
        selectedMicrophoneID = resolveSelection(
            current: selectedMicrophoneID,
            candidates: microphoneDevices.map(\.id),
            key: "selected.microphone"
        )
    }

    private func resolveSelection(current: String?, candidates: [String], key: String) -> String? {
        if let current, candidates.contains(current) { return current }
        if let stored = defaults.string(forKey: key), candidates.contains(stored) { return stored }
        return candidates.first
    }

    // MARK: - User actions

    func selectedCameraChanged() {
        defaults.set(selectedCameraID, forKey: "selected.camera")
        startCameraPreviewIfPossible()
        refreshStatus()
    }

    func selectedMicrophoneChanged() {
        defaults.set(selectedMicrophoneID, forKey: "selected.microphone")
        refreshStatus()
    }

    func webcamSizeChanged() {
        let clampedSizeFraction = OverlayPanelManager.clampedSizeFraction(CGFloat(webcamSizeFraction))
        if abs(webcamSizeFraction - Double(clampedSizeFraction)) > 0.0001 {
            webcamSizeFraction = Double(clampedSizeFraction)
        }
        defaults.set(Double(clampedSizeFraction), forKey: "overlay.sizeFraction")
        overlayPanelManager.updateSizeFraction(clampedSizeFraction)
        syncPreviewOverlayLayout()
    }

    func webcamShapeChanged() {
        overlayPanelManager.updateShape(webcamShape)
        syncPreviewOverlayLayout()
    }

    func webcamBorderStyleChanged() {
        overlayPanelManager.updateBorderStyle(webcamBorderStyle)
        syncPreviewOverlayLayout()
    }

    func cursorEffectsChanged() {
        defaults.set(cursorScale, forKey: "cursor.scale")
        defaults.set(cursorHighlightEnabled, forKey: "cursor.highlightEnabled")
        defaults.set(cursorClickRingsEnabled, forKey: "cursor.clickRingsEnabled")
        defaults.set(cursorZoomEnabled, forKey: "cursor.zoomEnabled")
        cursorTrackingManager.updateSettings(currentCursorEffectSettings())
    }

    func cursorScaleChanged() {
        let clampedScale = Self.clampedCursorScale(CGFloat(cursorScale))
        if abs(cursorScale - Double(clampedScale)) > 0.0001 {
            cursorScale = Double(clampedScale)
        }
        defaults.set(Double(clampedScale), forKey: "cursor.scale")
        cursorTrackingManager.updateSettings(currentCursorEffectSettings())
    }

    func cursorZoomScaleChanged() {
        let clampedScale = Self.clampedCursorZoomScale(CGFloat(cursorZoomScale))
        if abs(cursorZoomScale - Double(clampedScale)) > 0.0001 {
            cursorZoomScale = Double(clampedScale)
        }
        defaults.set(Double(clampedScale), forKey: "cursor.zoomScale")
        cursorTrackingManager.updateSettings(currentCursorEffectSettings())
    }

    func updatePreviewOverlayCenter(displayPoint: CGPoint, in displaySize: CGSize) {
        guard displaySize.width > 0, displaySize.height > 0 else { return }

        let side = min(displaySize.width, displaySize.height) * CGFloat(webcamSizeFraction)
        let xMargin = min(0.48, max(0.02, (side / 2) / displaySize.width))
        let yMargin = min(0.48, max(0.02, (side / 2) / displaySize.height))
        let normalizedCenter = CGPoint(
            x: (displayPoint.x / displaySize.width).clamped(to: xMargin...(1 - xMargin)),
            y: (1 - (displayPoint.y / displaySize.height)).clamped(to: yMargin...(1 - yMargin))
        )

        overlayNormalizedCenter = normalizedCenter
        overlayPanelManager.updateNormalizedCenter(normalizedCenter)
        syncPreviewOverlayLayout()
    }

    func resetPreviewOverlayPosition() {
        let normalizedCenter = CGPoint(x: 0.84, y: 0.2)
        overlayNormalizedCenter = normalizedCenter
        overlayPanelManager.updateNormalizedCenter(normalizedCenter)
        syncPreviewOverlayLayout()
    }

    func presentScreenSourcePicker() {
        statusMessage = "Opening system source picker…"
        screenSourcePickerManager.present()
    }

    func requestAVPermissions() async {
        switch await permissionsManager.ensureAVPermissions() {
        case .granted:
            permissionMessage = ""
            reloadDevices()
            startCameraPreviewIfPossible()
            refreshStatus()
        case .denied(let message):
            permissionMessage = message
            statusMessage = "Permission required."
        }
    }

    func openPrivacySettings() {
        permissionsManager.openPrivacySettings()
    }

    func revealLastRecording() {
        guard canRevealLastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastOutputPath)])
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard let pickedSelection else {
            statusMessage = "Choose a screen source to continue."
            return
        }
        guard await ensureAVPermissions() else { return }
        guard selectedCameraID != nil else {
            statusMessage = "Choose a camera to continue."
            return
        }
        guard selectedMicrophoneID != nil else {
            statusMessage = "Choose a microphone to continue."
            return
        }

        statusMessage = "Preparing recording…"

        let outputURL: URL
        do {
            outputURL = try await requestOutputURL()
        } catch RecorderError.saveCancelled {
            statusMessage = "Ready."
            return
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        do {
            try cameraCaptureManager.configure(
                videoDeviceID: selectedCameraID,
                audioDeviceID: selectedMicrophoneID
            )
            cameraCaptureManager.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.pipeline.appendAudio(sampleBuffer)
            }

            try pipeline.start(outputURL: outputURL, outputSize: recordingCanvasSize)
            startCursorTracking(for: pickedSelection)

            screenCaptureManager.onRecordingSampleBuffer = { [weak self] sampleBuffer in
                self?.pipeline.appendScreen(sampleBuffer)
            }

            cameraCaptureManager.startRunning()

            overlayPanelManager.show(
                session: cameraCaptureManager.session,
                contentRect: pickedSelection.contentRect,
                sizeFraction: webcamSizeFraction
            )

            isRecording = true
            statusMessage = "Recording…"
            startElapsedTimer()
        } catch {
            await cleanupAfterFailure(error)
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

        statusMessage = "Finishing recording…"
        stopElapsedTimer()
        isRecording = false

        screenCaptureManager.onRecordingSampleBuffer = nil
        overlayPanelManager.hide()
        cameraCaptureManager.onAudioSampleBuffer = nil

        do {
            let outputURL = try await pipeline.finish()
            lastOutputPath = outputURL.path
            statusMessage = "Saved \(outputURL.lastPathComponent)."
        } catch {
            statusMessage = error.localizedDescription
        }

        // Drop the microphone input so we don't keep it hot between takes.
        startCameraPreviewIfPossible()
        refreshStatus()
    }

    // MARK: - Camera preview (always-on AVCapture session)

    private func configureCameraCallbacks() {
        cameraCaptureManager.onVideoFrame = { [weak self] pixelBuffer, _ in
            self?.cameraFrameStore.update(pixelBuffer)
        }
    }

    private func startCameraPreviewIfPossible() {
        // Never reconfigure the AVCaptureSession while a recording is in
        // flight — doing so would yank the microphone input mid-recording
        // and drop audio samples.
        guard !isRecording else { return }

        guard let selectedCameraID else {
            cameraCaptureManager.stopRunning()
            return
        }

        guard permissionsManager.permissionState(for: .video) != .denied else {
            cameraCaptureManager.stopRunning()
            return
        }

        do {
            // Pass nil audio during preview — we only attach the mic when we
            // actually start recording, so the user isn't holding the mic
            // open while they compose.
            try cameraCaptureManager.configure(videoDeviceID: selectedCameraID, audioDeviceID: nil)
            cameraCaptureManager.startRunning()
        } catch {
        }
    }

    // MARK: - Screen capture (picker-driven)

    private func configureScreenCaptureCallbacks() {
        let previewRenderer = previewRenderer
        screenCaptureManager.onPreviewPixelBuffer = { pixelBuffer in
            previewRenderer.enqueue(pixelBuffer)
        }
        screenCaptureManager.onStreamError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleStreamError(error)
            }
        }
    }

    private func publishPreviewImage(_ composedImage: CGImage) {
        previewImage = NSImage(cgImage: composedImage, size: previewCanvasSize)
        previewMessage = ""
    }

    private func handleStreamError(_ error: Error) {
        let nsError = error as NSError
        pickedSelection = nil
        pickedSourceName = nil
        previewImage = nil
        previewRenderer.reset()
        overlayPanelManager.hide()

        if isRecording {
            isRecording = false
            stopElapsedTimer()
            pipeline.cancel()
            cameraCaptureManager.onAudioSampleBuffer = nil
            screenCaptureManager.onRecordingSampleBuffer = nil
            cursorTrackingManager.stop()
        }

        previewMessage = "The selected source stopped. Click Choose Screen Source to pick another."
        statusMessage = "Capture stopped: \(nsError.localizedDescription)"
    }

    private func configureScreenSourcePickerCallbacks() {
        screenSourcePickerManager.onSelection = { [weak self] filter in
            Task { @MainActor [weak self] in
                await self?.applyPickerFilter(filter)
            }
        }
        screenSourcePickerManager.onCancel = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
        screenSourcePickerManager.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.statusMessage = "Couldn't open source picker: \(error.localizedDescription)"
            }
        }
    }

    private func applyPickerFilter(_ filter: SCContentFilter) async {
        let selection = makeSelection(from: filter)
        pickedSelection = selection
        pickedSourceName = sourceName(for: filter)
        previewImage = nil
        previewRenderer.reset()
        previewMessage = "Starting live preview…"
        statusMessage = "Starting capture for \(pickedSourceName ?? "selected source")…"

        do {
            try await screenCaptureManager.start(filter: filter)
            startCursorTracking(for: selection)
            permissionMessage = ""
            refreshStatus()
        } catch {
            pickedSelection = nil
            pickedSourceName = nil
            cursorTrackingManager.stop()
            previewMessage = "Couldn't start capture: \(error.localizedDescription)"
            statusMessage = previewMessage
        }
    }

    private func makeSelection(from filter: SCContentFilter) -> ScreenCaptureSelection {
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

    // MARK: - Permissions

    private var needsCameraPermission: Bool {
        permissionsManager.permissionState(for: .video) != .authorized
    }

    private var needsMicrophonePermission: Bool {
        permissionsManager.permissionState(for: .audio) != .authorized
    }

    private func ensureAVPermissions() async -> Bool {
        switch await permissionsManager.ensureAVPermissions() {
        case .granted:
            permissionMessage = ""
            return true
        case .denied(let message):
            permissionMessage = message
            statusMessage = "Permission required."
            return false
        }
    }

    // MARK: - Status / overlay helpers

    private func configureOverlayCallbacks() {
        overlayPanelManager.onSizeFractionChanged = { [weak self] sizeFraction in
            guard let self else { return }
            self.webcamSizeFraction = Double(sizeFraction)
            self.defaults.set(Double(sizeFraction), forKey: "overlay.sizeFraction")
            self.syncPreviewOverlayLayout()
        }
        overlayPanelManager.onNormalizedCenterChanged = { [weak self] center in
            guard let self else { return }
            self.overlayNormalizedCenter = center
            self.syncPreviewOverlayLayout()
        }
    }

    private func refreshStatus() {
        if isRecording {
            statusMessage = "Recording…"
        } else if !hasPickedSource {
            statusMessage = "Click Choose Screen Source to begin."
        } else if cameraDevices.isEmpty {
            statusMessage = "No camera devices are currently available."
        } else if microphoneDevices.isEmpty {
            statusMessage = "No microphone devices are currently available."
        } else if selectedCameraID == nil {
            statusMessage = "Choose a camera to continue."
        } else if selectedMicrophoneID == nil {
            statusMessage = "Choose a microphone to continue."
        } else {
            statusMessage = "Ready."
        }
    }

    private func syncPreviewOverlayLayout() {
        var layout = overlayPanelManager.layoutStore.current()
        layout.sizeFraction = webcamSizeFraction
        layout.normalizedCenter = overlayNormalizedCenter
        layout.shape = webcamShape
        layout.borderStyle = webcamBorderStyle
        overlayPanelManager.layoutStore.update(layout)
    }

    private func currentPreviewOverlayLayout() -> OverlayLayout {
        syncPreviewOverlayLayout()
        return overlayPanelManager.layoutStore.current()
    }

    private func currentCursorEffectSettings() -> CursorEffectSettings {
        CursorEffectSettings(
            cursorScale: Self.clampedCursorScale(CGFloat(cursorScale)),
            isHighlightEnabled: cursorHighlightEnabled,
            isClickRingsEnabled: cursorClickRingsEnabled,
            isZoomEnabled: cursorZoomEnabled,
            zoomScale: Self.clampedCursorZoomScale(CGFloat(cursorZoomScale))
        )
    }

    private func startCursorTracking(for selection: ScreenCaptureSelection) {
        cursorTrackingManager.start(
            contentRect: selection.contentRect,
            settings: currentCursorEffectSettings()
        )
    }

    private static func clampedCursorScale(_ value: CGFloat) -> CGFloat {
        value.clamped(to: CursorEffectSettings.cursorScaleRange)
    }

    private static func clampedCursorZoomScale(_ value: CGFloat) -> CGFloat {
        value.clamped(to: CursorEffectSettings.zoomScaleRange)
    }

    // MARK: - Recording plumbing

    private func startElapsedTimer() {
        stopElapsedTimer()
        recordingStartDate = Date()
        elapsedTimeText = "00:00"

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartDate else { return }
                let interval = Int(Date().timeIntervalSince(start))
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
        screenCaptureManager.onRecordingSampleBuffer = nil
        cursorTrackingManager.stop()
        overlayPanelManager.hide()
        cameraCaptureManager.onAudioSampleBuffer = nil
        pipeline.cancel()
        isRecording = false
        stopElapsedTimer()
        startCameraPreviewIfPossible()
        statusMessage = error.localizedDescription
    }

    private func handlePipelineFailure(_ error: Error) async {
        guard isRecording else { return }
        await cleanupAfterFailure(error)
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
}

// MARK: - Preview rendering

private final class PreviewRenderPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder.preview.render", qos: .userInitiated)
    private let lock = NSLock()
    private let cameraFrameStore: LatestCameraFrameStore
    private let overlayLayoutStore: OverlayLayoutStore
    private let cursorStateStore: CursorStateStore
    private let outputSize: CGSize
    private let compositor = VideoCompositor()
    private let throttleInterval: TimeInterval = 1.0 / 20.0

    var onImage: ((CGImage) -> Void)?

    private var latestPixelBuffer: CVPixelBuffer?
    private var renderTimer: DispatchSourceTimer?
    private var generation = 0

    init(
        cameraFrameStore: LatestCameraFrameStore,
        overlayLayoutStore: OverlayLayoutStore,
        cursorStateStore: CursorStateStore,
        outputSize: CGSize
    ) {
        self.cameraFrameStore = cameraFrameStore
        self.overlayLayoutStore = overlayLayoutStore
        self.cursorStateStore = cursorStateStore
        self.outputSize = outputSize
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let shouldStartTimer: Bool

        lock.lock()
        latestPixelBuffer = pixelBuffer
        shouldStartTimer = renderTimer == nil
        lock.unlock()

        if shouldStartTimer {
            queue.async { [weak self] in
                self?.startTimerIfNeeded()
            }
        }
    }

    func reset() {
        let timer: DispatchSourceTimer?

        lock.lock()
        latestPixelBuffer = nil
        timer = renderTimer
        renderTimer = nil
        generation += 1
        lock.unlock()

        timer?.cancel()
    }

    private func startTimerIfNeeded() {
        lock.lock()
        guard renderTimer == nil else {
            lock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: throttleInterval, leeway: .milliseconds(8))
        renderTimer = timer
        lock.unlock()

        timer.setEventHandler { [weak self] in
            self?.renderLatestFrame()
        }
        timer.resume()
    }

    private func renderLatestFrame() {
        let pixelBuffer: CVPixelBuffer?
        let renderGeneration: Int

        lock.lock()
        pixelBuffer = latestPixelBuffer
        renderGeneration = generation
        lock.unlock()

        guard let pixelBuffer else { return }

        let image = compositor.previewImage(
            screenPixelBuffer: pixelBuffer,
            cameraPixelBuffer: cameraFrameStore.current(),
            overlay: overlayLayoutStore.current(),
            cursor: cursorStateStore.current(),
            outputSize: outputSize
        )

        if let image, isCurrentGeneration(renderGeneration) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGeneration(renderGeneration) else { return }
                self.onImage?(image)
            }
        }
    }

    private func isCurrentGeneration(_ renderGeneration: Int) -> Bool {
        lock.lock()
        let isCurrent = renderGeneration == generation
        lock.unlock()
        return isCurrent
    }
}

// MARK: - Recording pipeline (thread-safe writer wrapper)

private final class RecordingPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder.pipeline")
    private let cameraFrameStore: LatestCameraFrameStore
    private let overlayLayoutStore: OverlayLayoutStore
    private let cursorStateStore: CursorStateStore
    private let compositor = VideoCompositor()

    var onFailure: ((Error) -> Void)?

    private var writer: AssetWriterManager?
    private var terminalError: Error?

    init(
        cameraFrameStore: LatestCameraFrameStore,
        overlayLayoutStore: OverlayLayoutStore,
        cursorStateStore: CursorStateStore
    ) {
        self.cameraFrameStore = cameraFrameStore
        self.overlayLayoutStore = overlayLayoutStore
        self.cursorStateStore = cursorStateStore
    }

    func start(outputURL: URL, outputSize: CGSize) throws {
        terminalError = nil
        writer = try AssetWriterManager(outputURL: outputURL, outputSize: outputSize)
    }

    func appendScreen(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.terminalError == nil else { return }
            guard let writer = self.writer, let screenPixelBuffer = sampleBuffer.imageBuffer else { return }

            do {
                try writer.appendVideo(
                    screenPixelBuffer: screenPixelBuffer,
                    cameraPixelBuffer: self.cameraFrameStore.current(),
                    overlay: self.overlayLayoutStore.current(),
                    cursor: self.cursorStateStore.current(),
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

// MARK: - Helpers

private extension CGRect {
    func approximatelyEquals(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

private extension CMSampleBuffer {
    var presentationTimeStamp: CMTime {
        CMSampleBufferGetPresentationTimeStamp(self)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
