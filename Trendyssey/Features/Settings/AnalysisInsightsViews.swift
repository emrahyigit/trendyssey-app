import SwiftUI
import Charts

struct DailyBreakoutSimulatorView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var scenarioModel = JourneyModel.selected
    @State private var preferredTimeframe = AnalysisTimeframe.selected.rawValue
    @State private var lookback = ScenarioLookback.day1
    @State private var investment = 1_000.0
    @State private var minimumDivide = 5
    @State private var profitTarget = 5.0
    @State private var minimumRegime = 50
    @State private var minimumReadiness = 50
    @State private var minimumBreakoutQuality = 50
    @State private var minimumConfirmation = 50
    /// Minimum 24h quote volume in millions of dollars; 0 disables the filter.
    @State private var minimumVolumeMillions = 10
    @State private var entryStatus: SignalStatus = .breakoutDetected
    @State private var isScoreThresholdsExpanded = false
    @State private var entries: [BreakoutScenarioEntry] = []
    @State private var isTruncated = false
    /// True when the entries were recomputed here because the backend had none.
    @State private var isOnDevice = false
    @State private var isLoading = true
    @State private var loadFailed = false

    private let entryStatuses = SignalStatus.scenarioEntryCases

    private struct SimulatedTrade: Identifiable {
        let entry: BreakoutScenarioEntry
        let saleDate: Date?

        var id: UUID { entry.id }
    }

    private struct SlotOccupation {
        let releaseDate: Date?
    }

    private var minimumQuoteVolume: Double { Double(minimumVolumeMillions) * 1_000_000 }

    private var volumeEligibleEntries: [BreakoutScenarioEntry] {
        entries.filter { $0.quoteVolume24h >= minimumQuoteVolume }
    }

    private var regimeEligibleEntries: [BreakoutScenarioEntry] {
        volumeEligibleEntries.filter { $0.regimeScore >= minimumRegime }
    }

    private var readinessEligibleEntries: [BreakoutScenarioEntry] {
        regimeEligibleEntries.filter { $0.readinessScore >= minimumReadiness }
    }

    private var qualityEligibleEntries: [BreakoutScenarioEntry] {
        readinessEligibleEntries.filter { $0.breakoutQualityScore >= minimumBreakoutQuality }
    }

    private var eligibleEntries: [BreakoutScenarioEntry] {
        qualityEligibleEntries.filter { $0.confirmationScore >= minimumConfirmation }
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
        if regimeEligibleEntries.isEmpty {
            return L10n.text("No entry reaches regime \(minimumRegime).", "Hiçbir giriş \(minimumRegime) rejim puanına ulaşmıyor.")
        }
        if readinessEligibleEntries.isEmpty {
            return L10n.text("No entry reaches readiness \(minimumReadiness).", "Hiçbir giriş \(minimumReadiness) hazırlık puanına ulaşmıyor.")
        }
        if qualityEligibleEntries.isEmpty {
            return L10n.text("No entry reaches breakout quality \(minimumBreakoutQuality).", "Hiçbir giriş \(minimumBreakoutQuality) kırılım kalitesine ulaşmıyor.")
        }
        return L10n.text("No entry reaches confirmation \(minimumConfirmation).", "Hiçbir giriş \(minimumConfirmation) teyit puanına ulaşmıyor.")
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
            let saleDate = entry.targetHitDate(profitTarget: profitTarget)
            accepted.append(SimulatedTrade(entry: entry, saleDate: saleDate))
            activeSlots.append(SlotOccupation(releaseDate: saleDate))
        }
        return accepted
    }

    private var completedTrades: [SimulatedTrade] { simulatedTrades.filter { $0.saleDate != nil } }
    private var openTrades: [SimulatedTrade] { simulatedTrades.filter { $0.saleDate == nil } }
    private var openPositionCount: Int { openTrades.count }
    private var skippedOverlapCount: Int { eligibleEntries.count - simulatedTrades.count }

    private var targetHitRate: Double {
        guard !simulatedTrades.isEmpty else { return 0 }
        return Double(completedTrades.count) / Double(simulatedTrades.count)
    }

    private var allocationPerSlot: Double { investment / Double(minimumDivide) }

    private var simulatedProfit: Double {
        allocationPerSlot * profitTarget / 100 * Double(completedTrades.count)
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
                scenarioTags
                result
                positions
                Label(
                    L10n.text(
                        "Historical scenario only. A position closes when the market touches the directional virtual target inside any candle; no candle close is required. Positions that never touch it remain open and add no realized profit. Fees, funding, slippage and tax are excluded.",
                        "Yalnızca geçmiş veriye dayalı senaryodur. Piyasa herhangi bir mum içinde yönsel sanal hedefe dokunduğunda pozisyon kapanır; mum kapanışı beklenmez. Hedefe hiç dokunmayan pozisyonlar açık kalır ve gerçekleşmiş kâra eklenmez. Komisyon, fonlama, fiyat kayması ve vergi dahil değildir."
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
                ? L10n.text("What would the measured breakouts have returned?", "Ölçülen kırılımlar ne kadar sonuç üretirdi?")
                : L10n.text("What would the measured breakdowns have returned?", "Ölçülen düşüş kırılımları ne kadar sonuç üretirdi?"))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("Investment amount", "Senaryo tutarı")).font(.subheadline.bold())
                    Spacer()
                    Text(investment, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.accent)
                }
                Slider(value: $investment, in: 100...100_000, step: 100).tint(TrendysseyColor.accent)
            }
            .padding(.vertical, 10)
            Divider()
            VStack(spacing: 0) {
                selectionRow(
                    L10n.text("Model", "Model"),
                    value: scenarioModel.title
                ) {
                    Picker("", selection: $scenarioModel) {
                        ForEach(JourneyModel.selectableCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                }
                Divider()
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
                scoreThresholdRows
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
                Text(L10n.text(
                    "Enter when \(entryStatus.title(scenarioDirection)) begins and close when the \(scenarioDirection == .bullish ? "upside" : "downside") target is touched.",
                    "\(entryStatus.title(scenarioDirection)) başladığında giriş, \(scenarioDirection == .bullish ? "yukarı" : "aşağı") yönlü hedefe dokunulduğunda kapanış kabul edilir."
                ))
                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
            .padding(.top, 10)
        }
    }

    /// The four minimum-score steppers folded behind one summary row, the same
    /// presentation the notification score thresholds use in Settings.
    private var scoreThresholdRows: some View {
        DisclosureGroup(isExpanded: $isScoreThresholdsExpanded) {
            VStack(spacing: 0) {
                stepperRow(
                    L10n.text("Minimum regime: \(minimumRegime)", "Minimum rejim: \(minimumRegime)"),
                    value: $minimumRegime,
                    range: 0...90,
                    step: 10
                )
                Divider()
                stepperRow(
                    L10n.text("Minimum readiness: \(minimumReadiness)", "Minimum hazırlık: \(minimumReadiness)"),
                    value: $minimumReadiness,
                    range: 0...90,
                    step: 10
                )
                Divider()
                stepperRow(
                    L10n.text("Minimum breakout quality: \(minimumBreakoutQuality)", "Minimum kırılım kalitesi: \(minimumBreakoutQuality)"),
                    value: $minimumBreakoutQuality,
                    range: 0...90,
                    step: 10
                )
                Divider()
                stepperRow(
                    L10n.text("Minimum confirmation: \(minimumConfirmation)", "Minimum teyit: \(minimumConfirmation)"),
                    value: $minimumConfirmation,
                    range: 0...90,
                    step: 10
                )
            }
        } label: {
            HStack(spacing: 12) {
                Text(L10n.text("Score thresholds", "Puan eşikleri"))
                    .font(.subheadline)
                    .foregroundStyle(TrendysseyColor.primaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(L10n.text(
                    "R\(minimumRegime) · Rd\(minimumReadiness) · Q\(minimumBreakoutQuality) · C\(minimumConfirmation)",
                    "R\(minimumRegime) · H\(minimumReadiness) · K\(minimumBreakoutQuality) · T\(minimumConfirmation)"
                ))
                .font(.subheadline).monospacedDigit()
                .foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
        .frame(minHeight: 44)
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
                        "The budget is split into \(minimumDivide) reusable slot(s), \(Self.currencyText(allocationPerSlot, fractionDigits: 0)) each. \(completedTrades.count) directional position(s) closed at \(Self.percentText(profitTarget)).",
                        "Bütçe, her biri \(Self.currencyText(allocationPerSlot, fractionDigits: 0)) olan yeniden kullanılabilir \(minimumDivide) slota bölünür. \(completedTrades.count) yönsel pozisyon \(Self.percentText(profitTarget)) seviyesinde kapandı."
                    ))
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                    Divider()
                    funnel
                    Divider()
                    scoreProfile
                    HStack(spacing: 10) {
                        resultMetric(L10n.text("Target hit", "Hedefe ulaşma"), targetHitRate, format: .percent.precision(.fractionLength(0)))
                        resultCount(L10n.text("Closed", "Kapandı"), completedTrades.count)
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
            if minimumRegime > 0 {
                funnelRow(
                    L10n.text("Below regime \(minimumRegime)", "Rejim \(minimumRegime) altında"),
                    volumeEligibleEntries.count - regimeEligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            if minimumReadiness > 0 {
                funnelRow(
                    L10n.text("Below readiness \(minimumReadiness)", "Hazırlık \(minimumReadiness) altında"),
                    regimeEligibleEntries.count - readinessEligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            if minimumBreakoutQuality > 0 {
                funnelRow(
                    L10n.text("Below quality \(minimumBreakoutQuality)", "Kalite \(minimumBreakoutQuality) altında"),
                    readinessEligibleEntries.count - qualityEligibleEntries.count,
                    tint: TrendysseyColor.secondaryText
                )
            }
            if minimumConfirmation > 0 {
                funnelRow(
                    L10n.text("Below confirmation \(minimumConfirmation)", "Teyit \(minimumConfirmation) altında"),
                    qualityEligibleEntries.count - eligibleEntries.count,
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
                    "A position holds its slot until the target is hit, so positions that never reach it keep their slot for the rest of the window. Entries are filled oldest first, so later signals are the ones dropped. Raise the divide to make room.",
                    "Bir pozisyon hedefe ulaşana kadar slotunu tutar; hedefe hiç ulaşmayanlar aralığın sonuna kadar slotu bırakmaz. Girişler en eskiden başlayarak doldurulur, dolayısıyla atlananlar hep sonraki sinyallerdir. Yer açmak için bölme sayısını artırabilirsin."
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
            Text(L10n.text("AVERAGE ENTRY SCORES", "ORTALAMA GİRİŞ PUANLARI"))
                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                scenarioScoreTile(L10n.text("Regime", "Rejim"), averageScore(\.regimeScore))
                scenarioScoreTile(L10n.text("Readiness", "Hazırlık"), averageScore(\.readinessScore))
                scenarioScoreTile(L10n.text("Quality", "Kalite"), averageScore(\.breakoutQualityScore))
                scenarioScoreTile(L10n.text("Confirmation", "Teyit"), averageScore(\.confirmationScore))
            }
        }
    }

    private func averageScore(_ keyPath: KeyPath<BreakoutScenarioEntry, Int>) -> Int {
        guard !simulatedTrades.isEmpty else { return 0 }
        let total = simulatedTrades.reduce(0) { $0 + $1.entry[keyPath: keyPath] }
        return Int((Double(total) / Double(simulatedTrades.count)).rounded())
    }

    private func scenarioScoreTile(_ title: String, _ score: Int) -> some View {
        HStack {
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            Spacer(minLength: 6)
            Text("\(score)").font(.caption.bold()).monospacedDigit()
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(TrendysseyColor.elevated, in: RoundedRectangle(cornerRadius: 10))
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
        let profit = allocationPerSlot * profitTarget / 100
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
                if let saleDate = trade.saleDate {
                    Text(L10n.text(
                        "Closed \(L10n.dateTime(saleDate)) · held \(durationText(from: trade.entry.entryDate, to: saleDate))",
                        "Kapanış \(L10n.dateTime(saleDate)) · süre \(durationText(from: trade.entry.entryDate, to: saleDate))"
                    ))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                }
                Text(scoreSummary(trade.entry))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(profit, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                    .font(.subheadline.bold()).monospacedDigit().foregroundStyle(TrendysseyColor.positive)
                Text(profitTarget / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(1)))
                    .font(.caption2).monospacedDigit().foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
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
            "R \(entry.regimeScore) · Rd \(entry.readinessScore) · Q \(entry.breakoutQualityScore) · C \(entry.confirmationScore)",
            "R \(entry.regimeScore) · H \(entry.readinessScore) · K \(entry.breakoutQualityScore) · T \(entry.confirmationScore)"
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
