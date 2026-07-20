import SwiftUI

struct NotificationCenterView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedSignal: MarketSignal?

    private var store: NotificationCenterStore { environment.notificationStore }

    var body: some View {
        Group {
            switch store.state {
            case .idle, .loading:
                if store.items.isEmpty { ProgressView(L10n.text("Loading notifications…", "Bildirimler yükleniyor…")) }
                else { content }
            case .failed where store.items.isEmpty:
                ContentUnavailableView {
                    Label(L10n.text("Notifications unavailable", "Bildirimler alınamadı"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(L10n.text("Check your connection and try again.", "Bağlantını kontrol edip yeniden deneyebilirsin."))
                } actions: {
                    Button(L10n.text("Try Again", "Yeniden dene")) { Task { await store.refresh() } }
                        .buttonStyle(.borderedProminent).tint(TrendysseyColor.accent).foregroundStyle(.black)
                }
            default:
                content
            }
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Notifications", "Bildirimler"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("Mark All Read", "Tümünü okundu yap")) { store.markAllRead() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
    }

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("No notifications yet", "Henüz bildirim yok"), systemImage: "bell.slash")
            } description: {
                Text(L10n.text("Breakouts matching your filters will appear here.", "Filtrelerine uyan bir kırılım oluştuğunda burada göreceksin."))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.items) { item in
                        if let signal = item.signal {
                            Button {
                                store.markRead(item, opened: true)
                                selectedSignal = signal
                            } label: { NotificationRow(item: item) }
                                .buttonStyle(.plain)
                        } else {
                            Button { store.markRead(item) } label: { NotificationRow(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct NotificationRow: View {
    let item: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TrendysseyColor.primaryText)
                    .frame(width: 42, height: 42)
                    .background(TrendysseyColor.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if item.isUnread {
                    Circle().fill(TrendysseyColor.accent).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(TrendysseyColor.surface, lineWidth: 2))
                        .offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayTitle).font(.subheadline.weight(item.isUnread ? .bold : .semibold))
                    Spacer(minLength: 8)
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(1)
                }
                Text(displayBody).font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                if item.signal != nil {
                    Label(L10n.text("View details", "Detayı görüntüle"), systemImage: "arrow.up.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(TrendysseyColor.accent)
                }
            }
        }
        .padding(16)
        .background(item.isUnread ? TrendysseyColor.elevated.opacity(0.72) : TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(TrendysseyColor.border, lineWidth: 1) }
    }

    private var icon: String {
        guard let status = item.signalStatus else { return "bell.fill" }
        switch status {
        case .preBreakout: return "scope"
        case .breakoutDetected: return "bolt.fill"
        case .confirmed: return "checkmark.seal.fill"
        case .retest: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .watching, .expired: return "bell.fill"
        }
    }

    private var displayTitle: String {
        item.title
    }

    private var displayBody: String {
        item.body
    }
}
