import Foundation

struct PredictionTally: Sendable {
    var holds: Int
    var fails: Int
    var mine: String?
}

struct PredictionAccuracy: Sendable {
    let userID: UUID
    let resolvedCount: Int
    let correctCount: Int

    var accuracyPercent: Int {
        guard resolvedCount > 0 else { return 0 }
        return Int((Double(correctCount) / Double(resolvedCount) * 100).rounded())
    }
}

struct TopPredictor: Identifiable, Sendable {
    let userID: UUID
    let displayName: String
    let avatarKey: String?
    let position: Int
    let totalScore: Double
    let predictionCount: Int
    let isCurrentUser: Bool

    var id: UUID { userID }
}

enum DailyPredictionDirection: String, Codable, CaseIterable, Sendable {
    case up, down

    var title: String {
        switch self {
        case .up: L10n.text("Will rise", "Yükselecek")
        case .down: L10n.text("Will fall", "Düşecek")
        }
    }

    var systemImage: String { self == .up ? "arrow.up.right" : "arrow.down.right" }
}

struct DailyPredictionSymbol: Identifiable, Sendable {
    let symbolID: UUID
    let symbol: String
    let currentPrice: Double
    let quoteVolume24h: Double

    var id: UUID { symbolID }
    var baseAsset: String { symbol.replacingOccurrences(of: "USDT", with: "") }
}

struct PredictorDailyCall: Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let direction: DailyPredictionDirection
    let entryPrice: Double
    let markPrice: Double
    let priceChangePercent: Double
    let points: Double
    let predictedAt: Date
    let evaluationEndsAt: Date
    let isResolved: Bool
}

/// "Tutar mı?" predictions on breakout journeys plus per-user accuracy stats
/// used for the chat badges. A prediction resolves against the first
/// confirmed/failed journey event that closes after it.
actor SignalPredictionService {
    static let minimumResolvedForBadge = 5

    private struct PredictionRow: Decodable {
        let user_id: UUID
        let prediction: String
    }

    private struct AccuracyRow: Decodable {
        let user_id: UUID
        let resolved_count: Int
        let correct_count: Int
    }

    func tally(journeyID: UUID) async throws -> PredictionTally {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_predictions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "user_id,prediction"),
            .init(name: "journey_id", value: "eq.\(journeyID.uuidString.lowercased())"),
            .init(name: "limit", value: "1000"),
        ]
        let rows = try await get([PredictionRow].self, url: components.url!)
        let account = await UserSyncService.shared.accountSnapshot()
        return PredictionTally(
            holds: rows.filter { $0.prediction == "holds" }.count,
            fails: rows.filter { $0.prediction == "fails" }.count,
            mine: account.id.flatMap { id in rows.first { $0.user_id == id }?.prediction }
        )
    }

    func submit(journeyID: UUID, symbol: String, timeframe: String, holds: Bool) async throws {
        let account = await UserSyncService.shared.accountSnapshot()
        guard let userID = account.id, !account.isAnonymous else { throw PredictionError.appleAccountRequired }
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_predictions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": userID.uuidString,
            "symbol": symbol.uppercased(),
            "journey_id": journeyID.uuidString.lowercased(),
            "timeframe": timeframe,
            "prediction": holds ? "holds" : "fails",
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PredictionError.requestFailed }
        if http.statusCode == 409 { throw PredictionError.alreadyPredicted }
        guard 200..<300 ~= http.statusCode else { throw PredictionError.requestFailed }
    }

    private struct TopPredictorRow: Decodable {
        let rank_position: Int
        let user_id: UUID
        let display_name: String
        let avatar_key: String?
        let total_score: Double
        let prediction_count: Int
        let is_current_user: Bool
    }

    private struct DailyCallRow: Decodable {
        let id: UUID
        let symbol: String
        let direction: DailyPredictionDirection
        let entry_price: Double
        let mark_price: Double
        let price_change_percent: Double
        let points: Double
        let predicted_at: String
        let evaluation_ends_at: String
        let is_resolved: Bool
    }

    private struct PredictionSymbolRow: Decodable {
        let symbol_id: UUID
        let symbol: String
        let current_price: Double
        let quote_volume_24h: Double
    }

    /// Returns the top rows plus the signed-in user when they sit outside the
    /// requested limit. Every participant begins at 100 points.
    func topPredictors(limit: Int = 10) async throws -> [TopPredictor] {
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_daily_predictor_leaderboard"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_limit": limit])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw PredictionError.requestFailed }
        return try JSONDecoder().decode([TopPredictorRow].self, from: data).map { row in
            TopPredictor(
                userID: row.user_id,
                displayName: row.display_name,
                avatarKey: row.avatar_key,
                position: row.rank_position,
                totalScore: row.total_score,
                predictionCount: row.prediction_count,
                isCurrentUser: row.is_current_user
            )
        }
    }

    func dailyCalls(userID: UUID, day: Date = .now) async throws -> [PredictorDailyCall] {
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_predictor_daily_calls"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "p_user_id": userID.uuidString.lowercased(),
            "p_day": Self.utcDay.string(from: day)
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PredictionError.requestFailed
        }
        return try JSONDecoder().decode([DailyCallRow].self, from: data).compactMap { row in
            guard let predictedAt = Self.date(row.predicted_at),
                  let evaluationEndsAt = Self.date(row.evaluation_ends_at) else { return nil }
            return PredictorDailyCall(
                id: row.id,
                symbol: row.symbol,
                direction: row.direction,
                entryPrice: row.entry_price,
                markPrice: row.mark_price,
                priceChangePercent: row.price_change_percent,
                points: row.points,
                predictedAt: predictedAt,
                evaluationEndsAt: evaluationEndsAt,
                isResolved: row.is_resolved
            )
        }
    }

    func predictionSymbols(limit: Int = 100) async throws -> [DailyPredictionSymbol] {
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_daily_prediction_symbols"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_limit": limit])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PredictionError.requestFailed
        }
        return try JSONDecoder().decode([PredictionSymbolRow].self, from: data).map {
            DailyPredictionSymbol(
                symbolID: $0.symbol_id,
                symbol: $0.symbol,
                currentPrice: $0.current_price,
                quoteVolume24h: $0.quote_volume_24h
            )
        }
    }

    func submitDaily(symbol: String, direction: DailyPredictionDirection) async throws {
        let account = await UserSyncService.shared.accountSnapshot()
        guard account.id != nil, !account.isAnonymous else {
            throw PredictionError.appleAccountRequired
        }
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "functions/v1/daily-prediction"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "symbol": symbol.uppercased(),
            "direction": direction.rawValue
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PredictionError.requestFailed }
        if http.statusCode == 409 { throw PredictionError.alreadyPredicted }
        if http.statusCode == 403 { throw PredictionError.appleAccountRequired }
        guard 200..<300 ~= http.statusCode else { throw PredictionError.requestFailed }
    }

    /// Every prediction on a journey, so screens can weigh them by predictor.
    func journeyPredictions(journeyID: UUID) async throws -> [(userID: UUID, holds: Bool)] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_predictions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "user_id,prediction"),
            .init(name: "journey_id", value: "eq.\(journeyID.uuidString.lowercased())"),
            .init(name: "limit", value: "1000"),
        ]
        return try await get([PredictionRow].self, url: components.url!).map { ($0.user_id, $0.prediction == "holds") }
    }

    func accuracies(userIDs: [UUID]) async throws -> [UUID: PredictionAccuracy] {
        guard !userIDs.isEmpty else { return [:] }
        let list = Set(userIDs).map { $0.uuidString.lowercased() }.joined(separator: ",")
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/prediction_accuracy"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "user_id,resolved_count,correct_count"),
            .init(name: "user_id", value: "in.(\(list))"),
        ]
        let rows = try await get([AccuracyRow].self, url: components.url!)
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.user_id, PredictionAccuracy(userID: $0.user_id, resolvedCount: $0.resolved_count, correctCount: $0.correct_count))
        })
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let request = try await authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw PredictionError.requestFailed }
        return try JSONDecoder().decode(type, from: data)
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let utcDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    enum PredictionError: Error { case appleAccountRequired, alreadyPredicted, requestFailed }
}
