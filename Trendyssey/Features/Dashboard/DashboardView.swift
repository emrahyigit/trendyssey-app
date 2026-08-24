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

    @ViewBuilder private func carousel(_ signals: [MarketSignal]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(signals) { signal in
                    NavigationLink(value: signal) { FeaturedSignalCard(signal: signal) }
                        .buttonStyle(.plain)
                        .containerRelativeFrame(.horizontal, count: 10, span: signals.count > 1 ? 9 : 10, spacing: 12)
                }
            }.scrollTargetLayout()
        }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
        if signals.count > 1 {
            HStack(spacing: 5) {
                Text(L10n.text("Swipe for more states", "Diğer durumlar için kaydır"))
                Image(systemName: "arrow.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(TrendysseyColor.accent)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 4)
            .accessibilityLabel(L10n.text("Swipe right to view more coins", "Diğer coinleri görmek için sağa kaydır"))
        }
    }

    @ViewBuilder private func content(_ overview: MarketOverview) -> some View {
        // Spot users can only be long, so the home screen carries one buy-side
        // list. Rank runs down the cycle rather than by score alone: a handover
        // that just happened is a fresher entry than a move already running.
        // The slider is the turn window: control just changed hands, the
        // selling that held price down has died, or it is still being absorbed.
        // Dominance is deliberately absent — by then the move has happened.
        let turnRank: (MarketStateKind) -> Int = { state in
            switch state {
            case .buyerTakeover: 3
            case .sellerExhaustion: 2
            case .buySideAbsorption: 1
            default: 0
            }
        }
        // One step earlier on the cycle: sellers still landing blows, just
        // fewer of them. Not a turn yet.
        let wateringRank: (MarketStateKind) -> Int = { state in
            state == .sellerImpactFading ? 1 : 0
        }
        let ranked = { (rank: @escaping (MarketStateKind) -> Int, limit: Int) in
            overview.signals
                .filter { rank($0.marketState?.state ?? .lowParticipation) > 0 }
                .sorted {
                    let leftRank = rank($0.marketState?.state ?? .lowParticipation)
                    let rightRank = rank($1.marketState?.state ?? .lowParticipation)
                    if leftRank != rightRank { return leftRank > rightRank }
                    let left = $0.marketState?.stateScore ?? 0
                    let right = $1.marketState?.stateScore ?? 0
                    if left != right { return left > right }
                    return $0.quoteVolume24h > $1.quoteVolume24h
                }
                .prefix(limit)
        }
        let turning = Array(ranked(turnRank, 10))
        let watching = Array(ranked(wateringRank, 7))

        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("The Turn Window", "Dönüş Penceresi"),
                subtitle: L10n.text(
                    "Control just changed hands, the selling died, or it is still being absorbed on closed \(AnalysisTimeframe.selected.title) candles.",
                    "Kapanmış \(AnalysisTimeframe.selected.title) mumlarında yeni el değiştiren kontrol, tükenen satış veya hâlâ emilen satış."
                )
            )
            if turning.isEmpty {
                emptyRow(
                    L10n.text(
                        "No coin is turning right now",
                        "Şu anda dönen bir coin yok"
                    ),
                    icon: "arrow.turn.up.right"
                )
            } else {
                carousel(turning)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(
                L10n.text("Selling Losing Its Grip", "Satış Gücünü Yitiriyor"),
                subtitle: L10n.text(
                    "Sellers are still landing blows, just fewer of them. One step before the turn window.",
                    "Satıcılar hâlâ vuruyor ama daha azı tutuyor. Dönüş penceresinden bir adım önce."
                )
            )
            if watching.isEmpty {
                emptyRow(
                    L10n.text("No coin shows selling losing its grip", "Satışın gücünü yitirdiği bir coin yok"),
                    icon: "waveform.path.ecg"
                )
            } else {
                ForEach(watching) { signal in
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
