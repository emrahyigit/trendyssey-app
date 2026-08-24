import SwiftUI

struct TopPredictorsView: View {
    @State private var predictors: [TopPredictor] = []
    @State private var symbols: [DailyPredictionSymbol] = []
    @State private var selectedSymbol = ""
    @State private var direction = DailyPredictionDirection.up
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var account: UserSyncService.AccountSnapshot = .anonymous

    private var selected: DailyPredictionSymbol? {
        symbols.first { $0.symbol == selectedSymbol }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                explanation
                predictionComposer
                leaderboard
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Top Predictors", "En İyi Tahminciler"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var explanation: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("DAILY PREDICTION GAME", "GÜNLÜK TAHMİN OYUNU"), systemImage: "trophy.fill")
                    .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
                Text(L10n.text(
                    "Everyone starts at 100 points. Each call follows the coin for 24 hours from your vote and contributes between -5 and +5 points.",
                    "Herkes 100 puanla başlar. Her tahmin, oy anından itibaren coini 24 saat izler ve -5 ile +5 arasında puan getirir."
                ))
                .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                Text(L10n.text(
                    "You can call different coins each day, but each coin can be called only once per UTC day.",
                    "Her gün farklı coinlere tahmin verebilirsin; aynı coine bir UTC günü içinde yalnızca bir kez oy verilebilir."
                ))
                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
    }

    private var predictionComposer: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("MAKE TODAY'S CALL", "BUGÜNÜN TAHMİNİNİ YAP"))
                    .font(.caption.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                Menu {
                    Picker(L10n.text("Coin", "Coin"), selection: $selectedSymbol) {
                        ForEach(symbols) { item in
                            Text("\(item.baseAsset) · $\(price(item.currentPrice))")
                                .tag(item.symbol)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "bitcoinsign.circle.fill")
                            .foregroundStyle(TrendysseyColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected?.baseAsset ?? L10n.text("Choose coin", "Coin seç"))
                                .font(.headline)
                            if let selected {
                                Text("$\(price(selected.currentPrice)) · \(compact(selected.quoteVolume24h))")
                                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                    }
                    .padding(12)
                    .background(TrendysseyColor.elevated, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Picker(L10n.text("Direction", "Yön"), selection: $direction) {
                    ForEach(DailyPredictionDirection.allCases, id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Label(
                            direction == .up
                                ? L10n.text("Predict rise", "Yükselecek de")
                                : L10n.text("Predict fall", "Düşecek de"),
                            systemImage: direction.systemImage
                        )
                        Spacer()
                        if isSubmitting { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .foregroundStyle(.black)
                    .background(direction == .up ? TrendysseyColor.positive : TrendysseyColor.warning, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || isSubmitting || account.isAnonymous)
                .opacity(account.isAnonymous ? 0.5 : 1)

                if account.isAnonymous {
                    Label(
                        L10n.text(
                            "Connect your Apple account in Profile to join the daily game.",
                            "Günlük oyuna katılmak için Profil'de Apple hesabını bağla."
                        ),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                }
                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(TrendysseyColor.positive)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(TrendysseyColor.warning)
                }
            }
        }
    }

    @ViewBuilder private var leaderboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("LEADERBOARD", "SIRALAMA"))
                .font(.caption.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            if isLoading && predictors.isEmpty {
                SurfaceCard { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 26) }
            } else if predictors.isEmpty {
                SurfaceCard {
                    ContentUnavailableView(
                        L10n.text("No predictions yet", "Henüz tahmin yok"),
                        systemImage: "person.2",
                        description: Text(L10n.text("Make the first daily call.", "İlk günlük tahmini sen yap."))
                    )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(predictors.enumerated()), id: \.element.id) { index, predictor in
                        if predictor.isCurrentUser && predictor.position > 10 && index > 0 {
                            rankDivider
                        }
                        NavigationLink {
                            PredictorDailyCallsView(predictor: predictor)
                        } label: {
                            leaderboardRow(predictor)
                        }
                        .buttonStyle(.plain)
                        if index < predictors.count - 1 { Divider().padding(.leading, 68) }
                    }
                }
                .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var rankDivider: some View {
        HStack(spacing: 8) {
            Divider()
            Text(L10n.text("YOUR RANK", "SENİN SIRAN"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TrendysseyColor.secondaryText)
            Divider()
        }
        .padding(.horizontal, 15).padding(.vertical, 5)
    }

    private func leaderboardRow(_ predictor: TopPredictor) -> some View {
        HStack(spacing: 12) {
            Text("#\(predictor.position)")
                .font(.headline.bold()).monospacedDigit()
                .foregroundStyle(predictor.position <= 3 ? TrendysseyColor.accent : TrendysseyColor.secondaryText)
                .frame(width: 34)
            TrendysseyAvatarView(key: predictor.avatarKey ?? "orbit", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(predictor.displayName).font(.subheadline.bold()).lineLimit(1)
                Text(L10n.text("\(predictor.predictionCount) calls", "\(predictor.predictionCount) tahmin"))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            Spacer()
            Text(predictor.totalScore.formatted(.number.precision(.fractionLength(0...2))))
                .font(.headline.bold()).monospacedDigit()
                .foregroundStyle(predictor.totalScore >= 100 ? TrendysseyColor.positive : TrendysseyColor.negative)
            Image(systemName: "chevron.right")
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
        }
        .padding(14)
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        let service = SignalPredictionService()
        async let accountTask = UserSyncService.shared.accountSnapshot()
        async let predictorTask = try? service.topPredictors(limit: 10)
        async let symbolTask = try? service.predictionSymbols(limit: 100)
        account = await accountTask
        if let loaded = await predictorTask { predictors = loaded }
        if let loaded = await symbolTask {
            symbols = loaded
            if selectedSymbol.isEmpty { selectedSymbol = loaded.first?.symbol ?? "" }
        }
    }

    @MainActor private func submit() async {
        guard let selected else { return }
        isSubmitting = true
        errorMessage = nil
        successMessage = nil
        defer { isSubmitting = false }
        do {
            try await SignalPredictionService().submitDaily(symbol: selected.symbol, direction: direction)
            successMessage = L10n.text(
                "\(selected.baseAsset) call recorded at the live price.",
                "\(selected.baseAsset) tahmini canlı fiyattan kaydedildi."
            )
        } catch SignalPredictionService.PredictionError.alreadyPredicted {
            errorMessage = L10n.text(
                "You already called \(selected.baseAsset) today. Each coin can be called once per UTC day.",
                "\(selected.baseAsset) için bugün zaten tahmin verdin. Her coine bir UTC gününde bir kez oy verilebilir."
            )
        } catch SignalPredictionService.PredictionError.appleAccountRequired {
            errorMessage = L10n.text(
                "Connect your Apple account to join the leaderboard.",
                "Sıralamaya katılmak için Apple hesabını bağla."
            )
        } catch SignalPredictionService.PredictionError.rejected(let reason) {
            errorMessage = L10n.text(
                "Prediction was rejected: \(reason)",
                "Tahmin reddedildi: \(reason)"
            )
        } catch {
            let detail = SignalPredictionService.transportDetail(error)
            errorMessage = L10n.text(
                "Prediction could not be sent (\(detail)).",
                "Tahmin gönderilemedi (\(detail))."
            )
        }
        // The leaderboard refresh must never turn a saved call into an error.
        if let refreshed = try? await SignalPredictionService().topPredictors(limit: 10) {
            predictors = refreshed
        }
    }

    private func price(_ value: Double) -> String {
        let digits = value >= 1000 ? 2 : value >= 1 ? 4 : 6
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    private func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale))
    }
}

struct PredictorDailyCallsView: View {
    let predictor: TopPredictor
    @Environment(AppEnvironment.self) private var environment
    @State private var calls: [PredictorDailyCall] = []
    @State private var isLoading = true
    /// Tapping a call opens the coin, so the page needs the live signal behind
    /// each symbol. Loaded alongside the calls to keep the tap instant.
    @State private var signalsBySymbol: [String: MarketSignal] = [:]
    @State private var selectedSignal: MarketSignal?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SurfaceCard {
                    HStack(spacing: 13) {
                        TrendysseyAvatarView(key: predictor.avatarKey ?? "orbit", size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(predictor.displayName).font(.title3.bold())
                            Text(L10n.text("Rank #\(predictor.position)", "Sıra #\(predictor.position)"))
                                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(predictor.totalScore.formatted(.number.precision(.fractionLength(0...2))))
                                .font(.title2.bold()).monospacedDigit()
                            if let accuracy = predictor.accuracyPercent {
                                Text(L10n.text(
                                    "\(accuracy)% accuracy (\(predictor.scoredCount))",
                                    "%\(accuracy) isabet (\(predictor.scoredCount))"
                                ))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accuracy >= 50 ? TrendysseyColor.positive : TrendysseyColor.negative)
                                .padding(.top, 3)
                            }
                        }
                    }
                }
                Text(L10n.text("TODAY'S CALLS", "BUGÜNKÜ TAHMİNLER"))
                    .font(.caption.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                if isLoading {
                    SurfaceCard { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28) }
                } else if calls.isEmpty {
                    SurfaceCard {
                        ContentUnavailableView(
                            L10n.text("No call today", "Bugün tahmin yok"),
                            systemImage: "calendar.badge.minus"
                        )
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(calls) { call in
                            if let signal = signalsBySymbol[call.symbol] {
                                Button { selectedSignal = signal } label: {
                                    SurfaceCard { callRow(call) }
                                }
                                .buttonStyle(.plain)
                            } else {
                                SurfaceCard { callRow(call) }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(predictor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func callRow(_ call: PredictorDailyCall) -> some View {
        let tint = call.direction == .up ? TrendysseyColor.positive : TrendysseyColor.negative
        let remaining = call.evaluationEndsAt.formatted(.relative(presentation: .named))
        let finalizationText = call.isResolved
            ? L10n.text("24-hour score finalized", "24 saatlik puan kesinleşti")
            : L10n.text("Finalizes \(remaining)", "\(remaining) kesinleşir")
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                SymbolMark(symbol: call.symbol.replacingOccurrences(of: "USDT", with: ""), iconURL: signalsBySymbol[call.symbol]?.iconURL)
                Text(call.symbol.replacingOccurrences(of: "USDT", with: ""))
                    .font(.headline)
                if signalsBySymbol[call.symbol] != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TrendysseyColor.secondaryText)
                }
                Label(call.direction.title, systemImage: call.direction.systemImage)
                    .font(.caption.bold()).foregroundStyle(tint)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())
                Spacer()
                Text("\(call.points >= 0 ? "+" : "")\(call.points.formatted(.number.precision(.fractionLength(0...2))))")
                    .font(.headline.bold()).monospacedDigit()
                    .foregroundStyle(call.points >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
            }
            HStack {
                value(L10n.text("Vote price", "Oy fiyatı"), call.entryPrice)
                value(call.isResolved ? L10n.text("Final price", "Final fiyat") : L10n.text("Current price", "Güncel fiyat"), call.markPrice)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("MARKET MOVE", "PİYASA HAREKETİ"))
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(TrendysseyColor.secondaryText)
                    Text("\(call.priceChangePercent >= 0 ? "+" : "")\(call.priceChangePercent.formatted(.number.precision(.fractionLength(0...2))))%")
                        .font(.caption.bold()).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(finalizationText)
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
        }
    }

    private func value(_ title: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(TrendysseyColor.secondaryText)
            Text("$\(price(amount))").font(.caption.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func load() async {
        isLoading = true
        async let callsTask = try? SignalPredictionService().dailyCalls(userID: predictor.userID)
        async let overviewTask = try? environment.marketService.overview()
        calls = await callsTask ?? []
        // A coin outside the scanned universe simply stays untappable rather
        // than opening a detail page with nothing on it.
        if let overview = await overviewTask {
            signalsBySymbol = Dictionary(
                overview.signals.map { ($0.symbol, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        isLoading = false
    }

    private func price(_ value: Double) -> String {
        let digits = value >= 1000 ? 2 : value >= 1 ? 4 : 6
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}
