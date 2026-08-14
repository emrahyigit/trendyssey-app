import SwiftUI

/// Read-only window onto the trade executor: the parameters it runs with and
/// every order it has touched, newest first. The app never places or cancels
/// orders — the backend cron owns the trading loop.
struct LiveTradesView: View {
    @State private var config: TradeExecutorConfig?
    @State private var trades: [LiveTrade] = []
    @State private var currentPrices: [String: Double] = [:]
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isConfirmingReset = false
    @State private var isResetting = false
    @State private var resetFailed = false

    private var openTrades: [LiveTrade] { trades.filter { $0.status == "open" || $0.status == "pending_entry" } }
    private var closedTrades: [LiveTrade] { trades.filter { $0.status == "closed" } }
    private var realizedPnl: Double { closedTrades.compactMap(\.realizedQuotePnl).reduce(0, +) }
    private var unrealizedPnl: Double {
        openTrades.compactMap { $0.unrealizedPnl(currentPrice: currentPrices[$0.symbol]) }.reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let config { configCard(config) }
                if config?.resetRequested == true {
                    noticeCard(
                        L10n.text(
                            "Reset requested — the executor unwinds and clears everything within a minute.",
                            "Sıfırlama istendi — işlemci bir dakika içinde her şeyi kapatıp temizleyecek."
                        ),
                        icon: "arrow.counterclockwise.circle"
                    )
                }
                if resetFailed {
                    noticeCard(
                        L10n.text("Reset request failed. Try again.", "Sıfırlama isteği gönderilemedi. Yeniden dene."),
                        icon: "exclamationmark.triangle"
                    )
                }
                summaryCard
                if let firstError = trades.first(where: { $0.status == "error" || $0.errorMessage != nil }) {
                    noticeCard(
                        L10n.text(
                            "Last issue · \(firstError.symbol): \(firstError.errorMessage ?? "unknown")",
                            "Son sorun · \(firstError.symbol): \(firstError.errorMessage ?? "bilinmiyor")"
                        ),
                        icon: "exclamationmark.triangle"
                    )
                }
                tradeList
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Auto Trader", "Otomatik İşlemler"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    if isResetting { ProgressView() }
                    else { Text(L10n.text("Reset", "Sıfırla")).font(.subheadline.weight(.semibold)) }
                }
                .disabled(isResetting || config?.resetRequested == true)
            }
        }
        .confirmationDialog(
            L10n.text(
                "Close every position and wipe the trade history? The executor sells open holdings at market on its next run.",
                "Tüm pozisyonlar kapatılıp işlem geçmişi silinsin mi? İşlemci bir sonraki turunda açık pozisyonları piyasadan satar."
            ),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Reset auto trader", "Otomatik işlemleri sıfırla"), role: .destructive) {
                Task { await requestReset() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Cards

    private func configCard(_ config: TradeExecutorConfig) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        config.useTestnet ? L10n.text("TESTNET", "TESTNET") : L10n.text("LIVE", "CANLI"),
                        systemImage: config.useTestnet ? "testtube.2" : "bolt.circle.fill"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(config.useTestnet ? TrendysseyColor.accent : TrendysseyColor.warning)
                    Spacer()
                    Text(config.enabled ? L10n.text("Running", "Çalışıyor") : L10n.text("Paused", "Durduruldu"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(config.enabled ? TrendysseyColor.positive : TrendysseyColor.secondaryText)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if config.useChandelierExit == true {
                        // The tournament exit: the stop trails the highs, so
                        // there is no fixed target or stop to show.
                        parameterCell(
                            L10n.text("Exit", "Çıkış"),
                            L10n.text("Chandelier \(Self.percent(config.chandelierAtrMultiplier ?? 3))×ATR", "Chandelier \(Self.percent(config.chandelierAtrMultiplier ?? 3))×ATR"),
                            tint: TrendysseyColor.accent
                        )
                    } else {
                        parameterCell(L10n.text("Target", "Hedef"), "+%\(Self.percent(config.profitTargetPercent))", tint: TrendysseyColor.positive)
                        parameterCell(L10n.text("Stop", "Stop"), "-%\(Self.percent(config.stopLossPercent))", tint: TrendysseyColor.negative)
                    }
                    parameterCell(L10n.text("Time limit", "Süre"), "\(config.maxOpenHours)s")
                    parameterCell(L10n.text("Slots", "Slot"), "\(config.maxSlots)")
                    parameterCell(L10n.text("Per trade", "İşlem başına"), "$\(Self.percent(config.quotePerTrade))")
                    parameterCell(L10n.text("Min. volume", "Min. hacim"), config.minimumQuoteVolume > 0 ? "$\((config.minimumQuoteVolume / 1_000_000).formatted(.number.precision(.fractionLength(0))))M" : L10n.text("Off", "Kapalı"))
                    parameterCell(
                        L10n.text("Entry state", "Giriş durumu"),
                        entryStateText(config.allowedMarketStates),
                        tint: TrendysseyColor.accent
                    )
                    parameterCell(
                        L10n.text("Min. state score", "Min. durum puanı"),
                        (config.minimumStateScore ?? 0) > 0 ? "\(config.minimumStateScore ?? 0) / 100" : L10n.text("Off", "Kapalı")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parameterCell(_ title: String, _ value: String, tint: Color = TrendysseyColor.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(TrendysseyColor.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var summaryCard: some View {
        SurfaceCard {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                summaryCell(
                    L10n.text("REALIZED PNL", "GERÇEKLEŞEN K/Z"),
                    Self.signedAmount(realizedPnl),
                    tint: realizedPnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative
                )
                summaryCell(
                    L10n.text("OPEN PNL", "AKTİF K/Z"),
                    Self.signedAmount(unrealizedPnl),
                    tint: unrealizedPnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative
                )
                summaryCell(L10n.text("OPEN POSITIONS", "AÇIK POZİSYON"), "\(openTrades.count)")
                summaryCell(L10n.text("CLOSED", "KAPANAN"), "\(closedTrades.count)")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryCell(_ title: String, _ value: String, tint: Color = TrendysseyColor.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeCard(_ text: String, icon: String) -> some View {
        SurfaceCard {
            Label(text, systemImage: icon)
                .font(.caption).foregroundStyle(TrendysseyColor.warning).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Trades

    @ViewBuilder private var tradeList: some View {
        if isLoading && trades.isEmpty {
            SurfaceCard { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28) }
        } else if loadFailed && trades.isEmpty {
            SurfaceCard {
                ContentUnavailableView(
                    L10n.text("Trades unavailable", "İşlemler alınamadı"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(L10n.text("Check your connection and pull to refresh.", "Bağlantını kontrol edip yenilemek için aşağı çek."))
                )
            }
        } else if trades.isEmpty {
            SurfaceCard {
                ContentUnavailableView(
                    L10n.text("No trades yet", "Henüz işlem yok"),
                    systemImage: "clock",
                    description: Text(L10n.text(
                        "The executor opens a position when the selected market state and thresholds match.",
                        "Seçili piyasa durumu ve eşikler eşleştiğinde pozisyon açılacak."
                    ))
                )
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(trades) { trade in
                    SurfaceCard { row(trade) }
                }
            }
        }
    }

    private func row(_ trade: LiveTrade) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(trade.symbol).font(.subheadline.bold())
                statusChip(trade)
                Spacer()
                Text(trade.createdAt, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let signalPrice = trade.signalPrice {
                    detail(L10n.text("Signal", "Sinyal"), "$\(Self.price(signalPrice))")
                }
                if let entryPrice = trade.entryPrice {
                    detail(L10n.text("Filled at", "Alış"), "$\(Self.price(entryPrice))")
                }
                if trade.status == "open", let current = currentPrices[trade.symbol] {
                    detail(L10n.text("Now", "Güncel"), "$\(Self.price(current))")
                }
                if let exitPrice = trade.exitPrice {
                    detail(L10n.text("Exit", "Çıkış"), "$\(Self.price(exitPrice))")
                }
                if let pnl = trade.realizedQuotePnl {
                    detail(
                        L10n.text("Realized PnL", "Gerçekleşen K/Z"),
                        Self.signedAmount(pnl),
                        tint: pnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative
                    )
                } else if let pnl = trade.unrealizedPnl(currentPrice: currentPrices[trade.symbol]) {
                    detail(
                        L10n.text("Open PnL", "Aktif K/Z"),
                        Self.signedAmount(pnl),
                        tint: pnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative
                    )
                }
            }
            // The decision-time snapshot: what the executor measured when it acted.
            HStack(spacing: 6) {
                if let state = trade.entryMarketState {
                    snapshotChip(
                        "\(state.title)\(trade.entryMarketStateScore.map { " · \($0)/100" } ?? "")\(stateChangeText(trade.entryMarketStateChange))"
                    )
                }
                if let volume = trade.entryQuoteVolume {
                    snapshotChip(L10n.text("Vol $\(Self.compact(volume))", "Hacim $\(Self.compact(volume))"))
                }
                Spacer()
            }
            if let reason = trade.exitReason {
                Text(exitReasonText(reason, trade: trade))
                    .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            if let error = trade.errorMessage {
                Text(error).font(.caption2).foregroundStyle(TrendysseyColor.warning).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusChip(_ trade: LiveTrade) -> some View {
        let (title, tint): (String, Color) = switch trade.status {
        case "open": (L10n.text("Filled · Open", "Doldu · Açık"), TrendysseyColor.accent)
        case "pending_entry": (L10n.text("Not filled yet", "Henüz Dolmadı"), TrendysseyColor.warning)
        case "closed": ((trade.realizedQuotePnl ?? 0) >= 0 ? L10n.text("Won", "Kazandı") : L10n.text("Lost", "Kaybetti"),
                        (trade.realizedQuotePnl ?? 0) >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
        case "canceled": (L10n.text("Canceled", "İptal"), TrendysseyColor.secondaryText)
        default: (L10n.text("Error", "Hata"), TrendysseyColor.negative)
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func snapshotChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(TrendysseyColor.secondaryText)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(TrendysseyColor.elevated.opacity(0.7), in: Capsule())
    }

    private func entryStateText(_ states: [MarketStateKind]?) -> String {
        guard let states, !states.isEmpty else { return L10n.text("Any", "Tümü") }
        if states.count == 1 { return states[0].title }
        return L10n.text("\(states.count) states", "\(states.count) durum")
    }

    private func stateChangeText(_ change: Int?) -> String {
        guard let change, change != 0 else { return "" }
        return " · " + L10n.text(
            "change \(change > 0 ? "+" : "")\(change)",
            "değişim \(change > 0 ? "+" : "")\(change)"
        )
    }

    private func detail(_ title: String, _ value: String, tint: Color = TrendysseyColor.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exitReasonText(_ reason: String, trade: LiveTrade) -> String {
        switch reason {
        case "target": L10n.text("Closed at the profit target.", "Kâr hedefinde kapandı.")
        // A chandelier position has a stop but never a target; its stop fill
        // is the trail doing its job, not a fixed stop-loss.
        case "stop_loss" where trade.targetPrice == nil && trade.stopPrice != nil:
            L10n.text("Closed by the trailing stop.", "İz süren stopta kapandı.")
        case "stop_loss": L10n.text("Closed at the stop loss.", "Stop loss'ta kapandı.")
        case "time_limit": L10n.text("Closed at the holding time limit.", "Süre limitinde kapandı.")
        case "manual": L10n.text("Closed manually.", "Elle kapatıldı.")
        default: L10n.text("Closed with an error.", "Hatayla kapandı.")
        }
    }

    // MARK: - Actions

    @MainActor private func requestReset() async {
        isResetting = true
        resetFailed = false
        defer { isResetting = false }
        do {
            try await LiveTradingService.shared.requestReset()
            await load()
        } catch {
            resetFailed = true
        }
    }

    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let configTask = LiveTradingService.shared.config()
        async let tradesTask = LiveTradingService.shared.trades()
        let loadedConfig = try? await configTask
        let loadedTrades = try? await tradesTask
        if let loadedConfig { config = loadedConfig }
        if let loadedTrades {
            trades = loadedTrades
            let openSymbols = Array(Set(loadedTrades.filter { $0.status == "open" }.map(\.symbol)))
            currentPrices = (try? await LiveTradingService.shared.currentPrices(symbols: openSymbols)) ?? currentPrices
        }
        loadFailed = loadedTrades == nil
    }

    // MARK: - Formatting

    private static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func price(_ value: Double) -> String {
        let decimals = value >= 1000 ? 2 : value >= 1 ? 4 : 6
        return value.formatted(.number.precision(.fractionLength(0...decimals)))
    }

    private static func signedAmount(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(2)))) USDT"
    }

    private static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale))
    }
}
