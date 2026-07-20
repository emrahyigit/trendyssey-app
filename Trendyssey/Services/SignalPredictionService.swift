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

    enum PredictionError: Error { case appleAccountRequired, alreadyPredicted, requestFailed }
}
