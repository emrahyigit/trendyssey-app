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

    /// Statuses the on-device EMA journey can actually produce, in journey order.
    private static let filterStatuses: [SignalStatus] = [
        .watching, .preBreakout, .breakoutDetected, .retest, .confirmed, .failed
    ]
    private static let warmupLimit = 120

    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var liveSignals: [MarketSignal] = []
    @State private var selectedSignal: MarketSignal?
    @State private var isLoading = true
    @State private var statusFilter: SignalStatus?
    @State private var sortOption: SortOption = .confidence
    @State private var analyses: [String: EMAJourneyAnalysis] = [:]
    @State private var analyzedCount = 0
    @State private var warmupTotal = 0
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(AnalysisModelSelection.storageKey) private var preferredAnalysisModel = AnalysisModelSelection.defaultSlug

    private func phase(for signal: MarketSignal) -> SignalStatus {
        analyses[signal.symbol]?.currentPhase ?? signal.status
    }

    private func confidence(for signal: MarketSignal) -> Int {
        analyses[signal.symbol]?.confidence ?? (signal.hasScore ? signal.confidence : 0)
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
                    .listRowBackground(PulseColor.canvas)
                    .listRowSeparator(.hidden)
                if signals.isEmpty && !isLoading {
                    ContentUnavailableView(
                        L10n.text("No results", "Sonuç bulunamadı"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(L10n.text("Try changing the search text or status filter.", "Arama metnini veya durum filtresini değiştirmeyi deneyin."))
                    )
                    .listRowBackground(PulseColor.canvas)
                    .listRowSeparator(.hidden)
                }
                ForEach(signals) { signal in
                    Button { selectedSignal = signal } label: { SignalRow(signal: signal) }
                        .buttonStyle(.plain)
                        .listRowInsets(.init(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .listRowBackground(PulseColor.canvas)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .pulseBackground()
        .navigationTitle(L10n.text("Search Coins", "Coin Ara"))
        .searchable(text: $query, prompt: L10n.text("Search USDT pair", "USDT paritesi ara"))
        .navigationDestination(item: $selectedSignal) { SignalDetailView(signal: $0) }
        .overlay { if isLoading { ProgressView(L10n.text("Loading live market…", "Canlı piyasa yükleniyor…")).tint(PulseColor.accent) } }
        .task(id: "\(preferredAnalysisModel)|\(preferredTimeframe)") {
            isLoading = true
            liveSignals = (try? await environment.marketService.allSymbols()) ?? []
            isLoading = false
            await warmUpAnalyses()
        }
    }

    /// Analyzes the highest-volume coins up front so status filters and the
    /// confidence sort work on the same on-device values the rows display.
    /// Results are applied in a single pass at the end so the list re-orders
    /// once instead of reshuffling while the analysis streams in.
    @MainActor private func warmUpAnalyses() async {
        let symbols = liveSignals
            .filter { $0.hasScore || environment.subscriptionStore.isSubscribed }
            .sorted { $0.quoteVolume24h > $1.quoteVolume24h }
            .prefix(Self.warmupLimit)
            .map(\.symbol)
        warmupTotal = symbols.count
        analyzedCount = 0
        var collected: [String: EMAJourneyAnalysis] = [:]
        for batchStart in stride(from: 0, to: symbols.count, by: 8) {
            guard !Task.isCancelled else { return }
            let batch = Array(symbols[batchStart..<min(batchStart + 8, symbols.count)])
            await withTaskGroup(of: (String, EMAJourneyAnalysis?).self) { group in
                for symbol in batch {
                    group.addTask { (symbol, await EMAAnalysisCache.shared.analysis(for: symbol)) }
                }
                for await (symbol, analysis) in group {
                    if let analysis { collected[symbol] = analysis }
                }
            }
            analyzedCount = min(warmupTotal, analyzedCount + batch.count)
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            analyses = collected
            warmupTotal = 0
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Filters", "Filtreler"), systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColor.primaryText)
                if warmupTotal > 0 {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(L10n.text("Analyzing the market", "Piyasa analiz ediliyor"))
                }
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
                    .foregroundStyle(PulseColor.primaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(PulseColor.elevated, in: Capsule())
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
                            title: status.title,
                            isSelected: statusFilter == status
                        ) { statusFilter = status }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PulseColor.border, lineWidth: 1)
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
                .foregroundStyle(isSelected ? Color.black : PulseColor.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? PulseColor.accent : PulseColor.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(isSelected ? Color.clear : PulseColor.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
