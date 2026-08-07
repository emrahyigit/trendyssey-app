import Foundation

actor MarketCharacterService {
    static let shared = MarketCharacterService()

    private struct Parameters: Encodable {
        let p_model_slug: String
        let p_timeframe: String
        let p_lookback_days: Int
        let p_limit: Int
    }

    private struct Row: Decodable {
        let category: String
        let symbol: String
        let base_asset: String
        let icon_url: String?
        let current_price: Double?
        let price_change_percent_24h: Double?
        let quote_volume_24h: Double?
        let score: Double
        let rank_score: Double
        let sample_count: Int
        let success_count: Int
        let failure_count: Int
        let median_return_percent: Double?
        let rsi: Double?
        let atr_distance: Double?
    }

    private struct CacheEntry {
        let loadedAt: Date
        let rankings: [MarketCharacterEntry]
    }

    private var cache: [String: CacheEntry] = [:]

    func rankings(
        modelSlug: String,
        timeframe: String,
        lookbackDays: Int = 30,
        limit: Int = 20,
        forceRefresh: Bool = false
    ) async throws -> [MarketCharacterEntry] {
        let key = "\(modelSlug)|\(timeframe)|\(lookbackDays)|\(limit)"
        if !forceRefresh,
           let cached = cache[key],
           Date.now.timeIntervalSince(cached.loadedAt) < 300 {
            return cached.rankings
        }

        let url = SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_market_character_rankings")
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Parameters(
            p_model_slug: modelSlug,
            p_timeframe: timeframe,
            p_lookback_days: lookbackDays,
            p_limit: limit
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let rankings = try JSONDecoder().decode([Row].self, from: data).compactMap { row -> MarketCharacterEntry? in
            guard let category = MarketCharacterCategory(rawValue: row.category),
                  CryptoAssetUniverse.includes(symbol: row.symbol) else { return nil }
            return MarketCharacterEntry(
                category: category,
                symbol: row.symbol,
                baseAsset: row.base_asset,
                iconURL: row.icon_url,
                currentPrice: row.current_price ?? 0,
                change24h: row.price_change_percent_24h ?? 0,
                quoteVolume24h: row.quote_volume_24h ?? 0,
                score: row.score,
                rankScore: row.rank_score,
                sampleCount: row.sample_count,
                successCount: row.success_count,
                failureCount: row.failure_count,
                medianReturnPercent: row.median_return_percent,
                rsi: row.rsi,
                atrDistance: row.atr_distance
            )
        }
        cache[key] = CacheEntry(loadedAt: .now, rankings: rankings)
        return rankings
    }
}
