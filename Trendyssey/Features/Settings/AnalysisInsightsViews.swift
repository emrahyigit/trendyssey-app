import SwiftUI
import Charts

struct DailyBreakoutSimulatorView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var scenarioModel = JourneyModel.selected
    @State private var preferredTimeframe = AnalysisTimeframe.selected.rawValue
    @State private var lookback = ScenarioLookback.day1
    /// Fixed scenario stake — the page asks one question with one number.
    private let investment = 100_000.0
    @State private var minimumDivide = 5
    @State private var profitTarget = 10.0
    @State private var stopLoss = 10.0
    /// Positions may stay open at most this long; at the deadline they close at
    /// market, profit or loss.
    @State private var maxOpenHours = 24
    /// 0 disables the filter. Entries recorded before the score shipped carry
    /// no value and always pass.
    @State private var minimumRelativeStrength = 0
    /// Coins whose 30-day breakout success rate sits below this are skipped,
    /// mirroring the dashboard's protection against serial fake-out coins.
    @State private var minimumSuccessRate = 50
    /// 30-day per-coin track record, keyed by symbol, for the success filter.
    @State private var journeyStats: [String: SymbolJourneyStats] = [:]
    /// Minimum 24h quote volume in millions of dollars; 0 disables the filter.
    @State private var minimumVolumeMillions = 10
    @State private var entryStatus: SignalStatus = .breakoutDetected
    @State private var entries: [BreakoutScenarioEntry] = []
    @State private var isTruncated = false
    /// True when the entries were recomputed here because the backend had none.
    @State private var isOnDevice = false
    @State private var isLoading = true
    @State private var loadFailed = false

    private let entryStatuses = SignalStatus.scenarioEntryCases

    private struct SimulatedTrade: Identifiable {
        let entry: BreakoutScenarioEntry
        let exit: ScenarioExit?

        var id: UUID { entry.id }
    }

    private struct SlotOccupation {
        let releaseDate: Date?
    }

    private var minimumQuoteVolume: Double { Double(minimumVolumeMillions) * 1_000_000 }

    private var volumeEligibleEntries: [BreakoutScenarioEntry] {
        entries.filter { $0.quoteVolume24h >= minimumQuoteVolume }
    }

    /// The dashboard's fake-out shield, applied to the replay: a coin whose
    /// 30-day success rate is below the threshold is skipped. Coins without
    /// enough history (fewer than 4 breakouts) pass — absence of data is not
    /// evidence of a bad coin.
    private var successEligibleEntries: [BreakoutScenarioEntry] {
        volumeEligibleEntries.filter { entry in
            guard let stats = journeyStats[entry.symbol],
                  stats.startedCount >= 4,
                  let successRate = stats.successRatePercent else { return true }
            return successRate >= Double(minimumSuccessRate)
        }
    }

    private var eligibleEntries: [BreakoutScenarioEntry] {
        successEligibleEntries.filter { entry in
            guard minimumRelativeStrength > 0, let strength = entry.relativeStrengthScore else { return true }
            return strength >= minimumRelativeStrength
        }
    }

    private var scenarioDirection: JourneyDirection { scenarioModel.direction }

    private var minimumVolumeText: String {
        minimumVolumeMillions <= 0
            ? L10n.text("Off", "Kapalı")
            : "$\(minimumVolumeMillions)M"
    }

    private var emptyResultDescription: String {
        if entries.isEmpty {
            return L10n.text(
                "No \(entryStatus.title(scenarioDirection).lowercased()) entry matches this model and window. Try a wider scenario window.",
                "Bu model ve aralıkta \(entryStatus.title(scenarioDirection).lowercased()) girişi yok. Senaryo aralığını genişletmeyi deneyebilirsin."
            )
        }
        if volumeEligibleEntries.isEmpty {
            return L10n.text(
                "Entries exist, but every coin is below the \(minimumVolumeText) volume line.",
                "Giriş var ancak tüm coinlerin hacmi \(minimumVolumeText) çizgisinin altında."
            )
        }
        if successEligibleEntries.isEmpty {
            return L10n.text(
                "Every remaining coin's 30-day success rate is below \(minimumSuccessRate)%.",
                "Kalan tüm coinlerin 30 günlük başarı oranı %\(minimumSuccessRate) altında."
            )
        }
        return L10n.text(
            "No entry reaches signal strength \(minimumRelativeStrength).",
            "Hiçbir giriş \(minimumRelativeStrength) sinyal gücüne ulaşmıyor."
        )
    }

    private var simulatedTrades: [SimulatedTrade] {
        let candidates = eligibleEntries.sorted {
            if $0.entryDate != $1.entryDate { return $0.entryDate < $1.entryDate }
            if $0.breakoutQualityScore != $1.breakoutQualityScore { return $0.breakoutQualityScore > $1.breakoutQualityScore }
            if $0.confirmationScore != $1.confirmationScore { return $0.confirmationScore > $1.confirmationScore }
            if $0.readinessScore != $1.readinessScore { return $0.readinessScore > $1.readinessScore }
            if $0.volumeRatio != $1.volumeRatio { return $0.volumeRatio > $1.volumeRatio }
            return $0.symbol < $1.symbol
        }
        var activeSlots: [SlotOccupation] = []
        var accepted: [SimulatedTrade] = []

        for entry in candidates {
            activeSlots.removeAll { slot in
                guard let releaseDate = slot.releaseDate else { return false }
                return releaseDate <= entry.entryDate
            }
            guard activeSlots.count < minimumDivide else { continue }
            let exit = entry.exit(profitTarget: profitTarget, stopLoss: stopLoss, maxOpenHours: maxOpenHours)
            accepted.append(SimulatedTrade(entry: entry, exit: exit))
            activeSlots.append(SlotOccupation(releaseDate: exit?.date))
        }
        return accepted
    }

    private var completedTrades: [SimulatedTrade] { simulatedTrades.filter { $0.exit != nil } }
    private var openTrades: [SimulatedTrade] { simulatedTrades.filter { $0.exit == nil } }
    private var openPositionCount: Int { openTrades.count }
    private var skippedOverlapCount: Int { eligibleEntries.count - simulatedTrades.count }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                SurfaceCard { controls }
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
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Breakout Scenario", "Kırılım Senaryosu"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(preferredTimeframe)|\(entryStatus.rawValue)|\(lookback.rawValue)|\(scenarioModel.rawValue)") {
            await load()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("PRO SIMULATOR", "PRO SİMÜLATÖR"), systemImage: "function")
                .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
            Text(scenarioDirection == .bullish
                ? L10n.text("What would the measured breakouts have returned if you invested $100k?", "100k $ yatırsaydın ölçülen kırılımlar ne getirirdi?")
                : L10n.text("What would the measured breakdowns have returned if you invested $100k?", "100k $ yatırsaydın ölçülen düşüş kırılımları ne getirirdi?"))
                .font(.title2.bold())
            Text(L10n.text(
                "Every \(scenarioModel.title) entry that matched your filters in \(lookback.title.lowercased()) is listed below as a realized sale or an open position.",
                "\(lookback.title) içinde filtrelerine uyan her \(scenarioModel.title) girişi, aşağıda gerçekleşen satış veya açık pozisyon olarak listelenir."
            ))
            .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
            if isOnDevice {
                Text(L10n.text(
                    "The backend has no recorded history for this model yet, so the journeys were recomputed here over the \(JourneyBacktestService.symbolLimit) highest-volume coins.",
                    "Sunucuda bu model için henüz kayıt yok; süreçler en yüksek hacimli \(JourneyBacktestService.symbolLimit) coin üzerinde bu cihazda yeniden hesaplandı."
                ))
                .font(.caption).foregroundStyle(TrendysseyColor.warning)
            }
        }
    }

    private var scenarioTags: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(scenarioModel.title, icon: "chart.xyaxis.line")
                chip(AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe, icon: "clock")
                chip(lookback.shortTitle, icon: "calendar")
                chip(entryStatus.title(scenarioDirection), icon: "bolt.fill")
                if minimumVolumeMillions > 0 {
                    chip(L10n.text("Vol. ≥ \(minimumVolumeText)", "Hacim ≥ \(minimumVolumeText)"), icon: "drop.fill")
                }
                chip(L10n.text("\(eligibleEntries.count) signal(s)", "\(eligibleEntries.count) sinyal"), icon: "number")
                if isOnDevice {
                    chip(L10n.text("on this device", "bu cihazda"), icon: "iphone")
                }
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
                    Picker("", selection: $lookback) {
                        ForEach(ScenarioLookback.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                }
                Divider()
                selectionRow(
                    L10n.text("Entry status", "Alış durumu"),
                    value: entryStatus.title(scenarioDirection)
                ) {
                    Picker("", selection: $entryStatus) {
                        ForEach(entryStatuses, id: \.self) { status in
                            Text(status.title(scenarioDirection)).tag(status)
                        }
                    }
                }
                Divider()
                stepperRow(
                    L10n.text("Min. success rate: \(minimumSuccessRate)%", "Min. başarı oranı: %\(minimumSuccessRate)"),
                    value: $minimumSuccessRate,
                    range: 0...90,
                    step: 10
                )
                Divider()
                stepperRow(
                    L10n.text("Min. signal strength: \(minimumRelativeStrength)", "Min. sinyal gücü: \(minimumRelativeStrength)"),
                    value: $minimumRelativeStrength,
                    range: 0...90,
                    step: 10
                )
                Divider()
                stepperRow(
                    L10n.text("Minimum 24h volume: \(minimumVolumeText)", "Minimum 24s hacim: \(minimumVolumeText)"),
                    value: $minimumVolumeMillions,
                    range: 0...100,
                    step: 5
                )
                Divider()
                stepperRow(
                    L10n.text("Minimum divide: \(minimumDivide)", "Minimum bölme: \(minimumDivide)"),
                    value: $minimumDivide,
                    range: 1...20,
                    step: 1
                )
                Divider()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("Virtual close target", "Sanal kapanış hedefi")).font(.subheadline.bold())
                    Spacer()
                    Text(profitTarget / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(1)))
                        .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.positive)
                }
                Slider(value: $profitTarget, in: 0.5...20, step: 0.5).tint(TrendysseyColor.positive)
            }
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("Stop loss", "Stop loss")).font(.subheadline.bold())
                    Spacer()
                    Text(-stopLoss / 100, format: .percent.precision(.fractionLength(1)))
                        .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.negative)
                }
                Slider(value: $stopLoss, in: 0.5...20, step: 0.5).tint(TrendysseyColor.negative)
            }
            .padding(.top, 10)
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
                    description: Text(L10n.text("Journey entries or live price paths could not be loaded.", "Süreç girişleri veya canlı fiyat hareketleri yüklenemedi."))
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
                    Divider()
                    scoreProfile
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
            if minimumSuccessRate > 0 {
                funnelRow(
                    L10n.text("Success rate below \(minimumSuccessRate)%", "Başarı oranı %\(minimumSuccessRate) altında"),
                    volumeEligibleEntries.count - successEligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            if minimumRelativeStrength > 0 {
                funnelRow(
                    L10n.text("Below signal strength \(minimumRelativeStrength)", "Sinyal gücü \(minimumRelativeStrength) altında"),
                    successEligibleEntries.count - eligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            funnelRow(
                L10n.text("Simulated", "Simüle edilen"),
                simulatedTrades.count,
                tint: TrendysseyColor.positive
            )
            if skippedOverlapCount > 0 {
                funnelRow(
                    L10n.text("Skipped — no free slot", "Atlandı — boş slot yoktu"),
                    skippedOverlapCount,
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

    private var scoreProfile: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("AVERAGE SIGNAL STRENGTH AT ENTRY", "ORTALAMA GİRİŞ SİNYAL GÜCÜ"))
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            scenarioScoreTile(L10n.text("Signal strength", "Sinyal gücü"), text: averageRelativeStrengthText)
        }
    }

    private func scenarioScoreTile(_ title: String, text: String) -> some View {
        HStack {
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            Spacer(minLength: 6)
            Text(text).font(.caption.bold()).monospacedDigit()
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(TrendysseyColor.elevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Average over the entries that actually carry the score; "—" while the
    /// window predates it, so an unmeasured past never reads as "average 50".
    private var averageRelativeStrengthText: String {
        let values = simulatedTrades.compactMap { $0.entry.relativeStrengthScore }
        guard !values.isEmpty else { return "—" }
        return "\(Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()))"
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
                Text(scoreSummary(trade.entry))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).monospacedDigit()
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
                Text(scoreSummary(trade.entry))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).monospacedDigit()
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

    private func scoreSummary(_ entry: BreakoutScenarioEntry) -> String {
        L10n.text(
            "Signal strength \(entry.relativeStrengthScore.map { "\($0)" } ?? "—")",
            "Sinyal gücü \(entry.relativeStrengthScore.map { "\($0)" } ?? "—")"
        )
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
        HStack(spacing: 12) {
            Text(title).font(.subheadline)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 12)
            Menu {
                content()
                    .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Text(value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(TrendysseyColor.accent)
                .frame(maxWidth: 215, alignment: .trailing)
            }
            .layoutPriority(1)
        }
        .frame(minHeight: 44)
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
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
        journeyStats = (try? await JourneyStatsService.shared.invalidationStats(
            modelSlug: scenarioModel.serverSlug ?? AnalysisModelSelection.defaultSlug,
            timeframe: preferredTimeframe
        )) ?? [:]
        let result = try? await AnalysisInsightsService().scenarioEntries(
            modelSlug: scenarioModel.serverSlug ?? AnalysisModelSelection.defaultSlug,
            direction: scenarioModel.direction,
            timeframe: preferredTimeframe,
            status: entryStatus,
            lookback: lookback
        )
        if let result, !result.entries.isEmpty {
            entries = result.entries
            isTruncated = result.isTruncated
            isOnDevice = false
            loadFailed = false
            return
        }
        // The backend records journeys per model, and a model it has not run yet
        // has no history to replay. Rather than show an empty screen, the same
        // journeys are recomputed here from candles. Once the backend starts
        // recording them, the query above wins on its own.
        let replayed = await replayOnDevice()
        entries = replayed
        isTruncated = false
        isOnDevice = !replayed.isEmpty
        loadFailed = result == nil && replayed.isEmpty
    }

    @MainActor private func replayOnDevice() async -> [BreakoutScenarioEntry] {
        guard let symbols = try? await environment.marketService.allSymbols() else { return [] }
        let rankedSignals = symbols
            .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
            .prefix(JourneyBacktestService.symbolLimit)
        let ranked = rankedSignals.map(\.symbol)
        return await JourneyBacktestService.shared.scenarioEntries(
            model: scenarioModel,
            symbols: ranked,
            volumeBySymbol: Dictionary(rankedSignals.map { ($0.symbol, $0.quoteVolume24h) }, uniquingKeysWith: { first, _ in first }),
            timeframe: AnalysisTimeframe(rawValue: preferredTimeframe) ?? .m15,
            lookbackHours: min(lookback.hours, JourneyBacktestService.availableHours(timeframe: AnalysisTimeframe(rawValue: preferredTimeframe) ?? .m15)),
            status: entryStatus
        )
    }
}
