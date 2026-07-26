import SwiftUI

struct ScannerView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case confidence, volume, change

        var id: Self { self }
        var title: String {
            switch self {
            case .confidence: L10n.text("Confidence score", "Güven puanı")
            case .volume: L10n.text("24h volume", "24s hacim")
            case .change: L10n.text("24h change", "24s değişim")
            }
        }
    }

    /// Journey statuses the server records, in journey order.
    private static let filterStatuses: [SignalStatus] = [
        .watching, .preBreakout, .breakoutDetected, .retest, .confirmed, .failed
    ]

    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var liveSignals: [MarketSignal] = []
    @State private var selectedSignal: MarketSignal?
    @State private var isLoading = true
    @State private var statusFilter: SignalStatus?
    @State private var sortOption: SortOption = .confidence
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    private var journeyDirection: JourneyDirection {
        (JourneyModel(rawValue: journeyModel) ?? .emaCross).direction
    }

    // Filters and sorting run on the server-recorded phase and score — the
    // same values the rows display and the pushes were sent from.
    private func phase(for signal: MarketSignal) -> SignalStatus { signal.status }

    private func confidence(for signal: MarketSignal) -> Int {
        signal.hasScore ? signal.confidence : 0
    }

    private var signals: [MarketSignal] {
        let filtered = liveSignals.filter { signal in
            let matchesQuery = query.isEmpty
                || signal.symbol.localizedCaseInsensitiveContains(query)
                || signal.name.localizedCaseInsensitiveContains(query)
            let matchesStatus = statusFilter.map { $0 == phase(for: signal) } ?? true
            return matchesQuery && matchesStatus
        }
        switch sortOption {
        case .confidence:
            return filtered.sorted {
                let lhs = confidence(for: $0)
                let rhs = confidence(for: $1)
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
                        description: Text(L10n.text("Try changing the search text or status filter.", "Arama metnini veya durum filtresini değiştirmeyi deneyin."))
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
                        isSelected: statusFilter == nil
                    ) { statusFilter = nil }
                    ForEach(Self.filterStatuses, id: \.self) { status in
                        statusButton(
                            title: status.title(journeyDirection),
                            isSelected: statusFilter == status
                        ) { statusFilter = status }
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
