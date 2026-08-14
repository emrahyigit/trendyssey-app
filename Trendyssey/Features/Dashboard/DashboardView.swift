import SwiftUI

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store = DashboardStore()
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

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
        let earlyReversals = overview.signals
            .filter { ($0.marketState?.state.reversalPriority ?? 0) > 0 }
            .sorted {
                let leftPriority = $0.marketState?.state.reversalPriority ?? 0
                let rightPriority = $1.marketState?.state.reversalPriority ?? 0
                if leftPriority != rightPriority { return leftPriority > rightPriority }
                let left = $0.marketState?.stateScore ?? 0
                let right = $1.marketState?.stateScore ?? 0
                if left != right { return left > right }
                return $0.quoteVolume24h > $1.quoteVolume24h
            }
        let sellingStates = overview.signals
            .filter { signal in
                signal.marketState?.state == .sellingDominant || signal.marketState?.state == .breakdownRisk
            }
            .sorted {
                let left = $0.marketState?.stateScore ?? 0
                let right = $1.marketState?.stateScore ?? 0
                if left != right { return left > right }
                return $0.quoteVolume24h > $1.quoteVolume24h
            }
        let bullishMomentumStates = overview.signals
            .filter { $0.marketState?.state == .bullishMomentum }
            .sorted {
                let left = $0.marketState?.stateScore ?? 0
                let right = $1.marketState?.stateScore ?? 0
                if left != right { return left > right }
                return $0.quoteVolume24h > $1.quoteVolume24h
            }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Strong Bullish Momentum", "Güçlü Yükseliş Momentumu"),
                subtitle: L10n.text(
                    "Coins already advancing with sustained closed-candle strength.",
                    "Kapanmış mumlarda sürdürülebilir güçle hâlihazırda yükselen coinler."
                )
            )
            if bullishMomentumStates.isEmpty {
                emptyRow(
                    L10n.text("No strong bullish momentum state right now", "Şu anda güçlü yükseliş momentumu durumu yok"),
                    icon: "bolt.circle"
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(bullishMomentumStates) { signal in
                            NavigationLink(value: signal) { FeaturedSignalCard(signal: signal) }
                                .buttonStyle(.plain)
                                .containerRelativeFrame(.horizontal, count: 10, span: bullishMomentumStates.count > 1 ? 9 : 10, spacing: 12)
                        }
                    }.scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Early Reversal States", "Erken Dönüş Durumları"),
                subtitle: L10n.text(
                    "Seller impact fading, absorption and buyer confirmation on closed \(AnalysisTimeframe.selected.title) candles.",
                    "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında zayıflayan satıcı etkisi, absorpsiyon ve alıcı teyidi."
                )
            )
            if earlyReversals.isEmpty {
                emptyRow(
                    L10n.text(
                        "No early reversal state is active right now",
                        "Şu anda aktif bir erken dönüş durumu yok"
                    ),
                    icon: "waveform.path.ecg"
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(earlyReversals) { signal in
                            NavigationLink(value: signal) { FeaturedSignalCard(signal: signal) }
                                .buttonStyle(.plain)
                                .containerRelativeFrame(.horizontal, count: 10, span: earlyReversals.count > 1 ? 9 : 10, spacing: 12)
                        }
                    }.scrollTargetLayout()
                }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                if earlyReversals.count > 1 {
                    HStack(spacing: 5) {
                        Text(L10n.text("Swipe for more states", "Diğer durumlar için kaydır"))
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
                L10n.text("Selling Pressure", "Satış Baskısı"),
                subtitle: L10n.text(
                    "Coins where sellers are currently effective or downside continuation risk is elevated.",
                    "Satıcıların şu anda etkili olduğu veya düşüşün devam riskinin yükseldiği coinler."
                )
            )
            if sellingStates.isEmpty {
                emptyRow(L10n.text("No dominant selling state right now", "Şu anda baskın bir satış durumu yok"), icon: "arrow.down.circle")
            } else {
                ForEach(sellingStates.prefix(10)) { signal in
                    NavigationLink(value: signal) { SignalRow(signal: signal) }.buttonStyle(.plain)
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                TopPredictorsView()
            } label: {
                HStack {
                    sectionTitle(
                        L10n.text("Top Predictors", "En İyi Tahminciler"),
                        subtitle: L10n.text(
                            "Daily direction calls · everyone starts at 100 points",
                            "Günlük yön tahminleri · herkes 100 puanla başlar"
                        )
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
            if store.topPredictors.isEmpty {
                emptyRow(
                    L10n.text("Be the first to make today's call", "Bugünün ilk tahminini sen yap"),
                    icon: "person.2"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.topPredictors.enumerated()), id: \.element.id) { index, predictor in
                        if predictor.isCurrentUser && predictor.position > 10 && index > 0 {
                            HStack(spacing: 8) {
                                Divider()
                                Text(L10n.text("YOUR RANK", "SENİN SIRAN"))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(TrendysseyColor.secondaryText)
                                Divider()
                            }
                            .padding(.horizontal, 15).padding(.vertical, 5)
                        }
                        NavigationLink {
                            PredictorDailyCallsView(predictor: predictor)
                        } label: {
                            predictorRow(predictor)
                        }
                        .buttonStyle(.plain)
                        if index < store.topPredictors.count - 1 { Divider().padding(.leading, 70) }
                    }
                }
                .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        disclaimer
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(TrendysseyColor.secondaryText) } }
    private func predictorRow(_ predictor: TopPredictor) -> some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                TrendysseyAvatarView(key: predictor.avatarKey ?? "orbit", size: 42)
                Text("#\(predictor.position)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(predictor.position <= 3 ? .black : TrendysseyColor.primaryText)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(predictor.position <= 3 ? TrendysseyColor.accent : TrendysseyColor.elevated, in: Capsule())
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(predictor.displayName).font(.headline).lineLimit(1)
                    if predictor.isCurrentUser {
                        Text(L10n.text("YOU", "SEN"))
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(TrendysseyColor.accent, in: Capsule())
                    }
                }
                Text(L10n.text(
                    "\(predictor.predictionCount) daily calls",
                    "\(predictor.predictionCount) günlük tahmin"
                ))
                .font(.caption)
                .foregroundStyle(TrendysseyColor.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(predictor.totalScore.formatted(.number.precision(.fractionLength(0...2))))
                    .font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(predictor.totalScore >= 100 ? TrendysseyColor.positive : TrendysseyColor.negative)
                Text(L10n.text("points", "puan"))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
        }
        .padding(15)
    }
    private func emptyRow(_ text: String, icon: String) -> some View { Label(text, systemImage: icon).font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18)) }
    private var disclaimer: some View { Label(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."), systemImage: "info.circle").font(.caption).foregroundStyle(TrendysseyColor.secondaryText).padding(.horizontal, 4) }
    private var loading: some View { ProgressView(L10n.text("Analyzing closed candles…", "Kapanmış mumlar analiz ediliyor…")).tint(TrendysseyColor.accent).frame(maxWidth: .infinity).padding(.top, 100) }
    private func error(_ message: String) -> some View { ContentUnavailableView(L10n.text("Data unavailable", "Veri alınamadı"), systemImage: "wifi.exclamationmark", description: Text(message)) }
}
