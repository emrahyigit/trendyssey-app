import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = DashboardStore()
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.donchian20.rawValue

    /// A featured breakout has to clear this signal strength. Unmeasured coins
    /// do not qualify — at a bar this high, "no data" is not "strong".
    private static let minimumStageScore = 80

    /// Waiting-list coins must also show real strength before they earn a row.
    private static let minimumWaitingStrength = 70

    /// Phases that mean the breakout is under way: it started, it is being
    /// retested, or it strengthened.
    private static let breakoutPhases: Set<SignalStatus> = [.breakoutDetected, .confirmed, .retest]

    // Lists filter on the same server-recorded phase and score the cards
    // display, so selection and display always agree.
    private func phase(for signal: MarketSignal) -> SignalStatus { signal.status }

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
        // Featured = the breakout is under way, its signal strength clears the
        // 80 bar, its recent breakouts were not mostly fake-outs, and the
        // biggest money is shown first.
        let breakouts = overview.signals
            .filter { Self.breakoutPhases.contains(phase(for: $0)) }
            .filter { ($0.relativeStrengthScore ?? 0) >= Self.minimumStageScore }
            .filter { !store.isHighInvalidation($0.symbol) }
            .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
        let waiting = overview.signals
            .filter { phase(for: $0) == .preBreakout }
            .filter { ($0.relativeStrengthScore ?? 0) >= Self.minimumWaitingStrength }
            .filter { !store.isHighInvalidation($0.symbol) }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Featured Breakouts", "Öne Çıkan Kırılımlar"),
                subtitle: L10n.text(
                    "Signal strength \(Self.minimumStageScore)+ on closed \(AnalysisTimeframe.selected.title) candles, highest 24h volume first. Coins with over 75% of recent breakouts invalidated are hidden.",
                    "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında \(Self.minimumStageScore)+ sinyal gücü, en yüksek 24s hacim önce. Son kırılımlarının %75'inden fazlası geçersiz kalan coinler gizlenir."
                )
            )
            if breakouts.isEmpty {
                emptyRow(
                    L10n.text(
                        "No breakout has a signal strength of \(Self.minimumStageScore) or above right now",
                        "Şu anda sinyal gücü \(Self.minimumStageScore) ve üzeri olan kırılım yok"
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
                subtitle: L10n.text(
                    "Signal strength \(Self.minimumWaitingStrength)+ while conditions are monitored until a closed candle clears the level. High-invalidation coins are hidden.",
                    "Sinyal gücü \(Self.minimumWaitingStrength)+ olan coinler; kapanmış mum seviyeyi geçene kadar izlenir. Geçersizlik oranı yüksek coinler gizlenir."
                )
            )
            if waiting.isEmpty {
                emptyRow(L10n.text("No coin is waiting for a breakout right now", "Şu anda kırılım beklenen coin yok"), icon: "scope")
            } else {
                ForEach(waiting) { signal in
                    NavigationLink(value: signal) { SignalRow(signal: signal) }.buttonStyle(.plain)
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Top 10 Predictors", "En İyi 10 Tahminci"),
                subtitle: L10n.text("Ranked by verified breakout call accuracy", "Doğrulanmış kırılım tahmini isabetine göre sıralanır")
            )
            if store.topPredictors.isEmpty {
                emptyRow(
                    L10n.text("The board fills as breakout predictions resolve", "Kırılım tahminleri sonuçlandıkça liste dolacak"),
                    icon: "person.2"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.topPredictors.prefix(10).enumerated()), id: \.element.id) { index, predictor in
                        HStack(spacing: 12) {
                            Text("#\(index + 1)")
                                .font(.subheadline.bold()).monospacedDigit()
                                .foregroundStyle(index < 3 ? TrendysseyColor.accent : TrendysseyColor.secondaryText)
                                .frame(width: 34, alignment: .leading)
                            Text(predictor.displayName)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(L10n.text("\(predictor.accuracy)%", "%\(predictor.accuracy)"))
                                .font(.subheadline.bold()).monospacedDigit()
                                .foregroundStyle(predictor.accuracy >= 60 ? TrendysseyColor.positive : TrendysseyColor.secondaryText)
                            Text(L10n.text("\(predictor.resolvedCount) calls", "\(predictor.resolvedCount) tahmin"))
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(TrendysseyColor.secondaryText)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        if predictor.id != store.topPredictors.prefix(10).last?.id { Divider().padding(.leading, 15) }
                    }
                }
                .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        disclaimer
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) } }
    private func emptyRow(_ text: String, icon: String) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18)) }
    private var disclaimer: some View { Label(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."), systemImage: "info.circle").font(.caption).foregroundStyle(TrendysseyColor.secondaryText).padding(.horizontal, 4) }
    private var loading: some View { ProgressView(L10n.text("Analyzing closed candles…", "Kapanmış mumlar analiz ediliyor…")).tint(TrendysseyColor.accent).frame(maxWidth: .infinity).padding(.top, 100) }
    private func error(_ message: String) -> some View { ContentUnavailableView(L10n.text("Data unavailable", "Veri alınamadı"), systemImage: "wifi.exclamationmark", description: Text(message)) }
}
