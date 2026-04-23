import SwiftUI

@main
struct macOS_screen_recordring_AppApp: App {
    @StateObject private var recordingManager = RecordingManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingManager)
                .background(WindowAccessor { window in
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.isMovableByWindowBackground = true
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
            }
        }
    }
}
