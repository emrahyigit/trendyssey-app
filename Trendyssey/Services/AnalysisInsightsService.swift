import Foundation

/// How far back a scenario looks. Longer analysis timeframes produce far fewer
/// journey events, so a fixed 24-hour window leaves them with almost nothing to
/// measure; the default therefore scales with the timeframe.
enum ScenarioLookback: Int, CaseIterable, Identifiable, Sendable {
    case day1 = 24, day2 = 48, day3 = 72, week1 = 168, week2 = 336

    var id: Int { rawValue }

    nonisolated var hours: Double { Double(rawValue) }

    nonisolated var since: Date { .now.addingTimeInterval(-hours * 3600) }

    var title: String {
        switch self {
        case .day1: L10n.text("Last 24 hours", "Son 24 saat")
        case .day2: L10n.text("Last 2 days", "Son 2 gün")
        case .day3: L10n.text("Last 3 days", "Son 3 gün")
        case .week1: L10n.text("Last 7 days", "Son 7 gün")
        case .week2: L10n.text("Last 14 days", "Son 14 gün")
        }
    }

    var shortTitle: String {
        switch self {
        case .day1: L10n.text("24H", "24S")
        case .day2: L10n.text("2D", "2G")
        case .day3: L10n.text("3D", "3G")
        case .week1: L10n.text("7D", "7G")
        case .week2: L10n.text("14D", "14G")
        }
    }

    /// Candle interval used to replay what price did after each entry. Must be
    /// one of the four analysis timeframes, and coarse enough that one
    /// 100-candle fetch spans the whole window — otherwise the tail of a long
    /// scenario would be measured against no data.
    nonisolated var observationInterval: String {
        switch self {
        case .day1: "15m"   // 24h  = 96 candles
        case .day2: "1h"    // 48h  = 48 candles
        case .day3: "1h"    // 72h  = 72 candles
        case .week1: "4h"   // 7d   = 42 candles
        case .week2: "4h"   // 14d  = 84 candles
        }
    }

    /// A window that leaves each timeframe enough closed candles to produce a
    /// meaningful number of journey events.
    static func `default`(for timeframe: AnalysisTimeframe) -> ScenarioLookback {
        switch timeframe {
        case .m15: .day1
        case .h1: .day3
        case .h4: .week1
        case .d1: .week2
        }
    }
}

struct BreakoutScenarioEntry: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let status: SignalStatus
    let confidenceScore: Int
    let falseBreakoutRisk: Int
    let volumeRatio: Double
    let entryPrice: Double
    let latestPrice: Double
    let maximumObservedPrice: Double
    let entryDate: Date
    let observedCandles: [PriceCandle]

    var currentReturnPercent: Double {
        guard entryPrice > 0 else { return 0 }
        return (latestPrice - entryPrice) / entryPrice * 100
    }

    var maximumReturnPercent: Double {
        guard entryPrice > 0 else { return 0 }
        return (maximumObservedPrice - entryPrice) / entryPrice * 100
    }

    func targetHitDate(profitTarget: Double) -> Date? {
        let targetPrice = entryPrice * (1 + profitTarget / 100)
        return observedCandles.first(where: { $0.high >= targetPrice })?.closeTime
    }
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

    /// The scenario replays the highest-volume coins that produced a matching
    /// signal in the window. Each coin costs one observation-candle request, so
    /// this bound is what keeps the page fast.
    private static let scenarioSymbolLimit = 20

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
        let false_breakout_risk: Int
        let volume_ratio: Double?
        let analysis_models: Model
        let symbols: Symbol
    }

    func scenarioEntries(
        modelSlug: String,
        timeframe: String,
        status: SignalStatus,
        lookback: ScenarioLookback
    ) async throws -> BreakoutScenarioResult {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_journey_events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,status,price,candle_close_time,confidence,false_breakout_risk,volume_ratio,analysis_models!inner(slug,display_name),symbols!inner(symbol,quote_volume_24h)"),
            .init(name: "status", value: "eq.\(Self.databaseStatus(status))"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "analysis_models.slug", value: "eq.\(modelSlug)"),
            .init(name: "candle_close_time", value: "gte.\(Self.iso8601(lookback.since))"),
            // Highest-volume coins first, so even a truncated window always
            // contains the entries most worth acting on.
            .init(name: "order", value: "symbols(quote_volume_24h).desc,candle_close_time.desc"),
            .init(name: "limit", value: "\(Self.eventRowLimit)"),
        ]
        let allRows = try await get([ScenarioEventRow].self, url: components.url!)
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
                    guard let candles = try? await CandleService().candles(
                        for: symbol,
                        interval: interval,
                        startingAt: earliest,
                        limit: 100
                    ) else { return [] }
                    return datedEvents.map { row, entryDate in
                        let observed = candles.filter { $0.openTime > entryDate }
                        return BreakoutScenarioEntry(
                            id: row.id,
                            symbol: symbol,
                            status: status,
                            confidenceScore: row.confidence,
                            falseBreakoutRisk: row.false_breakout_risk,
                            volumeRatio: row.volume_ratio ?? 0,
                            entryPrice: row.price,
                            latestPrice: observed.last?.close ?? row.price,
                            maximumObservedPrice: observed.map(\.high).max() ?? row.price,
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
