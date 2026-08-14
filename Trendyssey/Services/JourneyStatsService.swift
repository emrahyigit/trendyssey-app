import Foundation

/// Confirmed-vs-invalidated journey counts for one symbol, computed by the
/// backend from the same event log the character rankings read. The detail
/// page shows these on every signal so an invalidation arrives as a known
/// base rate, not a surprise.
struct SymbolJourneyStats: Equatable, Sendable {
    let startedCount: Int
    let confirmedCount: Int
    let invalidatedCount: Int
    let inProgressCount: Int

    /// A journey counts as invalidated the moment it records a 'failed' event,
    /// no matter how far it got before dying — that is how users experience it
    /// through notifications. Success is simply "has not failed", which keeps
    /// started = invalidated + not-failed with no third bucket to explain.
    var invalidationRatePercent: Double? {
        guard startedCount > 0 else { return nil }
        return 100.0 * Double(invalidatedCount) / Double(startedCount)
    }

    var successRatePercent: Double? {
        guard startedCount > 0 else { return nil }
        return 100.0 * Double(startedCount - invalidatedCount) / Double(startedCount)
    }

    /// Since most breakouts on short timeframes eventually fail (the market
    /// average sits near 60%), the hiding bar is "clearly worse than the pack":
    /// more than three quarters invalidated, over a sample big enough to mean
    /// something. Coins matching this are dropped from Featured Breakouts and
    /// Waiting for Breakout; they remain visible everywhere else.
    var isHighInvalidation: Bool {
        startedCount >= 4 && invalidatedCount * 4 > startedCount * 3
    }
}

actor JourneyStatsService {
    static let shared = JourneyStatsService()

    private struct Parameters: Encodable {
        let p_model_slug: String
        let p_symbol: String
        let p_timeframe: String
        let p_lookback_days: Int
    }

    private struct Row: Decodable {
        let started_count: Int
        let confirmed_count: Int
        let invalidated_count: Int
        let in_progress_count: Int
    }

    private struct BulkParameters: Encodable {
        let p_model_slug: String
        let p_timeframe: String
        let p_lookback_days: Int
    }

    private struct BulkRow: Decodable {
        let symbol: String
        let started_count: Int
        let confirmed_count: Int
        let invalidated_count: Int
        let in_progress_count: Int
    }

    private struct CacheEntry {
        let loadedAt: Date
        let stats: SymbolJourneyStats
    }

    private struct BulkCacheEntry {
        let loadedAt: Date
        let stats: [String: SymbolJourneyStats]
    }

    private var cache: [String: CacheEntry] = [:]
    private var bulkCache: [String: BulkCacheEntry] = [:]

    /// Every symbol's counts in one call, keyed by ticker, so the dashboard
    /// can drop high-invalidation coins without a request per coin.
    func invalidationStats(
        modelSlug: String,
        timeframe: String,
        lookbackDays: Int = 30,
        forceRefresh: Bool = false
    ) async throws -> [String: SymbolJourneyStats] {
        let key = "\(modelSlug)|\(timeframe)|\(lookbackDays)"
        if !forceRefresh,
           let cached = bulkCache[key],
           Date.now.timeIntervalSince(cached.loadedAt) < 300 {
            return cached.stats
        }

        let url = SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_journey_invalidation_stats")
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BulkParameters(
            p_model_slug: modelSlug,
            p_timeframe: timeframe,
            p_lookback_days: lookbackDays
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let stats = try JSONDecoder().decode([BulkRow].self, from: data).reduce(into: [String: SymbolJourneyStats]()) { map, row in
            map[row.symbol] = SymbolJourneyStats(
                startedCount: row.started_count,
                confirmedCount: row.confirmed_count,
                invalidatedCount: row.invalidated_count,
                inProgressCount: row.in_progress_count
            )
        }
        bulkCache[key] = BulkCacheEntry(loadedAt: .now, stats: stats)
        return stats
    }

    func stats(
        symbol: String,
        modelSlug: String,
        timeframe: String,
        lookbackDays: Int = 30,
        forceRefresh: Bool = false
    ) async throws -> SymbolJourneyStats {
        let key = "\(symbol)|\(modelSlug)|\(timeframe)|\(lookbackDays)"
        if !forceRefresh,
           let cached = cache[key],
           Date.now.timeIntervalSince(cached.loadedAt) < 300 {
            return cached.stats
        }

        let url = SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_symbol_journey_stats")
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Parameters(
            p_model_slug: modelSlug,
            p_symbol: symbol,
            p_timeframe: timeframe,
            p_lookback_days: lookbackDays
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        guard let row = try JSONDecoder().decode([Row].self, from: data).first else {
            throw URLError(.cannotParseResponse)
        }
        let stats = SymbolJourneyStats(
            startedCount: row.started_count,
            confirmedCount: row.confirmed_count,
            invalidatedCount: row.invalidated_count,
            inProgressCount: row.in_progress_count
        )
        cache[key] = CacheEntry(loadedAt: .now, stats: stats)
        return stats
    }
}
