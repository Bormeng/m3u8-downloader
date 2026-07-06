import SwiftUI
import UserNotifications

@main
struct M3U8DownloaderApp: App {
    init() {
        // request notification permission once
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup("M3U8 Downloader") {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { } // single-window app
        }

        Settings {
            SettingsView()
        }
    }
}