import SwiftUI
import Charts

struct DailyBreakoutSimulatorView: View {
    @State private var preferredTimeframe = AnalysisTimeframe.selected.rawValue
    @State private var investment = 1_000.0
    @State private var minimumDivide = 5
    @State private var profitTarget = 5.0
    @State private var minimumConfidence = 50
    @State private var entryStatus: SignalStatus = .breakoutDetected
    @State private var entries: [BreakoutScenarioEntry] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    private let entryStatuses = SignalStatus.scenarioEntryCases

    private struct SimulatedTrade {
        let entry: BreakoutScenarioEntry
        let saleDate: Date?
    }

    private struct SlotOccupation {
        let releaseDate: Date?
    }

    private var eligibleEntries: [BreakoutScenarioEntry] {
        entries.filter { $0.signalStrength >= minimumConfidence }
    }

    private var simulatedTrades: [SimulatedTrade] {
        let candidates = eligibleEntries.sorted {
            if $0.entryDate != $1.entryDate { return $0.entryDate < $1.entryDate }
            if $0.signalStrength != $1.signalStrength { return $0.signalStrength > $1.signalStrength }
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

    private var simulatedProfit: Double {
        let allocationPerSlot = investment / Double(minimumDivide)
        return allocationPerSlot * profitTarget / 100 * Double(completedTrades.count)
    }

    private var unrealizedProfit: Double {
        let allocationPerSlot = investment / Double(minimumDivide)
        return openTrades.reduce(0) { $0 + allocationPerSlot * $1.entry.currentReturnPercent / 100 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                SurfaceCard { controls }
                scenarioTags
                result
                Label(
                    L10n.text(
                        "Historical scenario only. A sale completes when the market touches the virtual target price inside any candle; no candle close is required. Positions that never touch it remain open and add no realized profit. Fees, slippage and tax are excluded.",
                        "Yalnızca geçmiş veriye dayalı senaryodur. Piyasa herhangi bir mum içinde sanal hedef satış fiyatına dokunduğunda satış tamamlanır; mum kapanışı beklenmez. Hedefe hiç dokunmayan pozisyonlar açık kalır ve gerçekleşmiş kâra eklenmez. Komisyon, fiyat kayması ve vergi dahil değildir."
                    ),
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Daily Breakout Scenario", "Günlük Kırılım Senaryosu"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(preferredTimeframe)|\(entryStatus.rawValue)") { await load() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("PRO SIMULATOR", "PRO SİMÜLATÖR"), systemImage: "function")
                .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
            Text(L10n.text("What would the measured breakouts have returned?", "Ölçülen kırılımlar ne kadar sonuç üretirdi?"))
                .font(.title2.bold())
        }
    }

    private var scenarioTags: some View {
        HStack(spacing: 8) {
            chip("EMA 7/25/99", icon: "chart.xyaxis.line")
            chip(AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe, icon: "clock")
            chip(entryStatus.title, icon: "bolt.fill")
        }
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
                    L10n.text("Entry status", "Alış durumu"),
                    value: entryStatus.title
                ) {
                    Picker("", selection: $entryStatus) {
                        ForEach(entryStatuses, id: \.self) { status in
                            Text(status.title).tag(status)
                        }
                    }
                }
                Divider()
                stepperRow(
                    L10n.text("Minimum confidence: \(minimumConfidence)", "Minimum güven puanı: \(minimumConfidence)"),
                    value: $minimumConfidence,
                    range: 0...90,
                    step: 10
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
                    Text(L10n.text("Virtual sale target", "Sanal satış hedefi")).font(.subheadline.bold())
                    Spacer()
                    Text(profitTarget / 100, format: .percent.sign(strategy: .always()).precision(.fractionLength(1)))
                        .font(.headline).monospacedDigit().foregroundStyle(TrendysseyColor.positive)
                }
                Slider(value: $profitTarget, in: 0.5...20, step: 0.5).tint(TrendysseyColor.positive)
                Text(L10n.text(
                    "Buy when \(entryStatus.title) begins and sell the moment this profit target is touched.",
                    "\(entryStatus.title) başladığında alıp bu kâr hedefine dokunulduğu anda satıldığı kabul edilir."
                ))
                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
            .padding(.top, 10)
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
                    description: Text(entries.isEmpty
                        ? L10n.text("No \(entryStatus.title.lowercased()) entry in the last 24 hours matches these filters.", "Son 24 saatte bu filtrelere uyan \(entryStatus.title.lowercased()) girişi yok.")
                        : L10n.text("Entries exist, but none reach the minimum confidence of \(minimumConfidence). Lower the filter to include them.", "Giriş var ancak hiçbiri \(minimumConfidence) minimum güven puanına ulaşmıyor. Filtreyi düşürerek dahil edebilirsin."))
                )
            }
        } else {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("REALIZED 24H PROFIT", "GERÇEKLEŞEN 24S KÂR"))
                        .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                    Text(simulatedProfit, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(simulatedProfit >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                        .monospacedDigit()
                    Text(L10n.text(
                        "The budget is split into \(minimumDivide) reusable slot(s), \((investment / Double(minimumDivide)).formatted(.currency(code: "USD").precision(.fractionLength(0)))) each. \(completedTrades.count) virtual sale(s) completed at +\(profitTarget.formatted(.number.precision(.fractionLength(1))))%; \(skippedOverlapCount) overlapping entry event(s) were skipped because every slot was occupied.",
                        "Bütçe, her biri \((investment / Double(minimumDivide)).formatted(.currency(code: "USD").precision(.fractionLength(0)))) olan yeniden kullanılabilir \(minimumDivide) slota bölünür. \(completedTrades.count) sanal satış +%\(profitTarget.formatted(.number.precision(.fractionLength(1)))) seviyesinde tamamlandı; tüm slotlar dolu olduğu için çakışan \(skippedOverlapCount) giriş olayı atlandı."
                    ))
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                    HStack(spacing: 10) {
                        resultMetric(L10n.text("Target hit", "Hedefe ulaşma"), targetHitRate, format: .percent.precision(.fractionLength(0)))
                        resultCount(L10n.text("Sold", "Satıldı"), completedTrades.count)
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
                }
            }
        }
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
                .lineLimit(1)
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
        do {
            entries = try await AnalysisInsightsService().scenarioEntries(
                modelSlug: AnalysisModelSelection.selectedSlug,
                timeframe: preferredTimeframe,
                status: entryStatus,
                since: .now.addingTimeInterval(-86_400)
            )
            loadFailed = false
        } catch {
            entries = []
            loadFailed = true
        }
    }
}

struct ModelPerformanceComparisonView: View {
    private struct HorizonPerformance: Identifiable {
        let horizon: Int
        let performance: AnalysisModelPerformance?

        var id: Int { horizon }
        var title: String { L10n.text("\(horizon) candle(s) later", "\(horizon) mum sonra") }
    }

    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @State private var values: [HorizonPerformance] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    private static let horizons = [1, 4, 12]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("PRO PERFORMANCE", "PRO PERFORMANS"), systemImage: "chart.bar.xaxis")
                        .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
                    Text(L10n.text("How accurate is EMA Cross 7/25/99?", "EMA Cross 7/25/99 ne kadar isabetli?"))
                        .font(.title2.bold())
                    Text(L10n.text(
                        "Measured outcomes on \(AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe) candles, tracked over three horizons after each detected breakout.",
                        "\(AnalysisTimeframe(rawValue: preferredTimeframe)?.title ?? preferredTimeframe) mumlarında, algılanan her kırılımdan sonra üç ayrı ufukta ölçülen sonuçlar."
                    ))
                    .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
                }
                performanceContent
                Label(
                    L10n.text(
                        "Hold rate is the share of measured outcomes in which price stayed above the breakout level. Consider sample size and average return together; historical results do not guarantee future performance.",
                        "Tutma oranı, ölçülen sonuçlar içinde fiyatın kırılım seviyesinin üzerinde kaldığı durumların payıdır. Örneklem büyüklüğü ve ortalama getiri birlikte değerlendirilmelidir; geçmiş sonuçlar geleceği garanti etmez."
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Model Performance", "Model Performansı"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: preferredTimeframe) { await load() }
    }

    @ViewBuilder private var performanceContent: some View {
        if isLoading {
            SurfaceCard { ProgressView(L10n.text("Loading measurements…", "Ölçümler yükleniyor…")).frame(maxWidth: .infinity).padding(.vertical, 30) }
        } else if loadFailed {
            SurfaceCard { ContentUnavailableView(L10n.text("Measurements unavailable", "Ölçümler yüklenemedi"), systemImage: "wifi.exclamationmark") }
        } else if values.allSatisfy({ $0.performance == nil }) {
            SurfaceCard {
                ContentUnavailableView(
                    L10n.text("Not enough measurements", "Yeterli ölçüm yok"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(L10n.text("Evaluated outcomes will appear here as history grows.", "Geçmiş oluştukça değerlendirilmiş sonuçlar burada görünecek."))
                )
            }
        } else {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("HOLD RATE BY HORIZON", "UFKA GÖRE TUTMA ORANI")).font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                    Chart(values.filter { $0.performance != nil }) { value in
                        BarMark(
                            x: .value(L10n.text("Hold rate", "Tutma oranı"), value.performance?.successRate ?? 0),
                            y: .value(L10n.text("Horizon", "Ufuk"), value.title)
                        )
                        .foregroundStyle(TrendysseyColor.accent.gradient)
                        .annotation(position: .trailing) {
                            Text((value.performance?.successRate ?? 0) / 100, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.bold()).monospacedDigit()
                        }
                    }
                    .chartXScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } } } }
                    .frame(height: 170)
                }
            }
            ForEach(values) { value in
                if let performance = value.performance {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(value.title).font(.headline)
                                Spacer()
                                Text(performance.successRate / 100, format: .percent.precision(.fractionLength(0)))
                                    .font(.title3.bold()).foregroundStyle(performance.successRate >= 50 ? TrendysseyColor.positive : TrendysseyColor.warning).monospacedDigit()
                            }
                            HStack(spacing: 16) {
                                horizonMetric(L10n.text("Measured", "Ölçüm"), "\(performance.evaluatedCount)")
                                horizonMetric(L10n.text("H / F / L", "K / Y / Z"), "\(performance.winCount) / \(performance.flatCount) / \(performance.lossCount)")
                                horizonMetric(L10n.text("Avg. return", "Ort. getiri"), (performance.averageReturnPercent / 100).formatted(.percent.sign(strategy: .always()).precision(.fractionLength(2))))
                            }
                        }
                    }
                }
            }
        }
    }

    private func horizonMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.subheadline.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        let service = AnalysisInsightsService()
        do {
            var loaded: [HorizonPerformance] = []
            for horizon in Self.horizons {
                let rows = try await service.modelPerformance(timeframe: preferredTimeframe, horizon: horizon)
                loaded.append(HorizonPerformance(horizon: horizon, performance: rows.first))
            }
            values = loaded
            loadFailed = false
        } catch {
            values = []
            loadFailed = true
        }
    }
}
