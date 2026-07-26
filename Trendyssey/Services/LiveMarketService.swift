import Foundation

struct LiveMarketService: MarketService {
    private struct ActiveSymbol: Decodable {
        let id: UUID
        let symbol: String
        let base_asset: String
        let icon_url: String?
        let current_price: Double?
        let price_change_percent_24h: Double?
        let quote_volume_24h: Double?
    }
    private struct Row: Decodable {
        struct Symbol: Decodable {
            let symbol: String
            let base_asset: String
            let icon_url: String?
            let current_price: Double?
            let price_change_percent_24h: Double?
            let quote_volume_24h: Double?
        }
        let id: UUID
        let journey_id: UUID?
        let status: String
        let signal_price: Double
        let signal_time: Date
        let breakout_confidence_score: Int
        let false_breakout_risk: Int
        let market_activity_score: Int
        let volume_ratio: Double?
        let estimated_volume_delta: Double?
        let taker_buy_ratio: Double?
        let explanation: String
        let explanation_facts: SignalEvidence?
        let symbols: Symbol
    }

    // The server sweeps the whole enabled universe, so no client-side cap:
    // every coin with a signal row shows its server phase and score.
    func overview() async throws -> MarketOverview {
        try await loadSignals(includeWatching: true, universeLimit: nil)
    }
    func allSymbols() async throws -> [MarketSignal] {
        let analyzed = try await loadSignals(includeWatching: true, universeLimit: nil).signals
        let bySymbol = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.symbol, $0) })
        return try await activeSymbols().map { symbol in
            bySymbol[symbol.symbol] ?? MarketSignal(id: symbol.id, symbol: symbol.symbol, name: symbol.base_asset, iconURL: symbol.icon_url, price: symbol.current_price ?? 0, change24h: symbol.price_change_percent_24h ?? 0, quoteVolume24h: symbol.quote_volume_24h ?? 0, confidence: 0, falseBreakoutRisk: 100, activityScore: 0, volumeRatio: 0, takerBuyRatio: 0.5, estimatedDelta: 0, status: .watching, signalDate: .distantPast, explanation: L10n.text("Insufficient volume or candle history for a reliable score. You can still add this coin to favorites.", "Güvenilir bir skor için hacim veya mum geçmişi yetersiz. Bu coini yine de favorilere ekleyebilirsin."), hasScore: false)
        }
    }

    private func loadSignals(includeWatching: Bool, universeLimit: Int?) async throws -> MarketOverview {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/breakout_signals"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,journey_id,status,signal_price,signal_time,breakout_confidence_score,false_breakout_risk,market_activity_score,volume_ratio,estimated_volume_delta,taker_buy_ratio,explanation,explanation_facts,analysis_models!inner(slug),symbols(symbol,base_asset,icon_url,current_price,price_change_percent_24h,quote_volume_24h)"),
            .init(name: "order", value: "signal_time.desc"),
            .init(name: "timeframe", value: "eq.\(AnalysisTimeframe.selected.rawValue)"),
            .init(name: "analysis_models.slug", value: "eq.\(AnalysisModelSelection.selectedSlug)"),
            .init(name: "limit", value: "1000")
        ]
        let request = try await authenticatedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let rows = try decoder.decode([Row].self, from: data)
        // Dashboard averages are narrowed to the top 50 in the view.
        let active = try await activeSymbols()
        let selectedUniverse = universeLimit.map { Array(active.prefix($0)) } ?? active
        let universe = Set(selectedUniverse.map(\.symbol))
        let mapped = rows.filter { universe.contains($0.symbols.symbol) }.map { row in
            MarketSignal(id: row.id, journeyID: row.journey_id, symbol: row.symbols.symbol, name: row.symbols.base_asset, iconURL: row.symbols.icon_url, price: row.symbols.current_price ?? row.signal_price, change24h: row.symbols.price_change_percent_24h ?? 0, quoteVolume24h: row.symbols.quote_volume_24h ?? 0, confidence: row.breakout_confidence_score, falseBreakoutRisk: row.false_breakout_risk, activityScore: row.market_activity_score, volumeRatio: row.volume_ratio ?? 0, takerBuyRatio: row.taker_buy_ratio ?? 0.5, estimatedDelta: row.estimated_volume_delta ?? 0, status: status(row.status), signalDate: row.signal_time, explanation: row.explanation, evidence: row.explanation_facts)
        }
        var seenSymbols = Set<String>()
        let signals = mapped
            .filter { seenSymbols.insert($0.symbol).inserted }
            .filter { signal in
                if includeWatching { return true }
                switch signal.status {
                case .preBreakout, .breakoutDetected, .confirmed, .retest: return true
                case .watching, .failed, .expired: return false
                }
            }
            .sorted { lhs, rhs in
                if lhs.activityScore == rhs.activityScore { return lhs.symbol < rhs.symbol }
                return lhs.activityScore > rhs.activityScore
            }
        return MarketOverview(scannedCount: signals.count, newSignalCount: signals.filter { $0.status == .breakoutDetected || $0.status == .confirmed }.count, lowRiskCount: signals.filter { $0.falseBreakoutRisk <= 30 }.count, signals: signals)
    }

    private func activeSymbols() async throws -> [ActiveSymbol] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/symbols"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,symbol,base_asset,icon_url,current_price,price_change_percent_24h,quote_volume_24h"),
            .init(name: "is_enabled", value: "eq.true"),
            .init(name: "quote_asset", value: "eq.USDT"),
            .init(name: "order", value: "quote_volume_24h.desc"),
            .init(name: "limit", value: "1000")
        ]
        let request = try await authenticatedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([ActiveSymbol].self, from: data)
            .filter { CryptoAssetUniverse.includes(baseAsset: $0.base_asset) }
    }

    private func authenticatedRequest(url: URL) async throws -> URLRequest {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func status(_ value: String) -> SignalStatus {
        switch value {
        case "pre_breakout": .preBreakout
        case "breakout_detected": .breakoutDetected
        case "confirmed": .confirmed
        case "retest": .retest
        case "failed": .failed
        case "expired": .expired
        default: .watching
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Geçersiz ISO-8601 tarihi") }
        return date
    }
}
