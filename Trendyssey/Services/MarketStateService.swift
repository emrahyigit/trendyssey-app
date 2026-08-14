import Foundation

actor MarketStateService {
    static let shared = MarketStateService()

    private struct Row: Decodable {
        struct Symbol: Decodable { let symbol: String }

        let state: MarketStateKind
        let state_score: Int
        let previous_state_score: Int?
        let state_score_change: Int?
        let selling_pressure: Int
        let selling_pressure_change: Int?
        let downside_response: Int
        let downside_response_change: Int?
        let seller_efficiency: Int
        let seller_efficiency_change: Int?
        let efficiency_change: Int
        let absorption: Int
        let absorption_change: Int?
        let price_resilience: Int
        let price_resilience_change: Int?
        let bounce_readiness: Int
        let bounce_readiness_change: Int?
        let confirmation: Int
        let confirmation_change: Int?
        let state_since: Date
        let candle_close_time: Date
        let scoring_version: String
        let symbols: Symbol

        var snapshot: MarketStateSnapshot {
            MarketStateSnapshot(
                state: state,
                stateScore: state_score,
                previousStateScore: previous_state_score,
                stateScoreChange: state_score_change,
                sellingPressure: selling_pressure,
                sellingPressureChange: selling_pressure_change,
                downsideResponse: downside_response,
                downsideResponseChange: downside_response_change,
                sellerEfficiency: seller_efficiency,
                sellerEfficiencyChange: seller_efficiency_change,
                efficiencyChange: efficiency_change,
                absorption: absorption,
                absorptionChange: absorption_change,
                priceResilience: price_resilience,
                priceResilienceChange: price_resilience_change,
                bounceReadiness: bounce_readiness,
                bounceReadinessChange: bounce_readiness_change,
                confirmation: confirmation,
                confirmationChange: confirmation_change,
                stateSince: state_since,
                candleCloseTime: candle_close_time,
                scoringVersion: scoring_version
            )
        }
    }

    func snapshots(timeframe: String) async throws -> [String: MarketStateSnapshot] {
        var components = URLComponents(
            url: SupabaseConfig.projectURL.appending(path: "rest/v1/market_state_current"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "select", value: "state,state_score,previous_state_score,state_score_change,selling_pressure,selling_pressure_change,downside_response,downside_response_change,seller_efficiency,seller_efficiency_change,efficiency_change,absorption,absorption_change,price_resilience,price_resilience_change,bounce_readiness,bounce_readiness_change,confirmation,confirmation_change,state_since,candle_close_time,scoring_version,symbols!inner(symbol)"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "limit", value: "1000")
        ]
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .marketStateISO8601
        return Dictionary(uniqueKeysWithValues: try decoder.decode([Row].self, from: data).map {
            ($0.symbols.symbol, $0.snapshot)
        })
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let marketStateISO8601 = custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid market-state timestamp"
            )
        }
        return date
    }
}
