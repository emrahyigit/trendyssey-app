import SwiftUI
import Charts
import UIKit

struct SignalDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let signal: MarketSignal
    @State private var candles: [PriceCandle] = []
    @State private var analysis: EMAJourneyAnalysis?
    @State private var chartError = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"

    private static let emaFastColor = TrendysseyColor.binanceYellow
    private static let emaMediumColor = Color(red: 0.91, green: 0.42, blue: 0.66)
    private static let emaLongColor = Color(red: 0.62, green: 0.49, blue: 0.92)

    private var currentPhase: SignalStatus { analysis?.currentPhase ?? signal.status }

    /// Coins outside the backend's high-volume universe get live on-device
    /// analysis only for Pro members.
    private var liveAnalysisAllowed: Bool {
        signal.hasScore || environment.subscriptionStore.isSubscribed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
                    VStack(alignment: .leading) {
                        Text(signal.symbol).font(.title2.bold())
                        if liveAnalysisAllowed {
                            Text(currentPhase.title)
                                .font(.subheadline)
                                .foregroundStyle(currentPhase == .watching ? TrendysseyColor.secondaryText : TrendysseyColor.positive)
                        } else {
                            Text(L10n.text("Low-volume coin", "Düşük hacimli coin"))
                                .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText)
                        }
                    }
                    Spacer(minLength: 4)
                    binanceLink
                    favorite
                }
                SurfaceCard { candleChart }
                if liveAnalysisAllowed {
                    SurfaceCard { journeyCard }
                    SurfaceCard { confidenceCard }
                } else {
                    SurfaceCard { proTeaser }
                }
                SurfaceCard { CoinChatPreview(symbol: signal.symbol, journeyID: signal.journeyID, journeyPhase: currentPhase) }
            }.padding(18)
        }.background(TrendysseyColor.canvas.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
            .task(id: "\(signal.symbol)-\(preferredTimeframe)") {
                while !Task.isCancelled {
                    await loadCandles()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
    }

    private var proTeaser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("Live analysis is a Pro feature", "Canlı analiz bir Pro özelliği"), systemImage: "lock.fill")
                .font(.headline)
            Text(L10n.text(
                "This coin is outside the high-volume scan universe. Trendyssey Pro unlocks instant EMA 7/25/99 journey and confidence analysis for every listed coin.",
                "Bu coin yüksek hacimli tarama evreninin dışında. Trendyssey Pro, listelenen her coin için anlık EMA 7/25/99 süreç ve güven puanı analizini açar."
            ))
            .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
            NavigationLink { SubscriptionView() } label: {
                Text(L10n.text("Unlock with Trendyssey Pro", "Trendyssey Pro ile aç"))
                    .font(.subheadline.bold()).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(TrendysseyColor.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var binanceLink: some View {
        Button(action: openInBinance) {
            HStack(spacing: 5) {
                Image("BinanceMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("BINANCE")
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
        .accessibilityLabel(L10n.text("Open \(signal.baseSymbol) on Binance", "\(signal.baseSymbol) paritesini Binance'ta aç"))
    }

    private var binanceDeepLinkURL: URL {
        URL(string: "bnc://app.binance.com/trade/trade?at=spot&symbol=\(signal.symbol.lowercased())")!
    }

    private var binanceSpotWebURL: URL {
        URL(string: "https://www.binance.com/en/trade/\(signal.baseSymbol)_USDT?type=spot")!
    }

    private func openInBinance() {
        UIApplication.shared.open(binanceDeepLinkURL, options: [:]) { opened in
            guard !opened else { return }
            UIApplication.shared.open(binanceSpotWebURL)
        }
    }

    private var favorite: some View { Button { environment.toggleWatchlist(signal.symbol) } label: { Image(systemName: environment.watchlist.contains(signal.symbol) ? "star.fill" : "star").frame(width: 42, height: 42).background(TrendysseyColor.surface, in: Circle()) }.foregroundStyle(TrendysseyColor.accent).accessibilityLabel(L10n.text("Toggle watchlist", "Takip listesini değiştir")) }

    // MARK: - Chart

    private struct EMAPoint: Identifiable {
        let time: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
    }

    @ViewBuilder private var candleChart: some View {
        if candles.isEmpty && !chartError {
            ProgressView(L10n.text("Loading \(AnalysisTimeframe.selected.title) candles…", "\(AnalysisTimeframe.selected.title) mumları yükleniyor…")).frame(maxWidth: .infinity).frame(height: 220)
        } else if chartError {
            ContentUnavailableView(L10n.text("Chart unavailable", "Grafik yüklenemedi"), systemImage: "chart.xyaxis.line", description: Text(L10n.text("Close and reopen the page to retry.", "Yeniden denemek için sayfayı kapatıp açabilirsin.")))
                .frame(height: 220)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("Price candles", "Fiyat mumları")).font(.headline)
                    Spacer()
                    Text(AnalysisTimeframe.selected.rawValue.uppercased())
                    if candles.last?.isClosed == false { Label(L10n.text("LIVE", "GEÇİCİ"), systemImage: "clock").foregroundStyle(TrendysseyColor.warning) }
                    else { Text(L10n.text("CLOSED", "KAPANMIŞ")) }
                }.font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
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
                    ForEach(emaOverlayPoints) { point in
                        LineMark(
                            x: .value(L10n.text("Time", "Zaman"), point.time),
                            y: .value("EMA", point.value),
                            series: .value("EMA", point.series)
                        )
                        .foregroundStyle(emaColor(point.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
                .chartYScale(domain: chartDomain)
                .chartXAxis(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: 210)
                HStack(spacing: 12) {
                    emaLegend("EMA 7", Self.emaFastColor)
                    emaLegend("EMA 25", Self.emaMediumColor)
                    emaLegend("EMA 99", Self.emaLongColor)
                }
            }
        }
    }

    private func emaLegend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(TrendysseyColor.secondaryText)
        }
    }

    private var visibleCandles: [PriceCandle] { Array(candles.suffix(48)) }

    private var emaOverlayPoints: [EMAPoint] {
        guard let analysis, let windowStart = visibleCandles.first?.openTime else { return [] }
        var points: [EMAPoint] = []
        for (series, values) in [("EMA 7", analysis.emaFast), ("EMA 25", analysis.emaMedium), ("EMA 99", analysis.emaLong)] {
            for (index, candle) in analysis.candles.enumerated() where candle.openTime >= windowStart {
                if let value = values[index] {
                    points.append(EMAPoint(time: candle.openTime, value: value, series: series))
                }
            }
        }
        return points
    }

    private func emaColor(_ series: String) -> Color {
        switch series {
        case "EMA 7": Self.emaFastColor
        case "EMA 25": Self.emaMediumColor
        default: Self.emaLongColor
        }
    }

    private var chartDomain: ClosedRange<Double> {
        let visible = visibleCandles
        let emaValues = emaOverlayPoints.map(\.value)
        let lows = visible.map(\.low) + emaValues
        let highs = visible.map(\.high) + emaValues
        guard let low = lows.min(), let high = highs.max() else { return 0...1 }
        let padding = max((high - low) * 0.10, abs(high) * 0.001)
        return (low - padding)...(high + padding)
    }

    @MainActor private func loadCandles() async {
        do {
            let higher = AnalysisTimeframe.selected.higher
            async let higherCandles = CandleService().candles(for: signal.symbol, interval: higher.interval, limit: 200)
            let fetched = try await CandleService().candles(for: signal.symbol, limit: 500)
            candles = fetched
            if liveAnalysisAllowed {
                analysis = EMAJourneyAnalyzer.analyze(
                    candles: fetched,
                    higherTimeframeCandles: try? await higherCandles,
                    higherTimeframeTitle: higher.title
                )
            }
            chartError = false
        } catch { if candles.isEmpty { chartError = true } }
    }

    // MARK: - Journey (last 24 hours)

    @ViewBuilder private var journeyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("Breakout Journey", "Kırılım Süreci"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Spacer()
                Text(L10n.text("LAST 24H", "SON 24 SAAT"))
                    .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            }
            if let analysis {
                SignalJourneyProgress(status: analysis.currentPhase, compact: true)
                let events = analysis.events(lastHours: 24)
                if events.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("No phase transition in the last 24 hours.", "Son 24 saatte aşama geçişi olmadı."))
                            .font(.caption.weight(.semibold))
                        Text(analysis.currentPhase.journeyGuidance)
                            .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                    }
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(spacing: 3) {
                                Circle().fill(journeyColor(event.status)).frame(width: 10, height: 10)
                                if index < events.count - 1 {
                                    Rectangle().fill(TrendysseyColor.secondaryText.opacity(0.25)).frame(width: 1, height: 28)
                                }
                            }.padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.status.title).font(.subheadline.bold()).foregroundStyle(journeyColor(event.status))
                                Text(event.time.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
                            }
                            Spacer()
                            Text("$\(event.price.formatted(.number.precision(.fractionLength(2...6))))")
                                .font(.caption.bold()).monospacedDigit()
                        }
                    }
                }
                Text(L10n.text("Phases are derived from EMA 7/25 crossovers on closed \(AnalysisTimeframe.selected.title) candles; EMA 99 acts as the trend filter.", "Aşamalar, kapanmış \(AnalysisTimeframe.selected.title) mumlarındaki EMA 7/25 kesişimlerinden türetilir; EMA 99 trend filtresi olarak kullanılır."))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            } else if chartError {
                Label(L10n.text("Journey analysis is temporarily unavailable.", "Süreç analizi geçici olarak kullanılamıyor."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(TrendysseyColor.warning)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }

    private func journeyColor(_ status: SignalStatus) -> Color {
        switch status {
        case .confirmed, .retest: TrendysseyColor.positive
        case .breakoutDetected, .preBreakout: TrendysseyColor.accent
        case .failed, .expired: TrendysseyColor.negative
        case .watching: TrendysseyColor.secondaryText
        }
    }

    // MARK: - Confidence

    @ViewBuilder private var confidenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("Confidence Score", "Güven Puanı"), systemImage: "gauge.with.needle")
                .font(.headline)
            if let analysis {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(analysis.confidence)").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        + Text(" / 100").font(.subheadline).foregroundColor(TrendysseyColor.secondaryText)
                    Spacer()
                    Text(confidenceLevelTitle(analysis.confidence))
                        .font(.caption.bold())
                        .foregroundStyle(confidenceColor(analysis.confidence))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(confidenceColor(analysis.confidence).opacity(0.12), in: Capsule())
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TrendysseyColor.border)
                        Capsule()
                            .fill(confidenceColor(analysis.confidence))
                            .frame(width: max(6, proxy.size.width * CGFloat(analysis.confidence) / 100))
                    }
                }
                .frame(height: 6)
                Divider()
                Text(L10n.text("Why this score?", "Bu puan neden verildi?")).font(.subheadline.bold())
                ForEach(analysis.factors) { factor in factorRow(factor) }
                Text(L10n.text("Data is a statistical assessment, not investment advice.", "Veriler istatistiksel değerlendirmedir; yatırım tavsiyesi değildir."))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            } else if chartError {
                Text(L10n.text("The score could not be computed because candle data is unavailable.", "Mum verisi alınamadığı için puan hesaplanamadı."))
                    .font(.caption).foregroundStyle(TrendysseyColor.warning)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
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

    private func confidenceLevelTitle(_ score: Int) -> String {
        switch score {
        case 75...: L10n.text("Strong", "Güçlü")
        case 50..<75: L10n.text("Moderate", "Orta")
        case 30..<50: L10n.text("Weak", "Zayıf")
        default: L10n.text("Very weak", "Çok zayıf")
        }
    }

    private func confidenceColor(_ score: Int) -> Color {
        switch score {
        case 75...: TrendysseyColor.positive
        case 50..<75: TrendysseyColor.accent
        case 30..<50: TrendysseyColor.warning
        default: TrendysseyColor.negative
        }
    }
}
