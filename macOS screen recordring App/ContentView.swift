import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recordingManager: RecordingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recorder")
                    .font(.system(size: 28, weight: .semibold))
                Text("Capture a display or window, composite a draggable facecam overlay, and write a single movie file.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Screen Source") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !recordingManager.screenTargets.isEmpty {
                                Picker("Screen Source", selection: $recordingManager.selectedTargetID) {
                                    ForEach(recordingManager.screenTargets) { target in
                                        Text(target.name).tag(Optional(target.id))
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 360)

                                if recordingManager.isUsingSystemPickedSource {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text(recordingManager.selectedSourceSummary)
                                            .foregroundStyle(.primary)
                                    }
                                    .font(.footnote)
                                }
                            } else if recordingManager.hasSelectedScreenSource {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(recordingManager.selectedSourceSummary)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: 360, alignment: .leading)
                            } else {
                                Text(recordingManager.screenSourcePickerLabel)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: 360, alignment: .leading)
                            }

                            Button(recordingManager.hasSelectedScreenSource ? "Change Screen Source…" : "Choose Screen Source…") {
                                recordingManager.presentScreenSourcePicker()
                            }
                            .disabled(recordingManager.isRecording)
                        }
                    }

                    LabeledContent("Camera") {
                        if recordingManager.cameraDevices.isEmpty {
                            Text("No cameras available")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360, alignment: .leading)
                        } else {
                            Picker("Camera", selection: $recordingManager.selectedCameraID) {
                                ForEach(recordingManager.cameraDevices) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 360)
                        }
                    }

                    LabeledContent("Microphone") {
                        if recordingManager.microphoneDevices.isEmpty {
                            Text("No microphones available")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360, alignment: .leading)
                        } else {
                            Picker("Microphone", selection: $recordingManager.selectedMicrophoneID) {
                                ForEach(recordingManager.microphoneDevices) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 360)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Webcam Size")
                            Spacer()
                            Text(recordingManager.webcamSizeLabel)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $recordingManager.webcamSizeFraction, in: 0.15...0.28, step: 0.01)
                            .disabled(recordingManager.isRecording)
                    }
                }
            }

            GroupBox("Preview") {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.18))

                    if let previewImage = recordingManager.previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: recordingManager.needsScreenRecordingPermissionForPreview ? "lock.display" : "display")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(recordingManager.previewMessage)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)

                            if recordingManager.needsScreenRecordingPermissionForPreview {
                                HStack(spacing: 8) {
                                    Button("Open System Settings") {
                                        recordingManager.openSystemSettings()
                                    }

                                    Button("Relaunch App") {
                                        recordingManager.relaunchApplication()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Refresh") {
                                        Task {
                                            await recordingManager.refreshSources(forceScreenTargetReload: true)
                                            await recordingManager.refreshPreview()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(24)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
            }

            HStack(spacing: 12) {
                Button("Refresh Sources") {
                    Task {
                        await recordingManager.refreshSources(forceScreenTargetReload: true)
                        await recordingManager.refreshPreview()
                    }
                }

                if recordingManager.shouldShowPermissionActions {
                    if recordingManager.shouldShowGrantPermissionsButton {
                        Button("Grant Permissions") {
                            Task {
                                await recordingManager.requestPermissions()
                            }
                        }
                    }

                    Button("Open System Settings") {
                        recordingManager.openSystemSettings()
                    }

                    if recordingManager.shouldShowRelaunchButton {
                        Button("Relaunch App") {
                            recordingManager.relaunchApplication()
                        }
                    }
                }

                if recordingManager.isRecording {
                    Button("Stop Recording") {
                        Task {
                            await recordingManager.stopRecording()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Start Recording") {
                        Task {
                            await recordingManager.startRecording()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!recordingManager.canStartRecording)
                }

                Spacer()

                if recordingManager.canRevealLastRecording {
                    Button("Reveal Last Recording") {
                        recordingManager.revealLastRecording()
                    }
                }

                if recordingManager.isRecording {
                    Label(recordingManager.elapsedTimeText, systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                }
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(recordingManager.statusMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !recordingManager.permissionMessage.isEmpty {
                        Text(recordingManager.permissionMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !recordingManager.startDisabledReason.isEmpty {
                        Text(recordingManager.startDisabledReason)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !recordingManager.screenCaptureDiagnostics.isEmpty {
                        Text("ScreenCaptureKit details: \(recordingManager.screenCaptureDiagnostics)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    Text("During recording, a circular webcam overlay appears above the selected source and can be dragged live.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !recordingManager.lastOutputPath.isEmpty {
                        Text("Last Recording: \(recordingManager.lastOutputPath)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
        .task {
            await recordingManager.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await recordingManager.applicationDidBecomeActive()
            }
        }
        .onChange(of: recordingManager.selectedTargetID) { _, _ in
            Task {
                await recordingManager.selectedTargetChanged()
            }
        }
        .onChange(of: recordingManager.selectedCameraID) { _, _ in
            Task {
                await recordingManager.selectedCameraChanged()
            }
        }
        .onChange(of: recordingManager.selectedMicrophoneID) { _, _ in
            recordingManager.selectedMicrophoneChanged()
        }
        .onChange(of: recordingManager.webcamSizeFraction) { _, _ in
            Task {
                await recordingManager.webcamSizeChanged()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RecordingManager())
}
