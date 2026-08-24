import Foundation

actor MarketStateService {
    static let shared = MarketStateService()

    /// Every metric carries a level and a close-to-close delta. Listing the
    /// pairs together keeps the request and the model in step.
    private static let metricColumns = [
        "seller_pressure", "buyer_pressure",
        "seller_efficiency", "buyer_efficiency",
        "downside_response", "upside_response",
        "buy_side_absorption", "sell_side_absorption",
        "bullish_confirmation", "bearish_confirmation",
        "bounce_readiness", "rollover_readiness",
        "buyer_resilience", "seller_resilience"
    ]

    private static let selectColumns: String = ([
        "state", "state_score", "previous_state_score", "state_score_change",
        "seller_efficiency_trend", "buyer_efficiency_trend",
        "seller_pressure_trend", "buyer_pressure_trend",
        "state_since", "candle_close_time", "scoring_version",
        "market_context", "behavioral_scores", "behavioral_signals"
    ] + metricColumns.flatMap { [$0, "\($0)_change"] }
      + ["symbols!inner(symbol)"]).joined(separator: ",")

    /// Decoding an array of optionals still fails the whole array in Swift, so
    /// tolerance has to be written explicitly: a row this build cannot read
    /// becomes nil instead of throwing.
    private struct TolerantRow: Decodable {
        let row: Row?

        init(from decoder: Decoder) throws {
            row = try? Row(from: decoder)
        }
    }

    private struct Row: Decodable {
        struct Symbol: Decodable { let symbol: String }

        let state: MarketStateKind
        let state_score: Int
        let previous_state_score: Int?
        let state_score_change: Int?
        let seller_pressure: Int
        let seller_pressure_change: Int?
        let buyer_pressure: Int
        let buyer_pressure_change: Int?
        let seller_efficiency: Int
        let seller_efficiency_change: Int?
        let buyer_efficiency: Int
        let buyer_efficiency_change: Int?
        let downside_response: Int
        let downside_response_change: Int?
        let upside_response: Int
        let upside_response_change: Int?
        let buy_side_absorption: Int
        let buy_side_absorption_change: Int?
        let sell_side_absorption: Int
        let sell_side_absorption_change: Int?
        let bullish_confirmation: Int
        let bullish_confirmation_change: Int?
        let bearish_confirmation: Int
        let bearish_confirmation_change: Int?
        let bounce_readiness: Int
        let bounce_readiness_change: Int?
        let rollover_readiness: Int
        let rollover_readiness_change: Int?
        let buyer_resilience: Int
        let buyer_resilience_change: Int?
        let seller_resilience: Int
        let seller_resilience_change: Int?
        let seller_efficiency_trend: Int
        let buyer_efficiency_trend: Int
        let seller_pressure_trend: Int
        let buyer_pressure_trend: Int
        let state_since: Date
        let candle_close_time: Date
        let scoring_version: String
        let market_context: MarketBehaviorContext?
        let behavioral_scores: BehavioralStateScores?
        let behavioral_signals: [BehavioralSignal]?
        let symbols: Symbol

        var snapshot: MarketStateSnapshot {
            MarketStateSnapshot(
                state: state,
                stateScore: state_score,
                previousStateScore: previous_state_score,
                stateScoreChange: state_score_change,
                sellerPressure: seller_pressure,
                sellerPressureChange: seller_pressure_change,
                buyerPressure: buyer_pressure,
                buyerPressureChange: buyer_pressure_change,
                sellerEfficiency: seller_efficiency,
                sellerEfficiencyChange: seller_efficiency_change,
                buyerEfficiency: buyer_efficiency,
                buyerEfficiencyChange: buyer_efficiency_change,
                downsideResponse: downside_response,
                downsideResponseChange: downside_response_change,
                upsideResponse: upside_response,
                upsideResponseChange: upside_response_change,
                buySideAbsorption: buy_side_absorption,
                buySideAbsorptionChange: buy_side_absorption_change,
                sellSideAbsorption: sell_side_absorption,
                sellSideAbsorptionChange: sell_side_absorption_change,
                bullishConfirmation: bullish_confirmation,
                bullishConfirmationChange: bullish_confirmation_change,
                bearishConfirmation: bearish_confirmation,
                bearishConfirmationChange: bearish_confirmation_change,
                bounceReadiness: bounce_readiness,
                bounceReadinessChange: bounce_readiness_change,
                rolloverReadiness: rollover_readiness,
                rolloverReadinessChange: rollover_readiness_change,
                buyerResilience: buyer_resilience,
                buyerResilienceChange: buyer_resilience_change,
                sellerResilience: seller_resilience,
                sellerResilienceChange: seller_resilience_change,
                context: market_context ?? .unavailable,
                behavioralScores: behavioral_scores ?? .empty,
                behavioralSignals: behavioral_signals ?? [],
                sellerEfficiencyTrend: seller_efficiency_trend,
                buyerEfficiencyTrend: buyer_efficiency_trend,
                sellerPressureTrend: seller_pressure_trend,
                buyerPressureTrend: buyer_pressure_trend,
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
            .init(name: "select", value: Self.selectColumns),
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
        // A row whose state this build does not know is skipped rather than
        // failing the whole list, so a server-side vocabulary change degrades
        // to a missing coin instead of an empty screen.
        return Dictionary(uniqueKeysWithValues: try decoder.decode([TolerantRow].self, from: data)
            .compactMap(\.row)
            .map { ($0.symbols.symbol, $0.snapshot) })
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
