import Foundation

/// How far back a scenario looks. Longer analysis timeframes produce far fewer
/// journey events, so a fixed 24-hour window leaves them with almost nothing to
/// measure; the default therefore scales with the timeframe.
enum ScenarioLookback: Int, CaseIterable, Identifiable, Sendable {
    case day1 = 24, day2 = 48, day3 = 72, week1 = 168

    var id: Int { rawValue }

    nonisolated var hours: Double { Double(rawValue) }

    nonisolated var since: Date { .now.addingTimeInterval(-hours * 3600) }

    var title: String {
        switch self {
        case .day1: L10n.text("Last 24 hours", "Son 24 saat")
        case .day2: L10n.text("Last 2 days", "Son 2 gün")
        case .day3: L10n.text("Last 3 days", "Son 3 gün")
        case .week1: L10n.text("Last 7 days", "Son 7 gün")
        }
    }

    var shortTitle: String {
        switch self {
        case .day1: L10n.text("24H", "24S")
        case .day2: L10n.text("2D", "2G")
        case .day3: L10n.text("3D", "3G")
        case .week1: L10n.text("7D", "7G")
        }
    }

    /// Candle interval used to replay what price did after each entry. Every
    /// window uses the same fine 15m grid so the same entry produces the same
    /// sale in every window — a coarser grid would skip the entry's own hour,
    /// miss early target touches and make windows disagree. The longest
    /// window, 7 days, needs 672 candles and stays inside Binance's
    /// 1000-candle fetch cap; that cap is why there is no longer window.
    nonisolated var observationInterval: String { "15m" }

    /// Candles needed to span the whole window at `observationInterval`,
    /// with a small buffer.
    nonisolated var observationCandleLimit: Int { Int(hours * 4) + 8 }
}

extension Date {
    /// Binance reports a candle's close as the boundary minus one millisecond
    /// (10:44:59.999). Simulations and labels want the true boundary
    /// (10:45:00) — otherwise entries display at odd minutes and window
    /// arithmetic starts one millisecond early.
    nonisolated var ceiledToSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.up))
    }
}

struct BreakoutScenarioEntry: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let direction: JourneyDirection
    let regimeScore: Int
    let readinessScore: Int
    let breakoutQualityScore: Int
    let confirmationScore: Int
    /// 0-100 percentile of the coin's ~24h excess return vs BTC at entry.
    /// Nil for events recorded before the score shipped — those pass the
    /// scenario's relative-strength filter rather than being judged on a
    /// value that was never measured.
    let relativeStrengthScore: Int?
    /// Legacy 0-100 trend score at the entry candle. Nil for events recorded
    /// before the score shipped; no longer exposed as a product filter.
    let trendScore: Int?
    /// True when the entry candle was the backtested A+ setup.
    let trendEntry: Bool
    /// Market state frozen at the entry candle. Nil for history recorded
    /// before the market-state engine was introduced.
    let marketState: MarketStateKind?
    let marketStateScore: Int?
    let marketStateChange: Int?
    let falseBreakoutRisk: Int
    let volumeRatio: Double
    /// The coin's 24h quote volume, so the page's minimum-volume filter can
    /// work on loaded entries without refetching.
    let quoteVolume24h: Double
    let entryPrice: Double
    let latestPrice: Double
    let maximumObservedPrice: Double
    let minimumObservedPrice: Double
    let entryDate: Date
    let observedCandles: [PriceCandle]

    var currentReturnPercent: Double {
        guard entryPrice > 0 else { return 0 }
        return switch direction {
        case .bullish: (latestPrice - entryPrice) / entryPrice * 100
        case .bearish: (entryPrice - latestPrice) / entryPrice * 100
        }
    }

    var maximumReturnPercent: Double {
        guard entryPrice > 0 else { return 0 }
        return switch direction {
        case .bullish: (maximumObservedPrice - entryPrice) / entryPrice * 100
        case .bearish: (entryPrice - minimumObservedPrice) / entryPrice * 100
        }
    }

    /// Walks the observed candles and returns the first exit the position hits:
    /// the profit target, the stop loss, or the holding deadline. When one
    /// candle spans both the target and the stop, the stop is assumed to have
    /// hit first — the replay must not be more optimistic than reality could
    /// prove. Returns nil while the window ends with the position still open.
    func exit(profitTarget: Double, stopLoss: Double, maxOpenHours: Int) -> ScenarioExit? {
        guard entryPrice > 0 else { return nil }
        let deadline = entryDate.addingTimeInterval(Double(maxOpenHours) * 3600)
        let targetPrice = direction == .bullish
            ? entryPrice * (1 + profitTarget / 100)
            : entryPrice * (1 - profitTarget / 100)
        let stopPrice = direction == .bullish
            ? entryPrice * (1 - stopLoss / 100)
            : entryPrice * (1 + stopLoss / 100)
        var previous: PriceCandle?
        for candle in observedCandles {
            // The deadline expired before this candle even opened: the position
            // was closed at the last price the market printed before it.
            if candle.openTime >= deadline {
                let closePrice = previous?.close ?? entryPrice
                return ScenarioExit(
                    date: previous?.closeTime.ceiledToSecond ?? deadline,
                    returnPercent: directionalReturnPercent(closePrice),
                    reason: .timeLimit
                )
            }
            let stopHit = direction == .bullish ? candle.low <= stopPrice : candle.high >= stopPrice
            if stopHit {
                return ScenarioExit(date: candle.closeTime.ceiledToSecond, returnPercent: -stopLoss, reason: .stopLoss)
            }
            let targetHit = direction == .bullish ? candle.high >= targetPrice : candle.low <= targetPrice
            if targetHit {
                return ScenarioExit(date: candle.closeTime.ceiledToSecond, returnPercent: profitTarget, reason: .target)
            }
            // The deadline falls inside this candle: it survived the intrabar
            // checks above, so it closes at this candle's close, win or lose.
            if candle.closeTime >= deadline {
                return ScenarioExit(
                    date: candle.closeTime.ceiledToSecond,
                    returnPercent: directionalReturnPercent(candle.close),
                    reason: .timeLimit
                )
            }
            previous = candle
        }
        return nil
    }

    /// The tournament winner's exit: a stop that trails the high watermark by
    /// `multiplier` × ATR and only ever tightens. No target caps the winners;
    /// the holding deadline still applies. The ATR is approximated from the
    /// first 14 observed true ranges — the events carry no pre-entry candles,
    /// and volatility rarely jumps regimes inside one holding window.
    /// The stop ratchets only AFTER a candle survives its own check, so an
    /// intrabar high can never save the same candle's low.
    func chandelierExit(multiplier: Double, maxOpenHours: Int) -> ScenarioExit? {
        guard entryPrice > 0, !observedCandles.isEmpty else { return nil }
        let deadline = entryDate.addingTimeInterval(Double(maxOpenHours) * 3600)
        var trueRanges: [Double] = []
        var previousClose = entryPrice
        for candle in observedCandles.prefix(14) {
            trueRanges.append(max(
                candle.high - candle.low,
                abs(candle.high - previousClose),
                abs(candle.low - previousClose)
            ))
            previousClose = candle.close
        }
        let atr = trueRanges.reduce(0, +) / Double(max(trueRanges.count, 1))
        guard atr > 0 else { return nil }
        let width = multiplier * atr
        var watermark = entryPrice
        var stop = direction == .bullish ? entryPrice - width : entryPrice + width
        var previous: PriceCandle?
        for candle in observedCandles {
            if candle.openTime >= deadline {
                let closePrice = previous?.close ?? entryPrice
                return ScenarioExit(
                    date: previous?.closeTime.ceiledToSecond ?? deadline,
                    returnPercent: directionalReturnPercent(closePrice),
                    reason: .timeLimit
                )
            }
            let stopHit = direction == .bullish ? candle.low <= stop : candle.high >= stop
            if stopHit {
                return ScenarioExit(
                    date: candle.closeTime.ceiledToSecond,
                    returnPercent: directionalReturnPercent(stop),
                    reason: .stopLoss
                )
            }
            if candle.closeTime >= deadline {
                return ScenarioExit(
                    date: candle.closeTime.ceiledToSecond,
                    returnPercent: directionalReturnPercent(candle.close),
                    reason: .timeLimit
                )
            }
            watermark = direction == .bullish ? max(watermark, candle.high) : min(watermark, candle.low)
            stop = direction == .bullish ? max(stop, watermark - width) : min(stop, watermark + width)
            previous = candle
        }
        return nil
    }

    private func directionalReturnPercent(_ price: Double) -> Double {
        switch direction {
        case .bullish: (price - entryPrice) / entryPrice * 100
        case .bearish: (entryPrice - price) / entryPrice * 100
        }
    }

    /// Re-anchors the trade to the moment price moved another
    /// `additionalPercent` past the recorded event price — "wait for +x% of
    /// follow-through before opening the position". Returns nil when the
    /// window never reached that trigger, so no position is opened at all.
    func enteringAfter(additionalPercent: Double) -> BreakoutScenarioEntry? {
        guard additionalPercent > 0, entryPrice > 0 else { return self }
        let triggerPrice = direction == .bullish
            ? entryPrice * (1 + additionalPercent / 100)
            : entryPrice * (1 - additionalPercent / 100)
        guard let index = observedCandles.firstIndex(where: { candle in
            direction == .bullish ? candle.high >= triggerPrice : candle.low <= triggerPrice
        }) else { return nil }
        // The position opens intrabar at the trigger; observation starts on
        // that same candle, so a candle spanning trigger and stop still
        // resolves pessimistically inside exit().
        let observed = Array(observedCandles[index...])
        return BreakoutScenarioEntry(
            id: id,
            symbol: symbol,
            direction: direction,
            regimeScore: regimeScore,
            readinessScore: readinessScore,
            breakoutQualityScore: breakoutQualityScore,
            confirmationScore: confirmationScore,
            relativeStrengthScore: relativeStrengthScore,
            trendScore: trendScore,
            trendEntry: trendEntry,
            marketState: marketState,
            marketStateScore: marketStateScore,
            marketStateChange: marketStateChange,
            falseBreakoutRisk: falseBreakoutRisk,
            volumeRatio: volumeRatio,
            quoteVolume24h: quoteVolume24h,
            entryPrice: triggerPrice,
            latestPrice: observed.last?.close ?? triggerPrice,
            maximumObservedPrice: observed.map(\.high).max() ?? triggerPrice,
            minimumObservedPrice: observed.map(\.low).min() ?? triggerPrice,
            entryDate: observed[0].openTime,
            observedCandles: observed
        )
    }
}

struct ScenarioExit: Sendable {
    enum Reason: Sendable {
        case target, stopLoss, timeLimit
    }

    let date: Date
    let returnPercent: Double
    let reason: Reason
}

struct BreakoutScenarioResult: Sendable {
    let entries: [BreakoutScenarioEntry]
    /// True when the event query filled its row cap, so the oldest part of the
    /// window is missing and the scenario only covers the most recent events.
    let isTruncated: Bool

    static let empty = BreakoutScenarioResult(entries: [], isTruncated: false)
}

actor AnalysisInsightsService {
    /// Row cap on the Market State transition query.
    private static let eventRowLimit = 800
    private static let scenarioSymbolLimit = 100

    private struct ScenarioStateRow: Decodable, Sendable {
        let symbol_id: UUID
        let symbol: String
        let state: MarketStateKind
        let state_score: Int
        let state_score_change: Int?
        let candle_close_time: String
        let close_price: Double?
        let quote_volume_24h: Double?
    }

    func scenarioEntries(
        timeframe: String,
        lookback: ScenarioLookback
    ) async throws -> BreakoutScenarioResult {
        let allRows: [ScenarioStateRow] = try await rpc(
            "market_state_scenario_entries",
            body: [
                "p_timeframe": timeframe,
                "p_since": Self.iso8601(lookback.since),
                "p_limit": Self.eventRowLimit,
            ]
        )
        let eligibleRows = allRows.filter { CryptoAssetUniverse.includes(symbol: $0.symbol) }
        var selectedSymbols: [String] = []
        for row in eligibleRows where !selectedSymbols.contains(row.symbol) {
            selectedSymbols.append(row.symbol)
            if selectedSymbols.count >= Self.scenarioSymbolLimit { break }
        }
        let rows = eligibleRows.filter { selectedSymbols.contains($0.symbol) }
        let droppedSymbols = Set(eligibleRows.map(\.symbol)).count - selectedSymbols.count
        let interval = lookback.observationInterval
        let grouped = Dictionary(grouping: rows, by: \.symbol)
        let entries = await withTaskGroup(of: [BreakoutScenarioEntry].self) { group in
            for (symbol, events) in grouped {
                group.addTask {
                    let datedEvents = events.compactMap { row -> (ScenarioStateRow, Date)? in
                        guard let date = Self.date(row.candle_close_time) else { return nil }
                        return (row, date)
                    }
                    guard let earliest = datedEvents.map({ $0.1 }).min() else { return [] }
                    var candles: [PriceCandle]?
                    for attempt in 0..<3 {
                        candles = try? await CandleService().candles(
                            for: symbol,
                            interval: interval,
                            // One 15m candle before the transition supplies a
                            // close price for history recorded before the DB
                            // began freezing close_price on state rows.
                            startingAt: earliest.addingTimeInterval(-900),
                            limit: lookback.observationCandleLimit + 2
                        )
                        if candles != nil { break }
                        try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    }
                    guard let candles else { return [] }
                    return datedEvents.compactMap { row, rawEntryDate in
                        let entryDate = rawEntryDate.ceiledToSecond
                        let recordedClose = row.close_price ?? candles.last(where: {
                            $0.closeTime.ceiledToSecond <= entryDate
                        })?.close
                        guard let entryPrice = recordedClose, entryPrice > 0 else { return nil }
                        let observed = candles.filter { $0.openTime >= entryDate }
                        return BreakoutScenarioEntry(
                            id: UUID(),
                            symbol: symbol,
                            direction: .bullish,
                            regimeScore: 0,
                            readinessScore: 0,
                            breakoutQualityScore: row.state_score,
                            confirmationScore: row.state_score,
                            relativeStrengthScore: nil,
                            trendScore: nil,
                            trendEntry: row.state == .buyerTakeover && row.state_score >= MarketStateSnapshot.aPlusMinimumScore,
                            marketState: row.state,
                            marketStateScore: row.state_score,
                            marketStateChange: row.state_score_change,
                            falseBreakoutRisk: 0,
                            volumeRatio: 0,
                            quoteVolume24h: row.quote_volume_24h ?? 0,
                            entryPrice: entryPrice,
                            latestPrice: observed.last?.close ?? entryPrice,
                            maximumObservedPrice: observed.map(\.high).max() ?? entryPrice,
                            minimumObservedPrice: observed.map(\.low).min() ?? entryPrice,
                            entryDate: entryDate,
                            observedCandles: observed
                        )
                    }
                }
            }
            var values: [BreakoutScenarioEntry] = []
            for await batch in group { values.append(contentsOf: batch) }
            return values
        }
        return BreakoutScenarioResult(
            entries: entries.sorted {
                if $0.quoteVolume24h != $1.quoteVolume24h { return $0.quoteVolume24h > $1.quoteVolume24h }
                return $0.entryDate > $1.entryDate
            },
            isTruncated: allRows.count >= Self.eventRowLimit || droppedSymbols > 0
        )
    }

    private func rpc<T: Decodable>(_ name: String, body: [String: Any]) async throws -> T {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

}
