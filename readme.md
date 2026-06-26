# macOS Screen Recording App

This is a native macOS screen recorder Xcode project.

## Before Working

Before making task-specific changes, search `agent/learnings.md` for related notes. That file has important project-specific fixes around ScreenCaptureKit permissions, cursor overlays, recording timing, and Xcode archive behavior.

## Local Rebuild And Install

Use this after code changes when the app already installed on the Mac still shows the old behavior.

```bash
cd "/Users/naman/x code projects/macOS screen recordring App"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project "macOS screen recordring App.xcodeproj" \
  -scheme "macOS screen recordring App" \
  -configuration Debug \
  -derivedDataPath build/derived-data \
  build

osascript -e 'tell application "macOS screen recordring App" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf "/Applications/macOS screen recordring App.app"
ditto \
  "build/derived-data/Build/Products/Debug/macOS screen recordring App.app" \
  "/Applications/macOS screen recordring App.app"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "/Applications/macOS screen recordring App.app"

open "/Applications/macOS screen recordring App.app"
```

Why the `DEVELOPER_DIR` prefix is used: on this Mac, plain `xcodebuild` may fail if `xcode-select` points to Command Line Tools instead of full Xcode.

## Share The App With Someone

For a simple shareable build, make a Release app and zip it:

```bash
cd "/Users/naman/x code projects/macOS screen recordring App"

rm -rf dist
mkdir -p dist

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project "macOS screen recordring App.xcodeproj" \
  -scheme "macOS screen recordring App" \
  -configuration Release \
  -derivedDataPath build/derived-data \
  build

ditto -c -k --keepParent \
  "build/derived-data/Build/Products/Release/macOS screen recordring App.app" \
  "dist/macOS-screen-recordring-app-update-16.zip"
```

Send `dist/macOS-screen-recordring-app-update-16.zip`.

Current signing status: this project signs locally/ad-hoc unless a Developer ID team is configured. A recipient may need to right-click the app and choose Open, and they will still need to grant Screen Recording, Camera, and Microphone permissions on their Mac. For public distribution, use Apple Developer ID signing and notarization from Xcode Organizer.

Optional archive workflow:

```bash
cd "/Users/naman/x code projects/macOS screen recordring App"

rm -rf dist
mkdir -p dist

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild archive \
  -project "macOS screen recordring App.xcodeproj" \
  -scheme "macOS screen recordring App" \
  -configuration Release \
  -archivePath "dist/macOS-screen-recordring-app-update-16.xcarchive"
```

You can also do this in Xcode with Product > Archive, then use Organizer to distribute or export the app.

## Commit Template

Do not commit generated `build/` or `dist/` output. Commit only source/docs changes.

For the next update:

```bash
cd "/Users/naman/x code projects/macOS screen recordring App"

rm -rf build dist
git status
git add .
git commit -m "update 16"
git push
```

For later updates, change only the number, for example `update 17`, `update 18`, and so on.
