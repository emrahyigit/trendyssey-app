import Foundation

/// Detects Double Bottom and Double Top reversals and maps them onto the same
/// Breakout Journey lifecycle the EMA model uses:
///
/// - `watching`      the two pivots formed, price is still far from the neckline
/// - `preBreakout`   price closed inside the approach band under/over the neckline
/// - `breakoutDetected` a close cleared the neckline
/// - `retest`        price came back to the neckline after clearing it
/// - `confirmed`     the retest held, or three closes stayed beyond the neckline
/// - `failed`        price closed back through the neckline twice, or lost the pattern
///
/// A Double Top runs the mirror image of a Double Bottom, so both share this
/// implementation and only differ by `JourneyDirection`.
enum DoublePatternAnalyzer {
    /// Candles required on each side of a pivot before it counts as one.
    nonisolated static let pivotWindow = 3
    /// Candle distance allowed between the two pivots.
    nonisolated static let minSeparation = 5
    nonisolated static let maxSeparation = 60
    /// Price difference allowed between the two pivots.
    nonisolated static let levelTolerance = 0.02
    /// Minimum neckline distance from the pivots; flatter shapes are noise.
    nonisolated static let minDepth = 0.015
    /// Clearance a close needs beyond the neckline to count as a break.
    nonisolated static let breakoutBuffer = 0.001
    /// Distance from the neckline that counts as approaching it.
    nonisolated static let approachBand = 0.015
    /// Move back through a level that counts as a real violation, not noise.
    nonisolated static let invalidationBand = 0.005
    /// Candles searched before the first pivot for the trend being reversed.
    nonisolated static let contextWindow = 60

    struct Pattern: Sendable {
        let firstIndex: Int
        let secondIndex: Int
        let necklineIndex: Int
        let firstPrice: Double
        let secondPrice: Double
        let neckline: Double
        /// Price difference between the two pivots, as a fraction.
        let difference: Double
        /// Neckline distance from the pivot average, as a fraction.
        let depth: Double

        /// The level that has to hold for the pattern to stay valid: the lower of
        /// the two bottoms, or the higher of the two tops.
        nonisolated func base(_ direction: JourneyDirection) -> Double {
            direction == .bullish ? min(firstPrice, secondPrice) : max(firstPrice, secondPrice)
        }
    }

    nonisolated static func analyze(
        direction: JourneyDirection,
        candles allCandles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]?,
        higherTimeframeTitle: String?
    ) -> JourneyAnalysis? {
        let candles = allCandles.filter(\.isClosed)
        guard candles.count >= minSeparation + pivotWindow * 2 + 5 else { return nil }
        let volumeRatio = JourneyAnalyzer.latestVolumeRatio(candles: candles)
        let model: JourneyModel = direction == .bullish ? .doubleBottom : .doubleTop
        let emaLong = EMAJourneyAnalyzer.ema(candles.map(\.close), period: EMAJourneyAnalyzer.longPeriod)
        let trendSeries = [JourneySeries(key: "ema99", title: "EMA 99", values: emaLong)]
        let confluence = EMAJourneyAnalyzer.confluenceFactor(
            direction: direction,
            higherTimeframeCandles: higherTimeframeCandles,
            higherTimeframeTitle: higherTimeframeTitle
        )
        let marketAlignment = confluence.map { factor in
            factor.maxScore > 0 ? Double(factor.score) / Double(factor.maxScore) : 0.5
        } ?? 0.5

        let history = patterns(candles: candles, direction: direction)
        guard let pattern = history.last else {
            // No shape on the chart yet: the model is idle rather than wrong, so it
            // reports a watching journey with the one ingredient it can still score.
            let factors = [
                ConfidenceFactor(
                    key: "pattern",
                    title: direction == .bullish
                        ? L10n.text("No double bottom", "Çift dip yok")
                        : L10n.text("No double top", "Çift tepe yok"),
                    detail: direction == .bullish
                        ? L10n.text("No two lows close enough in price and time to form a double bottom.", "Fiyat ve zaman olarak çift dip oluşturacak kadar yakın iki dip bulunamadı.")
                        : L10n.text("No two highs close enough in price and time to form a double top.", "Fiyat ve zaman olarak çift tepe oluşturacak kadar yakın iki tepe bulunamadı."),
                    score: 0, maxScore: 100
                )
            ]
            return JourneyAnalysis(
                model: model,
                candles: candles,
                series: trendSeries,
                levels: [],
                markers: [],
                events: [],
                currentPhase: .watching,
                confidence: 0,
                factors: factors,
                volumeRatio: volumeRatio,
                scoreLayers: SignalScoreLayers(
                    regimeScore: Int((marketAlignment * 100).rounded()),
                    readinessScore: 0,
                    breakoutQualityScore: 0,
                    confirmationScore: 0,
                    breakoutTriggered: false,
                    scoringVersion: "breakout-scores-v2-pattern"
                )
            )
        }

        // Earlier patterns contribute their journeys as history; only the newest
        // one decides the phase the symbol is in right now.
        let walks = journeys(candles: candles, patterns: history, direction: direction)
        let events = walks.flatMap(\.events)
        let current = walks[walks.count - 1]
        let phase = current.phase
        let breakoutIndex = current.breakoutIndex
        let retestHeld = current.retestHeld
        var factors = confidenceFactors(
            candles: candles,
            pattern: pattern,
            direction: direction,
            phase: phase,
            breakoutIndex: breakoutIndex,
            retestHeld: retestHeld,
            volumeRatio: volumeRatio
        )
        if let confluence {
            factors.append(confluence)
        }
        let scoreLayers = patternScoreLayers(
            candles: candles,
            pattern: pattern,
            direction: direction,
            phase: phase,
            walk: current,
            factors: factors,
            marketAlignment: marketAlignment
        )
        let stageScore: Int = switch phase {
        case .watching, .preBreakout: scoreLayers.readinessScore
        case .breakoutDetected, .failed, .expired: scoreLayers.breakoutQualityScore
        case .confirmed, .retest: scoreLayers.confirmationScore
        }

        return JourneyAnalysis(
            model: model,
            candles: candles,
            series: trendSeries,
            levels: [
                JourneyLevel(key: "neckline", title: L10n.text("Neckline", "Boyun çizgisi"), price: pattern.neckline),
                JourneyLevel(
                    key: "patternBase",
                    title: direction == .bullish ? L10n.text("Bottoms", "Dipler") : L10n.text("Tops", "Tepeler"),
                    price: pattern.base(direction)
                ),
            ],
            markers: [
                JourneyMarker(key: "first", title: direction == .bullish ? L10n.text("1st bottom", "1. dip") : L10n.text("1st top", "1. tepe"), time: candles[pattern.firstIndex].openTime, price: pattern.firstPrice),
                JourneyMarker(key: "neck", title: L10n.text("Neckline", "Boyun çizgisi"), time: candles[pattern.necklineIndex].openTime, price: pattern.neckline),
                JourneyMarker(key: "second", title: direction == .bullish ? L10n.text("2nd bottom", "2. dip") : L10n.text("2nd top", "2. tepe"), time: candles[pattern.secondIndex].openTime, price: pattern.secondPrice),
            ],
            events: events,
            currentPhase: phase,
            confidence: stageScore,
            factors: factors,
            volumeRatio: volumeRatio,
            scoreLayers: scoreLayers
        )
    }

    /// Mirrors the server's v2 pattern layers. Pattern structure and proximity
    /// form readiness; the actual neckline-clearing candle forms quality; only
    /// candles after that trigger are allowed to form confirmation.
    private nonisolated static func patternScoreLayers(
        candles: [PriceCandle],
        pattern: Pattern,
        direction: JourneyDirection,
        phase: SignalStatus,
        walk: JourneyWalk,
        factors: [ConfidenceFactor],
        marketAlignment: Double
    ) -> SignalScoreLayers {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        func normalized(_ key: String) -> Double {
            guard let factor = factors.first(where: { $0.key == key }), factor.maxScore > 0 else { return 0 }
            return clamp(Double(factor.score) / Double(factor.maxScore))
        }

        let symmetry = normalized("symmetry")
        let depth = normalized("depth")
        let context = normalized("context")
        let currentVolume = normalized("volume")
        let alignment = clamp(marketAlignment)
        let current = candles[candles.count - 1]
        let signedDistance = direction == .bullish
            ? (pattern.neckline - current.close) / pattern.neckline
            : (current.close - pattern.neckline) / pattern.neckline
        let proximity = clamp(1 - max(0, signedDistance) / approachBand)
        let regimeScore = Int((100 * (0.55 * context + 0.45 * alignment)).rounded())
        let readinessScore = Int((100 * (
            0.30 * symmetry + 0.25 * depth + 0.20 * context +
            0.15 * proximity + 0.10 * currentVolume
        )).rounded())

        let historicalBreakoutIndex = walk.events
            .first(where: { $0.status == .breakoutDetected })
            .flatMap { event in candles.firstIndex(where: { $0.closeTime == event.time }) }
        guard let breakoutIndex = walk.breakoutIndex ?? historicalBreakoutIndex,
              phase != .watching, phase != .preBreakout else {
            return SignalScoreLayers(
                regimeScore: regimeScore,
                readinessScore: readinessScore,
                breakoutQualityScore: 0,
                confirmationScore: 0,
                breakoutTriggered: false,
                scoringVersion: "breakout-scores-v2-pattern"
            )
        }

        let breakoutCandle = candles[breakoutIndex]
        let breakoutRange = max(breakoutCandle.high - breakoutCandle.low, .leastNonzeroMagnitude)
        let directionalBody = clamp(
            (direction == .bullish
                ? breakoutCandle.close - breakoutCandle.open
                : breakoutCandle.open - breakoutCandle.close) / breakoutRange
        )
        let clearance = direction == .bullish
            ? (breakoutCandle.close - pattern.neckline) / pattern.neckline
            : (pattern.neckline - breakoutCandle.close) / pattern.neckline
        let clearanceQuality = clamp(clearance / max(pattern.depth * 0.25, breakoutBuffer))
        let breakoutVolumeRatio = JourneyAnalyzer.latestVolumeRatio(
            candles: Array(candles.prefix(breakoutIndex + 1))
        )
        let breakoutVolume = clamp((breakoutVolumeRatio - 0.70) / 1.30)
        let qualityScore = Int((100 * (
            0.20 * symmetry + 0.15 * depth + 0.25 * breakoutVolume +
            0.20 * directionalBody + 0.10 * clearanceQuality + 0.10 * alignment
        )).rounded())

        guard phase != .failed else {
            return SignalScoreLayers(
                regimeScore: regimeScore,
                readinessScore: readinessScore,
                breakoutQualityScore: qualityScore,
                confirmationScore: 0,
                breakoutTriggered: false,
                scoringVersion: "breakout-scores-v2-pattern"
            )
        }

        let recent = candles[max(breakoutIndex, candles.count - 3)...]
        let heldCloses = Double(recent.filter { candle in
            direction == .bullish ? candle.close > pattern.neckline : candle.close < pattern.neckline
        }.count) / Double(max(recent.count, 1))
        let levelHeld = direction == .bullish
            ? current.close > pattern.neckline
            : current.close < pattern.neckline
        let retestEvidence = walk.retestHeld ? 1.0 : phase == .retest ? 0.5 : 0
        let phaseProgress = phase == .confirmed ? 1.0 : phase == .retest ? 0.5 : 0.25
        let continuation = clamp(
            (direction == .bullish
                ? current.close - breakoutCandle.close
                : breakoutCandle.close - current.close) /
                (max(breakoutCandle.close, .leastNonzeroMagnitude) * max(pattern.depth, minDepth))
        )
        let confirmationScore = Int((100 * (
            0.25 * (levelHeld ? 1 : 0) + 0.25 * heldCloses +
            0.25 * retestEvidence + 0.15 * phaseProgress + 0.10 * continuation
        )).rounded())
        let breakoutTriggered = phase == .breakoutDetected || phase == .retest || phase == .confirmed

        return SignalScoreLayers(
            regimeScore: regimeScore,
            readinessScore: readinessScore,
            breakoutQualityScore: qualityScore,
            confirmationScore: confirmationScore,
            breakoutTriggered: breakoutTriggered,
            scoringVersion: "breakout-scores-v2-pattern"
        )
    }

    // MARK: - Pattern detection

    /// Indices whose low (bullish) or high (bearish) is the extreme of the
    /// surrounding `pivotWindow` candles on both sides.
    nonisolated static func pivotIndices(candles: [PriceCandle], direction: JourneyDirection) -> [Int] {
        guard candles.count > pivotWindow * 2 else { return [] }
        var indices: [Int] = []
        for index in pivotWindow..<(candles.count - pivotWindow) {
            let neighbours = (index - pivotWindow)...(index + pivotWindow)
            let isPivot = neighbours.allSatisfy { other in
                guard other != index else { return true }
                return direction == .bullish
                    ? candles[other].low >= candles[index].low
                    : candles[other].high <= candles[index].high
            }
            if isPivot { indices.append(index) }
        }
        return indices
    }

    /// The most recent pattern, i.e. the one the symbol is trading inside now.
    nonisolated static func detect(candles: [PriceCandle], direction: JourneyDirection) -> Pattern? {
        patterns(candles: candles, direction: direction).last
    }

    /// Every pattern in the candle history, oldest first and non-overlapping.
    /// Overlap is resolved from the newest shape backwards so the pattern closest
    /// to the present always survives; an older candidate only joins when it
    /// finished before the accepted newer one started. Candidates sharing a
    /// second pivot collapse to the most symmetric one.
    nonisolated static func patterns(candles: [PriceCandle], direction: JourneyDirection) -> [Pattern] {
        let candidates = candidatePatterns(candles: candles, direction: direction)
            .sorted {
                if $0.secondIndex != $1.secondIndex { return $0.secondIndex > $1.secondIndex }
                return $0.difference < $1.difference
            }
        var accepted: [Pattern] = []
        for candidate in candidates {
            guard let previous = accepted.last else {
                accepted.append(candidate)
                continue
            }
            if candidate.secondIndex <= previous.firstIndex { accepted.append(candidate) }
        }
        return accepted.reversed()
    }

    private nonisolated static func candidatePatterns(candles: [PriceCandle], direction: JourneyDirection) -> [Pattern] {
        let pivots = pivotIndices(candles: candles, direction: direction)
        guard pivots.count >= 2 else { return [] }
        var found: [Pattern] = []

        for (offset, first) in pivots.enumerated() {
            for second in pivots[(offset + 1)...] {
                let separation = second - first
                guard separation >= minSeparation, separation <= maxSeparation else { continue }
                let firstPrice = direction == .bullish ? candles[first].low : candles[first].high
                let secondPrice = direction == .bullish ? candles[second].low : candles[second].high
                guard firstPrice > 0 else { continue }
                let difference = abs(secondPrice - firstPrice) / firstPrice
                guard difference <= levelTolerance else { continue }

                let between = Array((first + 1)..<second)
                guard !between.isEmpty else { continue }
                let necklineIndex = direction == .bullish
                    ? between.max(by: { candles[$0].high < candles[$1].high })!
                    : between.min(by: { candles[$0].low < candles[$1].low })!
                let neckline = direction == .bullish ? candles[necklineIndex].high : candles[necklineIndex].low

                // The pivots must be the extremes of the shape: nothing between them
                // may run past the level they define.
                let extremeBetween = direction == .bullish
                    ? between.map { candles[$0].low }.min() ?? .infinity
                    : between.map { candles[$0].high }.max() ?? -.infinity
                let holdsShape = direction == .bullish
                    ? extremeBetween >= min(firstPrice, secondPrice) * (1 - invalidationBand)
                    : extremeBetween <= max(firstPrice, secondPrice) * (1 + invalidationBand)
                guard holdsShape else { continue }

                let average = (firstPrice + secondPrice) / 2
                guard average > 0 else { continue }
                let depth = direction == .bullish
                    ? (neckline - average) / average
                    : (average - neckline) / average
                guard depth >= minDepth else { continue }

                found.append(
                    Pattern(
                        firstIndex: first,
                        secondIndex: second,
                        necklineIndex: necklineIndex,
                        firstPrice: firstPrice,
                        secondPrice: secondPrice,
                        neckline: neckline,
                        difference: difference,
                        depth: depth
                    )
                )
            }
        }
        return found
    }

    // MARK: - Journey state machine

    struct JourneyWalk: Sendable {
        let events: [JourneyEvent]
        let phase: SignalStatus
        let breakoutIndex: Int?
        let retestHeld: Bool
    }

    /// One walk per pattern. Each walk stops where the next pattern's walk begins,
    /// so an older shape cannot keep reporting transitions after a newer one formed.
    nonisolated static func journeys(
        candles: [PriceCandle],
        patterns: [Pattern],
        direction: JourneyDirection
    ) -> [JourneyWalk] {
        patterns.enumerated().map { index, pattern in
            let nextStart = index + 1 < patterns.count
                ? patterns[index + 1].secondIndex + pivotWindow
                : candles.count
            return journey(
                candles: candles,
                pattern: pattern,
                direction: direction,
                endIndex: min(nextStart, candles.count)
            )
        }
    }

    /// Walks the candles after the second pivot is confirmed and returns the
    /// lifecycle transitions, the phase it ended on, the breakout candle and
    /// whether a retest held.
    private nonisolated static func journey(
        candles: [PriceCandle],
        pattern: Pattern,
        direction: JourneyDirection,
        endIndex: Int
    ) -> JourneyWalk {
        var state: SignalStatus = .watching
        var events: [JourneyEvent] = []
        var breakoutIndex: Int?
        var retestHeld = false
        var closesBackThrough = 0
        // A neckline break usually starts right at the neckline, so the candle
        // after it almost always wicks back to that level. Only once price has
        // closed clear of the neckline does a return to it count as a retest.
        var clearedByMargin = false

        let neckline = pattern.neckline
        let base = pattern.base(direction)
        // The second pivot is only a pivot once `pivotWindow` candles closed after it.
        let start = pattern.secondIndex + pivotWindow
        guard start < endIndex else {
            return JourneyWalk(events: [], phase: .watching, breakoutIndex: nil, retestHeld: false)
        }

        for index in start..<endIndex {
            let candle = candles[index]
            let clearedNeckline = direction == .bullish
                ? candle.close > neckline * (1 + breakoutBuffer)
                : candle.close < neckline * (1 - breakoutBuffer)
            let closedBackThrough = direction == .bullish
                ? candle.close < neckline * (1 - invalidationBand)
                : candle.close > neckline * (1 + invalidationBand)
            let touchedNeckline = direction == .bullish
                ? candle.low <= neckline * 1.002
                : candle.high >= neckline * 0.998
            let lostPattern = direction == .bullish
                ? candle.close < base * (1 - invalidationBand)
                : candle.close > base * (1 + invalidationBand)
            var newState = state

            switch state {
            case .watching, .preBreakout:
                if clearedNeckline {
                    newState = .breakoutDetected
                    breakoutIndex = index
                } else if lostPattern {
                    // Price left the shape before it could resolve: this pattern is done.
                    newState = .failed
                } else {
                    let distance = direction == .bullish
                        ? (neckline - candle.close) / neckline
                        : (candle.close - neckline) / neckline
                    newState = (distance >= 0 && distance <= approachBand) ? .preBreakout : .watching
                }
            case .breakoutDetected, .retest, .confirmed:
                if closedBackThrough {
                    closesBackThrough += 1
                    if closesBackThrough >= 2 {
                        newState = .failed
                        breakoutIndex = nil
                    } else if state != .retest {
                        newState = .retest
                    }
                } else {
                    closesBackThrough = 0
                    if state == .retest, clearedNeckline {
                        retestHeld = true
                        newState = .confirmed
                    } else if state != .retest, clearedByMargin, touchedNeckline {
                        // A pullback to the neckline is a retest whether it arrives
                        // before or after the move was confirmed.
                        newState = .retest
                    } else if state == .breakoutDetected, let breakout = breakoutIndex, index - breakout >= 3 {
                        let held = ((index - 2)...index).allSatisfy { other in
                            direction == .bullish
                                ? candles[other].close > neckline
                                : candles[other].close < neckline
                        }
                        if held { newState = .confirmed }
                    }
                }
            case .failed, .expired:
                break
            }

            if newState != state {
                state = newState
                events.append(JourneyEvent(status: state, time: candle.closeTime, price: candle.close))
                // A broken pattern is not re-entered; the next analysis picks up
                // whichever shape forms next.
                if state == .failed { break }
            }

            let clearanceReached = direction == .bullish
                ? candle.close > neckline * (1 + invalidationBand)
                : candle.close < neckline * (1 - invalidationBand)
            if clearanceReached { clearedByMargin = true }
        }
        return JourneyWalk(events: events, phase: state, breakoutIndex: breakoutIndex, retestHeld: retestHeld)
    }

    // MARK: - Confidence

    private nonisolated static func confidenceFactors(
        candles: [PriceCandle],
        pattern: Pattern,
        direction: JourneyDirection,
        phase: SignalStatus,
        breakoutIndex: Int?,
        retestHeld: Bool,
        volumeRatio: Double
    ) -> [ConfidenceFactor] {
        let lastIndex = candles.count - 1
        let pivotName = direction == .bullish
            ? L10n.text("bottoms", "dipler")
            : L10n.text("tops", "tepeler")
        var factors: [ConfidenceFactor] = []

        // 1. Pivot symmetry (max 20)
        let symmetryMax = 20
        let differencePercent = (pattern.difference * 100).formatted(.number.precision(.fractionLength(2)))
        let (symmetryScore, symmetryTitle): (Int, String) = switch pattern.difference {
        case ..<0.005: (symmetryMax, L10n.text("Pattern almost symmetric", "Formasyon neredeyse simetrik"))
        case ..<0.010: (15, L10n.text("Pattern symmetric", "Formasyon simetrik"))
        case ..<0.015: (11, L10n.text("Pattern slightly uneven", "Formasyon biraz dengesiz"))
        default: (7, L10n.text("Pattern uneven", "Formasyon dengesiz"))
        }
        factors.append(ConfidenceFactor(
            key: "symmetry",
            title: symmetryTitle,
            detail: L10n.text(
                "The two \(pivotName) are \(differencePercent)% apart in price; the closer they sit, the cleaner the level.",
                "İki \(pivotName) arasında %\(differencePercent) fiyat farkı var; fark azaldıkça seviye netleşir."
            ),
            score: symmetryScore, maxScore: symmetryMax
        ))

        // 2. Pattern depth (max 15)
        let depthMax = 15
        let depthPercent = (pattern.depth * 100).formatted(.number.precision(.fractionLength(1)))
        let (depthScore, depthTitle): (Int, String) = switch pattern.depth {
        case 0.06...: (depthMax, L10n.text("Pattern deep", "Formasyon derin"))
        case 0.035..<0.06: (12, L10n.text("Pattern well formed", "Formasyon belirgin"))
        case 0.02..<0.035: (8, L10n.text("Pattern shallow", "Formasyon sığ"))
        default: (5, L10n.text("Pattern very shallow", "Formasyon çok sığ"))
        }
        factors.append(ConfidenceFactor(
            key: "depth",
            title: depthTitle,
            detail: L10n.text(
                "The neckline sits \(depthPercent)% away from the \(pivotName), which is the room the move has if it completes.",
                "Boyun çizgisi \(pivotName) seviyesinden %\(depthPercent) uzakta; tamamlanırsa hareketin alanı bu kadar."
            ),
            score: depthScore, maxScore: depthMax
        ))

        // 3. Breakout freshness (max 15)
        let breakoutMax = 15
        let breakoutFactor: ConfidenceFactor
        if let breakoutIndex, phase != .failed, phase != .watching, phase != .preBreakout {
            let age = lastIndex - breakoutIndex
            let (score, title, detail): (Int, String, String) = switch age {
            case 0...2: (breakoutMax,
                         L10n.text("Fresh neckline break", "Taze boyun çizgisi kırılımı"),
                         L10n.text("The neckline was cleared just \(age) candle(s) ago.", "Boyun çizgisi yalnızca \(age) mum önce kırıldı."))
            case 3...6: (12,
                         L10n.text("Recent neckline break", "Yakın tarihli kırılım"),
                         L10n.text("The neckline break happened \(age) candles ago and is still recent.", "Boyun çizgisi kırılımı \(age) mum önce gerçekleşti; hâlâ güncel."))
            case 7...15: (8,
                          L10n.text("Break ageing", "Kırılım eskiyor"),
                          L10n.text("The break is \(age) candles old; part of the move may already be behind.", "Kırılım \(age) mum önceydi; hareketin bir bölümü geride kalmış olabilir."))
            default: (4,
                      L10n.text("Old break", "Eski kırılım"),
                      L10n.text("The neckline break is \(age) candles old.", "Boyun çizgisi kırılımı \(age) mum önce gerçekleşti."))
            }
            breakoutFactor = ConfidenceFactor(key: "breakout", title: title, detail: detail, score: score, maxScore: breakoutMax)
        } else if phase == .preBreakout {
            breakoutFactor = ConfidenceFactor(
                key: "breakout",
                title: L10n.text("Neckline not cleared yet", "Boyun çizgisi henüz kırılmadı"),
                detail: direction == .bullish
                    ? L10n.text("Price is approaching the neckline but has not closed above it.", "Fiyat boyun çizgisine yaklaştı ancak üzerinde kapanış yapmadı.")
                    : L10n.text("Price is approaching the neckline but has not closed below it.", "Fiyat boyun çizgisine yaklaştı ancak altında kapanış yapmadı."),
                score: 5, maxScore: breakoutMax
            )
        } else {
            breakoutFactor = ConfidenceFactor(
                key: "breakout",
                title: L10n.text("No neckline break", "Kırılım yok"),
                detail: L10n.text("The pattern has formed, but the neckline has not been cleared.", "Formasyon oluştu ancak boyun çizgisi kırılmadı."),
                score: 0, maxScore: breakoutMax
            )
        }
        factors.append(breakoutFactor)

        // 4. Volume support (max 20)
        factors.append(JourneyAnalyzer.volumeFactor(ratio: volumeRatio))

        // 5. Retest confirmation (max 15)
        let retestMax = 15
        let retestFactor: ConfidenceFactor
        if retestHeld {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("Retest held", "Retest başarılı"),
                detail: L10n.text("Price returned to the neckline and left it in the breakout direction — the level is verified.", "Fiyat boyun çizgisine dönüp kırılım yönünde ayrıldı — seviye doğrulandı."),
                score: retestMax, maxScore: retestMax
            )
        } else if phase == .retest {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("Retest in progress", "Retest sürüyor"),
                detail: L10n.text("Price is testing the neckline right now; the result is not final yet.", "Fiyat şu anda boyun çizgisini test ediyor; sonuç henüz netleşmedi."),
                score: 8, maxScore: retestMax
            )
        } else if phase == .breakoutDetected || phase == .confirmed {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("No retest yet", "Henüz retest yok"),
                detail: L10n.text("The neckline has not been retested; the level is unproven.", "Boyun çizgisi henüz yeniden test edilmedi; seviye kanıtlanmadı."),
                score: 4, maxScore: retestMax
            )
        } else {
            retestFactor = ConfidenceFactor(
                key: "retest",
                title: L10n.text("No retest", "Retest yok"),
                detail: L10n.text("A retest can only happen after the neckline is cleared.", "Retest ancak boyun çizgisi kırıldıktan sonra oluşabilir."),
                score: 0, maxScore: retestMax
            )
        }
        factors.append(retestFactor)

        // 6. The trend being reversed (max 10)
        let contextMax = 10
        let contextStart = max(0, pattern.firstIndex - contextWindow)
        let priorMove: Double
        if contextStart < pattern.firstIndex {
            let window = candles[contextStart..<pattern.firstIndex]
            if direction == .bullish {
                let peak = window.map(\.high).max() ?? pattern.firstPrice
                priorMove = peak > 0 ? (peak - pattern.firstPrice) / peak : 0
            } else {
                let trough = window.map(\.low).min() ?? pattern.firstPrice
                priorMove = trough > 0 ? (pattern.firstPrice - trough) / trough : 0
            }
        } else {
            priorMove = 0
        }
        let movePercent = (priorMove * 100).formatted(.number.precision(.fractionLength(1)))
        let (contextScore, contextTitle): (Int, String) = switch priorMove {
        case 0.10...: (contextMax, L10n.text("Clear trend to reverse", "Dönecek trend net"))
        case 0.05..<0.10: (7, L10n.text("Moderate prior trend", "Önceki trend orta güçte"))
        case 0.02..<0.05: (4, L10n.text("Weak prior trend", "Önceki trend zayıf"))
        default: (1, L10n.text("No trend to reverse", "Dönecek trend yok"))
        }
        factors.append(ConfidenceFactor(
            key: "context",
            title: contextTitle,
            detail: direction == .bullish
                ? L10n.text("Price fell \(movePercent)% into the first bottom. A double bottom is worth more after a real decline.", "Fiyat ilk dibe kadar %\(movePercent) düştü. Çift dip, gerçek bir düşüşün ardından daha anlamlıdır.")
                : L10n.text("Price rose \(movePercent)% into the first top. A double top is worth more after a real advance.", "Fiyat ilk tepeye kadar %\(movePercent) yükseldi. Çift tepe, gerçek bir yükselişin ardından daha anlamlıdır."),
            score: contextScore, maxScore: contextMax
        ))

        return factors
    }
}

enum DoubleBottomAnalyzer: JourneyDetector {
    nonisolated static let model = JourneyModel.doubleBottom

    nonisolated static func analyze(
        candles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]?,
        higherTimeframeTitle: String?
    ) -> JourneyAnalysis? {
        DoublePatternAnalyzer.analyze(
            direction: .bullish,
            candles: candles,
            higherTimeframeCandles: higherTimeframeCandles,
            higherTimeframeTitle: higherTimeframeTitle
        )
    }
}

enum DoubleTopAnalyzer: JourneyDetector {
    nonisolated static let model = JourneyModel.doubleTop

    nonisolated static func analyze(
        candles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]?,
        higherTimeframeTitle: String?
    ) -> JourneyAnalysis? {
        DoublePatternAnalyzer.analyze(
            direction: .bearish,
            candles: candles,
            higherTimeframeCandles: higherTimeframeCandles,
            higherTimeframeTitle: higherTimeframeTitle
        )
    }
}
