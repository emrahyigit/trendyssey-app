import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .dashboard
    @State private var dashboardPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $dashboardPath) {
                DashboardView()
                    .navigationDestination(for: MarketSignal.self) { SignalDetailView(signal: $0) }
                    .navigationDestination(for: NotificationRoute.self) { _ in NotificationCenterView() }
            }
                .tabItem { Label(L10n.text("Overview", "Özet"), systemImage: "sparkles.rectangle.stack.fill") }
                .tag(AppTab.dashboard)
            NavigationStack { ScannerView() }
                .tabItem { Label(L10n.text("Search", "Ara"), systemImage: "magnifyingglass") }
                .tag(AppTab.scanner)
            NavigationStack { WatchlistView() }
                .tabItem { Label(L10n.text("Watchlist", "Takip"), systemImage: "star.fill") }
                .tag(AppTab.watchlist)
            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.text("Profile", "Profil"), systemImage: "person.crop.circle.fill") }
                .tag(AppTab.settings)
        }
        .tint(PulseColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .pulse15PushOpened)) { notification in
            guard let value = notification.userInfo?["notificationId"] as? String else { return }
            openPush(value)
        }
        .task {
            await environment.subscriptionStore.refresh()
            await environment.notificationStore.refresh()
            if let pending = UserDefaults.standard.string(forKey: "pulse15.pendingPushNotificationId") {
                openPush(pending)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await environment.subscriptionStore.refresh()
                await environment.notificationStore.refresh()
            }
        }
    }

    private func openPush(_ value: String) {
        UserDefaults.standard.removeObject(forKey: "pulse15.pendingPushNotificationId")
        guard let notificationID = UUID(uuidString: value) else { return }
        Task {
            let signal = await environment.notificationStore.openPush(notificationID: notificationID)
            selection = .dashboard
            dashboardPath = NavigationPath()
            if let signal { dashboardPath.append(signal) }
            else { dashboardPath.append(NotificationRoute.center) }
        }
    }
}

private enum AppTab { case dashboard, scanner, watchlist, settings }
