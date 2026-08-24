import SwiftUI

struct ScannerView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case strongest, sellerExhaustion, buyerExhaustion, buyerResponse, sellerResponse, volume, change

        var id: Self { self }
        var title: String {
            switch self {
            case .strongest: L10n.text("Strongest read", "En güçlü okuma")
            case .sellerExhaustion: L10n.text("Seller exhaustion", "Satıcı tükenişi")
            case .buyerExhaustion: L10n.text("Buyer exhaustion", "Alıcı tükenişi")
            case .buyerResponse: L10n.text("Buyer response", "Alıcı karşılığı")
            case .sellerResponse: L10n.text("Seller response", "Satıcı karşılığı")
            case .volume: L10n.text("24h volume", "24s hacim")
            case .change: L10n.text("24h change", "24s değişim")
            }
        }
    }

    private enum BehaviorFilter: String, CaseIterable, Identifiable {
        case all, confirmed, bullish, bearish, exhaustion, rejection, divergence, recovery

        var id: Self { self }
        var title: String {
            switch self {
            case .all: L10n.text("All", "Tümü")
            case .confirmed: L10n.text("Confirmed", "Doğrulandı")
            case .bullish: L10n.text("Bullish", "Yükseliş")
            case .bearish: L10n.text("Bearish", "Düşüş")
            case .exhaustion: L10n.text("Exhaustion", "Tükeniş")
            case .rejection: L10n.text("Rejected breaks", "Reddedilen kırılım")
            case .divergence: L10n.text("Divergence", "Ayrışma")
            case .recovery: L10n.text("Recovery", "Toparlanma")
            }
        }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var liveSignals: [MarketSignal] = []
    @State private var selectedSignal: MarketSignal?
    @State private var isLoading = true
    @State private var behaviorFilter: BehaviorFilter = .all
    @State private var sortOption: SortOption = .strongest
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    private var signals: [MarketSignal] {
        let filtered = liveSignals.filter { signal in
            let matchesQuery = query.isEmpty
                || signal.symbol.localizedCaseInsensitiveContains(query)
                || signal.name.localizedCaseInsensitiveContains(query)
            return matchesQuery && matches(signal.marketState, filter: behaviorFilter)
        }
        return filtered.sorted { left, right in
            switch sortOption {
            case .volume:
                if left.quoteVolume24h != right.quoteVolume24h {
                    return left.quoteVolume24h > right.quoteVolume24h
                }
            case .change:
                if left.change24h != right.change24h { return left.change24h > right.change24h }
            default:
                let lhs = score(for: left, option: sortOption)
                let rhs = score(for: right, option: sortOption)
                if lhs != rhs { return lhs > rhs }
            }
            return left.symbol < right.symbol
        }
    }

    var body: some View {
        List {
            Section {
                filterControls
                    .listRowInsets(.init(top: 8, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(TrendysseyColor.canvas)
                    .listRowSeparator(.hidden)
                HStack {
                    Text(L10n.text("\(signals.count) coins", "\(signals.count) coin"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(AnalysisTimeframe.selected.title)
                        .font(.caption2.bold())
                        .foregroundStyle(TrendysseyColor.accent)
                }
                .foregroundStyle(TrendysseyColor.secondaryText)
                .listRowInsets(.init(top: 0, leading: 4, bottom: 4, trailing: 4))
                .listRowBackground(TrendysseyColor.canvas)
                .listRowSeparator(.hidden)
                if signals.isEmpty && !isLoading {
                    ContentUnavailableView(
                        L10n.text("No behavioral read", "Davranışsal okuma yok"),
                        systemImage: "waveform.path.ecg",
                        description: Text(L10n.text(
                            "Try a different signal family or search term.",
                            "Farklı bir sinyal ailesi veya arama metni deneyin."
                        ))
                    )
                    .listRowBackground(TrendysseyColor.canvas)
                    .listRowSeparator(.hidden)
                }
                ForEach(signals) { signal in
                    Button { selectedSignal = signal } label: {
                        SignalRow(signal: signal, showsAPlus: false)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(.init(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(TrendysseyColor.canvas)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .trendysseyBackground()
        .navigationTitle(L10n.text("Behavior Search", "Davranış Ara"))
        .searchable(text: $query, prompt: L10n.text("Search coin", "Coin ara"))
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
        .overlay {
            if isLoading {
                ProgressView(L10n.text("Reading behavior…", "Davranış okunuyor…"))
                    .tint(TrendysseyColor.accent)
            }
        }
        .task(id: "\(preferredTimeframe)|\(journeyModel)") {
            isLoading = true
            liveSignals = (try? await environment.marketService.allSymbols()) ?? []
            isLoading = false
        }
        .refreshable {
            liveSignals = (try? await environment.marketService.allSymbols()) ?? liveSignals
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Behavioral radar", "Davranış radarı"))
                        .font(.headline)
                    Text(L10n.text(
                        "Filter what is changing, not a static market label.",
                        "Statik piyasa etiketi yerine neyin değiştiğini filtrele."
                    ))
                    .font(.caption2)
                    .foregroundStyle(TrendysseyColor.secondaryText)
                }
                Spacer(minLength: 8)
                Menu {
                    Picker(L10n.text("Sort", "Sıralama"), selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.bold())
                        .foregroundStyle(TrendysseyColor.primaryText)
                        .frame(width: 34, height: 34)
                        .background(TrendysseyColor.elevated, in: Circle())
                }
            }
            Text(sortOption.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TrendysseyColor.accent)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BehaviorFilter.allCases) { filter in
                        statusButton(
                            title: filter.title,
                            isSelected: behaviorFilter == filter
                        ) { behaviorFilter = filter }
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

    private func score(for signal: MarketSignal, option: SortOption) -> Int {
        guard let snapshot = signal.marketState else { return 0 }
        return switch option {
        case .strongest: snapshot.leadingBehavioralSignal?.score ?? 0
        case .sellerExhaustion: snapshot.behavioralScores.sellerExhaustion
        case .buyerExhaustion: snapshot.behavioralScores.buyerExhaustion
        case .buyerResponse: snapshot.behavioralScores.buyerResponse
        case .sellerResponse: snapshot.behavioralScores.sellerResponse
        case .volume, .change: 0
        }
    }

    private func matches(_ snapshot: MarketStateSnapshot?, filter: BehaviorFilter) -> Bool {
        guard filter != .all else { return true }
        guard let readings = snapshot?.behavioralSignals, !readings.isEmpty else { return false }
        return switch filter {
        case .all: true
        case .confirmed: readings.contains { $0.status == .confirmed }
        case .bullish: readings.contains { $0.direction == .bullish }
        case .bearish: readings.contains { $0.direction == .bearish }
        case .exhaustion: readings.contains { $0.kind == .sellerExhaustion || $0.kind == .buyerExhaustion }
        case .rejection: readings.contains { $0.kind == .failedBreakdown || $0.kind == .failedBreakout }
        case .divergence: readings.contains {
            $0.kind == .sellPressureDownsideDivergence || $0.kind == .buyPressureUpsideDivergence
        }
        case .recovery: readings.contains {
            $0.kind == .buyerRecoveryStrengthening || $0.kind == .sellerRecoveryStrengthening
        }
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
