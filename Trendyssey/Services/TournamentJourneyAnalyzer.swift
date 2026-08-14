import Foundation

/// The on-device mirror of the server's tournament-winner engine
/// (`supabase/functions/_shared/signal_lifecycle.ts` + `trend_score.ts`):
/// a journey starts when a closed candle freshly clears the highest high of
/// the prior 55 candles; success is a touch of entry + 1.5×ATR, invalidation
/// is a 3×ATR chandelier trail that only ever ratchets up, and the horizon is
/// 3× the old 24h window. Replaced the EMA 7/25 crossover analyzer in Aug 2026.
enum TournamentJourneyAnalyzer: JourneyDetector {
    nonisolated static let model = JourneyModel.emaCross
    nonisolated static let breakoutPeriod = 55
    nonisolated static let mediumPeriod = 25
    nonisolated static let longPeriod = 99
    nonisolated static let momentumCandles = 20
    nonisolated static let chandelierMultiplier = 3.0
    nonisolated static let successAtr = 1.5
    nonisolated static let upgradeAtr = 3.0

    // MARK: - JourneyDetector

    nonisolated static func analyze(
        candles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]? = nil,
        higherTimeframeTitle: String? = nil
    ) -> JourneyAnalysis? {
        analyze(
            candles: candles,
            btcCandles: nil,
            higherTimeframeCandles: higherTimeframeCandles,
            higherTimeframeTitle: higherTimeframeTitle
        )
    }

    /// `btcCandles` feeds the momentum-vs-BTC component; without it the
    /// component reads the neutral midpoint and no entry can qualify as A+,
    /// exactly like the server when the BTC fetch fails.
    nonisolated static func analyze(
        candles allCandles: [PriceCandle],
        btcCandles: [PriceCandle]?,
        higherTimeframeCandles: [PriceCandle]? = nil,
        higherTimeframeTitle: String? = nil
    ) -> JourneyAnalysis? {
        let candles = allCandles.filter(\.isClosed)
        guard candles.count >= breakoutPeriod + 5 else { return nil }
        let closes = candles.map(\.close)
        let ema25 = ema(closes, period: mediumPeriod)
        let ema99 = ema(closes, period: longPeriod)
        let atr = atrSeries(candles)
        let level = donchianSeries(candles)
        let horizon = horizonCandles(for: candles)
        let btcCloseByTime: [Date: Double] = btcCandles.map { series in
            Dictionary(series.filter(\.isClosed).map { ($0.closeTime, $0.close) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]

        var state: SignalStatus = .watching
        var events: [JourneyEvent] = []
        var aPlusEventTimes: Set<Date> = []
        var entryPrice = 0.0
        var entryAtr = 0.0
        var highWatermark = 0.0
        var entryIndex = -1
        var entryEventTime: Date?
        var journeyIsAPlus = false

        for i in candles.indices {
            guard i >= breakoutPeriod, let hi55 = level[i], atr[i] > 0 else { continue }
            let candle = candles[i]
            let currentAtr = atr[i]
            // "Fresh" compares the previous close against ITS OWN prior-55
            // window, mirroring trend_score.ts — a steady climb where every
            // candle makes a new high is not a stream of fresh breakouts.
            let previousLevel = i > breakoutPeriod ? (level[i - 1] ?? hi55) : hi55
            let fresh = candle.close > hi55 && candles[i - 1].close <= previousLevel
            let regimeAligned = ema25[i].map { medium in
                ema99[i].map { medium > $0 && candle.close > $0 } ?? false
            } ?? false
            let momentum = momentumExcess(candles: candles, index: i, btcCloseByTime: btcCloseByTime)
            let clearanceAtr = (candle.close - hi55) / currentAtr
            var newState = state

            switch state {
            case .breakoutDetected:
                let trail = highWatermark - chandelierMultiplier * entryAtr
                if candle.low <= trail {
                    newState = .failed
                } else if candle.high >= entryPrice + successAtr * entryAtr {
                    newState = .confirmed
                } else if i - entryIndex >= horizon {
                    newState = .expired
                }
            case .confirmed:
                if i - entryIndex >= horizon { newState = .expired }
            case .watching, .preBreakout, .failed, .expired:
                if fresh {
                    newState = .breakoutDetected
                    entryPrice = candle.close
                    entryAtr = currentAtr
                    highWatermark = candle.close
                    entryIndex = i
                    entryEventTime = candle.closeTime
                    journeyIsAPlus = regimeAligned && (momentum ?? 0) > 0
                    if journeyIsAPlus { aPlusEventTimes.insert(candle.closeTime) }
                } else if clearanceAtr <= 0 {
                    // Enter within half an ATR below the 55-high; leave only
                    // past 0.8 ATR — the same hysteresis the server uses.
                    if state == .preBreakout {
                        newState = clearanceAtr < -0.8 ? .watching : .preBreakout
                    } else {
                        newState = clearanceAtr >= -0.5 ? .preBreakout : .watching
                    }
                } else if state == .failed || state == .expired {
                    newState = .watching
                }
            }

            // A+ can also align mid-journey; the journey keeps the badge for
            // its whole life, matching the server's sticky flag.
            if newState == .breakoutDetected || newState == .confirmed {
                if !journeyIsAPlus, fresh == false, regimeAligned, (momentum ?? 0) > 0, candle.close > hi55 {
                    journeyIsAPlus = true
                    if let entryEventTime { aPlusEventTimes.insert(entryEventTime) }
                }
                // The candle survived its own stop check above; only now may
                // its high raise the trail — and never on the entry candle
                // itself, whose watermark is its close, same as the server.
                if entryIndex != i {
                    highWatermark = max(highWatermark, candle.high)
                }
            }

            if newState != state {
                state = newState
                events.append(JourneyEvent(status: state, time: candle.closeTime, price: candle.close))
            }
        }

        let volumeRatio = JourneyAnalyzer.latestVolumeRatio(candles: candles)
        let last = candles.count - 1
        let score = trendComponents(
            candles: candles,
            index: last,
            level: level[last],
            atr: atr[last],
            ema25: ema25[last],
            ema99: ema99[last],
            btcCloseByTime: btcCloseByTime
        )
        let factors = trendFactors(score)
        var analysis = JourneyAnalysis(
            model: model,
            candles: candles,
            series: [
                JourneySeries(key: "d55", title: L10n.text("Reference level", "Referans seviye"), values: level),
                JourneySeries(key: "ema25", title: "EMA 25", values: ema25),
                JourneySeries(key: "ema99", title: "EMA 99", values: ema99),
            ],
            levels: level[last].map { [JourneyLevel(key: "d55", title: L10n.text("Reference level", "Referans seviye"), price: $0)] } ?? [],
            markers: [],
            events: events,
            currentPhase: state,
            confidence: score.total,
            factors: factors,
            volumeRatio: volumeRatio
        )
        analysis.scoreLayers = SignalScoreLayers(
            regimeScore: Int((Double(score.regime) / 25 * 100).rounded()),
            readinessScore: Int((Double(score.breakout) / 40 * 100).rounded()),
            breakoutQualityScore: score.total,
            confirmationScore: state == .confirmed ? 100 : state == .breakoutDetected ? 35 : 0,
            breakoutTriggered: state == .breakoutDetected || state == .confirmed,
            scoringVersion: "trend-score-v1"
        )
        analysis.trendScore = score.total
        analysis.aPlusEventTimes = aPlusEventTimes
        return analysis
    }

    // MARK: - Trend score (mirror of trend_score.ts)

    private struct TrendComponents {
        let breakout: Int
        let regime: Int
        let momentum: Int
        let health: Int
        var total: Int { breakout + regime + momentum + health }
    }

    private nonisolated static func trendComponents(
        candles: [PriceCandle],
        index: Int,
        level: Double?,
        atr: Double,
        ema25: Double?,
        ema99: Double?,
        btcCloseByTime: [Date: Double]
    ) -> TrendComponents {
        guard let level, atr > 0, index >= breakoutPeriod else {
            return TrendComponents(breakout: 0, regime: 0, momentum: 10, health: 0)
        }
        let close = candles[index].close
        let clearance = (close - level) / atr
        let breakout = close > level
            ? Int((25 + 15 * min(1, max(0, clearance))).rounded())
            : Int((15 * min(1, max(0, 1 + clearance))).rounded())
        let stack = ema25.flatMap { medium in ema99.map { medium > $0 } } ?? false
        let above = ema99.map { close > $0 } ?? false
        let regime = (stack ? 15 : 0) + (above ? 10 : 0)
        let excess = momentumExcess(candles: candles, index: index, btcCloseByTime: btcCloseByTime)
        let momentum = excess.map { Int((20 * min(1, max(0, ($0 + 0.02) / 0.06))).rounded()) } ?? 10
        let recent = candles[max(0, index - 21)...index]
        let recentHigh = recent.map(\.high).max() ?? close
        let chandelier = recentHigh - chandelierMultiplier * atr
        let health = Int((15 * min(1, max(0, (close - chandelier) / atr / chandelierMultiplier))).rounded())
        return TrendComponents(breakout: breakout, regime: regime, momentum: momentum, health: health)
    }

    private nonisolated static func trendFactors(_ score: TrendComponents) -> [ConfidenceFactor] {
        [
            ConfidenceFactor(
                key: "trend.breakout",
                title: L10n.text("Breakout position", "Kırılım konumu"),
                detail: L10n.text("Where price sits against the tracked reference level.", "Fiyatın izlenen referans seviyeye göre konumu."),
                score: score.breakout, maxScore: 40
            ),
            ConfidenceFactor(
                key: "trend.regime",
                title: L10n.text("Trend regime", "Trend rejimi"),
                detail: L10n.text("EMA 25 above EMA 99 with price above both.", "EMA 25, EMA 99'un üzerinde ve fiyat her ikisinin üstünde."),
                score: score.regime, maxScore: 25
            ),
            ConfidenceFactor(
                key: "trend.momentum",
                title: L10n.text("Momentum vs BTC", "BTC'ye görece momentum"),
                detail: L10n.text("The coin's 20-candle return measured against BTC's.", "Coinin 20 mumluk getirisinin BTC'ninkiyle kıyası."),
                score: score.momentum, maxScore: 20
            ),
            ConfidenceFactor(
                key: "trend.health",
                title: L10n.text("Trend health", "Trend sağlığı"),
                detail: L10n.text("Distance above a stop trailing the recent high by 3×ATR.", "Son zirveyi 3×ATR geriden izleyen stopun ne kadar üzerinde kalındığı."),
                score: score.health, maxScore: 15
            ),
        ]
    }

    private nonisolated static func momentumExcess(
        candles: [PriceCandle],
        index: Int,
        btcCloseByTime: [Date: Double]
    ) -> Double? {
        guard index >= momentumCandles, !btcCloseByTime.isEmpty else { return nil }
        let base = candles[index - momentumCandles]
        let last = candles[index]
        guard base.close > 0,
              let btcLast = btcCloseByTime[last.closeTime],
              let btcBase = btcCloseByTime[base.closeTime],
              btcBase > 0 else { return nil }
        return (last.close / base.close - 1) - (btcLast / btcBase - 1)
    }

    // MARK: - Shared indicator math

    nonisolated static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard values.count >= period, period > 0 else { return Array(repeating: nil, count: values.count) }
        var result: [Double?] = Array(repeating: nil, count: values.count)
        let seed = values[0..<period].reduce(0, +) / Double(period)
        result[period - 1] = seed
        let multiplier = 2.0 / Double(period + 1)
        var previous = seed
        for index in period..<values.count {
            let value = (values[index] - previous) * multiplier + previous
            result[index] = value
            previous = value
        }
        return result
    }

    /// Highest high of the PRIOR 55 candles per index (current excluded).
    nonisolated static func donchianSeries(_ candles: [PriceCandle]) -> [Double?] {
        var result: [Double?] = Array(repeating: nil, count: candles.count)
        for i in candles.indices where i >= breakoutPeriod {
            result[i] = candles[(i - breakoutPeriod)..<i].map(\.high).max()
        }
        return result
    }

    /// Rolling ATR(14), same recurrence as the server's indicator library.
    nonisolated static func atrSeries(_ candles: [PriceCandle], period: Int = 14) -> [Double] {
        var result = [Double](repeating: 0, count: candles.count)
        var value = 0.0
        var seeded = 0
        for i in candles.indices where i > 0 {
            let range = max(
                candles[i].high - candles[i].low,
                abs(candles[i].high - candles[i - 1].close),
                abs(candles[i].low - candles[i - 1].close)
            )
            if seeded < period {
                value = (value * Double(seeded) + range) / Double(seeded + 1)
                seeded += 1
            } else {
                value = (value * Double(period - 1) + range) / Double(period)
            }
            result[i] = value
        }
        return result
    }

    /// 3× the old 24h window, in candles, inferred from the candle spacing.
    private nonisolated static func horizonCandles(for candles: [PriceCandle]) -> Int {
        guard candles.count >= 2 else { return 288 }
        let minutes = candles[1].openTime.timeIntervalSince(candles[0].openTime) / 60
        switch minutes {
        case ..<30: return 288
        case ..<120: return 72
        case ..<720: return 18
        default: return 21
        }
    }

    // MARK: - Higher-timeframe confluence (max 10)

    /// Scores how well the next timeframe up agrees with the move, in the
    /// tournament model's regime terms: EMA 25 against EMA 99 with price.
    nonisolated static func confluenceFactor(
        direction: JourneyDirection,
        higherTimeframeCandles: [PriceCandle]?,
        higherTimeframeTitle: String?
    ) -> ConfidenceFactor? {
        let confluenceMax = 10
        guard let allCandles = higherTimeframeCandles else { return nil }
        let candles = allCandles.filter(\.isClosed)
        guard candles.count >= mediumPeriod + 1 else { return nil }
        let closes = candles.map(\.close)
        let lastIndex = closes.count - 1
        guard let medium = ema(closes, period: mediumPeriod)[lastIndex] else { return nil }
        let long = ema(closes, period: longPeriod)[lastIndex]
        let timeframe = higherTimeframeTitle ?? ""
        let close = closes[lastIndex]
        let agrees = direction == .bullish ? close > medium : close < medium
        let fullyStacked = direction == .bullish
            ? long.map { medium > $0 && close > medium } ?? false
            : long.map { medium < $0 && close < medium } ?? false

        if agrees, fullyStacked {
            return ConfidenceFactor(
                key: "confluence",
                title: L10n.text("Higher timeframe fully aligned", "Üst dilim tam uyumlu"),
                detail: direction == .bullish
                    ? L10n.text("On the \(timeframe) chart, price rides above EMA 25 and EMA 25 above EMA 99 — the move trades with the larger trend.", "\(timeframe) grafiğinde fiyat EMA 25'in, EMA 25 de EMA 99'un üzerinde — hareket büyük trendle aynı yönde.")
                    : L10n.text("On the \(timeframe) chart, price sits below EMA 25 and EMA 25 below EMA 99 — the move trades with the larger trend.", "\(timeframe) grafiğinde fiyat EMA 25'in, EMA 25 de EMA 99'un altında — hareket büyük trendle aynı yönde."),
                score: confluenceMax, maxScore: confluenceMax
            )
        }
        if agrees {
            return ConfidenceFactor(
                key: "confluence",
                title: L10n.text("Higher timeframe supportive", "Üst dilim destekliyor"),
                detail: direction == .bullish
                    ? L10n.text("On the \(timeframe) chart, price is above EMA 25; the larger trend leans upward.", "\(timeframe) grafiğinde fiyat EMA 25'in üzerinde; büyük trend yukarı eğilimli.")
                    : L10n.text("On the \(timeframe) chart, price is below EMA 25; the larger trend leans downward.", "\(timeframe) grafiğinde fiyat EMA 25'in altında; büyük trend aşağı eğilimli."),
                score: 7, maxScore: confluenceMax
            )
        }
        return ConfidenceFactor(
            key: "confluence",
            title: L10n.text("Higher timeframe opposed", "Üst dilim ters yönde"),
            detail: direction == .bullish
                ? L10n.text("On the \(timeframe) chart, price is below EMA 25 — the breakout is moving against the larger trend.", "\(timeframe) grafiğinde fiyat EMA 25'in altında — kırılım büyük trende karşı ilerliyor.")
                : L10n.text("On the \(timeframe) chart, price is above EMA 25 — the breakdown is moving against the larger trend.", "\(timeframe) grafiğinde fiyat EMA 25'in üzerinde — düşüş büyük trende karşı ilerliyor."),
            score: 1, maxScore: confluenceMax
        )
    }
}
