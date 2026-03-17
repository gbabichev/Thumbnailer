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
