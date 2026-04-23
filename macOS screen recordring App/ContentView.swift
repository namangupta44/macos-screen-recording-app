import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recordingManager: RecordingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            GroupBox { sourceSection }

            GroupBox("Preview") { previewArea }

            controlsRow

            GroupBox("Status") { statusSection }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 560)
        .task {
            await recordingManager.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recordingManager.applicationDidBecomeActive() }
        }
        .onChange(of: recordingManager.selectedCameraID) { _, _ in
            recordingManager.selectedCameraChanged()
        }
        .onChange(of: recordingManager.selectedMicrophoneID) { _, _ in
            recordingManager.selectedMicrophoneChanged()
        }
        .onChange(of: recordingManager.webcamSizeFraction) { _, _ in
            recordingManager.webcamSizeChanged()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recorder")
                .font(.system(size: 28, weight: .semibold))
            Text("Pick a display or window, composite a draggable facecam overlay, and record it to a single movie file.")
                .foregroundStyle(.secondary)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Screen Source") {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = recordingManager.pickedSourceName {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(name).foregroundStyle(.primary)
                        }
                    } else {
                        Text("No screen source picked yet.")
                            .foregroundStyle(.secondary)
                    }

                    Button(recordingManager.hasPickedSource ? "Change Screen Source…" : "Choose Screen Source…") {
                        recordingManager.presentScreenSourcePicker()
                    }
                    .disabled(recordingManager.isRecording)
                }
                .frame(maxWidth: 360, alignment: .leading)
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

    private var previewArea: some View {
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
                    Image(systemName: recordingManager.hasPickedSource ? "display" : "rectangle.dashed")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(recordingManager.previewMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                    if !recordingManager.hasPickedSource {
                        Button("Choose Screen Source…") {
                            recordingManager.presentScreenSourcePicker()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            if recordingManager.needsAVPermissionsPrompt {
                Button("Grant Camera & Microphone Access") {
                    Task { await recordingManager.requestAVPermissions() }
                }
            }

            if recordingManager.isRecording {
                Button("Stop Recording") {
                    Task { await recordingManager.stopRecording() }
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Start Recording") {
                    Task { await recordingManager.startRecording() }
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
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recordingManager.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !recordingManager.permissionMessage.isEmpty {
                Text(recordingManager.permissionMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !recordingManager.startDisabledReason.isEmpty && !recordingManager.isRecording {
                Text(recordingManager.startDisabledReason)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
}

#Preview {
    ContentView()
        .environmentObject(RecordingManager())
}
