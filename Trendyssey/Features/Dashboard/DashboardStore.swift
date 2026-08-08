import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    enum State { case idle, loading, loaded(MarketOverview), failed(String) }
    private(set) var state: State = .idle
    private(set) var journeyStats: [String: SymbolJourneyStats] = [:]
    private(set) var topPredictors: [TopPredictor] = []

    /// Breakouts of this coin mostly invalidated recently, so the featured and
    /// waiting lists skip it. Unknown coins pass — missing history is not guilt.
    func isHighInvalidation(_ symbol: String) -> Bool {
        journeyStats[symbol]?.isHighInvalidation ?? false
    }

    func load(using service: MarketService, forceRefresh: Bool = false) async {
        guard case .idle = state else { return }
        state = .loading
        do {
            async let overviewRequest = service.overview()
            async let statsRequest = try? JourneyStatsService.shared.invalidationStats(
                modelSlug: AnalysisModelSelection.selectedSlug,
                timeframe: AnalysisTimeframe.selected.rawValue,
                forceRefresh: forceRefresh
            )
            async let predictorRequest = try? SignalPredictionService().topPredictors(limit: 10)
            let overview = try await overviewRequest
            journeyStats = await statsRequest ?? [:]
            topPredictors = await predictorRequest ?? []
            state = .loaded(overview)
        }
        catch is CancellationError { state = .idle }
        catch { state = .failed(L10n.text("Market data could not be refreshed.", "Piyasa verileri şu anda yenilenemedi.")) }
    }

    func retry(using service: MarketService) async {
        state = .idle
        await load(using: service, forceRefresh: true)
    }
}
