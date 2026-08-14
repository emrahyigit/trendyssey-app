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
    let status: SignalStatus
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

    private func directionalReturnPercent(_ price: Double) -> Double {
        switch direction {
        case .bullish: (price - entryPrice) / entryPrice * 100
        case .bearish: (entryPrice - price) / entryPrice * 100
        }
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
    /// Row cap on the journey-event query. The query is ordered by 24h volume,
    /// so even a truncated window starts with the coins most worth acting on.
    private static let eventRowLimit = 800

    /// The scenario replays every universe coin that produced a matching signal
    /// in the window — the scan universe is 100 coins and observation candles
    /// come straight from Binance in parallel, so covering all of them is cheap.
    /// The volume filter on the page is what narrows this down, not a hard cap.
    private static let scenarioSymbolLimit = 100

    private struct Model: Decodable, Sendable {
        let slug: String
        let display_name: String
    }

    private struct Symbol: Decodable, Sendable {
        let symbol: String
        let quote_volume_24h: Double?
    }

    private struct ScenarioEventRow: Decodable, Sendable {
        let id: UUID
        let status: String
        let price: Double
        let candle_close_time: String
        let confidence: Int
        let regime_score: Int?
        let readiness_score: Int?
        let breakout_quality_score: Int?
        let confirmation_score: Int?
        let relative_strength_score: Int?
        let false_breakout_risk: Int
        let volume_ratio: Double?
        /// The coin's 24h volume when the event happened. Filtering on this
        /// instead of the live volume keeps the replay deterministic: a coin
        /// whose volume fell overnight no longer loses its past trades.
        let quote_volume_24h: Double?
        let analysis_models: Model
        let symbols: Symbol
    }

    func scenarioEntries(
        modelSlug: String,
        direction: JourneyDirection,
        timeframe: String,
        status: SignalStatus,
        lookback: ScenarioLookback
    ) async throws -> BreakoutScenarioResult {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_journey_events"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            .init(name: "select", value: "id,status,price,candle_close_time,confidence,regime_score,readiness_score,breakout_quality_score,confirmation_score,relative_strength_score,false_breakout_risk,volume_ratio,quote_volume_24h,analysis_models!inner(slug,display_name),symbols!inner(symbol,quote_volume_24h)"),
            .init(name: "status", value: "eq.\(Self.databaseStatus(status))"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "analysis_models.slug", value: "eq.\(modelSlug)"),
            .init(name: "candle_close_time", value: "gte.\(Self.iso8601(lookback.since))"),
            // Highest-volume coins first, so even a truncated window always
            // contains the entries most worth acting on.
            .init(name: "order", value: "symbols(quote_volume_24h).desc,candle_close_time.desc"),
            .init(name: "limit", value: "\(Self.eventRowLimit)"),
        ]
        if modelSlug == "double-bottom-v1" || modelSlug == "double-top-v1" {
            // Never mix legacy all-purpose confidence rows into the independent
            // v2 pattern layers shown by the scenario screen.
            queryItems.append(.init(name: "scoring_version", value: "eq.breakout-scores-v2-pattern"))
        }
        components.queryItems = queryItems
        var allRows: [ScenarioEventRow]
        do {
            allRows = try await get([ScenarioEventRow].self, url: components.url!)
        } catch {
            // The event-level volume column ships in a migration; if that has
            // not been applied yet the select 400s. Retry without the column
            // so the page keeps working on the live-volume fallback.
            components.queryItems = queryItems.map { item in
                item.name == "select"
                    ? URLQueryItem(name: "select", value: item.value?.replacingOccurrences(of: ",quote_volume_24h,analysis_models", with: ",analysis_models"))
                    : item
            }
            allRows = try await get([ScenarioEventRow].self, url: components.url!)
        }
        let eligibleRows = allRows.filter { CryptoAssetUniverse.includes(symbol: $0.symbols.symbol) }
        // Rows arrive ordered by volume, so the first N distinct symbols are the
        // highest-volume coins that actually produced this signal in the window.
        // Only those are replayed; everything else would just slow the page down.
        var selectedSymbols: [String] = []
        for row in eligibleRows where !selectedSymbols.contains(row.symbols.symbol) {
            selectedSymbols.append(row.symbols.symbol)
            if selectedSymbols.count >= Self.scenarioSymbolLimit { break }
        }
        let rows = eligibleRows.filter { selectedSymbols.contains($0.symbols.symbol) }
        let droppedSymbols = Set(eligibleRows.map(\.symbols.symbol)).count - selectedSymbols.count
        let interval = lookback.observationInterval
        let grouped = Dictionary(grouping: rows, by: { $0.symbols.symbol })
        let entries = await withTaskGroup(of: [BreakoutScenarioEntry].self) { group in
            for (symbol, events) in grouped {
                group.addTask {
                    let datedEvents = events.compactMap { row -> (ScenarioEventRow, Date)? in
                        guard let date = Self.date(row.candle_close_time) else { return nil }
                        return (row, date)
                    }
                    guard let earliest = datedEvents.map({ $0.1 }).min() else { return [] }
                    // One failed fetch silently deleted every trade of the
                    // coin from the replay — on wide windows the burst of 100
                    // parallel requests made that common enough that a 7-day
                    // scenario could shrink to a handful of coins. Retry with
                    // backoff before giving the symbol up.
                    var candles: [PriceCandle]?
                    for attempt in 0..<3 {
                        candles = try? await CandleService().candles(
                            for: symbol,
                            interval: interval,
                            startingAt: earliest,
                            limit: lookback.observationCandleLimit
                        )
                        if candles != nil { break }
                        try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    }
                    guard let candles else { return [] }
                    return datedEvents.map { row, rawEntryDate in
                        // The boundary, not Binance's boundary-minus-1ms: the
                        // trade opens exactly when the entry candle closes.
                        let entryDate = rawEntryDate.ceiledToSecond
                        let observed = candles.filter { $0.openTime >= entryDate }
                        return BreakoutScenarioEntry(
                            id: row.id,
                            symbol: symbol,
                            status: status,
                            direction: direction,
                            regimeScore: row.regime_score ?? 0,
                            readinessScore: row.readiness_score ?? 0,
                            breakoutQualityScore: row.breakout_quality_score ?? row.confidence,
                            confirmationScore: row.confirmation_score ?? 0,
                            relativeStrengthScore: row.relative_strength_score,
                            falseBreakoutRisk: row.false_breakout_risk,
                            volumeRatio: row.volume_ratio ?? 0,
                            quoteVolume24h: row.quote_volume_24h ?? row.symbols.quote_volume_24h ?? 0,
                            entryPrice: row.price,
                            latestPrice: observed.last?.close ?? row.price,
                            maximumObservedPrice: observed.map(\.high).max() ?? row.price,
                            minimumObservedPrice: observed.map(\.low).min() ?? row.price,
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
        let volumeBySymbol = Dictionary(
            rows.map { ($0.symbols.symbol, $0.symbols.quote_volume_24h ?? 0) },
            uniquingKeysWith: { first, _ in first }
        )
        return BreakoutScenarioResult(
            // Highest 24h volume first; recency breaks ties within a coin.
            entries: entries.sorted {
                let lhs = volumeBySymbol[$0.symbol] ?? 0
                let rhs = volumeBySymbol[$1.symbol] ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.entryDate > $1.entryDate
            },
            isTruncated: allRows.count >= Self.eventRowLimit || droppedSymbols > 0
        )
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
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

    private static func databaseStatus(_ status: SignalStatus) -> String {
        switch status {
        case .watching: "watching"
        case .preBreakout: "pre_breakout"
        case .breakoutDetected: "breakout_detected"
        case .confirmed: "confirmed"
        case .retest: "retest"
        case .failed: "failed"
        case .expired: "expired"
        }
    }
}
