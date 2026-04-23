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
