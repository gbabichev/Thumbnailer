import SwiftUI
import UserNotifications


@main
struct Thumbnailer: App {
    var body: some Scene {
        
        WindowGroup {
            ContentView()
                .task {
                    // Runs once when ContentView appears on launch
                    await requestNotificationAuthIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppMenuCommands()
            SidebarCommands()
        }
        
        // MARK: - Custom About Window
        Window("About Thumbnailer", id: "AboutWindow") {
            AboutView()
                .frame(width: 400, height: 400)
        }
        .windowResizability(.contentSize) // Makes window non-resizable and size == content
        .defaultSize(width: 400, height: 400)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
func requestNotificationAuthIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .notDetermined:
        _ = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        //print("🔔 Notifications granted? \(granted)")
    case .denied:
        break
        //print("🔕 Notifications denied by user.")
    case .authorized, .provisional, .ephemeral:
        break
        //print("✅ Notifications already authorized.")
    @unknown default:
        break
    }
}
