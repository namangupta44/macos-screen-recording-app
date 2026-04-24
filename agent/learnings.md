# Learnings

## 2026-04-23 19:55 IST

- For this macOS recorder, do not gate camera and microphone enumeration behind `SCShareableContent` loading. If Screen Recording permission is denied, `loadScreenTargets()` throws and the app can accidentally hide otherwise valid camera and microphone devices.
- The app target must carry `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, and sandbox entitlements for `com.apple.security.device.camera`, `com.apple.security.device.microphone`, and `com.apple.security.files.user-selected.read-write`; otherwise AVFoundation device discovery inside the app can appear broken even when the hardware is present.

## 2026-04-23 21:37 IST

- For this recorder, do not treat `CGPreflightScreenCaptureAccess()` as the only truth for whether screen capture is usable. On newer macOS flows it can stay false or stale while the better fallback is to let `SCContentSharingPicker` provide a real `SCContentFilter`, then use that filter for preview and recording.

## 2026-04-23 21:49 IST

- For this recorder, do not auto-load `SCShareableContent` on launch or every app activation when Screen Recording access is still unavailable. That eager refresh can retrigger the macOS TCC prompt repeatedly and create a permission loop.
- Keep permission-specific UI state separate from device-availability messages. If "Grant Permissions" is shown for missing hardware instead of actual denied permissions, the app can end up re-requesting Screen Recording access unnecessarily.

## 2026-04-23 22:09 IST

- For this recorder, do not keep retrying `SCScreenshotManager.captureImage` on a timer after a ScreenCaptureKit permission failure. The preview loop can retrigger the system permission prompt repeatedly and make the app look stuck.
- When `AVAssetWriter` starts its session at `.zero`, normalize both screen-frame and audio sample times relative to the first captured screen frame. Mixing a non-zero `startSession(atSourceTime:)` with zero-based appended times can produce empty or zero-second `.mov` files while errors are easy to miss.
- For this recorder, do not wire `CGRequestScreenCaptureAccess()` into recurring UI actions such as Start/Grant/Refresh flows. It is safer to request camera and microphone via AVFoundation, then treat actual ScreenCaptureKit source loading, picker selection, preview capture, and stream startup as the authoritative screen-access checks.

## 2026-04-23 22:40 IST

- For this recorder, do not derive the default screen source from the alphabetically first `SCShareableContent` target. Displays and windows are mixed together, so the explicit default should prefer the main display, then any display, and only fall back to a window if no display is available.

## 2026-04-23 22:46 IST

- For this recorder, keep screen-permission handling out of generic "grant permissions" helpers. Those flows should only request camera and microphone access; otherwise `Start Recording` or `Grant Permissions` can keep reopening the macOS Screen Recording prompt even after the app is already enabled in System Settings.
- For a previously selected `ScreenTarget`, do not block `currentCaptureSelection()` on `CGPreflightScreenCaptureAccess()` alone. Let `ScreenCaptureKit` resolve the actual capture selection and treat that result as the authoritative screen-access check.

## 2026-04-23 23:50 IST

- For this recorder, `syncScreenRecordingPermissionState()` must never downgrade a confirmed-`.granted` screen-capture state back to `.denied` just because `CGPreflightScreenCaptureAccess()` returns false. Preflight can stay stale/false indefinitely after the user grants Screen Recording in System Settings until a full relaunch, so the only signals that should flip the state to `.denied` are an actual `SCStream` / `SCScreenshotManager` failure. Otherwise the preview flips into the "permission required" state on every window activation even though capture works.
- Gate the preview UI (`canCapturePreview`, `needsScreenRecordingPermissionForPreview`) on the authoritative `screenCaptureAccessState`/`selectedPickerSelection` combination, not directly on `CGPreflightScreenCaptureAccess()`. Otherwise the `Open System Settings` / `Relaunch App` panel can stay stuck on screen while the underlying capture path is actually healthy.
- In `applicationDidBecomeActive()`, only honor a pending force-reload of `SCShareableContent` when we already have screen-recording access (Preflight true, prior `.granted` state, or an active picker selection). Otherwise every return-from-System-Settings re-triggers the macOS TCC prompt and creates the exact popup loop users complain about.
- `NSWorkspace.openApplication(at:configuration:)` on the app's own bundle URL re-activates the running instance instead of spawning a new process, so pairing it with `NSApp.terminate(nil)` leaves the user with no app running. Set `NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true` before launching so a fresh process really comes up before the old one quits.

## 2026-04-24 00:30 IST

- For this recorder, the Screen Recording TCC prompt reliably reappears whenever **any** codepath calls `SCShareableContent.excludingDesktopWindows(...)` or `CGPreflightScreenCaptureAccess()`, even after the user has already chosen a source through `SCContentSharingPicker`. The stable fix is to eliminate every `SCShareableContent`/Preflight call in the app - only use `SCContentSharingPicker` for source selection - because the filter the picker returns **is** the grant. With those calls gone, there is no second code path left that can re-fire the system TCC dialog.
- Drive both the live preview and the recording output from a single `SCStream` built from the picker-provided filter. Feed preview frames off `didOutputSampleBuffer` (throttled to ~20fps for the UI) and, while recording, tee the same sample buffers to `AVAssetWriter`. This removes the need for a parallel `SCScreenshotManager` polling loop (which had its own TCC prompt risk) and keeps the preview perfectly in sync with what is being recorded.
- Cap the `SCStreamConfiguration` `width`/`height` derived from `filter.contentRect * filter.pointPixelScale` to the longest-edge of 1920 and force both dimensions even. Retina displays routinely produce odd dimensions like 3024x1890 which the H.264 encoder will silently reject, leaving an empty `.mov`.
- Never call `CameraCaptureManager.configure(videoDeviceID:audioDeviceID:)` while `isRecording` is true: it rebuilds the `AVCaptureSession` inputs and yanks the microphone mid-recording, producing `.mov` files with audible drops. Gate all preview-only reconfigurations (camera picker change, `applicationDidBecomeActive`) on `!isRecording`.

## 2026-04-24 13:54 IST

- When adding live facecam overlay controls, update `OverlayPanelManager.layoutStore` as the single source of truth. The floating panel UI and `RecordingPipeline` both read that store, so live resize/drag changes made during recording must go through it to keep the visible overlay and saved video aligned.

## 2026-04-24 14:07 IST

- The main preview uses SwiftUI's top-left coordinate space, while `VideoCompositor` uses a bottom-left Core Image coordinate space. When dragging the webcam overlay in the preview, convert the preview Y coordinate with `1 - (displayY / displayHeight)` before writing `OverlayLayout.normalizedCenter`, otherwise the saved recording position is vertically flipped.

## 2026-04-24 14:51 IST

- Cursor highlight, click rings, custom cursor size, and follow zoom should stay in the existing compositor pipeline. Hide ScreenCaptureKit's built-in cursor (`configuration.showsCursor = false`), sample `NSEvent.mouseLocation` against the picker filter's `contentRect` as soon as preview capture starts, store normalized cursor state in a lock-protected store, and let `VideoCompositor` draw/zoom per frame; do not introduce a second capture or post-processing path.

## 2026-04-24 15:07 IST

- Keep live preview compositing off the main actor. The preview path should throttle to about 20fps, render the latest available frame on a dedicated serial queue, drop stale pending frames, and only publish the finished `NSImage`/`CGImage` back to SwiftUI on the main actor; otherwise `CIContext.createCGImage` plus webcam/cursor effects can make the preview window feel hung.

## 2026-04-24 15:31 IST

- The main window uses `isMovableByWindowBackground = true`, so SwiftUI-only drag gestures in the preview can be preempted by AppKit window dragging. Interactive preview regions such as the facecam position handle should use an `NSViewRepresentable` hit-test surface with `mouseDownCanMoveWindow = false` and handle `mouseDragged` itself.
