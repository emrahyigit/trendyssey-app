import Foundation

/// Replays a journey model over recent candle history on the device. Kept only
/// as the breakout scenario's fallback for when the backend has no recorded
/// history for the selected model yet; every regular screen reads the server.
actor JourneyBacktestService {
    static let shared = JourneyBacktestService()

    /// Highest-volume coins replayed. Kept small because each one is a download.
    nonisolated static let symbolLimit = 25
    /// Candles fetched per symbol — the last 100 per timeframe, like every
    /// other screen. This is what sets how far back any window can reach.
    nonisolated static let candleLimit = 100

    private struct CacheKey: Hashable {
        let symbol: String
        let timeframe: String
    }

    private struct CachedCandles {
        let candles: [PriceCandle]
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CachedCandles] = [:]
    private let lifetime: TimeInterval = 300

    /// How far back `candleLimit` candles reach on this timeframe. Windows longer
    /// than this cannot be measured and are clamped by the caller.
    nonisolated static func availableHours(timeframe: AnalysisTimeframe) -> Double {
        Double(candleLimit) * Double(timeframe.minutes) / 60
    }

    /// Scenario entries derived on the device, in the same shape the server
    /// query returns. Used when the backend has no recorded history for the
    /// selected model yet, so the scenario still has something to replay.
    func scenarioEntries(
        model: JourneyModel,
        symbols: [String],
        volumeBySymbol: [String: Double],
        timeframe: AnalysisTimeframe,
        lookbackHours: Double,
        status: SignalStatus
    ) async -> [BreakoutScenarioEntry] {
        let since = Date.now.addingTimeInterval(-lookbackHours * 3600)
        let interval = timeframe.rawValue
        var entries: [BreakoutScenarioEntry] = []

        for start in stride(from: 0, to: symbols.count, by: 8) {
            if Task.isCancelled { break }
            let batch = Array(symbols[start..<min(start + 8, symbols.count)])
            let candlesBySymbol = await candles(for: batch, interval: interval)
            for (symbol, candles) in candlesBySymbol {
                guard let analysis = JourneyAnalyzer.analyze(model: model, candles: candles) else { continue }
                var indexByCloseTime: [Date: Int] = [:]
                for (index, candle) in analysis.candles.enumerated() { indexByCloseTime[candle.closeTime] = index }

                for event in analysis.events
                where event.status == status && event.time >= since && event.price > 0 {
                    guard let index = indexByCloseTime[event.time], index + 1 < analysis.candles.count else { continue }
                    let observed = Array(analysis.candles[(index + 1)...])
                    let fallbackConfirmation = switch event.status {
                    case .confirmed: 100
                    case .retest: 60
                    case .breakoutDetected: 35
                    default: 0
                    }
                    entries.append(
                        BreakoutScenarioEntry(
                            id: UUID(),
                            symbol: symbol,
                            status: status,
                            direction: model.direction,
                            // The score describes the symbol's current journey, not
                            // this historical event; it is the closest stand-in the
                            // device has for the score the backend would have stored.
                            regimeScore: analysis.scoreLayers?.regimeScore ?? analysis.confidence,
                            readinessScore: analysis.scoreLayers?.readinessScore ?? analysis.confidence,
                            breakoutQualityScore: analysis.scoreLayers?.breakoutQualityScore ?? analysis.confidence,
                            confirmationScore: analysis.scoreLayers?.confirmationScore ?? fallbackConfirmation,
                            // The device replay has no BTC series; unmeasured
                            // entries pass the relative-strength filter.
                            relativeStrengthScore: nil,
                            falseBreakoutRisk: max(0, 100 - analysis.confidence),
                            volumeRatio: analysis.volumeRatio,
                            quoteVolume24h: volumeBySymbol[symbol] ?? 0,
                            entryPrice: event.price,
                            latestPrice: observed.last?.close ?? event.price,
                            maximumObservedPrice: observed.map(\.high).max() ?? event.price,
                            minimumObservedPrice: observed.map(\.low).min() ?? event.price,
                            entryDate: event.time.ceiledToSecond,
                            observedCandles: observed
                        )
                    )
                }
            }
        }
        return entries.sorted { $0.entryDate > $1.entryDate }
    }

    // MARK: - Candles

    private func candles(for symbols: [String], interval: String) async -> [String: [PriceCandle]] {
        var result: [String: [PriceCandle]] = [:]
        var missing: [String] = []
        for symbol in symbols {
            let key = CacheKey(symbol: symbol, timeframe: interval)
            if let cached = cache[key], Date.now.timeIntervalSince(cached.fetchedAt) < lifetime {
                result[symbol] = cached.candles
            } else {
                missing.append(symbol)
            }
        }
        guard !missing.isEmpty else { return result }

        let limit = Self.candleLimit
        let fetched = await withTaskGroup(of: (String, [PriceCandle]?).self) { group in
            for symbol in missing {
                group.addTask {
                    let candles = try? await CandleService().candles(for: symbol, interval: interval, limit: limit)
                    return (symbol, candles)
                }
            }
            var values: [String: [PriceCandle]] = [:]
            for await (symbol, candles) in group {
                if let candles { values[symbol] = candles }
            }
            return values
        }
        for (symbol, candles) in fetched {
            cache[CacheKey(symbol: symbol, timeframe: interval)] = CachedCandles(candles: candles, fetchedAt: .now)
            result[symbol] = candles
        }
        return result
    }
}
