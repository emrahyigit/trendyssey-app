import Foundation

actor NotificationService {
    private struct Row: Decodable {
        struct Signal: Decodable {
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
            let signal_time: String
            let breakout_confidence_score: Int
            let regime_score: Int?
            let readiness_score: Int?
            let breakout_quality_score: Int?
            let confirmation_score: Int?
            let breakout_triggered: Bool?
            let false_breakout_risk: Int
            let market_activity_score: Int
            let volume_ratio: Double?
            let estimated_volume_delta: Double?
            let taker_buy_ratio: Double?
            let explanation: String
            let explanation_facts: SignalEvidence?
            let symbols: Symbol
        }

        let id: UUID
        let title: String
        let body: String
        let status: AppNotificationStatus
        let signal_status: String?
        let created_at: String
        let breakout_signals: Signal?
    }

    func notifications() async throws -> [AppNotification] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,title,body,status,signal_status,created_at,breakout_signals(id,journey_id,status,signal_price,signal_time,breakout_confidence_score,regime_score,readiness_score,breakout_quality_score,confirmation_score,breakout_triggered,false_breakout_risk,market_activity_score,volume_ratio,estimated_volume_delta,taker_buy_ratio,explanation,explanation_facts,symbols(symbol,base_asset,icon_url,current_price,price_change_percent_24h,quote_volume_24h))"),
            .init(name: "notification_type", value: "eq.breakout_signal"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: "100"),
        ]
        let request = try await authenticatedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode([Row].self, from: data).compactMap(map)
    }

    func mark(_ id: UUID, as status: AppNotificationStatus) async throws {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")]
        var request = try await authenticatedRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        var body: [String: String] = ["status": status.rawValue]
        if status == .read || status == .opened { body["read_at"] = ISO8601DateFormatter().string(from: .now) }
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func markAllRead() async throws {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "status", value: "eq.unread"),
            .init(name: "notification_type", value: "eq.breakout_signal"),
        ]
        var request = try await authenticatedRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([
            "status": AppNotificationStatus.read.rawValue,
            "read_at": ISO8601DateFormatter().string(from: .now),
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func authenticatedRequest(url: URL) async throws -> URLRequest {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }

    private func map(_ row: Row) -> AppNotification? {
        guard let createdAt = Self.date(row.created_at) else { return nil }
        if let signal = row.breakout_signals,
           !CryptoAssetUniverse.includes(baseAsset: signal.symbols.base_asset) {
            return nil
        }
        return AppNotification(
            id: row.id,
            title: row.title,
            body: row.body,
            status: row.status,
            createdAt: createdAt,
            signalStatus: row.signal_status.map(Self.status),
            signal: row.breakout_signals.flatMap(Self.marketSignal)
        )
    }

    private static func marketSignal(_ row: Row.Signal) -> MarketSignal? {
        guard let signalDate = date(row.signal_time) else { return nil }
        return MarketSignal(
            id: row.id,
            journeyID: row.journey_id,
            symbol: row.symbols.symbol,
            name: row.symbols.base_asset,
            iconURL: row.symbols.icon_url,
            price: row.symbols.current_price ?? row.signal_price,
            change24h: row.symbols.price_change_percent_24h ?? 0,
            quoteVolume24h: row.symbols.quote_volume_24h ?? 0,
            confidence: row.breakout_quality_score ?? row.breakout_confidence_score,
            regimeScore: row.regime_score ?? row.explanation_facts?.scoreLayers?.regimeScore ?? 0,
            readinessScore: row.readiness_score ?? row.explanation_facts?.scoreLayers?.readinessScore ?? 0,
            breakoutQualityScore: row.breakout_quality_score ?? row.breakout_confidence_score,
            confirmationScore: row.confirmation_score ?? row.explanation_facts?.scoreLayers?.confirmationScore ?? 0,
            breakoutTriggered: row.breakout_triggered ?? row.explanation_facts?.scoreLayers?.breakoutTriggered ?? false,
            falseBreakoutRisk: row.false_breakout_risk,
            activityScore: row.market_activity_score,
            volumeRatio: row.volume_ratio ?? 0,
            takerBuyRatio: row.taker_buy_ratio ?? 0.5,
            estimatedDelta: row.estimated_volume_delta ?? 0,
            status: status(row.status),
            signalDate: signalDate,
            explanation: row.explanation,
            evidence: row.explanation_facts
        )
    }

    private static func status(_ value: String) -> SignalStatus {
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

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
