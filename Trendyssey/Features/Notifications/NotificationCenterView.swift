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
                Text(L10n.text("Market State transitions matching your filters will appear here.", "Filtrelerine uyan Piyasa Durumu geçişleri burada görünür."))
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
                if let signal = item.signal {
                    signalMetrics(signal)
                    Label(L10n.text("View details", "Detayı görüntüle"), systemImage: "arrow.up.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(TrendysseyColor.accent)
                }
            }
        }
        .padding(16)
        .background(item.isUnread ? TrendysseyColor.elevated.opacity(0.72) : TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(TrendysseyColor.border, lineWidth: 1) }
    }

    private func signalMetrics(_ signal: MarketSignal) -> some View {
        HStack(spacing: 6) {
            metric(
                nil,
                value: notificationStateText(signal),
                icon: signal.marketState?.state.systemImage ?? "waveform.path.ecg",
                tint: signal.marketState?.state.color ?? TrendysseyColor.secondaryText
            )
            metric(
                L10n.text("24h Vol", "24s Hacim"),
                value: "$\(signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale)))",
                icon: "chart.bar.fill",
                tint: TrendysseyColor.accent
            )
        }
    }

    private func metric(_ title: String?, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            if let title {
                Text(title).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
            }
            Text(value).monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func notificationStateText(_ signal: MarketSignal) -> String {
        guard let state = signal.marketState else {
            return L10n.text("State updating", "Durum güncelleniyor")
        }
        guard state.hasActiveState else { return L10n.text("No active state", "Aktif durum yok") }
        let change = state.stateScoreChange.flatMap { value in
            value == 0 ? nil : " · \(value > 0 ? "+" : "")\(value)"
        } ?? ""
        return "\(state.state.title) · \(state.stateScore)/100\(change)"
    }

    private var icon: String {
        item.signal?.marketState?.state.systemImage ?? "waveform.path.ecg"
    }

    private var displayTitle: String {
        item.title
    }

    private var displayBody: String {
        item.body
    }
}
