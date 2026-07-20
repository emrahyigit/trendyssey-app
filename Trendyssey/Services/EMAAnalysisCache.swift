import Foundation

/// Shares on-device EMA 7/25/99 analyses between list rows and cards so the
/// status and confidence shown in lists always match the detail page.
@MainActor
final class EMAAnalysisCache {
    static let shared = EMAAnalysisCache()

    private struct Entry {
        let analysis: EMAJourneyAnalysis
        let timeframe: String
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<EMAJourneyAnalysis?, Never>] = [:]
    private let lifetime: TimeInterval = 90

    func cached(for symbol: String) -> EMAJourneyAnalysis? {
        guard let entry = entries[symbol],
              entry.timeframe == AnalysisTimeframe.selected.rawValue,
              Date.now.timeIntervalSince(entry.fetchedAt) < lifetime else { return nil }
        return entry.analysis
    }

    func analysis(for symbol: String) async -> EMAJourneyAnalysis? {
        if let cached = cached(for: symbol) { return cached }
        if let task = inFlight[symbol] { return await task.value }
        let timeframe = AnalysisTimeframe.selected.rawValue
        let higher = AnalysisTimeframe.selected.higher
        let task = Task<EMAJourneyAnalysis?, Never>.detached(priority: .userInitiated) {
            async let baseCandles = CandleService().candles(for: symbol, limit: 500)
            async let higherCandles = CandleService().candles(for: symbol, interval: higher.interval, limit: 200)
            guard let candles = try? await baseCandles else { return nil }
            return EMAJourneyAnalyzer.analyze(
                candles: candles,
                higherTimeframeCandles: try? await higherCandles,
                higherTimeframeTitle: higher.title
            )
        }
        inFlight[symbol] = task
        let result = await task.value
        inFlight[symbol] = nil
        if let result {
            entries[symbol] = Entry(analysis: result, timeframe: timeframe, fetchedAt: .now)
        }
        return result
    }
}
