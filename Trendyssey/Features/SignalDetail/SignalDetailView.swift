import SwiftUI
import Charts
import UIKit

struct SignalDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let signal: MarketSignal
    @State private var candles: [PriceCandle] = []
    @State private var analysis: JourneyAnalysis?
    @State private var chartOverlay = JourneyChartOverlay.empty
    @State private var chartError = false
    @State private var refreshedMarketState: MarketStateSnapshot?
    /// (holds, fails) among predictors with a proven record on this journey.
    @State private var topPredictorConsensus: (holds: Int, fails: Int)?
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    private static let overlayColors: [String: Color] = [
        "ema7": TrendysseyColor.binanceYellow,
        "ema25": Color(red: 0.91, green: 0.42, blue: 0.66),
        "ema99": Color(red: 0.62, green: 0.49, blue: 0.92),
        "donchianUpper": TrendysseyColor.accent,
        "breakoutLevel": TrendysseyColor.accent,
        "horizontalResistance": TrendysseyColor.accent,
        "rangeUpper": TrendysseyColor.accent,
        "rangeLower": Color(red: 0.28, green: 0.66, blue: 0.88),
        "neckline": TrendysseyColor.accent,
        "patternBase": Color(red: 0.62, green: 0.49, blue: 0.92),
    ]

    /// Raw storage may still hold a retired model from an older install; the
    /// chart must follow the same gate the data queries use.
    private var selectedModel: JourneyModel {
        guard let model = JourneyModel(rawValue: journeyModel),
              JourneyModel.selectableCases.contains(model) else { return .emaCross }
        return model
    }
    private var selectedTimeframe: AnalysisTimeframe { AnalysisTimeframe(rawValue: preferredTimeframe) ?? .m15 }
    private var currentMarketState: MarketStateSnapshot? { refreshedMarketState ?? signal.marketState }

    /// Analysis exists only where the server computed it: coins with a signal
    /// row. The app never derives one of its own.
    private var liveAnalysisAllowed: Bool {
        signal.hasScore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
                    VStack(alignment: .leading) {
                        Text(signal.symbol)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        // The state belongs to the Market Control card below;
                        // repeating it in the header only crowded the title.
                        if !liveAnalysisAllowed {
                            Text(L10n.text("Low-volume coin", "Düşük hacimli coin"))
                                .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
                        }
                    }
                    Spacer(minLength: 4)
                    binanceLink
                    favorite
                }
                SurfaceCard { candleChart }
                if let state = currentMarketState {
                    SurfaceCard { CurrentMarketStateCard(snapshot: state) }
                }
                if let consensus = topPredictorConsensus {
                    SurfaceCard {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.badge.gearshape")
                                .font(.caption).foregroundStyle(TrendysseyColor.accent)
                            Text(L10n.text(
                                "Top predictors on this observation: \(consensus.holds) positive · \(consensus.fails) negative",
                                "Bu gözlemde en iyi tahminciler: \(consensus.holds) olumlu · \(consensus.fails) olumsuz"
                            ))
                            .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !liveAnalysisAllowed {
                    SurfaceCard { proTeaser }
                }
                SurfaceCard { CoinChatPreview(symbol: signal.symbol, journeyID: signal.journeyID) }
            }.padding(18)
        }.background(TrendysseyColor.canvas.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
            .task(id: "\(signal.symbol)-\(preferredTimeframe)-\(journeyModel)") {
                let requestedModel = selectedModel
                let requestedTimeframe = selectedTimeframe
                analysis = nil
                chartOverlay = .empty
                topPredictorConsensus = nil
                if let states = try? await MarketStateService.shared.snapshots(timeframe: requestedTimeframe.rawValue) {
                    refreshedMarketState = states[signal.symbol]
                }
                Task { await loadTopPredictorConsensus() }
                while !Task.isCancelled {
                    await loadCandles(model: requestedModel, timeframe: requestedTimeframe)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    private var proTeaser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("Not enough volume to analyze", "Analiz için yeterli hacim yok"), systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.headline)
            Text(L10n.text(
                "Only the 100 highest-volume coins are analyzed on each candle close. This coin is currently below that line; it joins the scans as soon as its volume carries it back into the top 100.",
                "Her mum kapanışında sadece hacmi en yüksek 100 coin analiz edilir. Bu coin şu anda bu çizginin altında; hacmi onu yeniden ilk 100'e taşıdığında taramalara dahil olur."
            ))
            .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exchange: PreferredExchange { .binance }

    private var binanceLink: some View {
        Button(action: openInExchange) {
            HStack(spacing: 5) {
                if exchange.usesBinanceMark {
                    Image("BinanceMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                }
                Text(exchange.title.uppercased())
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(0.55)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .black))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(TrendysseyColor.binanceYellow, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
        .accessibilityLabel(L10n.text("Open \(signal.baseSymbol) on \(exchange.title)", "\(signal.baseSymbol) paritesini \(exchange.title) üzerinde aç"))
    }

    private func openInExchange() {
        let webURL = exchange.webURL(baseAsset: signal.baseSymbol)
        guard let appURL = exchange.appURL(symbol: signal.symbol) else {
            UIApplication.shared.open(webURL)
            return
        }
        UIApplication.shared.open(appURL, options: [:]) { opened in
            guard !opened else { return }
            UIApplication.shared.open(webURL)
        }
    }

    private var favorite: some View { Button { environment.toggleWatchlist(signal.symbol) } label: { Image(systemName: environment.watchlist.contains(signal.symbol) ? "star.fill" : "star").frame(width: 42, height: 42).background(TrendysseyColor.surface, in: Circle()) }.foregroundStyle(TrendysseyColor.accent).accessibilityLabel(L10n.text("Toggle watchlist", "Takip listesini değiştir")) }

    // MARK: - Chart

    private struct OverlayPoint: Identifiable {
        let time: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
    }

    @ViewBuilder private var candleChart: some View {
        if candles.isEmpty && !chartError {
            ProgressView(L10n.text("Loading \(selectedTimeframe.title) candles…", "\(selectedTimeframe.title) mumları yükleniyor…")).frame(maxWidth: .infinity).frame(height: 220)
        } else if chartError {
            ContentUnavailableView(L10n.text("Chart unavailable", "Grafik yüklenemedi"), systemImage: "chart.xyaxis.line", description: Text(L10n.text("Close and reopen the page to retry.", "Yeniden denemek için sayfayı kapatıp açabilirsin.")))
                .frame(height: 220)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("Price candles", "Fiyat mumları"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("(\(selectedTimeframe.rawValue.uppercased()))")
                        .font(.caption.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                    HStack(alignment: .center, spacing: 4) {
                        Circle().fill(TrendysseyColor.negative).frame(width: 6, height: 6)
                        Text(verbatim: "LIVE").font(.caption2.bold())
                    }
                    .foregroundStyle(TrendysseyColor.negative)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(TrendysseyColor.negative.opacity(0.12), in: Capsule())
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("$\(livePrice.formatted(.number.precision(.fractionLength(2...6)).locale(L10n.locale)))")
                            .font(.caption.bold())
                            .foregroundStyle(TrendysseyColor.primaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(L10n.text("Vol. $\(compactChartVolume)", "Hacim $\(compactChartVolume)"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(TrendysseyColor.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Chart {
                    ForEach(visibleCandles) { candle in
                        RuleMark(x: .value(L10n.text("Time", "Zaman"), candle.openTime), yStart: .value(L10n.text("Low", "Düşük"), candle.low), yEnd: .value(L10n.text("High", "Yüksek"), candle.high))
                            .foregroundStyle(candle.isRising ? TrendysseyColor.positive : TrendysseyColor.negative)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: candle.isClosed ? [] : [3, 3]))
                            .opacity(candle.isClosed ? 1 : 0.45)
                        RectangleMark(x: .value(L10n.text("Time", "Zaman"), candle.openTime), yStart: .value(L10n.text("Open", "Açılış"), candle.open), yEnd: .value(L10n.text("Close", "Kapanış"), candle.close), width: 5)
                            .foregroundStyle(candle.isRising ? TrendysseyColor.positive : TrendysseyColor.negative)
                            .opacity(candle.isClosed ? 1 : 0.45)
                    }
                    ForEach(seriesPoints) { point in
                        LineMark(
                            x: .value(L10n.text("Time", "Zaman"), point.time),
                            y: .value(L10n.text("Value", "Değer"), point.value),
                            series: .value(L10n.text("Series", "Seri"), point.series)
                        )
                        .foregroundStyle(Self.overlayColor(point.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                    ForEach(chartOverlay.levels) { level in
                        RuleMark(y: .value(level.title, level.price))
                            .foregroundStyle(Self.overlayColor(level.key))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(visibleMarkers) { marker in
                        PointMark(
                            x: .value(L10n.text("Time", "Zaman"), marker.time),
                            y: .value(marker.title, marker.price)
                        )
                        .foregroundStyle(TrendysseyColor.accent)
                        .symbolSize(70)
                    }
                }
                .chartYScale(domain: chartDomain)
                .chartXAxis(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: 210)
                chartLegend
            }
        }
    }

    @ViewBuilder private var chartLegend: some View {
        if !chartOverlay.series.isEmpty || !chartOverlay.levels.isEmpty {
            HStack(spacing: 12) {
                ForEach(chartOverlay.series) { series in
                    overlayLegend(series.title, Self.overlayColor(series.key), dashed: false)
                }
                ForEach(chartOverlay.levels) { level in
                    overlayLegend(level.title, Self.overlayColor(level.key), dashed: true)
                }
            }
        }
    }

    private func overlayLegend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Capsule().fill(color).frame(width: 5, height: 3)
                Capsule().fill(color).frame(width: 5, height: 3)
            } else {
                Capsule().fill(color).frame(width: 14, height: 3)
            }
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(TrendysseyColor.secondaryText)
                .lineLimit(1)
        }
    }

    /// The last 48 candles, widened when the model marks pattern pivots further
    /// back so the shape it found stays on screen.
    /// The newest close, which is the live price while the last candle is open.
    private var livePrice: Double { candles.last?.close ?? signal.price }

    private var compactChartVolume: String {
        signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale))
    }

    private var visibleCandles: [PriceCandle] {
        let minimumWindow = 48
        guard let earliestMarker = chartOverlay.markers.map(\.time).min() else {
            return Array(candles.suffix(minimumWindow))
        }
        let sinceMarker = candles.filter { $0.openTime >= earliestMarker }.count
        return Array(candles.suffix(min(140, max(minimumWindow, sinceMarker + 6))))
    }

    private var seriesPoints: [OverlayPoint] {
        guard let windowStart = visibleCandles.first?.openTime else { return [] }
        var points: [OverlayPoint] = []
        for series in chartOverlay.series {
            for (index, candle) in candles.enumerated() where candle.openTime >= windowStart {
                if index < series.values.count, let value = series.values[index] {
                    points.append(OverlayPoint(time: candle.openTime, value: value, series: series.key))
                }
            }
        }
        return points
    }

    private var visibleMarkers: [JourneyMarker] {
        guard let windowStart = visibleCandles.first?.openTime else { return [] }
        return chartOverlay.markers.filter { $0.time >= windowStart }
    }

    private static func overlayColor(_ key: String) -> Color {
        overlayColors[key] ?? TrendysseyColor.secondaryText
    }

    private var chartDomain: ClosedRange<Double> {
        let visible = visibleCandles
        let overlayValues = seriesPoints.map(\.value)
            + chartOverlay.levels.map(\.price)
            + visibleMarkers.map(\.price)
        let lows = visible.map(\.low) + overlayValues
        let highs = visible.map(\.high) + overlayValues
        guard let low = lows.min(), let high = highs.max() else { return 0...1 }
        let padding = max((high - low) * 0.10, abs(high) * 0.001)
        return (low - padding)...(high + padding)
    }

    @MainActor private func loadCandles(model: JourneyModel, timeframe: AnalysisTimeframe) async {
        do {
            let fetched = try await CandleService().liveChartCandles(
                for: signal.symbol,
                interval: timeframe.rawValue,
                // EMA 99 needs enough warm-up candles to span the full
                // 48-candle viewport instead of appearing as a tiny tail.
                limit: 160
            )
            guard !Task.isCancelled, model == selectedModel, timeframe == selectedTimeframe else { return }
            candles = fetched
            // EMA/channel lines are display-only and use the same live Binance
            // candles as the chart. Server evidence is merged in below when it
            // arrives, but sparse snapshot history can no longer blank the UI.
            chartOverlay = ChartOverlayService.overlay(
                model: model,
                candles: fetched,
                serverAnalysis: nil
            )
            chartError = false

            var serverAnalysis: JourneyAnalysis?
            if liveAnalysisAllowed, !fetched.isEmpty {
                serverAnalysis = await ServerAnalysisService.shared.analysis(
                    for: signal,
                    model: model,
                    timeframe: timeframe.rawValue,
                    candles: fetched
                )
            }
            guard !Task.isCancelled, model == selectedModel, timeframe == selectedTimeframe else { return }
            analysis = serverAnalysis
            chartOverlay = ChartOverlayService.overlay(
                model: model,
                candles: fetched,
                serverAnalysis: serverAnalysis
            )
        } catch { if candles.isEmpty { chartError = true } }
    }

    /// Counts only predictions from users with a proven record (5+ resolved,
    /// 60%+ accuracy), so the line reflects informed opinion, not raw votes.
    @MainActor private func loadTopPredictorConsensus() async {
        guard let journeyID = signal.journeyID else { return }
        let service = SignalPredictionService()
        guard let votes = try? await service.journeyPredictions(journeyID: journeyID), !votes.isEmpty,
              let records = try? await service.accuracies(userIDs: votes.map(\.userID)) else { return }
        let qualified = votes.filter { vote in
            guard let record = records[vote.userID] else { return false }
            return record.resolvedCount >= 5 && record.accuracyPercent >= 60
        }
        guard !qualified.isEmpty else { return }
        topPredictorConsensus = (
            holds: qualified.filter(\.holds).count,
            fails: qualified.filter { !$0.holds }.count
        )
    }

    private func factorRow(_ factor: ConfidenceFactor) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: factorIcon(factor))
                .foregroundStyle(factorColor(factor)).font(.caption)
            VStack(alignment: .leading, spacing: 3) {
                Text(factor.title).font(.caption.bold())
                Text(factor.detail)
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("\(factor.score)/\(factor.maxScore)")
                .font(.caption.bold()).monospacedDigit().foregroundStyle(factorColor(factor))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(factorColor(factor).opacity(0.10), in: Capsule())
        }
    }

    private func factorIcon(_ factor: ConfidenceFactor) -> String {
        switch factor.strength {
        case 0.66...: "checkmark.circle.fill"
        case 0.33..<0.66: "minus.circle.fill"
        default: "exclamationmark.circle.fill"
        }
    }

    private func factorColor(_ factor: ConfidenceFactor) -> Color {
        switch factor.strength {
        case 0.66...: TrendysseyColor.positive
        case 0.33..<0.66: TrendysseyColor.warning
        default: TrendysseyColor.negative
        }
    }

}
