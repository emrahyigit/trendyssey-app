import Foundation

/// Assembles the coin-detail analysis purely from values the server has
/// already computed and stored. Nothing here derives anything: the phase and
/// score come from the signal row, the journey from recorded events, the EMA
/// overlay lines from per-candle indicator snapshots and the pattern levels
/// from the signal's evidence — so the detail page can never disagree with the
/// lists or the push notification that opened it.
actor ServerAnalysisService {
    static let shared = ServerAnalysisService()

    private struct SignalRow: Decodable {
        let symbol_id: UUID
        let status: String
        let breakout_confidence_score: Int
        let volume_ratio: Double?
        let breakout_level: Double?
        let explanation_facts: SignalEvidence?
    }

    private struct EventRow: Decodable {
        let status: String
        let candle_close_time: String
        let price: Double
    }

    private struct SnapshotRow: Decodable {
        let candle_close_time: String
        let ema_fast: Double?
        let ema_slow: Double?
        let ema_long: Double?
    }

    private struct ModelRow: Decodable {
        let id: UUID
    }

    private var modelIDs: [String: UUID] = [:]

    func analysis(for signal: MarketSignal, model: JourneyModel, candles: [PriceCandle]) async -> JourneyAnalysis? {
        guard signal.hasScore, !candles.isEmpty else { return nil }
        guard let row = try? await fetchSignalRow(id: signal.id) else { return nil }

        let events = (try? await fetchEvents(signalID: signal.id)) ?? []
        var series: [JourneySeries] = []
        var levels: [JourneyLevel] = []
        var markers: [JourneyMarker] = []

        switch model {
        case .emaCross:
            series = (try? await emaSeries(row: row, model: model, candles: candles)) ?? []
        case .doubleBottom, .doubleTop:
            let evidence = row.explanation_facts
            if let neckline = evidence?.neckline {
                levels.append(JourneyLevel(key: "neckline", title: L10n.text("Neckline", "Boyun çizgisi"), price: neckline))
            }
            if let first = evidence?.firstPivotPrice, let second = evidence?.secondPivotPrice {
                let base = model.direction == .bullish ? min(first, second) : max(first, second)
                levels.append(JourneyLevel(
                    key: "patternBase",
                    title: model.direction == .bullish ? L10n.text("Pattern base", "Formasyon tabanı") : L10n.text("Pattern top", "Formasyon tepesi"),
                    price: base
                ))
            }
            let bullish = model.direction == .bullish
            if let price = evidence?.firstPivotPrice, let time = Self.date(evidence?.firstPivotOpenTime) {
                markers.append(JourneyMarker(key: "first", title: bullish ? L10n.text("1st bottom", "1. dip") : L10n.text("1st top", "1. tepe"), time: time, price: price))
            }
            if let price = evidence?.neckline, let time = Self.date(evidence?.necklineOpenTime) {
                markers.append(JourneyMarker(key: "neck", title: L10n.text("Neckline", "Boyun çizgisi"), time: time, price: price))
            }
            if let price = evidence?.secondPivotPrice, let time = Self.date(evidence?.secondPivotOpenTime) {
                markers.append(JourneyMarker(key: "second", title: bullish ? L10n.text("2nd bottom", "2. dip") : L10n.text("2nd top", "2. tepe"), time: time, price: price))
            }
        }

        return JourneyAnalysis(
            model: model,
            candles: candles,
            series: series,
            levels: levels,
            markers: markers,
            events: events,
            currentPhase: Self.status(row.status),
            confidence: row.breakout_confidence_score,
            factors: factors(model: model, evidence: row.explanation_facts),
            volumeRatio: row.volume_ratio ?? signal.volumeRatio
        )
    }

    // MARK: - Server reads

    private func fetchSignalRow(id: UUID) async throws -> SignalRow? {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/breakout_signals"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "symbol_id,status,breakout_confidence_score,volume_ratio,breakout_level,explanation_facts"),
            .init(name: "id", value: "eq.\(id.uuidString)"),
            .init(name: "limit", value: "1"),
        ]
        return try await get([SignalRow].self, url: components.url!).first
    }

    private func fetchEvents(signalID: UUID) async throws -> [JourneyEvent] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/signal_journey_events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "status,candle_close_time,price"),
            .init(name: "breakout_signal_id", value: "eq.\(signalID.uuidString)"),
            .init(name: "order", value: "candle_close_time.desc"),
            .init(name: "limit", value: "60"),
        ]
        let rows = try await get([EventRow].self, url: components.url!)
        return rows.compactMap { row in
            guard let time = Self.date(row.candle_close_time) else { return nil }
            return JourneyEvent(status: Self.status(row.status), time: time, price: row.price)
        }.reversed()
    }

    /// EMA overlay values the scanner stored per closed candle, aligned
    /// index-by-index with the chart's candles.
    private func emaSeries(row: SignalRow, model: JourneyModel, candles: [PriceCandle]) async throws -> [JourneySeries] {
        guard let modelID = try await modelID(slug: model.serverSlug ?? AnalysisModelSelection.defaultSlug) else { return [] }
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/indicator_snapshots"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "candle_close_time,ema_fast,ema_slow,ema_long"),
            .init(name: "analysis_model_id", value: "eq.\(modelID.uuidString)"),
            .init(name: "symbol_id", value: "eq.\(row.symbol_id.uuidString)"),
            .init(name: "timeframe", value: "eq.\(AnalysisTimeframe.selected.rawValue)"),
            .init(name: "order", value: "candle_close_time.desc"),
            .init(name: "limit", value: "\(candles.count)"),
        ]
        let rows = try await get([SnapshotRow].self, url: components.url!)
        guard !rows.isEmpty else { return [] }
        var byCloseSecond: [Int: SnapshotRow] = [:]
        for snapshot in rows {
            if let time = Self.date(snapshot.candle_close_time) {
                byCloseSecond[Int(time.timeIntervalSince1970.rounded())] = snapshot
            }
        }
        func values(_ path: KeyPath<SnapshotRow, Double?>) -> [Double?] {
            candles.map { byCloseSecond[Int($0.closeTime.timeIntervalSince1970.rounded())]?[keyPath: path] }
        }
        let fast = values(\.ema_fast)
        let slow = values(\.ema_slow)
        let long = values(\.ema_long)
        var series: [JourneySeries] = []
        if fast.contains(where: { $0 != nil }) { series.append(JourneySeries(key: "ema7", title: "EMA 7", values: fast)) }
        if slow.contains(where: { $0 != nil }) { series.append(JourneySeries(key: "ema25", title: "EMA 25", values: slow)) }
        if long.contains(where: { $0 != nil }) { series.append(JourneySeries(key: "ema99", title: "EMA 99", values: long)) }
        return series
    }

    private func modelID(slug: String) async throws -> UUID? {
        if let cached = modelIDs[slug] { return cached }
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/analysis_models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id"),
            .init(name: "slug", value: "eq.\(slug)"),
            .init(name: "limit", value: "1"),
        ]
        guard let id = try await get([ModelRow].self, url: components.url!).first?.id else { return nil }
        modelIDs[slug] = id
        return id
    }

    // MARK: - Mapping

    /// "Why this score" rows, exactly as the server scored them.
    private func factors(model: JourneyModel, evidence: SignalEvidence?) -> [ConfidenceFactor] {
        switch model {
        case .emaCross:
            return (evidence?.scoreComponents ?? [])
                .filter { $0.metric == "confidence" }
                .map { component in
                    ConfidenceFactor(
                        key: component.key,
                        title: component.name,
                        detail: component.explanation,
                        score: Int(component.contribution.rounded()),
                        maxScore: Int(component.maximumScore.rounded())
                    )
                }
        case .doubleBottom, .doubleTop:
            return (evidence?.confidenceFactors ?? []).map { factor in
                let text = Self.patternFactorText(factor.key)
                return ConfidenceFactor(key: factor.key, title: text.title, detail: text.detail, score: factor.score, maxScore: factor.maxScore)
            }
        }
    }

    private static func patternFactorText(_ key: String) -> (title: String, detail: String) {
        switch key {
        case "symmetry":
            (L10n.text("Pivot symmetry", "Pivot simetrisi"), L10n.text("How closely the two pivots sit at the same level.", "İki pivotun aynı seviyeye ne kadar yakın olduğu."))
        case "depth":
            (L10n.text("Pattern depth", "Formasyon derinliği"), L10n.text("Distance between the neckline and the pivots.", "Boyun çizgisi ile pivotlar arasındaki mesafe."))
        case "breakout":
            (L10n.text("Breakout freshness", "Kırılım tazeliği"), L10n.text("How recently the neckline was broken.", "Boyun çizgisinin ne kadar yakın zamanda kırıldığı."))
        case "volume":
            (L10n.text("Volume support", "Hacim desteği"), L10n.text("Last closed candle against the 20-candle average volume.", "Son kapanan mumun 20 mum ortalama hacmine oranı."))
        case "retest":
            (L10n.text("Retest confirmation", "Yeniden test teyidi"), L10n.text("Whether the neckline held when price came back to it.", "Fiyat geri döndüğünde boyun çizgisinin tutup tutmadığı."))
        case "context":
            (L10n.text("Prior trend", "Önceki trend"), L10n.text("The size of the move the pattern is reversing.", "Formasyonun tersine çevirdiği hareketin büyüklüğü."))
        default:
            (key, "")
        }
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

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value)
    }
}
