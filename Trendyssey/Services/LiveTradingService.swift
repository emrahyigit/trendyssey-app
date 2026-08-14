import Foundation

/// One row of the executor's ledger — every order the testnet (or live)
/// trader touched, as written by the trade-executor edge function.
struct LiveTrade: Identifiable, Decodable, Sendable {
    let id: UUID
    let symbol: String
    let status: String
    let entryTriggerPrice: Double?
    let entryPrice: Double?
    let entryQuantity: Double?
    let enteredAt: Date?
    let targetPrice: Double?
    let stopPrice: Double?
    let exitPrice: Double?
    let exitReason: String?
    let exitedAt: Date?
    let realizedQuotePnl: Double?
    let errorMessage: String?
    let isTestnet: Bool
    let createdAt: Date
    /// Decision-time snapshot, frozen by the executor when it acted.
    let signalPrice: Double?
    let entryStrength: Int?
    let entrySuccessRate: Int?
    let entryQuoteVolume: Double?
    let entryTrendScore: Int?
    let entryMarketState: MarketStateKind?
    let entryMarketStateScore: Int?
    let entryMarketStateChange: Int?

    var returnPercent: Double? {
        guard let entryPrice, let exitPrice, entryPrice > 0 else { return nil }
        return (exitPrice - entryPrice) / entryPrice * 100
    }

    /// Mark-to-market profit for an open position at the given price.
    func unrealizedPnl(currentPrice: Double?) -> Double? {
        guard status == "open", let entryPrice, let entryQuantity, let currentPrice else { return nil }
        return (currentPrice - entryPrice) * entryQuantity
    }
}

/// The single-row executor configuration, read-only for the app.
struct TradeExecutorConfig: Decodable, Sendable {
    let enabled: Bool
    let useTestnet: Bool
    let timeframe: String
    let entryTriggerPercent: Double
    let profitTargetPercent: Double
    let stopLossPercent: Double
    let maxOpenHours: Int
    let maxSlots: Int
    let quotePerTrade: Double
    let minimumSignalStrength: Int
    let minimumSuccessRate: Int
    let minimumQuoteVolume: Double
    /// Nil until the trader trend-filter migration lands server-side.
    let minimumTrendScore: Int?
    let requireTrendEntry: Bool?
    let allowedMarketStates: [MarketStateKind]?
    let minimumStateScore: Int?
    /// Nil until the chandelier-exit migration lands server-side.
    let useChandelierExit: Bool?
    let chandelierAtrMultiplier: Double?
    let resetRequested: Bool
}

actor LiveTradingService {
    static let shared = LiveTradingService()

    func config() async throws -> TradeExecutorConfig? {
        let baseColumns = "enabled,use_testnet,timeframe,entry_trigger_percent,profit_target_percent,stop_loss_percent,max_open_hours,max_slots,quote_per_trade,minimum_signal_strength,minimum_success_rate,minimum_quote_volume,reset_requested"
        // The trend and chandelier columns each ship in their own migration;
        // until one lands its select 400s, so fall back column set by column
        // set rather than blanking the page.
        let columnSets = [
            baseColumns + ",minimum_trend_score,require_trend_entry,use_chandelier_exit,chandelier_atr_multiplier,allowed_market_states,minimum_state_score",
            baseColumns + ",minimum_trend_score,require_trend_entry,use_chandelier_exit,chandelier_atr_multiplier,allowed_market_states",
            baseColumns + ",minimum_trend_score,require_trend_entry,use_chandelier_exit,chandelier_atr_multiplier",
            baseColumns + ",minimum_trend_score,require_trend_entry",
            baseColumns,
        ]
        for (index, columns) in columnSets.enumerated() {
            do {
                let rows: [TradeExecutorConfig] = try await fetch(
                    path: "rest/v1/trade_config",
                    query: [.init(name: "select", value: columns)]
                )
                return rows.first
            } catch {
                if index == columnSets.count - 1 { throw error }
            }
        }
        return nil
    }

    func trades(limit: Int = 100) async throws -> [LiveTrade] {
        let baseColumns = "id,symbol,status,entry_trigger_price,entry_price,entry_quantity,entered_at,target_price,stop_price,exit_price,exit_reason,exited_at,realized_quote_pnl,error_message,is_testnet,created_at,signal_price,entry_strength,entry_success_rate,entry_quote_volume"
        let query: (String) -> [URLQueryItem] = { columns in
            [
                .init(name: "select", value: columns),
                .init(name: "order", value: "created_at.desc"),
                .init(name: "limit", value: "\(limit)"),
            ]
        }
        do {
            return try await fetch(path: "rest/v1/live_trades", query: query(baseColumns + ",entry_trend_score,entry_market_state,entry_market_state_score,entry_market_state_change"))
        } catch {
            do {
                return try await fetch(path: "rest/v1/live_trades", query: query(baseColumns + ",entry_trend_score"))
            } catch {
                return try await fetch(path: "rest/v1/live_trades", query: query(baseColumns))
            }
        }
    }

    /// Live prices for the given tickers, for mark-to-market on open trades.
    func currentPrices(symbols: [String]) async throws -> [String: Double] {
        guard !symbols.isEmpty else { return [:] }
        struct Row: Decodable {
            let symbol: String
            let currentPrice: Double?
        }
        let rows: [Row] = try await fetch(
            path: "rest/v1/symbols",
            query: [
                .init(name: "select", value: "symbol,current_price"),
                .init(name: "symbol", value: "in.(\(symbols.joined(separator: ",")))"),
            ]
        )
        return rows.reduce(into: [:]) { $0[$1.symbol] = $1.currentPrice }
    }

    /// Pushes the Breakout Scenario parameters into the executor's config.
    func applyScenarioParameters(
        profitTargetPercent: Double,
        stopLossPercent: Double,
        maxOpenHours: Int,
        maxSlots: Int,
        minimumSignalStrength: Int,
        minimumSuccessRate: Int,
        minimumQuoteVolume: Double,
        allowedMarketStates: [MarketStateKind],
        minimumStateScore: Int,
        useChandelierExit: Bool,
        chandelierAtrMultiplier: Double,
        timeframe: String,
        modelSlug: String
    ) async throws {
        var body: [String: Any] = [
            "p_entry_trigger_percent": 0,
            "p_profit_target_percent": profitTargetPercent,
            "p_stop_loss_percent": stopLossPercent,
            "p_max_open_hours": maxOpenHours,
            "p_max_slots": maxSlots,
            "p_minimum_signal_strength": minimumSignalStrength,
            "p_minimum_success_rate": minimumSuccessRate,
            "p_minimum_quote_volume": minimumQuoteVolume,
            "p_minimum_trend_score": 0,
            "p_require_trend_entry": false,
            "p_use_chandelier_exit": useChandelierExit,
            "p_chandelier_atr_multiplier": chandelierAtrMultiplier,
            "p_timeframe": timeframe,
            "p_model_slug": modelSlug,
        ]
        do {
            try await rpc("update_trade_config", body: body)
        } catch {
            // Older servers only know the shorter signatures; peel the newest
            // parameters off one migration at a time and apply what remains.
            body.removeValue(forKey: "p_use_chandelier_exit")
            body.removeValue(forKey: "p_chandelier_atr_multiplier")
            do {
                try await rpc("update_trade_config", body: body)
            } catch {
                body.removeValue(forKey: "p_minimum_trend_score")
                body.removeValue(forKey: "p_require_trend_entry")
                try await rpc("update_trade_config", body: body)
            }
        }
        try await rpc(
            "update_trade_market_state_rules",
            body: [
                "p_allowed_market_states": allowedMarketStates.map(\.rawValue),
                "p_minimum_state_score": minimumStateScore,
            ]
        )
    }

    /// Asks the executor to unwind every position and wipe its ledger on the
    /// next minute tick. The app never talks to the exchange itself.
    func requestReset() async throws {
        try await rpc("request_auto_trader_reset", body: [:])
    }

    private func rpc(_ name: String, body: [String: Any]) async throws {
        let url = SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/\(name)")
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }

    private func fetch<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date: \(value)"))
        }
        return try decoder.decode(T.self, from: data)
    }
}
