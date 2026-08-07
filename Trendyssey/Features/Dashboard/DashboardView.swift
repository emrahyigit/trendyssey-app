import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = DashboardStore()
    @State private var selectedCharacterCategory = MarketCharacterCategory.successful
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.donchian20.rawValue

    /// A featured breakout has to clear this. Without it the section fills with
    /// coins that are technically in a breakout phase but scored so low that the
    /// move carries no weight.
    private static let minimumStageScore = 50

    /// Phases that mean the breakout is under way: it started, it is being
    /// retested, or it strengthened.
    private static let breakoutPhases: Set<SignalStatus> = [.breakoutDetected, .confirmed, .retest]

    // Lists filter on the same server-recorded phase and score the cards
    // display, so selection and display always agree.
    private func phase(for signal: MarketSignal) -> SignalStatus { signal.status }
    private func stageScore(for signal: MarketSignal) -> Int { signal.stageScore }

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
            .filter { stageScore(for: $0) >= Self.minimumStageScore }
            .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
        let waiting = overview.signals.filter { phase(for: $0) == .preBreakout }
        let topVolume50 = Array(
            overview.signals
                .filter(\.hasScore)
                .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
                .prefix(50)
        )
        // Regime/readiness describe the liquid market universe, while quality
        // and confirmation describe active breakout journeys. Build those two
        // cohorts independently so a valid breakout is not dropped merely
        // because it sits outside the top-50 volume slice.
        let activeBreakouts = overview.signals.filter(isActiveBreakout)
        let averages = averageMetrics(
            marketSignals: topVolume50,
            breakoutSignals: activeBreakouts
        )
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("MODEL SCORE AVERAGES", "MODEL PUAN ORTALAMALARI"))
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            HStack(spacing: 0) {
                compactAverage(L10n.text("REGIME", "REJİM"), averages.regime)
                averageDivider
                compactAverage(L10n.text("READINESS", "HAZIRLIK"), averages.readiness)
                averageDivider
                compactAverage(L10n.text("QUALITY", "KALİTE"), averages.quality)
                averageDivider
                compactAverage(L10n.text("CONFIRM", "TEYİT"), averages.confirmation)
            }
            .padding(.vertical, 12)
            .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(TrendysseyColor.border, lineWidth: 1)
            }
            Text(L10n.text(
                "Regime/readiness: \(averages.allCount) high-volume coins · Quality/confirmation: \(averages.breakoutCount) active breakout coins",
                "Rejim/hazırlık: yüksek hacimli \(averages.allCount) coin · Kalite/teyit: aktif kırılımdaki \(averages.breakoutCount) coin"
            ))
            .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Featured Breakouts", "Öne Çıkan Kırılımlar"),
                subtitle: L10n.text(
                    "Current-stage score \(Self.minimumStageScore)+ on closed \(AnalysisTimeframe.selected.title) candles, highest 24h volume first",
                    "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında \(Self.minimumStageScore)+ aşama puanı, en yüksek 24s hacim önce"
                )
            )
            if breakouts.isEmpty {
                emptyRow(
                    L10n.text(
                        "No breakout has a current-stage score of \(Self.minimumStageScore) or above right now",
                        "Şu anda aşama puanı \(Self.minimumStageScore) ve üzeri olan kırılım yok"
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
        MarketCharactersSection(
            entries: store.marketCharacters,
            signals: overview.signals,
            selection: $selectedCharacterCategory
        )
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

    private func compactAverage(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(TrendysseyColor.primaryText)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TrendysseyColor.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var averageDivider: some View {
        Divider()
            .frame(height: 36)
    }
    private func averageMetrics(
        marketSignals: [MarketSignal],
        breakoutSignals: [MarketSignal]
    ) -> (regime: String, readiness: String, quality: String, confirmation: String, allCount: Int, breakoutCount: Int) {
        func average(_ keyPath: KeyPath<MarketSignal, Int>, in cohort: [MarketSignal]) -> String {
            guard !cohort.isEmpty else { return "—" }
            let value = cohort.reduce(0.0) { $0 + Double($1[keyPath: keyPath]) } / Double(cohort.count)
            return "\(Int(value.rounded()))"
        }

        return (
            average(\.regimeScore, in: marketSignals),
            average(\.readinessScore, in: marketSignals),
            average(\.breakoutQualityScore, in: breakoutSignals),
            average(\.confirmationScore, in: breakoutSignals),
            marketSignals.count,
            breakoutSignals.count
        )
    }
    private func isActiveBreakout(_ signal: MarketSignal) -> Bool {
        signal.hasScore && signal.breakoutTriggered && Self.breakoutPhases.contains(signal.status)
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) } }
    private func emptyRow(_ text: String, icon: String) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18)) }
    private var disclaimer: some View { Label(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."), systemImage: "info.circle").font(.caption).foregroundStyle(TrendysseyColor.secondaryText).padding(.horizontal, 4) }
    private var loading: some View { ProgressView(L10n.text("Analyzing closed candles…", "Kapanmış mumlar analiz ediliyor…")).tint(TrendysseyColor.accent).frame(maxWidth: .infinity).padding(.top, 100) }
    private func error(_ message: String) -> some View { ContentUnavailableView(L10n.text("Data unavailable", "Veri alınamadı"), systemImage: "wifi.exclamationmark", description: Text(message)) }
}
