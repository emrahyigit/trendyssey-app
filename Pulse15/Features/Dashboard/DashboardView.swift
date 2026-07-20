import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = DashboardStore()
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(AnalysisModelSelection.storageKey) private var preferredAnalysisModel = AnalysisModelSelection.defaultSlug

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                switch store.state {
                case .idle, .loading: loading
                case .failed(let message): error(message)
                case .loaded(let overview): content(overview)
                }
            }.padding(.horizontal, 18).padding(.bottom, 28)
        }
        .background(PulseColor.canvas.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
        .task(id: "\(preferredAnalysisModel)|\(preferredTimeframe)") { await store.retry(using: environment.marketService) }
        .task { await environment.notificationStore.refresh() }
        .refreshable { await store.retry(using: environment.marketService) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PulseColor.accent)
                    Image("Pulse15LogoMark")
                        .resizable().scaledToFit()
                        .padding(.vertical, 5)
                        .foregroundStyle(.black)
                }
                .frame(width: 34, height: 34)
                Text("TRENDYSSEY")
                    .font(.caption.weight(.bold))
                    .tracking(2.4)
                    .foregroundStyle(PulseColor.accent)
                Spacer()
                NavigationLink(value: NotificationRoute.center) {
                    Image(systemName: environment.notificationStore.unreadCount > 0 ? "bell.fill" : "bell")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(PulseColor.surface, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if environment.notificationStore.unreadCount > 0 {
                                Text("\(min(environment.notificationStore.unreadCount, 99))")
                                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 2)
                                    .background(PulseColor.negative, in: Capsule())
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .foregroundStyle(PulseColor.primaryText)
                .accessibilityLabel(L10n.text("Notifications", "Bildirimler"))
            }
            Text(L10n.text("Market Overview", "Piyasa Özeti"))
                .font(.largeTitle.bold())
                .foregroundStyle(PulseColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 2)
    }

    @ViewBuilder private func content(_ overview: MarketOverview) -> some View {
        let breakouts = overview.signals.filter { [.breakoutDetected, .confirmed, .retest].contains($0.status) }
        let waiting = overview.signals.filter { $0.status == .preBreakout }
        let topVolume50 = Array(
            overview.signals
                .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
                .prefix(50)
        )
        let averages = averageMetrics(for: topVolume50)
        HStack(spacing: 10) {
            stat(L10n.text("AVG. STRENGTH", "GÜÇ ORT."), averages.confidence, "checkmark.shield.fill")
            stat(L10n.text("AVG. VOLUME", "HACİM ORT."), averages.volume, "chart.bar.fill")
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Featured Breakouts", "Öne Çıkan Kırılımlar"),
                subtitle: L10n.text("Moves started on closed \(AnalysisTimeframe.selected.title) candles", "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında başlayan hareketler")
            )
            if breakouts.isEmpty {
                emptyRow(L10n.text("No featured breakout right now", "Şu anda öne çıkan kırılım yok"), icon: "chart.line.uptrend.xyaxis")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(breakouts) { signal in
                            NavigationLink(value: signal) { FeaturedSignalCard(signal: signal) }
                                .buttonStyle(.plain)
                                .containerRelativeFrame(.horizontal, count: 10, span: breakouts.count > 1 ? 9 : 10, spacing: 12)
                        }
                    }.scrollTargetLayout()
                }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                if breakouts.count > 1 {
                    HStack(spacing: 5) {
                        Text(L10n.text("Swipe for more", "Diğerleri için kaydır"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PulseColor.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
                    .accessibilityLabel(L10n.text("Swipe right to view more breakouts", "Diğer kırılımları görmek için sağa kaydır"))
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Waiting for Breakout", "Kırılım Beklenenler"),
                subtitle: L10n.text("Conditions are monitored until a closed candle clears the level", "Kapanmış mum seviyeyi geçene kadar koşullar izleniyor")
            )
            if waiting.isEmpty {
                emptyRow(L10n.text("No coin is waiting for a breakout right now", "Şu anda kırılım beklenen coin yok"), icon: "scope")
            } else {
                ForEach(waiting) { signal in
                    NavigationLink(value: signal) { SignalRow(signal: signal) }.buttonStyle(.plain)
                }
            }
        }
        disclaimer
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(PulseColor.accent); Text(value).font(.title2.bold()).monospacedDigit(); Text(title).font(.caption2.weight(.bold)).foregroundStyle(PulseColor.secondaryText).lineLimit(1).minimumScaleFactor(0.8) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private func averageMetrics(for signals: [MarketSignal]) -> (confidence: String, volume: String) {
        guard !signals.isEmpty else { return ("—", "—") }
        let count = Double(signals.count)
        let confidence = Int((signals.reduce(0.0) { $0 + Double($1.confidence) } / count).rounded())
        let volume = signals.reduce(0.0) { $0 + $1.volumeRatio } / count
        return ("\(confidence)", String(format: "%.1fx", volume))
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(PulseColor.secondaryText) } }
    private func emptyRow(_ text: String, icon: String) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(PulseColor.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 18)) }
    private var disclaimer: some View { Label(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."), systemImage: "info.circle").font(.caption).foregroundStyle(PulseColor.secondaryText).padding(.horizontal, 4) }
    private var loading: some View { ProgressView(L10n.text("Analyzing closed candles…", "Kapanmış mumlar analiz ediliyor…")).tint(PulseColor.accent).frame(maxWidth: .infinity).padding(.top, 100) }
    private func error(_ message: String) -> some View { ContentUnavailableView(L10n.text("Data unavailable", "Veri alınamadı"), systemImage: "wifi.exclamationmark", description: Text(message)) }
}
