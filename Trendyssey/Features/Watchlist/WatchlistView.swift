import SwiftUI

struct WatchlistView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var liveSignals: [MarketSignal] = []
    @State private var selectedSignal: MarketSignal?
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(AnalysisModelSelection.storageKey) private var preferredAnalysisModel = AnalysisModelSelection.defaultSlug

    private var followedSignals: [MarketSignal] { liveSignals.filter { environment.watchlist.contains($0.symbol) } }

    var body: some View {
        List(followedSignals) { signal in
            Button { selectedSignal = signal } label: { SignalRow(signal: signal) }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 5, leading: 0, bottom: 5, trailing: 0))
                .listRowBackground(TrendysseyColor.canvas).listRowSeparator(.hidden)
        }
        .trendysseyBackground().navigationTitle(L10n.text("Watchlist", "Takip Listesi"))
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
        .overlay { if followedSignals.isEmpty { ContentUnavailableView(L10n.text("Your watchlist is empty", "Takip listen boş"), systemImage: "star", description: Text(L10n.text("Add coins from a signal detail page.", "Bir sinyal detayından coin ekleyebilirsin."))) } }
        .task(id: "\(preferredAnalysisModel)|\(preferredTimeframe)") { liveSignals = (try? await environment.marketService.allSymbols()) ?? [] }
    }
}
