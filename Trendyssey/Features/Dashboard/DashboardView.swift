import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = DashboardStore()
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    /// A featured breakout has to clear this. Without it the section fills with
    /// coins that are technically in a breakout phase but scored so low that the
    /// move carries no weight.
    private static let minimumConfidence = 50

    /// Phases that mean the breakout is under way: it started, it is being
    /// retested, or it strengthened.
    private static let breakoutPhases: Set<SignalStatus> = [.breakoutDetected, .confirmed, .retest]

    // Lists filter on the same server-recorded phase and score the cards
    // display, so selection and display always agree.
    private func phase(for signal: MarketSignal) -> SignalStatus { signal.status }
    private func confidence(for signal: MarketSignal) -> Int { signal.confidence }

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
        .background(TrendysseyColor.canvas.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
        .task(id: "\(journeyModel)|\(preferredTimeframe)") {
            await store.retry(using: environment.marketService)
        }
        .task { await environment.notificationStore.refresh() }
        .refreshable {
            await store.retry(using: environment.marketService)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TrendysseyColor.accent)
                    Image("TrendysseyLogoMark")
                        .resizable().scaledToFit()
                        .padding(.vertical, 5)
                        .foregroundStyle(.black)
                }
                .frame(width: 34, height: 34)
                Text("TRENDYSSEY")
                    .font(.caption.weight(.bold))
                    .tracking(2.4)
                    .foregroundStyle(TrendysseyColor.accent)
                Spacer()
                NavigationLink(value: NotificationRoute.center) {
                    Image(systemName: environment.notificationStore.unreadCount > 0 ? "bell.fill" : "bell")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(TrendysseyColor.surface, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if environment.notificationStore.unreadCount > 0 {
                                Text("\(min(environment.notificationStore.unreadCount, 99))")
                                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 2)
                                    .background(TrendysseyColor.negative, in: Capsule())
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .foregroundStyle(TrendysseyColor.primaryText)
                .accessibilityLabel(L10n.text("Notifications", "Bildirimler"))
            }
            Text(L10n.text("Market Overview", "Piyasa Özeti"))
                .font(.largeTitle.bold())
                .foregroundStyle(TrendysseyColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 2)
    }

    @ViewBuilder private func content(_ overview: MarketOverview) -> some View {
        // Featured = the breakout is under way, it scored well enough to be worth
        // surfacing, and the biggest money is shown first.
        let breakouts = overview.signals
            .filter { Self.breakoutPhases.contains(phase(for: $0)) }
            .filter { confidence(for: $0) >= Self.minimumConfidence }
            .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
        let waiting = overview.signals.filter { phase(for: $0) == .preBreakout }
        let topVolume50 = Array(
            overview.signals
                .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
                .prefix(50)
        )
        let averages = averageMetrics(for: topVolume50)
        HStack(spacing: 10) {
            stat(L10n.text("AVG. CONFIDENCE", "GÜVEN ORT."), averages.confidence, "checkmark.shield.fill")
            stat(L10n.text("AVG. VOLUME", "HACİM ORT."), averages.volume, "chart.bar.fill")
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Featured Breakouts", "Öne Çıkan Kırılımlar"),
                subtitle: L10n.text(
                    "Confidence \(Self.minimumConfidence)+ on closed \(AnalysisTimeframe.selected.title) candles, highest 24h volume first",
                    "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında \(Self.minimumConfidence)+ güven puanı, en yüksek 24s hacim önce"
                )
            )
            if breakouts.isEmpty {
                emptyRow(
                    L10n.text(
                        "No breakout is scoring \(Self.minimumConfidence) or above right now",
                        "Şu anda \(Self.minimumConfidence) ve üzeri puan alan kırılım yok"
                    ),
                    icon: "chart.line.uptrend.xyaxis"
                )
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
                    .foregroundStyle(TrendysseyColor.accent)
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
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(TrendysseyColor.accent); Text(value).font(.title2.bold()).monospacedDigit(); Text(title).font(.caption2.weight(.bold)).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(1).minimumScaleFactor(0.8) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private func averageMetrics(for signals: [MarketSignal]) -> (confidence: String, volume: String) {
        guard !signals.isEmpty else { return ("—", "—") }
        let count = Double(signals.count)
        let confidence = Int((signals.reduce(0.0) { $0 + Double($1.confidence) } / count).rounded())
        let volume = signals.reduce(0.0) { $0 + $1.volumeRatio } / count
        return ("\(confidence)", String(format: "%.1fx", volume))
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) } }
    private func emptyRow(_ text: String, icon: String) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18)) }
    private var disclaimer: some View { Label(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."), systemImage: "info.circle").font(.caption).foregroundStyle(TrendysseyColor.secondaryText).padding(.horizontal, 4) }
    private var loading: some View { ProgressView(L10n.text("Analyzing closed candles…", "Kapanmış mumlar analiz ediliyor…")).tint(TrendysseyColor.accent).frame(maxWidth: .infinity).padding(.top, 100) }
    private func error(_ message: String) -> some View { ContentUnavailableView(L10n.text("Data unavailable", "Veri alınamadı"), systemImage: "wifi.exclamationmark", description: Text(message)) }
}
