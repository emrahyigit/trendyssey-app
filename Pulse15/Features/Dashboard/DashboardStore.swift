import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    enum State { case idle, loading, loaded(MarketOverview), failed(String) }
    private(set) var state: State = .idle

    func load(using service: MarketService) async {
        guard case .idle = state else { return }
        state = .loading
        do { state = .loaded(try await service.overview()) }
        catch is CancellationError { state = .idle }
        catch { state = .failed(L10n.text("Market data could not be refreshed.", "Piyasa verileri şu anda yenilenemedi.")) }
    }

    func retry(using service: MarketService) async {
        state = .idle
        await load(using: service)
    }
}
