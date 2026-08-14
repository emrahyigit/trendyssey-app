import Foundation

actor NotificationService {
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
        let title: String
        let body: String
        let status: AppNotificationStatus
        let created_at: String
        let market_state: MarketStateKind?
        let market_state_score: Int?
        let market_state_change: Int?
        let symbols: Symbol?
    }

    func notifications() async throws -> [AppNotification] {
        var components = URLComponents(
            url: SupabaseConfig.projectURL.appending(path: "rest/v1/notifications"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "select", value: "id,title,body,status,created_at,market_state,market_state_score,market_state_change,symbols(symbol,base_asset,icon_url,current_price,price_change_percent_24h,quote_volume_24h)"),
            .init(name: "notification_type", value: "eq.market_state"),
            .init(name: "order", value: "created_at.desc"),
            .init(name: "limit", value: "100"),
        ]
        let request = try await authenticatedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let timeframe = UserDefaults.standard.string(forKey: "preferredTimeframe") ?? "15m"
        let marketStates = (try? await MarketStateService.shared.snapshots(timeframe: timeframe)) ?? [:]
        return rows.compactMap { map($0, marketStates: marketStates) }
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
            .init(name: "notification_type", value: "eq.market_state"),
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

    private func map(_ row: Row, marketStates: [String: MarketStateSnapshot]) -> AppNotification? {
        guard let createdAt = Self.date(row.created_at) else { return nil }
        let signal = row.symbols.flatMap { symbol -> MarketSignal? in
            guard CryptoAssetUniverse.includes(baseAsset: symbol.base_asset) else { return nil }
            let state = marketStates[symbol.symbol]
            return MarketSignal(
                id: row.id,
                symbol: symbol.symbol,
                name: symbol.base_asset,
                iconURL: symbol.icon_url,
                price: symbol.current_price ?? 0,
                change24h: symbol.price_change_percent_24h ?? 0,
                quoteVolume24h: symbol.quote_volume_24h ?? 0,
                confidence: row.market_state_score ?? state?.stateScore ?? 0,
                falseBreakoutRisk: 0,
                activityScore: 0,
                volumeRatio: 0,
                takerBuyRatio: 0.5,
                estimatedDelta: 0,
                signalDate: createdAt,
                explanation: row.body,
                marketState: state
            )
        }
        return AppNotification(
            id: row.id,
            title: row.title,
            body: row.body,
            status: row.status,
            createdAt: createdAt,
            signal: signal
        )
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
