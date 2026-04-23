import SwiftUI

@main
struct macOS_screen_recordring_AppApp: App {
    @StateObject private var recordingManager = RecordingManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingManager)
        }
    }
}
