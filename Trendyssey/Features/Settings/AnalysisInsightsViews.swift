import SwiftUI
import Charts

private enum ScenarioBehaviorFilter: String, CaseIterable, Identifiable {
    case anyBullish = "any_bullish"
    case buyerTakeover = "buyer_takeover"
    case failedBreakdown = "failed_breakdown"
    case sellerExhaustion = "seller_exhaustion"
    case buyerRecovery = "buyer_recovery_strengthening"
    case sellDivergence = "sell_pressure_downside_divergence"
    case lowerLowFailure = "lower_low_failure"
    case downsideWeakening = "downside_progress_weakening"

    var id: String { rawValue }
    var kind: BehavioralSignalKind? { BehavioralSignalKind(rawValue: rawValue) }
    var kinds: [BehavioralSignalKind] {
        kind.map { [$0] } ?? [
            .buyerTakeover, .failedBreakdown, .sellerExhaustion,
            .buyerRecoveryStrengthening, .sellPressureDownsideDivergence,
            .lowerLowFailure, .downsideProgressWeakening,
        ]
    }
    var title: String { kind?.title ?? L10n.text("Any bullish behavior", "Tüm yükseliş davranışları") }
}

struct DailyBreakoutSimulatorView: View {
    @State private var preferredTimeframe = AnalysisTimeframe.selected.rawValue
    /// Every tunable persists across launches, so the page reopens exactly as
    /// it was left and the saved set can be pushed to the auto trader.
    @AppStorage("scenarioLookbackHours") private var lookbackHours = ScenarioLookback.day1.rawValue
    /// Fixed scenario stake — the page asks one question with one number.
    private let investment = 100_000.0
    @AppStorage("scenarioMinimumDivide") private var minimumDivide = 5
    @AppStorage("scenarioProfitTarget") private var profitTarget = 10.0
    @AppStorage("scenarioStopLoss") private var stopLoss = 10.0
    /// Positions may stay open at most this long; at the deadline they close at
    /// market, profit or loss. 72h default: the trend backtest validated an
    /// exit horizon of 3× the 24h journey horizon.
    @AppStorage("scenarioMaxOpenHours") private var maxOpenHours = 72
    /// The behavior frozen on the entry candle. Confirmation is conservative:
    /// exhaustion alone never masquerades as buyer control.
    @AppStorage("scenarioBehaviorFilter") private var behaviorFilterRaw = ScenarioBehaviorFilter.buyerTakeover.rawValue
    @AppStorage("scenarioRequireBehaviorConfirmed") private var requireConfirmed = true
    /// The tournament winner's exit: a stop trailing the high watermark by
    /// multiplier × ATR, no profit target. On by default — it beat the fixed
    /// target/stop pair with every entry method on every timeframe.
    @AppStorage("scenarioUseChandelier") private var useChandelierExit = true
    @AppStorage("scenarioChandelierMultiplier") private var chandelierMultiplier = 3.0
    /// Minimum 24h quote volume in millions of dollars; 0 disables the filter.
    @AppStorage("scenarioMinimumVolumeMillions") private var minimumVolumeMillions = 10
    /// Minimum score of the state frozen on the entry candle; 0 disables it.
    @AppStorage("scenarioMinimumBehaviorScore") private var minimumBehaviorScore = 60
    @State private var isApplyingToTrader = false
    @State private var appliedToTrader = false
    @State private var applyFailed = false
    @State private var entries: [BreakoutScenarioEntry] = []
    @State private var isTruncated = false
    @State private var isLoading = true
    @State private var loadFailed = false

    private var lookback: ScenarioLookback { ScenarioLookback(rawValue: lookbackHours) ?? .day1 }
    private var lookbackBinding: Binding<ScenarioLookback> {
        Binding(get: { lookback }, set: { lookbackHours = $0.rawValue })
    }
    private var behaviorFilter: ScenarioBehaviorFilter {
        ScenarioBehaviorFilter(rawValue: behaviorFilterRaw) ?? .buyerTakeover
    }

    private struct SimulatedTrade: Identifiable {
        let entry: BreakoutScenarioEntry
        let exit: ScenarioExit?

        var id: UUID { entry.id }
    }

    private struct SlotOccupation {
        let symbol: String
        let releaseDate: Date?
    }

    private struct SimulationOutcome {
        let trades: [SimulatedTrade]
        /// Entries dropped because the coin already had a position open or
        /// had already entered on the same UTC day.
        let skippedSameCoin: Int
        /// Entries dropped because every slot was occupied.
        let skippedNoSlot: Int
    }

    private var minimumQuoteVolume: Double { Double(minimumVolumeMillions) * 1_000_000 }

    private var volumeEligibleEntries: [BreakoutScenarioEntry] {
        entries.filter { $0.quoteVolume24h >= minimumQuoteVolume }
    }

    private var behaviorEligibleEntries: [BreakoutScenarioEntry] {
        volumeEligibleEntries.filter { entry in
            guard let signal = entry.behavioralSignal,
                  signal.direction == .bullish,
                  behaviorFilter.kinds.contains(signal.kind) else { return false }
            return !requireConfirmed || signal.status == .confirmed
        }
    }

    private var eligibleEntries: [BreakoutScenarioEntry] {
        behaviorEligibleEntries.filter { ($0.behavioralSignal?.score ?? 0) >= minimumBehaviorScore }
    }

    private var minimumVolumeText: String {
        minimumVolumeMillions <= 0
            ? L10n.text("Off", "Kapalı")
            : "$\(minimumVolumeMillions)M"
    }

    private var emptyResultDescription: String {
        if entries.isEmpty {
            return L10n.text(
                "No bullish behavioral transition was recorded in this window. Try a wider window.",
                "Bu aralıkta yükseliş yönlü davranış geçişi kaydedilmedi. Aralığı genişletmeyi deneyebilirsin."
            )
        }
        if volumeEligibleEntries.isEmpty {
            return L10n.text(
                "Entries exist, but every coin is below the \(minimumVolumeText) volume line.",
                "Giriş var ancak tüm coinlerin hacmi \(minimumVolumeText) çizgisinin altında."
            )
        }
        if behaviorEligibleEntries.isEmpty {
            return L10n.text(
                "No \(behaviorFilter.title) event matched the confirmation rule in this window.",
                "Bu aralıkta teyit kuralına uyan \(behaviorFilter.title) olayı yok."
            )
        }
        return L10n.text(
            "No behavior reached the minimum evidence score of \(minimumBehaviorScore).",
            "Hiçbir davranış \(minimumBehaviorScore) minimum kanıt puanına ulaşmadı."
        )
    }

    private var simulationOutcome: SimulationOutcome {
        let candidates = eligibleEntries.sorted {
            if $0.entryDate != $1.entryDate { return $0.entryDate < $1.entryDate }
            if $0.marketStateScore != $1.marketStateScore { return ($0.marketStateScore ?? 0) > ($1.marketStateScore ?? 0) }
            return $0.symbol < $1.symbol
        }
        var activeSlots: [SlotOccupation] = []
        var accepted: [SimulatedTrade] = []
        var entryDaysBySymbol: [String: Set<Int>] = [:]
        var skippedSameCoin = 0
        var skippedNoSlot = 0

        for entry in candidates {
            activeSlots.removeAll { slot in
                guard let releaseDate = slot.releaseDate else { return false }
                return releaseDate <= entry.entryDate
            }
            // One position per coin: never a second entry while the coin's
            // position is still open, and never a re-entry on the same UTC
            // day — the same timeframe keeps re-firing on the same move, and
            // stacking those entries would just multiply one bet.
            let entryDay = Int(entry.entryDate.timeIntervalSince1970 / 86_400)
            if activeSlots.contains(where: { $0.symbol == entry.symbol })
                || entryDaysBySymbol[entry.symbol]?.contains(entryDay) == true {
                skippedSameCoin += 1
                continue
            }
            guard activeSlots.count < minimumDivide else {
                skippedNoSlot += 1
                continue
            }
            let exit = useChandelierExit
                ? entry.chandelierExit(multiplier: chandelierMultiplier, maxOpenHours: maxOpenHours)
                : entry.exit(profitTarget: profitTarget, stopLoss: stopLoss, maxOpenHours: maxOpenHours)
            accepted.append(SimulatedTrade(entry: entry, exit: exit))
            activeSlots.append(SlotOccupation(symbol: entry.symbol, releaseDate: exit?.date))
            entryDaysBySymbol[entry.symbol, default: []].insert(entryDay)
        }
        return SimulationOutcome(trades: accepted, skippedSameCoin: skippedSameCoin, skippedNoSlot: skippedNoSlot)
    }

    private var simulatedTrades: [SimulatedTrade] { simulationOutcome.trades }

    private var completedTrades: [SimulatedTrade] { simulatedTrades.filter { $0.exit != nil } }
    private var openTrades: [SimulatedTrade] { simulatedTrades.filter { $0.exit == nil } }
    private var openPositionCount: Int { openTrades.count }

    private var targetExitCount: Int { simulatedTrades.filter { $0.exit?.reason == .target }.count }
    private var stopLossExitCount: Int { simulatedTrades.filter { $0.exit?.reason == .stopLoss }.count }
    private var timeLimitExitCount: Int { simulatedTrades.filter { $0.exit?.reason == .timeLimit }.count }

    private var targetHitRate: Double {
        guard !simulatedTrades.isEmpty else { return 0 }
        return Double(targetExitCount) / Double(simulatedTrades.count)
    }

    private var allocationPerSlot: Double { investment / Double(minimumDivide) }

    private var simulatedProfit: Double {
        completedTrades.reduce(0) { total, trade in
            total + allocationPerSlot * (trade.exit?.returnPercent ?? 0) / 100
        }
    }

    private var unrealizedProfit: Double {
        openTrades.reduce(0) { $0 + allocationPerSlot * $1.entry.currentReturnPercent / 100 }
    }

    /// Newest first, so the most recent activity is what the user reads first.
    private var listedCompletedTrades: [SimulatedTrade] {
        completedTrades.sorted { $0.entry.entryDate > $1.entry.entryDate }
    }

    private var listedOpenTrades: [SimulatedTrade] {
        openTrades.sorted { $0.entry.entryDate > $1.entry.entryDate }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    SurfaceCard { controls }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label(
                        L10n.text(
                            "Behavior is frozen on the entry candle. Exhaustion says the old side is weakening; confirmation is required to claim that buyers have taken control.",
                            "Davranış giriş mumunda dondurulur. Tükeniş eski tarafın zayıfladığını söyler; kontrolün alıcılara geçtiğini söylemek için teyit gerekir."
                        ),
                        systemImage: "trophy"
                    )
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                    applyToTraderCard
                    result
                    positions
                    Label(
                        L10n.text(
                            "Historical scenario only. A position closes when the market touches the target or the stop loss inside any candle — no candle close is required — or at market once the holding limit expires. When one candle spans both levels, the stop is assumed to have hit first. Fees, funding, slippage and tax are excluded.",
                            "Yalnızca geçmiş veriye dayalı senaryodur. Piyasa herhangi bir mum içinde hedefe veya stop loss'a dokunduğunda pozisyon kapanır — mum kapanışı beklenmez — ya da açık kalma limiti dolduğunda piyasa fiyatından kapatılır. Bir mum iki seviyeyi birden kapsıyorsa önce stopun geldiği varsayılır. Komisyon, fonlama, fiyat kayması ve vergi dahil değildir."
                        ),
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                }
                .frame(width: max(0, geometry.size.width - 36), alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .clipped()
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Behavior Scenario", "Davranış Senaryosu"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { applyTunedDefaultsOnce() }
        .onChange(of: traderParameterSignature) {
            // Any parameter drift invalidates the green "applied" state — the
            // trader is now running something other than what the page shows.
            appliedToTrader = false
            applyFailed = false
        }
        .task(id: "\(preferredTimeframe)|\(lookback.rawValue)") {
            await load()
        }
    }

    /// One-time reset of persisted tunables to the Aug 2026 backtest winners:
    /// A+ trend entries, no extra trigger, symmetric 10/10 barriers and the
    /// validated 72h (3× journey horizon) holding limit. Fresh installs get
    /// the same values from the property defaults; adjusting anything after
    /// this keeps working as before.
    private func applyTunedDefaultsOnce() {
        let appliedKey = "scenarioTrendDefaultsApplied"
        guard !UserDefaults.standard.bool(forKey: appliedKey) else { return }
        UserDefaults.standard.set(true, forKey: appliedKey)
        resetToTournamentWinner()
    }

    /// Sets every tunable to the Aug 2026 tournament winner: A+ entries only,
    /// no extra trigger, chandelier 3×ATR trail, 72h (3× journey horizon)
    /// holding limit. Also behind the "Reset to Tournament Winner" button.
    private func resetToTournamentWinner() {
        profitTarget = 10
        stopLoss = 10
        maxOpenHours = 72
        minimumDivide = 5
        minimumVolumeMillions = 10
        minimumBehaviorScore = 60
        behaviorFilterRaw = ScenarioBehaviorFilter.buyerTakeover.rawValue
        requireConfirmed = true
        useChandelierExit = true
        chandelierMultiplier = 3
    }

    /// Mirrors what "Apply to auto trader" actually sends, so the caption can
    /// never drift from the configuration again.
    private var applyDescription: String {
        let exit = useChandelierExit
            ? L10n.text("the chandelier \(Self.multiplierText(chandelierMultiplier))×ATR trail", "chandelier \(Self.multiplierText(chandelierMultiplier))×ATR izini")
            : L10n.text("the fixed target/stop pair", "sabit hedef/stop çiftini")
        return L10n.text(
            "Sends \(exit), holding limit, slots, \(behaviorFilter.title), confirmation and the evidence floor to the trader.",
            "İşlemciye \(exit), süre limitini, slotları, \(behaviorFilter.title), teyit kuralını ve kanıt tabanını gönderir."
        )
    }

    /// Everything "Apply to auto trader" would send. When any of it drifts
    /// from what was last applied, the button drops its "applied" state.
    private var traderParameterSignature: String {
        [
            "\(profitTarget)", "\(stopLoss)",
            "\(maxOpenHours)", "\(minimumDivide)", "\(minimumVolumeMillions)",
            behaviorFilter.rawValue, "\(minimumBehaviorScore)", "\(requireConfirmed)",
            "\(useChandelierExit)", "\(chandelierMultiplier)",
            preferredTimeframe,
        ].joined(separator: "|")
    }

    /// Pushes the page's behavioral entry contract into the auto trader.
    private var applyToTraderCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { resetToTournamentWinner() }
                } label: {
                    HStack {
                        Label(
                            L10n.text("Reset to Behavioral Default", "Davranış Varsayılanına Dön"),
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
                .foregroundStyle(TrendysseyColor.accent)
                Text(L10n.text(
                    "Confirmed buyer takeovers with evidence ≥60, chandelier 3×ATR trail, 72h limit, 5 slots and a $10M volume floor.",
                    "Kanıtı ≥60 olan teyitli alıcı devralımları, chandelier 3×ATR iz, 72s limit, 5 slot ve 10M$ hacim tabanı."
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(2)
                Divider().padding(.vertical, 4)
                Button {
                    Task { await applyToAutoTrader() }
                } label: {
                    HStack {
                        Label(
                            appliedToTrader
                                ? L10n.text("Applied to auto trader", "Otomatik işlemlere uygulandı")
                                : L10n.text("Apply to auto trader", "Otomatik işlemlere uygula"),
                            systemImage: appliedToTrader ? "checkmark.circle.fill" : "arrow.right.circle"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        if isApplyingToTrader { ProgressView() }
                    }
                }
                .disabled(isApplyingToTrader)
                .foregroundStyle(appliedToTrader ? TrendysseyColor.positive : TrendysseyColor.accent)
                if applyFailed {
                    Text(L10n.text("Could not update the trader. Try again.", "İşlemci güncellenemedi. Yeniden dene."))
                        .font(.caption).foregroundStyle(TrendysseyColor.warning)
                }
                Text(applyDescription)
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(2)
            }
        }
    }

    @MainActor private func applyToAutoTrader() async {
        isApplyingToTrader = true
        applyFailed = false
        defer { isApplyingToTrader = false }
        do {
            try await LiveTradingService.shared.applyScenarioParameters(
                profitTargetPercent: profitTarget,
                stopLossPercent: stopLoss,
                maxOpenHours: maxOpenHours,
                maxSlots: minimumDivide,
                minimumSignalStrength: 0,
                minimumSuccessRate: 0,
                minimumQuoteVolume: Double(minimumVolumeMillions) * 1_000_000,
                allowedMarketStates: MarketStateKind.allCases,
                minimumStateScore: 0,
                allowedBehaviorSignals: behaviorFilter.kinds,
                minimumBehaviorScore: minimumBehaviorScore,
                requireBehaviorConfirmed: requireConfirmed,
                useChandelierExit: useChandelierExit,
                chandelierAtrMultiplier: chandelierMultiplier,
                timeframe: preferredTimeframe,
                modelSlug: AnalysisModelSelection.defaultSlug
            )
            appliedToTrader = true
        } catch {
            applyFailed = true
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("PRO SIMULATOR", "PRO SİMÜLATÖR"), systemImage: "function")
                .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
            Text(L10n.text(
                "What happened after the market printed these behaviors?",
                "Piyasa bu davranışları ürettikten sonra ne oldu?"
            ))
                .font(.title2.bold())
            Text(L10n.text(
                "The replay follows $100k through only the bullish behaviors that matched your evidence contract in \(lookback.title.lowercased()).",
                "Tekrar, 100 bin doları \(lookback.title) içinde yalnızca kanıt sözleşmene uyan yükseliş davranışlarında izler."
            ))
            .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
        }
    }

    private var scenarioTags: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe, icon: "clock")
                chip(lookback.shortTitle, icon: "calendar")
                if minimumVolumeMillions > 0 {
                    chip(L10n.text("Vol. ≥ \(minimumVolumeText)", "Hacim ≥ \(minimumVolumeText)"), icon: "drop.fill")
                }
                chip(behaviorFilter.title, icon: behaviorFilter.kind.map { _ in "waveform.path.ecg" } ?? "square.grid.2x2")
                chip(L10n.text("Evidence ≥ \(minimumBehaviorScore)", "Kanıt ≥ \(minimumBehaviorScore)"), icon: "checklist")
                chip(requireConfirmed ? L10n.text("Confirmed", "Teyitli") : L10n.text("Developing + confirmed", "Gelişen + teyitli"), icon: requireConfirmed ? "checkmark.seal.fill" : "clock.arrow.circlepath")
                if useChandelierExit {
                    chip(
                        L10n.text("Chandelier \(Self.multiplierText(chandelierMultiplier))×ATR", "Chandelier \(Self.multiplierText(chandelierMultiplier))×ATR"),
                        icon: "arrow.up.forward.and.arrow.down.backward"
                    )
                }
                chip(L10n.text("\(eligibleEntries.count) transition(s)", "\(eligibleEntries.count) geçiş"), icon: "number")
            }
        }
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                selectionRow(
                    L10n.text("Timeframe", "Zaman dilimi"),
                    value: AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe
                ) {
                    Picker("", selection: $preferredTimeframe) {
                        ForEach(AnalysisTimeframe.allCases) { timeframe in
                            Text(timeframe.title).tag(timeframe.rawValue)
                        }
                    }
                }
                Divider()
                selectionRow(
                    L10n.text("Window", "Aralık"),
                    value: lookback.title
                ) {
                    Picker("", selection: lookbackBinding) {
                        ForEach(ScenarioLookback.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                }
                Divider()
                selectionRow(
                    L10n.text("Behavior to replay", "Tekrarlanacak davranış"),
                    value: behaviorFilter.title
                ) {
                    Picker("", selection: $behaviorFilterRaw) {
                        ForEach(ScenarioBehaviorFilter.allCases) { filter in
                            Text(filter.title).tag(filter.rawValue)
                        }
                    }
                }
                Divider()
                stepperRow(
                    L10n.text(
                        "Minimum evidence: \(minimumBehaviorScore)",
                        "Minimum kanıt: \(minimumBehaviorScore)"
                    ),
                    value: $minimumBehaviorScore,
                    range: 30...100,
                    step: 5
                )
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Require structural confirmation", "Yapısal teyit zorunlu"))
                            .font(.subheadline)
                        Text(L10n.text(
                            "Prevents exhaustion alone from being treated as buyer control.",
                            "Tükenişin tek başına alıcı kontrolü sayılmasını engeller."
                        ))
                        .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $requireConfirmed).labelsHidden().tint(TrendysseyColor.accent)
                }
                .padding(.vertical, 10)
                Divider()
                stepperRow(
                    L10n.text("Min. 24h volume: \(minimumVolumeText)", "Min. 24s hacim: \(minimumVolumeText)"),
                    value: $minimumVolumeMillions,
                    range: 0...100,
                    step: 5
                )
                Divider()
                stepperRow(
                    L10n.text("Min. divide: \(minimumDivide)", "Min. bölme: \(minimumDivide)"),
                    value: $minimumDivide,
                    range: 1...20,
                    step: 1
                )
                Divider()
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Chandelier trailing exit", "Chandelier iz süren çıkış"))
                        .font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                    Text(L10n.text(
                        "The stop follows the highs, so no fixed target caps the run.",
                        "Stop zirveleri takip eder; sabit bir hedef kazancı sınırlamaz."
                    ))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $useChandelierExit).labelsHidden().tint(TrendysseyColor.accent)
            }
            .frame(minHeight: 44)
            .padding(.top, 10)
            if useChandelierExit {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("Trail width", "İz genişliği")).font(.subheadline.bold())
                        Spacer()
                        Text("\(Self.multiplierText(chandelierMultiplier))×ATR")
                            .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.accent)
                    }
                    Slider(
                        value: $chandelierMultiplier,
                        in: 1.5...4,
                        step: 0.5
                    )
                    .tint(TrendysseyColor.accent)
                    .padding(.vertical, 6)
                    Text(L10n.text(
                        "3× was the backtest winner. Tighter trails exit sooner and give back less; wider trails survive more shakeouts.",
                        "Backtest galibi 3× idi. Dar iz daha erken çıkar ve daha az geri verir; geniş iz sarsıntılara daha çok dayanır."
                    ))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                }
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("Virtual close target", "Sanal kapanış hedefi")).font(.subheadline.bold())
                        Spacer()
                        Text(profitTarget / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(1)))
                            .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.positive)
                    }
                    Slider(
                        value: $profitTarget,
                        in: 0.5...20,
                        step: 0.5
                    )
                    .tint(TrendysseyColor.positive)
                    .padding(.vertical, 6)
                }
                .padding(.top, 10)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("Stop loss", "Stop loss")).font(.subheadline.bold())
                        Spacer()
                        Text(-stopLoss / 100, format: .percent.precision(.fractionLength(1)))
                            .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.negative)
                    }
                    Slider(
                        value: $stopLoss,
                        in: 0.5...20,
                        step: 0.5
                    )
                    .tint(TrendysseyColor.negative)
                    .padding(.vertical, 6)
                }
                .padding(.top, 10)
            }
            Divider().padding(.top, 10)
            stepperRow(
                L10n.text("Max. holding time: \(maxOpenHours)h", "Maks. açık kalma: \(maxOpenHours)s"),
                value: $maxOpenHours,
                range: 4...168,
                step: 4
            )
        }
    }

    @ViewBuilder private var result: some View {
        if isLoading {
            SurfaceCard { ProgressView(L10n.text("Calculating scenario…", "Senaryo hesaplanıyor…")).frame(maxWidth: .infinity).padding(.vertical, 28) }
        } else if loadFailed {
            SurfaceCard {
                ContentUnavailableView(
                    L10n.text("Scenario unavailable", "Senaryo kullanılamıyor"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(L10n.text("Behavior transitions or live price paths could not be loaded.", "Davranış geçişleri veya canlı fiyat hareketleri yüklenemedi."))
                )
            }
        } else if eligibleEntries.isEmpty {
            SurfaceCard {
                ContentUnavailableView(
                    L10n.text("No matching result", "Eşleşen sonuç yok"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(emptyResultDescription)
                )
            }
        } else {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("REALIZED PROFIT · \(lookback.shortTitle)", "GERÇEKLEŞEN KÂR · \(lookback.shortTitle)"))
                        .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                    Text(simulatedProfit, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(simulatedProfit >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                        .monospacedDigit()
                    Text(L10n.text(
                        "The budget is split into \(minimumDivide) reusable slot(s), \(Self.currencyText(allocationPerSlot, fractionDigits: 0)) each. \(completedTrades.count) position(s) closed: \(targetExitCount) at the target, \(stopLossExitCount) at the stop, \(timeLimitExitCount) at the \(maxOpenHours)h limit.",
                        "Bütçe, her biri \(Self.currencyText(allocationPerSlot, fractionDigits: 0)) olan yeniden kullanılabilir \(minimumDivide) slota bölünür. \(completedTrades.count) pozisyon kapandı: \(targetExitCount) hedefte, \(stopLossExitCount) stopta, \(timeLimitExitCount) tanesi \(maxOpenHours) saat limitinde."
                    ))
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                    Divider()
                    funnel
                    HStack(spacing: 10) {
                        resultMetric(L10n.text("Target hit", "Hedefe ulaşma"), targetHitRate, format: .percent.precision(.fractionLength(0)))
                        resultCount(L10n.text("Stopped", "Stop"), stopLossExitCount)
                        resultCount(L10n.text("Timed out", "Süre doldu"), timeLimitExitCount)
                        resultCount(L10n.text("Open", "Açık"), openPositionCount)
                    }
                    if openPositionCount > 0 {
                        Divider()
                        HStack {
                            Text(L10n.text("Open positions, unrealized", "Açık pozisyonlar, gerçekleşmemiş"))
                                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                            Spacer()
                            Text(unrealizedProfit, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                                .font(.subheadline.bold()).monospacedDigit()
                                .foregroundStyle(unrealizedProfit >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                        }
                    }
                    if isTruncated {
                        Label(
                            L10n.text(
                                "Only the most recent entries in this window were loaded, so the oldest part of it is not covered.",
                                "Bu aralıkta yalnızca en yeni girişler yüklendi; aralığın en eski bölümü kapsanmıyor."
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2).foregroundStyle(TrendysseyColor.warning)
                    }
                }
            }
        }
    }

    /// Every entry the window returned, and what became of it. Without this the
    /// slot mechanic is invisible: a coin can be missing from the lists purely
    /// because capital was already committed when its signal arrived, and there
    /// was nothing on screen saying so.
    private var funnel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("WHERE THE ENTRIES WENT", "GİRİŞLER NE OLDU"))
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            funnelRow(
                L10n.text("Found in this window", "Bu aralıkta bulunan"),
                entries.count,
                tint: TrendysseyColor.primaryText
            )
            if minimumVolumeMillions > 0 {
                funnelRow(
                    L10n.text("Below \(minimumVolumeText) volume", "Hacmi \(minimumVolumeText) altında"),
                    entries.count - volumeEligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            funnelRow(
                L10n.text("Different behavior or confirmation", "Farklı davranış veya teyit"),
                volumeEligibleEntries.count - behaviorEligibleEntries.count,
                tint: TrendysseyColor.secondaryText
            )
            funnelRow(
                L10n.text("Evidence below \(minimumBehaviorScore)", "Kanıtı \(minimumBehaviorScore) altında"),
                behaviorEligibleEntries.count - eligibleEntries.count,
                tint: TrendysseyColor.secondaryText
            )
            funnelRow(
                L10n.text("Simulated", "Simüle edilen"),
                simulatedTrades.count,
                tint: TrendysseyColor.positive
            )
            let outcome = simulationOutcome
            if outcome.skippedSameCoin > 0 {
                funnelRow(
                    L10n.text("Skipped — same coin", "Atlandı — aynı coin"),
                    outcome.skippedSameCoin,
                    tint: TrendysseyColor.warning
                )
                Text(L10n.text(
                    "A coin never carries two positions at once, and never enters twice on the same day (UTC) — repeated signals on the same move would only multiply one bet.",
                    "Bir coinde aynı anda iki pozisyon taşınmaz ve aynı gün (UTC) içinde ikinci giriş yapılmaz — aynı hareketin tekrarlayan sinyalleri tek bahsi katlamaktan başka işe yaramaz."
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(2)
            }
            if outcome.skippedNoSlot > 0 {
                funnelRow(
                    L10n.text("Skipped — no free slot", "Atlandı — boş slot yoktu"),
                    outcome.skippedNoSlot,
                    tint: TrendysseyColor.warning
                )
                Text(L10n.text(
                    "A position holds its slot until it closes — at the target, the stop loss or the \(maxOpenHours)h limit. Entries are filled oldest first, so later signals are the ones dropped. Raise the divide to make room.",
                    "Bir pozisyon kapanana kadar slotunu tutar — hedefte, stop loss'ta veya \(maxOpenHours) saat limitinde. Girişler en eskiden başlayarak doldurulur, dolayısıyla atlananlar hep sonraki sinyallerdir. Yer açmak için bölme sayısını artırabilirsin."
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(2)
            }
        }
    }

    private func funnelRow(_ title: String, _ value: Int, tint: Color) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            Spacer(minLength: 8)
            Text("\(value)").font(.caption.bold()).monospacedDigit().foregroundStyle(tint)
        }
    }

    // MARK: - Positions

    @ViewBuilder private var positions: some View {
        if !isLoading, !loadFailed, !simulatedTrades.isEmpty {
            if !listedCompletedTrades.isEmpty {
                SurfaceCard {
                    positionList(
                        title: L10n.text("Realized closes", "Gerçekleşen kapanışlar"),
                        icon: "checkmark.circle.fill",
                        tint: TrendysseyColor.positive,
                        trades: listedCompletedTrades
                    ) { trade in
                        completedRow(trade)
                    }
                }
            }
            if !listedOpenTrades.isEmpty {
                SurfaceCard {
                    positionList(
                        title: L10n.text("Open positions", "Açık pozisyonlar"),
                        icon: "hourglass",
                        tint: TrendysseyColor.accent,
                        trades: listedOpenTrades
                    ) { trade in
                        openRow(trade)
                    }
                }
            }
        }
    }

    private func positionList<Row: View>(
        title: String,
        icon: String,
        tint: Color,
        trades: [SimulatedTrade],
        @ViewBuilder row: @escaping (SimulatedTrade) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
                Spacer()
                Text("\(trades.count)").font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(TrendysseyColor.secondaryText)
            }
            // Every position is listed; lazily, because a wide window with a
            // high divide can complete hundreds of sales.
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(trades) { trade in
                    row(trade)
                    if trade.id != trades.last?.id { Divider() }
                }
            }
        }
    }

    private func completedRow(_ trade: SimulatedTrade) -> some View {
        let returnPercent = trade.exit?.returnPercent ?? 0
        let profit = allocationPerSlot * returnPercent / 100
        let isUp = returnPercent >= 0
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(trade.entry.symbol.replacingOccurrences(of: "USDT", with: ""))
                        .font(.subheadline.bold())
                    directionBadge(trade.entry.direction)
                    if let reason = trade.exit?.reason {
                        exitReasonBadge(reason)
                    }
                }
                Text(L10n.text(
                    "Entry \(L10n.dateTime(trade.entry.entryDate))",
                    "Giriş \(L10n.dateTime(trade.entry.entryDate))"
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                if let exit = trade.exit {
                    Text(L10n.text(
                        "Closed \(L10n.dateTime(exit.date)) · held \(durationText(from: trade.entry.entryDate, to: exit.date))",
                        "Kapanış \(L10n.dateTime(exit.date)) · süre \(durationText(from: trade.entry.entryDate, to: exit.date))"
                    ))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                }
                Text(entryStateSummary(trade.entry))
                    .font(.caption2)
                    .foregroundStyle(trade.entry.behavioralSignal?.direction.color ?? TrendysseyColor.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(profit, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                    .font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(isUp ? TrendysseyColor.positive : TrendysseyColor.negative)
                Text(returnPercent / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(1)))
                    .font(.caption2).monospacedDigit().foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
    }

    private func exitReasonBadge(_ reason: ScenarioExit.Reason) -> some View {
        let (text, tint): (String, Color) = switch reason {
        case .target: (L10n.text("TARGET", "HEDEF"), TrendysseyColor.positive)
        case .stopLoss: ("STOP", TrendysseyColor.negative)
        case .timeLimit: (L10n.text("TIME", "SÜRE"), TrendysseyColor.warning)
        }
        return Text(text)
            .font(.system(size: 8, weight: .black, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func openRow(_ trade: SimulatedTrade) -> some View {
        let unrealized = allocationPerSlot * trade.entry.currentReturnPercent / 100
        let isUp = trade.entry.currentReturnPercent >= 0
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(trade.entry.symbol.replacingOccurrences(of: "USDT", with: ""))
                        .font(.subheadline.bold())
                    directionBadge(trade.entry.direction)
                }
                Text(L10n.text(
                    "Entry \(L10n.dateTime(trade.entry.entryDate))",
                    "Giriş \(L10n.dateTime(trade.entry.entryDate))"
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                Text(L10n.text(
                    "Open \(durationText(from: trade.entry.entryDate, to: .now)) · peak \(Self.percentText(trade.entry.maximumReturnPercent))",
                    "\(durationText(from: trade.entry.entryDate, to: .now))’dir açık · zirve \(Self.percentText(trade.entry.maximumReturnPercent))"
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                Text(entryStateSummary(trade.entry))
                    .font(.caption2)
                    .foregroundStyle(trade.entry.behavioralSignal?.direction.color ?? TrendysseyColor.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(unrealized, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                    .font(.subheadline.bold()).monospacedDigit()
                    .foregroundStyle(isUp ? TrendysseyColor.positive : TrendysseyColor.negative)
                Text(trade.entry.currentReturnPercent / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(2)))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(isUp ? TrendysseyColor.positive : TrendysseyColor.negative)
            }
        }
    }

    private func directionBadge(_ direction: JourneyDirection) -> some View {
        Text(direction == .bullish ? "LONG" : "SHORT")
            .font(.system(size: 8, weight: .black, design: .rounded))
            .foregroundStyle(direction == .bullish ? TrendysseyColor.positive : TrendysseyColor.negative)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background((direction == .bullish ? TrendysseyColor.positive : TrendysseyColor.negative).opacity(0.12), in: Capsule())
    }

    private func entryStateSummary(_ entry: BreakoutScenarioEntry) -> String {
        guard let signal = entry.behavioralSignal else {
            return L10n.text("Behavior not recorded", "Davranış kaydedilmemiş")
        }
        let status = signal.status == .confirmed
            ? L10n.text("confirmed", "teyitli")
            : L10n.text("developing", "gelişiyor")
        return "\(signal.kind.title) · \(signal.score)/100 · \(status)"
    }

    /// Values interpolated into a sentence miss the environment locale, so they
    /// are formatted against the in-app language explicitly.
    private static func percentText(_ percent: Double) -> String {
        (percent / 100).formatted(
            .percent.sign(strategy: .always()).precision(.fractionLength(2)).locale(L10n.locale)
        )
    }

    private static func currencyText(_ amount: Double, fractionDigits: Int) -> String {
        amount.formatted(
            .currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(L10n.locale)
        )
    }

    /// "3" for whole multiples, "2.5" otherwise — slider steps are halves.
    fileprivate static func multiplierText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let hours = minutes / 60
        if hours >= 24 {
            return L10n.text("\(hours / 24)d \(hours % 24)h", "\(hours / 24)g \(hours % 24)s")
        }
        if hours > 0 {
            return L10n.text("\(hours)h \(minutes % 60)m", "\(hours)s \(minutes % 60)d")
        }
        return L10n.text("\(minutes)m", "\(minutes)d")
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(TrendysseyColor.surface, in: Capsule())
            .overlay(Capsule().stroke(TrendysseyColor.border, lineWidth: 1))
    }

    private func selectionRow<Content: View>(
        _ title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(TrendysseyColor.primaryText)
            Menu {
                content()
                    .labelsHidden()
            } label: {
                HStack(spacing: 8) {
                    Text(value)
                        .lineLimit(1)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(TrendysseyColor.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(TrendysseyColor.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).lineLimit(2)
            Spacer(minLength: 8)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .frame(height: 44)
    }

    private func resultMetric<F: FormatStyle>(_ title: String, _ value: F.FormatInput, format: F) -> some View where F.FormatInput: Equatable, F.FormatOutput == String {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: format).font(.subheadline.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultCount(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.subheadline.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        let result = try? await AnalysisInsightsService().scenarioEntries(
            timeframe: preferredTimeframe,
            lookback: lookback
        )
        if let result {
            entries = result.entries
            isTruncated = result.isTruncated
            loadFailed = false
            return
        }
        entries = []
        isTruncated = false
        loadFailed = true
    }
}
