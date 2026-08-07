import Foundation

/// Assembles the coin-detail analysis purely from values the server has
/// already computed and stored. Nothing here derives anything: the phase and
/// score come from the signal row, the journey from recorded events and pattern
/// levels from the signal's evidence. Live chart overlays are assembled
/// separately from the Binance candles currently visible on screen.
actor ServerAnalysisService {
    static let shared = ServerAnalysisService()

    private struct SignalRow: Decodable {
        let id: UUID
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

    func analysis(
        for signal: MarketSignal,
        model: JourneyModel,
        timeframe: String,
        candles: [PriceCandle]
    ) async -> JourneyAnalysis? {
        guard signal.hasScore, !candles.isEmpty else { return nil }
        // The row is resolved by symbol + selected model + timeframe, never by
        // the id the list happened to load. The list's signal belongs to the
        // model that was selected when it loaded; if the user switches models
        // and comes back, keying by that id would explain one model's score
        // with another model's evidence.
        guard let row = try? await fetchSignalRow(
            symbol: signal.symbol,
            modelSlug: model.serverSlug ?? AnalysisModelSelection.defaultSlug,
            timeframe: timeframe
        ) else { return nil }

        let events = (try? await fetchEvents(signalID: row.id)) ?? []
        let currentStatus = Self.status(row.status)
        let scoreLayers = row.explanation_facts?.scoreLayers
        let stageScore: Int = if let scoreLayers {
            switch currentStatus {
            case .watching, .preBreakout: scoreLayers.readinessScore
            case .breakoutDetected, .failed, .expired: scoreLayers.breakoutQualityScore
            case .confirmed, .retest: scoreLayers.confirmationScore
            }
        } else {
            row.breakout_confidence_score
        }
        let series: [JourneySeries] = []
        var levels: [JourneyLevel] = []
        var markers: [JourneyMarker] = []

        switch model {
        case .emaCross:
            break
        case .donchian20, .donchian50, .horizontalLevel, .consolidation:
            if let level = row.breakout_level {
                levels.append(JourneyLevel(
                    key: "breakoutLevel",
                    title: L10n.text("Breakout level", "Kırılım seviyesi"),
                    price: level
                ))
            }
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
            currentPhase: currentStatus,
            confidence: stageScore,
            factors: factors(model: model, evidence: row.explanation_facts),
            volumeRatio: row.volume_ratio ?? signal.volumeRatio,
            scoreLayers: scoreLayers,
            directionalFactors: directionalFactors(model: model, evidence: row.explanation_facts)
        )
    }

    // MARK: - Server reads

    private func fetchSignalRow(symbol: String, modelSlug: String, timeframe: String) async throws -> SignalRow? {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/breakout_signals"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,symbol_id,status,breakout_confidence_score,volume_ratio,breakout_level,explanation_facts,analysis_models!inner(slug),symbols!inner(symbol)"),
            .init(name: "symbols.symbol", value: "eq.\(symbol.uppercased())"),
            .init(name: "analysis_models.slug", value: "eq.\(modelSlug)"),
            .init(name: "timeframe", value: "eq.\(timeframe)"),
            .init(name: "order", value: "signal_time.desc"),
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

    // MARK: - Mapping

    /// "Why this score" rows, exactly as the server scored them. Both model
    /// families store the score's own ingredients in `confidenceFactors`, so
    /// the rows always sum to the score they explain.
    private func factors(model: JourneyModel, evidence: SignalEvidence?) -> [ConfidenceFactor] {
        let stored = evidence?.confidenceFactors ?? []
        switch model {
        case .emaCross:
            guard !stored.isEmpty else {
                // Rows written before the ingredient list existed: fall back to
                // the engine components until the next scan refreshes them.
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
            }
            return stored.map { factor in
                let text = Self.emaFactorText(factor.key)
                return ConfidenceFactor(key: factor.key, title: text.title, detail: text.detail, score: factor.score, maxScore: factor.maxScore)
            }
        case .donchian20, .donchian50, .horizontalLevel, .consolidation:
            if let scores = evidence?.scoreLayers {
                return [
                    ConfidenceFactor(key: "regime", title: L10n.text("Market regime", "Piyasa rejimi"), detail: L10n.text("How suitable the current trend regime is for a breakout strategy.", "Mevcut trend rejiminin breakout stratejisine ne kadar uygun olduğu."), score: scores.regimeScore, maxScore: 100),
                    ConfidenceFactor(key: "readiness", title: L10n.text("Breakout readiness", "Kırılım hazırlığı"), detail: L10n.text("Proximity, compression and repeated level tests before the trigger.", "Tetik öncesi seviyeye yakınlık, sıkışma ve tekrarlanan seviye testleri."), score: scores.readinessScore, maxScore: 100),
                    ConfidenceFactor(key: "quality", title: L10n.text("Breakout quality", "Kırılım kalitesi"), detail: L10n.text("Closed-candle clearance, volume, candle quality, trend and market alignment, reduced by any bearish deductions.", "Kapanış mesafesi, hacim, mum kalitesi, trend ve piyasa uyumu; ayı yönlü kesintilerle düşürülür."), score: scores.breakoutQualityScore, maxScore: 100),
                    ConfidenceFactor(key: "confirmation", title: L10n.text("Post-breakout confirmation", "Kırılım sonrası teyit"), detail: L10n.text("Holding the level, retest and continuation after the trigger.", "Tetik sonrası seviyeyi koruma, retest ve devam hareketi."), score: scores.confirmationScore, maxScore: 100),
                ]
            }
            return []
        case .doubleBottom, .doubleTop:
            if let scores = evidence?.scoreLayers {
                return [
                    ConfidenceFactor(key: "regime", title: L10n.text("Reversal regime", "Dönüş rejimi"), detail: L10n.text("Prior move and directional alignment with the broader market.", "Önceki hareket ve geniş piyasa ile yönsel uyum."), score: scores.regimeScore, maxScore: 100),
                    ConfidenceFactor(key: "readiness", title: L10n.text("Pattern readiness", "Formasyon hazırlığı"), detail: L10n.text("Pivot symmetry, depth, context and proximity to the neckline before the trigger.", "Tetik öncesi pivot simetrisi, derinlik, bağlam ve boyun çizgisine yakınlık."), score: scores.readinessScore, maxScore: 100),
                    ConfidenceFactor(key: "quality", title: L10n.text("Break quality", "Kırılım kalitesi"), detail: L10n.text("The neckline-clearing candle's volume, body, clearance and directional alignment.", "Boyun çizgisini kıran mumun hacmi, gövdesi, mesafesi ve yönsel uyumu."), score: scores.breakoutQualityScore, maxScore: 100),
                    ConfidenceFactor(key: "confirmation", title: L10n.text("Post-break confirmation", "Kırılım sonrası teyit"), detail: L10n.text("Holding closes, retest evidence and continuation after the neckline trigger.", "Boyun çizgisi tetiklendikten sonraki kapanışlar, retest ve devam hareketi."), score: scores.confirmationScore, maxScore: 100),
                ]
            }
            return stored.map { factor in
                let text = Self.patternFactorText(factor.key)
                return ConfidenceFactor(key: factor.key, title: text.title, detail: text.detail, score: factor.score, maxScore: factor.maxScore)
            }
        }
    }

    private static func emaFactorText(_ key: String) -> (title: String, detail: String) {
        switch key {
        case "alignment":
            (L10n.text("Trend alignment", "Trend dizilimi"), L10n.text("Price above EMA 7, EMA 7 above EMA 25, EMA 25 above EMA 99.", "Fiyat EMA 7'nin, EMA 7 EMA 25'in, EMA 25 EMA 99'un üzerinde."))
        case "cross":
            (L10n.text("Crossover freshness", "Kesişim tazeliği"), L10n.text("How recently EMA 7 crossed above EMA 25.", "EMA 7'nin EMA 25'i ne kadar yakın zamanda yukarı kestiği."))
        case "retest":
            (L10n.text("Retest", "Yeniden test"), L10n.text("Whether the EMA zone held when price came back to it.", "Fiyat geri döndüğünde EMA bölgesinin tutup tutmadığı."))
        case "volume":
            (L10n.text("Volume support", "Hacim desteği"), L10n.text("Last closed candle against the 20-candle average volume.", "Son kapanan mumun 20 mum ortalama hacmine oranı."))
        case "longTerm":
            (L10n.text("Long-term trend", "Uzun vadeli trend"), L10n.text("Price against a rising or falling EMA 99.", "Fiyatın yükselen ya da düşen EMA 99'a göre konumu."))
        case "momentum":
            (L10n.text("Momentum", "Momentum"), L10n.text("Consecutive closes above EMA 7.", "EMA 7 üzerinde art arda kapanış sayısı."))
        case "btcStrength":
            (L10n.text("Strength vs BTC", "BTC'ye karşı güç"), L10n.text("Return against BTC over the last 12 candles, and holding flat or green while BTC candles close red.", "Son 12 mumda BTC'ye karşı getiri ve BTC mumları kırmızı kapanırken yatay ya da yeşil kalabilme."))
        default:
            (key, "")
        }
    }

    /// The directional evidence rows for the collapsed sub-section on the coin
    /// page. Only level engines carry them, and only rows with a known key are
    /// shown.
    private func directionalFactors(model: JourneyModel, evidence: SignalEvidence?) -> [ConfidenceFactor] {
        switch model {
        case .donchian20, .donchian50, .horizontalLevel, .consolidation:
            (evidence?.confidenceFactors ?? []).compactMap { factor in
                guard let text = Self.directionalFactorText(factor.key) else { return nil }
                return ConfidenceFactor(key: factor.key, title: text.title, detail: text.detail, score: factor.score, maxScore: factor.maxScore)
            }
        case .emaCross, .doubleBottom, .doubleTop:
            []
        }
    }

    /// The quality deductions: bearish evidence that subtracted points from the
    /// quality score. All rows are inverted on the wire (full score = no
    /// warning), and only fired warnings are shown.
    private static func directionalFactorText(_ key: String) -> (title: String, detail: String)? {
        switch key {
        case "doubleTop":
            (L10n.text("Double top", "Çift tepe"),
             L10n.text("A recent double top argues against upward follow-through.", "Yakın zamandaki çift tepe yukarı yönlü devamın aleyhine işaret eder."))
        case "headShoulders":
            (L10n.text("Head & shoulders", "Omuz-baş-omuz"),
             L10n.text("Three peaks with a higher middle suggest a topping structure.", "Ortası daha yüksek üç tepe, tepe oluşumuna işaret eder."))
        case "risingWedge":
            (L10n.text("Rising wedge", "Yükselen takoz"),
             L10n.text("Price grinds higher while candle ranges contract — an ascent running out of room.", "Fiyat yükselirken mum aralıkları daralıyor — alanı tükenen bir yükseliş."))
        case "lowVolume":
            (L10n.text("Low volume", "Düşük hacim"),
             L10n.text("The last closed candle traded well below its 20-candle average volume.", "Son kapanan mumun hacmi 20 mum ortalamasının belirgin altında."))
        case "weakTrend":
            (L10n.text("Weak trend", "Zayıf trend"),
             L10n.text("The EMA stack and slope argue against a sustained upward move.", "EMA dizilimi ve eğimi kalıcı bir yükselişin aleyhine."))
        case "nearbyResistance":
            (L10n.text("Nearby resistance", "Yakın direnç"),
             L10n.text("A tested resistance sits close overhead, capping the room to run.", "Test edilmiş bir direnç hemen üstte; hareket alanını sınırlıyor."))
        case "highVolatility":
            (L10n.text("High volatility", "Yüksek volatilite"),
             L10n.text("Candle ranges expanded sharply — moves are getting erratic.", "Mum aralıkları sert genişledi — hareketler düzensizleşiyor."))
        case "sellVolume":
            (L10n.text("Heavy selling volume", "Yoğun satış hacmi"),
             L10n.text("Recent volume is elevated and concentrated on falling candles.", "Yakın dönem hacmi yüksek ve düşen mumlarda yoğunlaşmış."))
        case "ema99Rejection":
            (L10n.text("EMA 99 rejection", "EMA 99 reddi"),
             L10n.text("Price was rejected at EMA 99 and stays clearly below it.", "Fiyat EMA 99'dan geri döndü ve belirgin şekilde altında kalıyor."))
        default: nil
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
        case "btcStrength":
            (L10n.text("Strength vs BTC", "BTC'ye karşı güç"), L10n.text("Return against BTC over the last 12 candles, and holding flat or green while BTC candles close red.", "Son 12 mumda BTC'ye karşı getiri ve BTC mumları kırmızı kapanırken yatay ya da yeşil kalabilme."))
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
