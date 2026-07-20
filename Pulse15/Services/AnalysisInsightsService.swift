import Foundation

struct BreakoutScenarioEntry: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let status: SignalStatus
    let signalStrength: Int
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

struct WeeklyModelReport: Sendable {
    let evaluatedCount: Int
    let winCount: Int
    let flatCount: Int
    let lossCount: Int
    let averageReturnPercent: Double
    let bestReturnPercent: Double
    let worstReturnPercent: Double

    var winRate: Double {
        guard evaluatedCount > 0 else { return 0 }
        return Double(winCount) / Double(evaluatedCount) * 100
    }
}

struct AnalysisModelPerformance: Identifiable, Sendable {
    var id: String { modelSlug }
    let modelSlug: String
    let modelName: String
    let evaluatedCount: Int
    let winCount: Int
    let flatCount: Int
    let lossCount: Int
    let successRate: Double
    let averageReturnPercent: Double
}

actor AnalysisInsightsService {
    private struct Model: Decodable, Sendable {
        let slug: String
        let display_name: String
    }

    private struct Symbol: Decodable, Sendable {
        let symbol: String
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

    private struct PerformanceRow: Decodable {
        let return_percent: Double
        let outcome_label: String?
        let analysis_models: Model
    }

    func scenarioEntries(modelSlug: String, timeframe: String, status: SignalStatus, since: Date) async throws -> [BreakoutScenarioEntry] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_journey_events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,status,price,candle_close_time,confidence,false_breakout_risk,volume_ratio,analysis_models!inner(slug,display_name),symbols!inner(symbol)"),
            .init(name: "status", value: "eq.\(Self.databaseStatus(status))"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "analysis_models.slug", value: "eq.\(modelSlug)"),
            .init(name: "candle_close_time", value: "gte.\(Self.iso8601(since))"),
            .init(name: "order", value: "candle_close_time.desc"),
            .init(name: "limit", value: "500"),
        ]
        let rows = try await get([ScenarioEventRow].self, url: components.url!)
            .filter { CryptoAssetUniverse.includes(symbol: $0.symbols.symbol) }
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
                        interval: "5m",
                        startingAt: earliest,
                        limit: 500
                    ) else { return [] }
                    return datedEvents.map { row, entryDate in
                        let observed = candles.filter { $0.openTime > entryDate }
                        return BreakoutScenarioEntry(
                            id: row.id,
                            symbol: symbol,
                            status: status,
                            signalStrength: row.confidence,
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
        return entries.sorted { $0.entryDate > $1.entryDate }
    }

    func modelPerformance(timeframe: String, horizon: Int) async throws -> [AnalysisModelPerformance] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_outcome_snapshots"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "return_percent,outcome_label,analysis_models!inner(slug,display_name)"),
            .init(name: "status", value: "eq.evaluated"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "horizon_candles", value: "eq.\(horizon)"),
            .init(name: "limit", value: "2000"),
        ]
        let rows = try await get([PerformanceRow].self, url: components.url!)
        let groups = Dictionary(grouping: rows, by: { $0.analysis_models.slug })
        return groups.values.compactMap { values in
            guard let first = values.first else { return nil }
            let wins = values.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.win.rawValue }.count
            let flats = values.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.flat.rawValue }.count
            let losses = values.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.loss.rawValue }.count
            let count = values.count
            let average = values.reduce(0.0) { $0 + $1.return_percent } / Double(max(count, 1))
            return AnalysisModelPerformance(
                modelSlug: first.analysis_models.slug,
                modelName: first.analysis_models.display_name,
                evaluatedCount: count,
                winCount: wins,
                flatCount: flats,
                lossCount: losses,
                successRate: Double(wins) / Double(max(count, 1)) * 100,
                averageReturnPercent: average
            )
        }
        .sorted {
            if $0.successRate != $1.successRate { return $0.successRate > $1.successRate }
            return $0.modelName < $1.modelName
        }
    }

    func weeklyReport(timeframe: String) async throws -> WeeklyModelReport {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_outcome_snapshots"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "return_percent,outcome_label"),
            .init(name: "status", value: "eq.evaluated"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "created_at", value: "gte.\(Self.iso8601(Date.now.addingTimeInterval(-7 * 86_400)))"),
            .init(name: "limit", value: "5000"),
        ]
        let rows = try await get([PerformanceRow2].self, url: components.url!)
        let returns = rows.compactMap(\.return_percent)
        return WeeklyModelReport(
            evaluatedCount: rows.count,
            winCount: rows.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.win.rawValue }.count,
            flatCount: rows.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.flat.rawValue }.count,
            lossCount: rows.filter { $0.outcome_label == SignalOutcomeSnapshot.Outcome.loss.rawValue }.count,
            averageReturnPercent: returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count),
            bestReturnPercent: returns.max() ?? 0,
            worstReturnPercent: returns.min() ?? 0
        )
    }

    private struct PerformanceRow2: Decodable {
        let return_percent: Double?
        let outcome_label: String?
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
