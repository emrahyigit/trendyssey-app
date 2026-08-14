import Foundation

enum AppNotificationStatus: String, Codable, Sendable {
    case unread, read, opened, dismissed
}

struct AppNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let body: String
    var status: AppNotificationStatus
    let createdAt: Date
    let signal: MarketSignal?

    var isUnread: Bool { status == .unread }
}

enum NotificationRoute: Hashable {
    case center
}

extension Notification.Name {
    static let trendysseyPushOpened = Notification.Name("trendyssey.push.opened")
}
