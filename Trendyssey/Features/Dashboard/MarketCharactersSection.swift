import SwiftUI

struct MarketCharactersSection: View {
    let entries: [MarketCharacterEntry]
    let signals: [MarketSignal]
    @Binding var selection: MarketCharacterCategory
    @State private var choseInitialAvailableCategory = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.donchian20.rawValue

    private var selectedEntries: [MarketCharacterEntry] {
        entries.filter { $0.category == selection }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Market Characters", "Piyasa Karakterleri"))
                        .font(.title3.bold())
                    Text(L10n.text("One compact view, four different lenses", "Tek kompakt alan, dört farklı bakış"))
                        .font(.caption)
                        .foregroundStyle(TrendysseyColor.secondaryText)
                }
                Spacer()
                NavigationLink(value: MarketCharacterRoute(category: selection)) {
                    HStack(spacing: 4) {
                        Text(L10n.text("See all", "Tümünü Gör"))
                        Image(systemName: "chevron.right").font(.caption2.bold())
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.accent)
                }
            }

            MarketCharacterCategoryPicker(selection: $selection)

            if selectedEntries.isEmpty {
                SurfaceCard { emptyState }
            } else {
                VStack(spacing: 10) {
                    ForEach(selectedEntries) { entry in
                        if let signal = signals.first(where: { $0.symbol == entry.symbol }) {
                            NavigationLink(value: signal) {
                                MarketCharacterRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        } else {
                            MarketCharacterRow(entry: entry)
                        }
                    }
                }
            }

            Text(L10n.text(
                "Last 30 days · \(selectedModel.title) · \(selectedTimeframe.title)",
                "Son 30 gün · \(selectedModel.title) · \(selectedTimeframe.title)"
            ))
            .font(.caption2)
            .foregroundStyle(TrendysseyColor.secondaryText)
            .padding(.horizontal, 4)
        }
        .onChange(of: entries, initial: true) { _, updated in
            guard !choseInitialAvailableCategory, !updated.isEmpty else { return }
            choseInitialAvailableCategory = true
            guard !updated.contains(where: { $0.category == selection }),
                  let available = MarketCharacterCategory.allCases.first(where: { category in
                      updated.contains(where: { $0.category == category })
                  }) else { return }
            selection = available
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: selection.systemImage)
                .font(.title3)
                .foregroundStyle(selection.tint)
                .frame(width: 34, height: 34)
                .background(selection.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Not enough data yet", "Henüz yeterli veri yok"))
                    .font(.subheadline.weight(.semibold))
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(TrendysseyColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var emptyMessage: String {
        switch selection {
        case .successful, .disappointing:
            L10n.text("Completed breakout journeys will appear here.", "Tamamlanan kırılım yolculukları burada görünecek.")
        case .overheated, .depressed:
            L10n.text("No coin currently clears the technical threshold.", "Şu anda teknik eşiği geçen coin bulunmuyor.")
        }
    }

    private var selectedModel: JourneyModel {
        JourneyModel(rawValue: journeyModel) ?? .donchian20
    }

    private var selectedTimeframe: AnalysisTimeframe {
        AnalysisTimeframe(rawValue: preferredTimeframe) ?? .m15
    }
}

struct MarketCharactersView: View {
    let initialCategory: MarketCharacterCategory

    @Environment(AppEnvironment.self) private var environment
    @State private var selection: MarketCharacterCategory
    @State private var entries: [MarketCharacterEntry] = []
    @State private var signals: [MarketSignal] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @AppStorage("preferredTimeframe") private var preferredTimeframe = "15m"
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.donchian20.rawValue

    init(initialCategory: MarketCharacterCategory) {
        self.initialCategory = initialCategory
        _selection = State(initialValue: initialCategory)
    }

    private var selectedEntries: [MarketCharacterEntry] {
        entries.filter { $0.category == selection }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MarketCharacterCategoryPicker(selection: $selection)

                if isLoading {
                    ProgressView(L10n.text("Calculating rankings…", "Sıralamalar hesaplanıyor…"))
                        .tint(TrendysseyColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                } else if selectedEntries.isEmpty {
                    ContentUnavailableView(
                        loadFailed ? L10n.text("Rankings unavailable", "Sıralamalar alınamadı") : L10n.text("Not enough data", "Yeterli veri yok"),
                        systemImage: selection.systemImage,
                        description: Text(L10n.text(
                            "This ranking appears when the selected model has enough closed-candle observations.",
                            "Seçilen modelde yeterli kapanmış mum gözlemi oluştuğunda bu sıralama gösterilir."
                        ))
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(selectedEntries) { entry in
                            if let signal = signals.first(where: { $0.symbol == entry.symbol }) {
                                NavigationLink(value: signal) {
                                    MarketCharacterRow(entry: entry, expanded: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                MarketCharacterRow(entry: entry, expanded: true)
                            }
                        }
                    }
                }

                Label(
                    L10n.text(
                        "Historical rates describe past model outcomes. Overheated and depressed are technical position labels, not valuation or advice.",
                        "Geçmiş oranlar modelin önceki sonuçlarını anlatır. Isınmış ve baskılanmış teknik konum etiketidir; değerleme veya tavsiye değildir."
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(TrendysseyColor.secondaryText)
                .padding(.horizontal, 4)
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(selection.fullTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(preferredTimeframe)|\(journeyModel)") { await load() }
        .refreshable { await load(forceRefresh: true) }
    }

    @MainActor
    private func load(forceRefresh: Bool = false) async {
        isLoading = true
        loadFailed = false
        async let rankingRequest = try? MarketCharacterService.shared.rankings(
            modelSlug: AnalysisModelSelection.selectedSlug,
            timeframe: AnalysisTimeframe.selected.rawValue,
            forceRefresh: forceRefresh
        )
        async let signalRequest = try? environment.marketService.allSymbols()
        let loadedRankings = await rankingRequest
        let loadedSignals = await signalRequest
        entries = loadedRankings ?? []
        signals = loadedSignals ?? []
        loadFailed = loadedRankings == nil
        isLoading = false
    }
}

struct MarketCharacterCategoryPicker: View {
    @Binding var selection: MarketCharacterCategory

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(MarketCharacterCategory.allCases) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = category }
                    } label: {
                        Label(category.title, systemImage: category.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selection == category ? Color.black : TrendysseyColor.secondaryText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(selection == category ? TrendysseyColor.accent : TrendysseyColor.surface, in: Capsule())
                            .overlay {
                                Capsule().stroke(selection == category ? Color.clear : TrendysseyColor.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct MarketCharacterRow: View {
    let entry: MarketCharacterEntry
    var expanded = false

    var body: some View {
        HStack(spacing: 13) {
            SymbolMark(symbol: entry.baseAsset, iconURL: entry.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.baseAsset).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TrendysseyColor.secondaryText)
                    .lineLimit(expanded ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(primaryValue)
                    .font(.headline.bold()).monospacedDigit()
                    .foregroundStyle(entry.category.tint)
                Text(primaryLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
        .padding(15)
        .background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var primaryValue: String {
        switch entry.category {
        case .successful, .disappointing:
            "\(entry.score.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)))%"
        case .overheated, .depressed:
            entry.score.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
        }
    }

    private var primaryLabel: String {
        switch entry.category {
        case .successful: L10n.text("success", "başarı")
        case .disappointing: L10n.text("invalidated", "geçersiz")
        case .overheated: L10n.text("heat score", "ısınma puanı")
        case .depressed: L10n.text("pressure score", "baskı puanı")
        }
    }

    private var detail: String {
        switch entry.category {
        case .successful:
            let median = entry.medianReturnPercent.map { value in
                L10n.text("median \(signed(value))", "medyan \(signed(value))")
            }
            return [
                L10n.text("\(entry.successCount)/\(entry.sampleCount) successful", "\(entry.successCount)/\(entry.sampleCount) başarılı"),
                median,
                sampleWarning
            ].compactMap { $0 }.joined(separator: " · ")
        case .disappointing:
            return [
                L10n.text("\(entry.failureCount)/\(entry.sampleCount) journeys", "\(entry.failureCount)/\(entry.sampleCount) yolculuk"),
                sampleWarning
            ].compactMap { $0 }.joined(separator: " · ")
        case .overheated, .depressed:
            let rsi = entry.rsi.map { "RSI \(Int($0.rounded()))" }
            let atr = entry.atrDistance.map { value in
                L10n.text("EMA \(signed(value, suffix: " ATR"))", "EMA \(signed(value, suffix: " ATR"))")
            }
            return [rsi, atr].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var sampleWarning: String? {
        guard entry.sampleCount < 5 else { return nil }
        return L10n.text("early data", "erken veri")
    }

    private func signed(_ value: Double, suffix: String = "%") -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
        return "\(value > 0 ? "+" : "")\(number)\(suffix)"
    }
}
