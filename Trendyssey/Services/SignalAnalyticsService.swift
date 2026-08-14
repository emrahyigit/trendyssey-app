import Foundation

struct SignalJourneyEvent: Identifiable, Sendable {
    let id: UUID
    let status: SignalStatus
    let candleCloseTime: Date
    let price: Double
    let confidence: Int
    let falseBreakoutRisk: Int
    let volumeRatio: Double
}

struct SignalOutcomeSnapshot: Identifiable, Sendable {
    enum Outcome: String, Sendable { case win, flat, loss }
    enum State: String, Sendable { case pending, evaluated, unavailable }

    let id: UUID
    let horizonCandles: Int
    let state: State
    let returnPercent: Double?
    let favorablePercent: Double?
    let adversePercent: Double?
    let heldAboveBreakout: Bool?
    let outcome: Outcome?
}

actor SignalAnalyticsService {
    private struct JourneyRow: Decodable {
        let id: UUID
        let status: String
        let candle_close_time: String
        let price: Double
        let confidence: Int
        let false_breakout_risk: Int
        let volume_ratio: Double?
    }

    private struct OutcomeRow: Decodable {
        let id: UUID
        let horizon_candles: Int
        let status: String
        let return_percent: Double?
        let max_favorable_excursion_percent: Double?
        let max_adverse_excursion_percent: Double?
        let held_above_breakout: Bool?
        let outcome_label: String?
    }

    func journey(id: UUID?) async throws -> [SignalJourneyEvent] {
        guard let id else { return [] }
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_journey_events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,status,candle_close_time,price,confidence,false_breakout_risk,volume_ratio"),
            .init(name: "journey_id", value: "eq.\(id.uuidString.lowercased())"),
            .init(name: "order", value: "candle_close_time.asc,created_at.asc"),
        ]
        let rows = try await get([JourneyRow].self, url: components.url!)
        return rows.compactMap { row in
            guard let date = Self.date(row.candle_close_time) else { return nil }
            return SignalJourneyEvent(
                id: row.id,
                status: Self.status(row.status),
                candleCloseTime: date,
                price: row.price,
                confidence: row.confidence,
                falseBreakoutRisk: row.false_breakout_risk,
                volumeRatio: row.volume_ratio ?? 0
            )
        }
    }

    func outcomes(journeyID: UUID?) async throws -> [SignalOutcomeSnapshot] {
        guard let journeyID else { return [] }
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_outcome_snapshots"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,horizon_candles,status,return_percent,max_favorable_excursion_percent,max_adverse_excursion_percent,held_above_breakout,outcome_label"),
            .init(name: "journey_id", value: "eq.\(journeyID.uuidString.lowercased())"),
            .init(name: "order", value: "horizon_candles.asc"),
        ]
        return try await get([OutcomeRow].self, url: components.url!).map { row in
            SignalOutcomeSnapshot(
                id: row.id,
                horizonCandles: row.horizon_candles,
                state: SignalOutcomeSnapshot.State(rawValue: row.status) ?? .pending,
                returnPercent: row.return_percent,
                favorablePercent: row.max_favorable_excursion_percent,
                adversePercent: row.max_adverse_excursion_percent,
                heldAboveBreakout: row.held_above_breakout,
                outcome: row.outcome_label.flatMap(SignalOutcomeSnapshot.Outcome.init(rawValue:))
            )
        }
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
}
