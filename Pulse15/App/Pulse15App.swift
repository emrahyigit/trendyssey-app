import SwiftUI
@preconcurrency import UserNotifications

@main
struct Pulse15App: App {
    @UIApplicationDelegateAdaptor(Pulse15AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.preview
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    @AppStorage("themeMode") private var themeMode = AppThemeMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            AccessGateView()
                .environment(environment)
                .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .english).locale)
                .preferredColorScheme((AppThemeMode(rawValue: themeMode) ?? .system).colorScheme)
        }
    }
}

@MainActor
final class Pulse15AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                application.registerForRemoteNotifications()
            case .notDetermined:
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                if granted {
                    UserDefaults.standard.set(true, forKey: "notificationsEnabled")
                    application.registerForRemoteNotifications()
                    let watchlist = UserDefaults.standard.stringArray(forKey: "pulse15.watchlist.symbols") ?? []
                    await UserSyncService.shared.syncCurrentState(watchlist: watchlist)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let notificationID = response.notification.request.content.userInfo["notificationId"] as? String
        Task { @MainActor in
            if let notificationID {
                UserDefaults.standard.set(notificationID, forKey: "pulse15.pendingPushNotificationId")
                NotificationCenter.default.post(name: .pulse15PushOpened, object: nil, userInfo: ["notificationId": notificationID])
            }
            completionHandler()
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        Task { await UserSyncService.shared.syncDeviceToken(token, identifier: identifier, environment: environment) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}
