import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let marketService: MarketService
    let notificationStore: NotificationCenterStore
    let subscriptionStore: SubscriptionStore
    var watchlist: Set<String>
    private let watchlistKey = "pulse15.watchlist.symbols"

    init(marketService: MarketService, watchlist: Set<String>? = nil) {
        self.marketService = marketService
        self.notificationStore = NotificationCenterStore()
        self.subscriptionStore = SubscriptionStore()
        if let watchlist {
            self.watchlist = watchlist
        } else if let saved = UserDefaults.standard.stringArray(forKey: watchlistKey) {
            self.watchlist = Set(saved)
        } else {
            self.watchlist = []
        }
        let initialWatchlist = Array(self.watchlist)
        Task { await UserSyncService.shared.syncCurrentState(watchlist: initialWatchlist) }
    }

    func toggleWatchlist(_ symbol: String) {
        if watchlist.contains(symbol) { watchlist.remove(symbol) } else { watchlist.insert(symbol) }
        UserDefaults.standard.set(Array(watchlist).sorted(), forKey: watchlistKey)
        let currentWatchlist = Array(watchlist)
        Task { await UserSyncService.shared.syncCurrentState(watchlist: currentWatchlist) }
    }

    static let preview = AppEnvironment(marketService: LiveMarketService())
}
