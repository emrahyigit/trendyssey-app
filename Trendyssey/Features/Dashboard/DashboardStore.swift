import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    enum State { case idle, loading, loaded(MarketOverview), failed(String) }
    private(set) var state: State = .idle
    private(set) var topPredictors: [TopPredictor] = []

    func load(using service: MarketService, forceRefresh: Bool = false) async {
        guard case .idle = state else { return }
        state = .loading
        do {
            async let overviewRequest = service.overview()
            async let predictorRequest = try? SignalPredictionService().topPredictors(limit: 10)
            let overview = try await overviewRequest
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
