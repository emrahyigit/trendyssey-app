import SwiftUI

struct ScannerView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case state, absorption, pressure, volume, change

        var id: Self { self }
        var title: String {
            switch self {
            case .state: L10n.text("State strength", "Durum gücü")
            case .absorption: L10n.text("Absorption", "Absorpsiyon")
            case .pressure: L10n.text("Selling pressure", "Satış baskısı")
            case .volume: L10n.text("24h volume", "24s hacim")
            case .change: L10n.text("24h change", "24s değişim")
            }
        }
    }

    private static let filterStates: [MarketStateKind] = [
        .buySideAbsorption, .sellerImpactFading, .bounceAttempt,
        .bullishConfirmation, .sellingDominant, .breakdownRisk, .neutral
    ]

    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var liveSignals: [MarketSignal] = []
    @State private var selectedSignal: MarketSignal?
    @State private var isLoading = true
    @State private var stateFilter: MarketStateKind?
    @State private var sortOption: SortOption = .state
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    private func score(for signal: MarketSignal, option: SortOption) -> Int {
        return switch option {
        case .state: signal.marketState?.stateScore ?? 0
        case .absorption: signal.marketState?.absorption ?? 0
        case .pressure: signal.marketState?.sellingPressure ?? 0
        case .volume, .change: 0
        }
    }

    private var signals: [MarketSignal] {
        let filtered = liveSignals.filter { signal in
            let matchesQuery = query.isEmpty
                || signal.symbol.localizedCaseInsensitiveContains(query)
                || signal.name.localizedCaseInsensitiveContains(query)
            let matchesState = stateFilter.map { $0 == signal.marketState?.state } ?? true
            return matchesQuery && matchesState
        }
        switch sortOption {
        case .state, .absorption, .pressure:
            return filtered.sorted {
                let lhs = score(for: $0, option: sortOption)
                let rhs = score(for: $1, option: sortOption)
                if lhs != rhs { return lhs > rhs }
                if $0.quoteVolume24h != $1.quoteVolume24h { return $0.quoteVolume24h > $1.quoteVolume24h }
                return $0.symbol < $1.symbol
            }
        case .volume:
            return filtered.sorted {
                if $0.quoteVolume24h != $1.quoteVolume24h { return $0.quoteVolume24h > $1.quoteVolume24h }
                return $0.symbol < $1.symbol
            }
        case .change:
            return filtered.sorted {
                if $0.change24h != $1.change24h { return $0.change24h > $1.change24h }
                return $0.symbol < $1.symbol
            }
        }
    }

    var body: some View {
        List {
            Section {
                filterControls
                    .listRowInsets(.init(top: 8, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(TrendysseyColor.canvas)
                    .listRowSeparator(.hidden)
                if signals.isEmpty && !isLoading {
                    ContentUnavailableView(
                        L10n.text("No results", "Sonuç bulunamadı"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(L10n.text("Try changing the search text or market-state filter.", "Arama metnini veya piyasa durumu filtresini değiştirmeyi deneyin."))
                    )
                    .listRowBackground(TrendysseyColor.canvas)
                    .listRowSeparator(.hidden)
                }
                ForEach(signals) { signal in
                    Button { selectedSignal = signal } label: { SignalRow(signal: signal) }
                        .buttonStyle(.plain)
                        .listRowInsets(.init(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .listRowBackground(TrendysseyColor.canvas)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .trendysseyBackground()
        .navigationTitle(L10n.text("Search Coins", "Coin Ara"))
        .searchable(text: $query, prompt: L10n.text("Search USDT pair", "USDT paritesi ara"))
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
        .overlay { if isLoading { ProgressView(L10n.text("Loading live market…", "Canlı piyasa yükleniyor…")).tint(TrendysseyColor.accent) } }
        .task(id: "\(preferredTimeframe)|\(journeyModel)") {
            isLoading = true
            liveSignals = (try? await environment.marketService.allSymbols()) ?? []
            isLoading = false
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Filters", "Filtreler"), systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.primaryText)
                Spacer()
                Menu {
                    Picker(L10n.text("Sort", "Sıralama"), selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortOption.title)
                        Image(systemName: "chevron.down").font(.caption2.bold())
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.primaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(TrendysseyColor.elevated, in: Capsule())
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    statusButton(
                        title: L10n.text("All", "Tümü"),
                        isSelected: stateFilter == nil
                    ) { stateFilter = nil }
                    ForEach(Self.filterStates, id: \.self) { state in
                        statusButton(
                            title: state.title,
                            isSelected: stateFilter == state
                        ) { stateFilter = state }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(TrendysseyColor.border, lineWidth: 1)
        }
    }

    private func statusButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18), action)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : TrendysseyColor.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? TrendysseyColor.accent : TrendysseyColor.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(isSelected ? Color.clear : TrendysseyColor.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
