import SwiftUI
@preconcurrency import UserNotifications

@main
struct TrendysseyApp: App {
    @UIApplicationDelegateAdaptor(TrendysseyAppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.preview
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.default.rawValue
    @AppStorage("themeMode") private var themeMode = AppThemeMode.system.rawValue

    init() {
        // EMA Cross was retired as a selectable breakout model. Existing
        // installs move to the new production default instead of requesting an
        // inactive backend slug while still showing the old picker label.
        if UserDefaults.standard.string(forKey: JourneyModel.storageKey) == JourneyModel.emaCross.rawValue {
            UserDefaults.standard.set(JourneyModel.donchian20.rawValue, forKey: JourneyModel.storageKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            AccessGateView()
                .environment(environment)
                .environment(\.locale, (AppLanguage(rawValue: appLanguage) ?? .english).locale)
                .preferredColorScheme((AppThemeMode(rawValue: themeMode) ?? .system).colorScheme)
                // Localized strings come from L10n, which reads UserDefaults —
                // invisible to SwiftUI, so a view whose inputs did not change is
                // free to keep its old text. Picker options were the visible
                // symptom: their ForEach identities never change, so they stayed
                // in the previous language until relaunch. Keying the tree on the
                // language rebuilds everything exactly when it changes.
                .id(appLanguage)
        }
    }
}

@MainActor
final class TrendysseyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // Screenshot/UI-test hook: `-uiTestSkipNotificationPrompt YES` keeps
        // the permission alert from covering the UI.
        if UserDefaults.standard.bool(forKey: "uiTestSkipNotificationPrompt") { return true }
        #endif
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
                    let watchlist = UserDefaults.standard.stringArray(forKey: "trendyssey.watchlist.symbols") ?? []
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
                UserDefaults.standard.set(notificationID, forKey: "trendyssey.pendingPushNotificationId")
                NotificationCenter.default.post(name: .trendysseyPushOpened, object: nil, userInfo: ["notificationId": notificationID])
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
