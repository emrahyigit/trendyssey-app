import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class NotificationCenterStore {
    enum State: Equatable { case idle, loading, loaded, failed }

    private let service = NotificationService()
    var items: [AppNotification] = []
    var state: State = .idle

    var unreadCount: Int { items.count(where: \.isUnread) }

    func refresh() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await service.notifications()
            state = .loaded
            try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        } catch {
            state = .failed
        }
    }

    func markRead(_ item: AppNotification, opened: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let status: AppNotificationStatus = opened ? .opened : .read
        guard items[index].status != status else { return }
        items[index].status = status
        Task {
            do { try await service.mark(item.id, as: status) }
            catch { await refresh() }
            try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        for index in items.indices where items[index].isUnread { items[index].status = .read }
        Task {
            do { try await service.markAllRead() }
            catch { await refresh() }
            try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        }
    }

    func openPush(notificationID: UUID) async -> MarketSignal? {
        if !items.contains(where: { $0.id == notificationID }) { await refresh() }
        guard let item = items.first(where: { $0.id == notificationID }) else { return nil }
        markRead(item, opened: true)
        return item.signal
    }
}
