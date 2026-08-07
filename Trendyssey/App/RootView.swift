import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = RootView.initialTab
    @State private var dashboardPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $dashboardPath) {
                DashboardView()
                    .navigationDestination(for: MarketSignal.self) { SignalDetailView(signal: $0) }
                    .navigationDestination(for: NotificationRoute.self) { _ in NotificationCenterView() }
                    .navigationDestination(for: MarketCharacterRoute.self) { route in
                        MarketCharactersView(initialCategory: route.category)
                    }
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
        .tint(TrendysseyColor.accent)
        .onReceive(NotificationCenter.default.publisher(for: .trendysseyPushOpened)) { notification in
            guard let value = notification.userInfo?["notificationId"] as? String else { return }
            openPush(value)
        }
        .task {
            await environment.subscriptionStore.refresh()
            await environment.notificationStore.refresh()
            if let pending = UserDefaults.standard.string(forKey: "trendyssey.pendingPushNotificationId") {
                openPush(pending)
            }
            #if DEBUG
            // Screenshot/UI-test hook: `-uiTestOpenSignal ATOMUSDT` opens that
            // signal's detail page on launch.
            if let symbol = UserDefaults.standard.string(forKey: "uiTestOpenSignal"),
               let signal = try? await environment.marketService.allSymbols()
                   .first(where: { $0.symbol == symbol || $0.name == symbol }) {
                dashboardPath.append(signal)
            }
            if let rawCategory = UserDefaults.standard.string(forKey: "uiTestMarketCharacters"),
               let category = MarketCharacterCategory(rawValue: rawCategory) {
                dashboardPath.append(MarketCharacterRoute(category: category))
            }
            #endif
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
        UserDefaults.standard.removeObject(forKey: "trendyssey.pendingPushNotificationId")
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

extension RootView {
    // Screenshot/UI-test hook: select the initial tab via launch argument,
    // e.g. `-uiTestTab scanner`. Debug builds only.
    fileprivate static var initialTab: AppTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uiTestTab") {
        case "scanner": return .scanner
        case "watchlist": return .watchlist
        case "settings": return .settings
        default: return .dashboard
        }
        #else
        return .dashboard
        #endif
    }
}
