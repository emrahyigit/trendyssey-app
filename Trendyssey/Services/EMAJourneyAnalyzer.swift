import Foundation

/// Detects breakout journeys from EMA 7/25 crossovers (EMA 99 as the long-term filter),
/// matching the moving averages Binance shows by default, and derives a single
/// 0–100 confidence score with human-readable reasons.
enum EMAJourneyAnalyzer: JourneyDetector {
    nonisolated static let model = JourneyModel.emaCross
    nonisolated static let fastPeriod = 7
    nonisolated static let mediumPeriod = 25
    nonisolated static let longPeriod = 99

    nonisolated static func analyze(
        candles allCandles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]? = nil,
        higherTimeframeTitle: String? = nil
    ) -> JourneyAnalysis? {
        let candles = allCandles.filter(\.isClosed)
        guard candles.count >= mediumPeriod + 5 else { return nil }
        let closes = candles.map(\.close)
        let emaFast = ema(closes, period: fastPeriod)
        let emaMedium = ema(closes, period: mediumPeriod)
        let emaLong = ema(closes, period: longPeriod)

        let (events, phase, lastCrossIndex, retestState) = journey(
            candles: candles, emaFast: emaFast, emaMedium: emaMedium
        )
        let volumeRatio = JourneyAnalyzer.latestVolumeRatio(candles: candles)
        var factors = confidenceFactors(
            candles: candles,
            emaFast: emaFast,
            emaMedium: emaMedium,
            emaLong: emaLong,
            phase: phase,
            lastCrossIndex: lastCrossIndex,
            retestState: retestState,
            volumeRatio: volumeRatio
        )
        if let confluence = confluenceFactor(
            direction: .bullish,
            higherTimeframeCandles: higherTimeframeCandles,
            higherTimeframeTitle: higherTimeframeTitle
        ) {
            factors.append(confluence)
        }
        return JourneyAnalysis(
            model: model,
            candles: candles,
            series: [
                JourneySeries(key: "ema7", title: "EMA 7", values: emaFast),
                JourneySeries(key: "ema25", title: "EMA 25", values: emaMedium),
                JourneySeries(key: "ema99", title: "EMA 99", values: emaLong),
            ],
            levels: [],
            markers: [],
            events: events,
            currentPhase: phase,
            confidence: JourneyAnalyzer.confidence(from: factors),
            factors: factors,
            volumeRatio: volumeRatio
        )
    }

    // MARK: - EMA

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

    // MARK: - Journey state machine

    private nonisolated enum RetestState { case none, testing, held }

    private nonisolated static func journey(
        candles: [PriceCandle],
        emaFast: [Double?],
        emaMedium: [Double?]
    ) -> ([JourneyEvent], SignalStatus, Int?, Bool) {
        var state: SignalStatus = .watching
        var events: [JourneyEvent] = []
        var crossIndex: Int?
        var lastCrossIndex: Int?
        var retest: RetestState = .none

        for i in candles.indices {
            guard i > 0,
                  let fast = emaFast[i], let medium = emaMedium[i],
                  let prevFast = emaFast[i - 1], let prevMedium = emaMedium[i - 1] else { continue }
            let candle = candles[i]
            let crossedUp = prevFast <= prevMedium && fast > medium
            let crossedDown = prevFast >= prevMedium && fast < medium
            // Closes less than 0.2% below the EMA 25 are treated as noise, not a support break.
            let supportBreakBand = 1 - 0.002
            let closedBelowSupport = candle.close < medium * supportBreakBand
            let previousClosedBelowSupport = emaMedium[i - 1].map { candles[i - 1].close < $0 * supportBreakBand } ?? false
            var newState = state

            switch state {
            case .watching, .preBreakout, .failed, .expired:
                if crossedUp {
                    newState = .breakoutDetected
                    crossIndex = i
                    lastCrossIndex = i
                    retest = .none
                } else if fast > medium, candle.close > fast {
                    // The uptrend survived a soft failure (no cross-down happened);
                    // a strong close above both EMAs restarts the journey.
                    newState = .breakoutDetected
                    crossIndex = i
                    lastCrossIndex = lastCrossIndex ?? i
                    retest = .none
                } else if fast < medium {
                    // The fast EMA is approaching the medium EMA from below: a cross may be near.
                    // Enter below 0.4% with a narrowing gap; leave only above 0.8% (hysteresis).
                    let gap = (medium - fast) / max(candle.close, .leastNonzeroMagnitude)
                    let previousGap = (prevMedium - prevFast) / max(candles[i - 1].close, .leastNonzeroMagnitude)
                    if state == .preBreakout {
                        newState = gap > 0.008 ? .watching : .preBreakout
                    } else {
                        newState = (gap < 0.004 && gap < previousGap) ? .preBreakout : .watching
                    }
                } else if state == .failed || state == .expired {
                    newState = .watching
                }
            case .breakoutDetected, .retest, .confirmed:
                if crossedDown {
                    newState = .failed
                    crossIndex = nil
                    retest = .none
                } else if closedBelowSupport {
                    if previousClosedBelowSupport {
                        // Two consecutive closes below the EMA 25 support invalidate the move.
                        newState = .failed
                        crossIndex = nil
                        retest = .none
                    } else if state != .retest {
                        newState = .retest
                        retest = .testing
                    }
                } else if state == .breakoutDetected, candle.low <= medium * 1.002 {
                    newState = .retest
                    retest = .testing
                } else if state == .retest, candle.close > fast {
                    retest = .held
                    newState = .confirmed
                } else if state == .breakoutDetected, let cross = crossIndex, i - cross >= 3 {
                    let heldAboveSupport = ((i - 2)...i).allSatisfy { j in
                        guard let support = emaMedium[j] else { return false }
                        return candles[j].close > support
                    }
                    if heldAboveSupport { newState = .confirmed }
                }
            }

            if newState != state {
                state = newState
                events.append(JourneyEvent(status: state, time: candle.closeTime, price: candle.close))
            }
        }
        return (events, state, lastCrossIndex, retest == .held)
    }

    // MARK: - Confidence

    private nonisolated static func confidenceFactors(
        candles: [PriceCandle],
        emaFast: [Double?],
        emaMedium: [Double?],
        emaLong: [Double?],
        phase: SignalStatus,
        lastCrossIndex: Int?,
        retestState retestHeld: Bool,
        volumeRatio: Double
    ) -> [ConfidenceFactor] {
        let lastIndex = candles.count - 1
        let close = candles[lastIndex].close
        let fast = emaFast[lastIndex]
        let medium = emaMedium[lastIndex]
        let long = emaLong[lastIndex]
        var factors: [ConfidenceFactor] = []

        // 1. EMA alignment (max 20)
        let alignmentMax = 20
        let alignment: ConfidenceFactor
        if let fast, let medium, let long, fast > medium, medium > long {
            alignment = ConfidenceFactor(
                key: "alignment",
                title: L10n.text("Trend alignment strong", "Trend dizilimi güçlü"),
                detail: L10n.text("EMA 7 > EMA 25 > EMA 99 — all three averages are stacked upward.", "EMA 7 > EMA 25 > EMA 99 — üç ortalama da yükseliş yönünde sıralı."),
                score: alignmentMax, maxScore: alignmentMax
            )
        } else if let fast, let medium, fast > medium {
            alignment = ConfidenceFactor(
                key: "alignment",
                title: L10n.text("Short-term trend up", "Kısa vadeli trend yukarı"),
                detail: L10n.text("EMA 7 is above EMA 25, but the long-term EMA 99 is not aligned yet.", "EMA 7, EMA 25'in üzerinde; ancak uzun vadeli EMA 99 henüz dizilime katılmadı."),
                score: 11, maxScore: alignmentMax
            )
        } else {
            alignment = ConfidenceFactor(
                key: "alignment",
                title: L10n.text("Trend alignment weak", "Trend dizilimi zayıf"),
                detail: L10n.text("EMA 7 is below EMA 25, so the averages do not support an upward move.", "EMA 7, EMA 25'in altında; ortalamalar yükselişi desteklemiyor."),
                score: 2, maxScore: alignmentMax
            )
        }
        factors.append(alignment)

        // 2. Crossover freshness (max 15)
        let crossMax = 15
        if let crossIndex = lastCrossIndex, phase != .failed, phase != .watching, phase != .preBreakout {
            let age = lastIndex - crossIndex
            let (score, title, detail): (Int, String, String) = switch age {
            case 0...2: (crossMax,
                         L10n.text("Fresh EMA crossover", "Taze EMA kesişimi"),
                         L10n.text("EMA 7 crossed above EMA 25 just \(age) candle(s) ago.", "EMA 7, EMA 25'i yalnızca \(age) mum önce yukarı kesti."))
            case 3...6: (12,
                         L10n.text("Recent EMA crossover", "Yakın tarihli EMA kesişimi"),
                         L10n.text("The EMA 7/25 crossover happened \(age) candles ago and is still recent.", "EMA 7/25 kesişimi \(age) mum önce gerçekleşti; hâlâ güncel."))
            case 7...15: (8,
                          L10n.text("Crossover ageing", "Kesişim eskiyor"),
                          L10n.text("The crossover is \(age) candles old; part of the move may already be behind.", "Kesişim \(age) mum önceydi; hareketin bir bölümü geride kalmış olabilir."))
            default: (4,
                      L10n.text("Old crossover", "Eski kesişim"),
                      L10n.text("The last crossover is \(age) candles old.", "Son kesişim \(age) mum önce gerçekleşti."))
            }
            factors.append(ConfidenceFactor(key: "cross", title: title, detail: detail, score: score, maxScore: crossMax))
        } else {
            factors.append(ConfidenceFactor(
                key: "cross",
                title: L10n.text("No active crossover", "Aktif kesişim yok"),
                detail: L10n.text("EMA 7 has not crossed above EMA 25 yet, so no breakout journey is running.", "EMA 7 henüz EMA 25'i yukarı kesmedi; aktif bir kırılım süreci yok."),
                score: 0, maxScore: crossMax
            ))
        }

        // 3. Retest confirmation (max 15)
        let retestMax = 15
        let retestFactor: ConfidenceFactor
        if retestHeld {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("Retest held", "Retest başarılı"),
                detail: L10n.text("Price pulled back to the EMA 25 zone and held above it — support is verified.", "Fiyat EMA 25 bölgesine geri çekilip üzerinde tutundu — destek doğrulandı."),
                score: retestMax, maxScore: retestMax
            )
        } else if phase == .retest {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("Retest in progress", "Retest sürüyor"),
                detail: L10n.text("Price is currently testing the EMA 25 support; the result is not final yet.", "Fiyat şu anda EMA 25 desteğini test ediyor; sonuç henüz netleşmedi."),
                score: 8, maxScore: retestMax
            )
        } else if phase == .breakoutDetected || phase == .confirmed {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("No retest yet", "Henüz retest yok"),
                detail: L10n.text("The breakout has not been retested; support is unproven.", "Kırılım sonrası seviye henüz test edilmedi; destek kanıtlanmadı."),
                score: 4, maxScore: retestMax
            )
        } else {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("No retest", "Retest yok"),
                detail: L10n.text("A retest can only happen after a crossover starts a journey.", "Retest ancak bir kesişim süreci başladıktan sonra oluşabilir."),
                score: 0, maxScore: retestMax
            )
        }
        factors.append(retestFactor)

        // 4. Volume support (max 20)
        factors.append(JourneyAnalyzer.volumeFactor(ratio: volumeRatio))

        // 5. Long-term trend vs EMA 99 (max 10)
        let longMax = 10
        if let long {
            let previousLong = emaLong.dropLast().last ?? nil
            let longRising = previousLong.map { long >= $0 } ?? false
            if close > long && longRising {
                factors.append(ConfidenceFactor(
                    key: "longTerm",
                    title: L10n.text("Long-term trend supportive", "Uzun vadeli trend destekliyor"),
                    detail: L10n.text("Price is above a rising EMA 99, so the move goes with the broader trend.", "Fiyat, yükselen EMA 99'un üzerinde; hareket ana trendle aynı yönde."),
                    score: longMax, maxScore: longMax
                ))
            } else if close > long {
                factors.append(ConfidenceFactor(
                    key: "longTerm",
                    title: L10n.text("Price above EMA 99", "Fiyat EMA 99 üzerinde"),
                    detail: L10n.text("Price is above EMA 99, but the long average is still flat or falling.", "Fiyat EMA 99'un üzerinde; ancak uzun ortalama hâlâ yatay veya düşüşte."),
                    score: 7, maxScore: longMax
                ))
            } else {
                factors.append(ConfidenceFactor(
                    key: "longTerm",
                    title: L10n.text("Below the long-term trend", "Uzun vadeli trendin altında"),
                    detail: L10n.text("Price is below EMA 99; the breakout is fighting the broader trend.", "Fiyat EMA 99'un altında; kırılım ana trende karşı ilerliyor."),
                    score: 1, maxScore: longMax
                ))
            }
        } else {
            factors.append(ConfidenceFactor(
                key: "longTerm",
                title: L10n.text("EMA 99 not available", "EMA 99 hesaplanamadı"),
                detail: L10n.text("Not enough candle history to compute the 99-period average.", "99 periyotluk ortalama için yeterli mum geçmişi yok."),
                score: 0, maxScore: longMax
            ))
        }

        // 6. Momentum (max 10)
        let momentumMax = 10
        var streak = 0
        if fast != nil {
            for i in stride(from: lastIndex, through: 0, by: -1) {
                guard let f = emaFast[i], candles[i].close > f else { break }
                streak += 1
            }
        }
        let (momentumScore, momentumTitle): (Int, String) = switch streak {
        case 3...: (momentumMax, L10n.text("Momentum strong", "Momentum güçlü"))
        case 2: (7, L10n.text("Momentum building", "Momentum oluşuyor"))
        case 1: (4, L10n.text("Momentum weak", "Momentum zayıf"))
        default: (0, L10n.text("No momentum", "Momentum yok"))
        }
        factors.append(ConfidenceFactor(
            key: "momentum",
            title: momentumTitle,
            detail: streak > 0
                ? L10n.text("The last \(streak) candle(s) closed above EMA 7.", "Son \(streak) mum EMA 7'nin üzerinde kapandı.")
                : L10n.text("The last candle closed below EMA 7.", "Son mum EMA 7'nin altında kapandı."),
            score: momentumScore, maxScore: momentumMax
        ))

        return factors
    }

    // MARK: - Higher-timeframe confluence (max 10)

    /// Scores how well the next timeframe up agrees with the move, so setups that
    /// trade with the larger trend rank above counter-trend ones. Shared by every
    /// model; a bearish journey wants the higher timeframe stacked downward.
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
        guard let fast = ema(closes, period: fastPeriod)[lastIndex],
              let medium = ema(closes, period: mediumPeriod)[lastIndex] else { return nil }
        let long = ema(closes, period: longPeriod)[lastIndex]
        let timeframe = higherTimeframeTitle ?? ""
        let close = closes[lastIndex]
        let agrees = direction == .bullish ? fast > medium : fast < medium
        let fullyStacked = direction == .bullish
            ? long.map { medium > $0 && close > fast } ?? false
            : long.map { medium < $0 && close < fast } ?? false

        if agrees, fullyStacked {
            return ConfidenceFactor(
                key: "confluence",
                title: L10n.text("Higher timeframe fully aligned", "Üst dilim tam uyumlu"),
                detail: direction == .bullish
                    ? L10n.text("On the \(timeframe) chart, price and all three EMAs are stacked upward — the move trades with the larger trend.", "\(timeframe) grafiğinde fiyat ve üç EMA da yükseliş yönünde sıralı — hareket büyük trendle aynı yönde.")
                    : L10n.text("On the \(timeframe) chart, price and all three EMAs are stacked downward — the move trades with the larger trend.", "\(timeframe) grafiğinde fiyat ve üç EMA da düşüş yönünde sıralı — hareket büyük trendle aynı yönde."),
                score: confluenceMax, maxScore: confluenceMax
            )
        }
        if agrees {
            return ConfidenceFactor(
                key: "confluence",
                title: L10n.text("Higher timeframe supportive", "Üst dilim destekliyor"),
                detail: direction == .bullish
                    ? L10n.text("On the \(timeframe) chart, EMA 7 is above EMA 25; the larger trend leans upward.", "\(timeframe) grafiğinde EMA 7, EMA 25'in üzerinde; büyük trend yukarı eğilimli.")
                    : L10n.text("On the \(timeframe) chart, EMA 7 is below EMA 25; the larger trend leans downward.", "\(timeframe) grafiğinde EMA 7, EMA 25'in altında; büyük trend aşağı eğilimli."),
                score: 7, maxScore: confluenceMax
            )
        }
        return ConfidenceFactor(
            key: "confluence",
            title: L10n.text("Higher timeframe opposed", "Üst dilim ters yönde"),
            detail: direction == .bullish
                ? L10n.text("On the \(timeframe) chart, EMA 7 is below EMA 25 — the breakout is moving against the larger trend.", "\(timeframe) grafiğinde EMA 7, EMA 25'in altında — kırılım büyük trende karşı ilerliyor.")
                : L10n.text("On the \(timeframe) chart, EMA 7 is above EMA 25 — the breakdown is moving against the larger trend.", "\(timeframe) grafiğinde EMA 7, EMA 25'in üzerinde — düşüş büyük trende karşı ilerliyor."),
            score: 1, maxScore: confluenceMax
        )
    }
}
