import SwiftUI

/// Behavior-first window onto the backend-owned executor. Weakening is
/// observed, structure confirms, and only then may the backend act.
struct LiveTradesView: View {
    @State private var config: TradeExecutorConfig?
    @State private var trades: [LiveTrade] = []
    @State private var currentPrices: [String: Double] = [:]
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isConfirmingReset = false
    @State private var isResetting = false
    @State private var resetFailed = false

    private var openTrades: [LiveTrade] {
        trades.filter { $0.status == "open" || $0.status == "pending_entry" }
    }
    private var historyTrades: [LiveTrade] {
        let openIDs = Set(openTrades.map(\.id))
        return trades.filter { !openIDs.contains($0.id) }
    }
    private var closedTrades: [LiveTrade] { trades.filter { $0.status == "closed" } }
    private var realizedPnl: Double { closedTrades.compactMap(\.realizedQuotePnl).reduce(0, +) }
    private var unrealizedPnl: Double {
        openTrades.compactMap { $0.unrealizedPnl(currentPrice: currentPrices[$0.symbol]) }.reduce(0, +)
    }
    private var wins: Int { closedTrades.filter { ($0.realizedQuotePnl ?? 0) > 0 }.count }
    private var capitalAtWork: Double {
        openTrades.reduce(0) { $0 + ($1.entryPrice ?? 0) * ($1.entryQuantity ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let config {
                    decisionContract(config)
                    behaviorPath(config)
                }
                if config?.resetRequested == true {
                    notice(L10n.text(
                        "Reset queued. Positions will be unwound on the next executor pass.",
                        "Sıfırlama sırada. Pozisyonlar işlemcinin sonraki turunda kapatılacak."
                    ), icon: "arrow.counterclockwise.circle")
                }
                if resetFailed {
                    notice(L10n.text("Reset request failed. Try again.", "Sıfırlama isteği gönderilemedi. Yeniden dene."), icon: "exclamationmark.triangle")
                }
                portfolioPulse
                if let issue = trades.first(where: { $0.status == "error" || $0.errorMessage != nil }) {
                    notice(L10n.text(
                        "Last issue · \(issue.symbol): \(issue.errorMessage ?? "unknown")",
                        "Son sorun · \(issue.symbol): \(issue.errorMessage ?? "bilinmiyor")"
                    ), icon: "exclamationmark.triangle")
                }
                ledger
                resetAction
            }
            .padding(18)
        }
        .background(TrendysseyColor.canvas.ignoresSafeArea())
        .navigationTitle(L10n.text("Behavior Auto Trader", "Davranış Otomasyonu"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L10n.text(
                "Close every position and clear the ledger? Open holdings are sold at market on the next executor pass.",
                "Tüm pozisyonlar kapatılıp kayıtlar temizlensin mi? Açık varlıklar sonraki turda piyasadan satılır."
            ),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Reset auto trader", "Otomasyonu sıfırla"), role: .destructive) {
                Task { await requestReset() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("BEHAVIOR EXECUTION", "DAVRANIŞ YÜRÜTME"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.bold()).foregroundStyle(TrendysseyColor.accent)
                Spacer()
                if let config {
                    pill(config.enabled ? L10n.text("RUNNING", "ÇALIŞIYOR") : L10n.text("PAUSED", "DURDU"), tint: config.enabled ? TrendysseyColor.positive : TrendysseyColor.secondaryText)
                }
            }
            Text(L10n.text("Acts only after behavior becomes evidence.", "Yalnızca davranış kanıta dönüştüğünde hareket eder."))
                .font(.title2.bold())
            Text(L10n.text(
                "Exhaustion is an observation, not an entry. The executor waits for the selected behavior, evidence floor and structural confirmation.",
                "Tükeniş bir gözlemdir, giriş değildir. İşlemci seçili davranışı, kanıt tabanını ve yapısal teyidi bekler."
            ))
            .font(.subheadline).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
        }
    }

    private func decisionContract(_ config: TradeExecutorConfig) -> some View {
        let kinds = config.allowedBehaviorSignals ?? [.buyerTakeover]
        let minimum = config.minimumBehaviorScore ?? 60
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.text("ENTRY CONTRACT", "GİRİŞ SÖZLEŞMESİ"))
                        .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                    Spacer()
                    pill(config.useTestnet ? "TESTNET" : L10n.text("LIVE", "CANLI"), tint: config.useTestnet ? TrendysseyColor.accent : TrendysseyColor.warning)
                }
                ForEach(kinds, id: \.self) { kind in
                    Label(kind.title, systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(TrendysseyColor.positive)
                }
                Divider()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ruleCell(L10n.text("Evidence floor", "Kanıt tabanı"), "\(minimum) / 100", icon: "checklist")
                    ruleCell(L10n.text("Confirmation", "Teyit"), config.requireBehaviorConfirmed == false ? L10n.text("Developing allowed", "Gelişen dahil") : L10n.text("Required", "Zorunlu"), icon: "checkmark.seal")
                    ruleCell(L10n.text("Timeframe", "Zaman dilimi"), config.timeframe.uppercased(), icon: "clock")
                    ruleCell(L10n.text("Volume floor", "Hacim tabanı"), config.minimumQuoteVolume > 0 ? "$\(Self.compact(config.minimumQuoteVolume))" : L10n.text("Off", "Kapalı"), icon: "drop")
                    ruleCell(L10n.text("Position size", "Pozisyon boyutu"), "$\(Self.number(config.quotePerTrade))", icon: "banknote")
                    ruleCell(L10n.text("Capacity", "Kapasite"), "\(openTrades.count) / \(config.maxSlots)", icon: "square.grid.2x2")
                }
                Text(L10n.text(
                    "Edit this contract in Behavior Scenario, then apply it to the trader.",
                    "Bu sözleşmeyi Davranış Senaryosu'nda düzenleyip işlemciye uygula."
                ))
                .font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
        }
    }

    private func behaviorPath(_ config: TradeExecutorConfig) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("HOW A POSITION OPENS", "POZİSYON NASIL AÇILIR"))
                    .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                HStack(alignment: .top, spacing: 7) {
                    pathStep("1", L10n.text("Observe", "Gözle"), L10n.text("Weakening", "Zayıflama"), tint: TrendysseyColor.warning)
                    pathArrow
                    pathStep("2", L10n.text("Confirm", "Teyit"), L10n.text("Response + structure", "Karşılık + yapı"), tint: TrendysseyColor.accent)
                    pathArrow
                    pathStep("3", L10n.text("Execute", "Uygula"), L10n.text("Rules + free slot", "Kurallar + boş slot"), tint: TrendysseyColor.positive)
                }
                Divider()
                HStack {
                    Label(
                        config.useChandelierExit == true
                            ? L10n.text("Chandelier \(Self.number(config.chandelierAtrMultiplier ?? 3))×ATR exit", "Chandelier \(Self.number(config.chandelierAtrMultiplier ?? 3))×ATR çıkış")
                            : L10n.text("Fixed target / stop", "Sabit hedef / stop"),
                        systemImage: "arrow.up.forward.and.arrow.down.backward"
                    )
                    .font(.caption.weight(.semibold))
                    Spacer()
                    Text(L10n.text("Max \(config.maxOpenHours)h", "Maks. \(config.maxOpenHours)s"))
                        .font(.caption).monospacedDigit().foregroundStyle(TrendysseyColor.secondaryText)
                }
            }
        }
    }

    private var pathArrow: some View {
        Image(systemName: "chevron.right").font(.caption2.bold())
            .foregroundStyle(TrendysseyColor.secondaryText).padding(.top, 18)
    }

    private func pathStep(_ number: String, _ title: String, _ detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(number).font(.caption2.bold()).foregroundStyle(tint)
                .frame(width: 22, height: 22).background(tint.opacity(0.14), in: Circle())
            Text(title).font(.caption.bold()).foregroundStyle(tint)
            Text(detail).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portfolioPulse: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("PORTFOLIO PULSE", "PORTFÖY NABZI"))
                    .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    metric(L10n.text("REALIZED", "GERÇEKLEŞEN"), Self.signed(realizedPnl), tint: realizedPnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                    metric(L10n.text("OPEN PNL", "AKTİF K/Z"), Self.signed(unrealizedPnl), tint: unrealizedPnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                    metric(L10n.text("CAPITAL AT WORK", "ÇALIŞAN SERMAYE"), "$\(Self.number(capitalAtWork))")
                    metric(L10n.text("CLOSED OUTCOMES", "KAPANAN SONUÇ"), "\(wins) / \(closedTrades.count) " + L10n.text("wins", "kazanç"))
                }
            }
        }
    }

    @ViewBuilder private var ledger: some View {
        if isLoading && trades.isEmpty {
            SurfaceCard { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28) }
        } else if loadFailed && trades.isEmpty {
            SurfaceCard {
                ContentUnavailableView(L10n.text("Ledger unavailable", "Kayıtlar alınamadı"), systemImage: "wifi.exclamationmark", description: Text(L10n.text("Check the connection and pull to refresh.", "Bağlantıyı kontrol edip aşağı çek.")))
            }
        } else if trades.isEmpty {
            SurfaceCard {
                ContentUnavailableView(L10n.text("Waiting for evidence", "Kanıt bekleniyor"), systemImage: "waveform.path.ecg", description: Text(L10n.text("No behavior has completed the entry contract yet.", "Henüz hiçbir davranış giriş sözleşmesini tamamlamadı.")))
            }
        } else {
            if !openTrades.isEmpty { tradeSection(L10n.text("Active decisions", "Aktif kararlar"), trades: openTrades, tint: TrendysseyColor.accent) }
            if !historyTrades.isEmpty { tradeSection(L10n.text("Decision history", "Karar geçmişi"), trades: historyTrades, tint: TrendysseyColor.secondaryText) }
        }
    }

    private func tradeSection(_ title: String, trades: [LiveTrade], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(trades.count)").font(.caption.bold()).foregroundStyle(tint)
            }
            ForEach(trades) { trade in SurfaceCard { tradeRow(trade) } }
        }
    }

    private func tradeRow(_ trade: LiveTrade) -> some View {
        let tint = trade.entryBehaviorDirection?.color ?? TrendysseyColor.secondaryText
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(trade.symbol.replacingOccurrences(of: "USDT", with: "")).font(.headline)
                pill(statusTitle(trade), tint: statusTint(trade))
                Spacer()
                Text(trade.createdAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            if let behavior = trade.entryBehaviorKind {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: trade.entryBehaviorDirection?.icon ?? "waveform.path")
                        .foregroundStyle(tint).frame(width: 24, height: 24).background(tint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(behavior.title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                        Text("\(trade.entryBehaviorScore ?? 0)/100 · " + behaviorStatus(trade.entryBehaviorStatus))
                            .font(.caption2).monospacedDigit().foregroundStyle(TrendysseyColor.secondaryText)
                    }
                }
                if let evidence = trade.entryBehaviorEvidence, !evidence.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(evidence, id: \.self) { item in
                                Text(evidenceTitle(item)).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 4).background(tint.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                Text(L10n.text("Legacy decision · behavior was not frozen.", "Eski karar · davranış anlık görüntüsü kaydedilmemiş."))
                    .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let entry = trade.entryPrice { detail(L10n.text("Entry", "Giriş"), "$\(Self.price(entry))") }
                if trade.status == "open", let current = currentPrices[trade.symbol] { detail(L10n.text("Now", "Güncel"), "$\(Self.price(current))") }
                if let exit = trade.exitPrice { detail(L10n.text("Exit", "Çıkış"), "$\(Self.price(exit))") }
                if let pnl = trade.realizedQuotePnl { detail(L10n.text("Result", "Sonuç"), Self.signed(pnl), tint: pnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative) }
                else if let pnl = trade.unrealizedPnl(currentPrice: currentPrices[trade.symbol]) { detail(L10n.text("Open PnL", "Aktif K/Z"), Self.signed(pnl), tint: pnl >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative) }
                if let volume = trade.entryQuoteVolume { detail(L10n.text("Entry volume", "Giriş hacmi"), "$\(Self.compact(volume))") }
            }
            if let reason = trade.exitReason {
                Label(exitReason(reason, trade: trade), systemImage: "arrow.uturn.backward.circle").font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            }
            if let error = trade.errorMessage { Text(error).font(.caption2).foregroundStyle(TrendysseyColor.warning).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetAction: some View {
        Button(role: .destructive) { isConfirmingReset = true } label: {
            HStack {
                Label(L10n.text("Close positions and reset ledger", "Pozisyonları kapat ve kayıtları sıfırla"), systemImage: "arrow.counterclockwise").font(.subheadline.weight(.semibold))
                Spacer()
                if isResetting { ProgressView() }
            }
            .padding(14).background(TrendysseyColor.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isResetting || config?.resetRequested == true)
    }

    private func ruleCell(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText)
            Text(value).font(.footnote.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(10)
        .background(TrendysseyColor.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metric(_ title: String, _ value: String, tint: Color = TrendysseyColor.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(tint).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, _ value: String, tint: Color = TrendysseyColor.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(TrendysseyColor.secondaryText).lineLimit(1)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(tint).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, icon: String) -> some View {
        SurfaceCard { Label(text, systemImage: icon).font(.caption).foregroundStyle(TrendysseyColor.warning).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption2.bold()).foregroundStyle(tint).padding(.horizontal, 8).padding(.vertical, 4).background(tint.opacity(0.12), in: Capsule())
    }

    private func statusTitle(_ trade: LiveTrade) -> String {
        switch trade.status {
        case "open": L10n.text("OPEN", "AÇIK")
        case "pending_entry": L10n.text("PENDING", "BEKLİYOR")
        case "closed": (trade.realizedQuotePnl ?? 0) >= 0 ? L10n.text("WON", "KAZANDI") : L10n.text("LOST", "KAYBETTİ")
        case "canceled": L10n.text("CANCELED", "İPTAL")
        default: L10n.text("ERROR", "HATA")
        }
    }

    private func statusTint(_ trade: LiveTrade) -> Color {
        switch trade.status {
        case "open": TrendysseyColor.accent
        case "pending_entry": TrendysseyColor.warning
        case "closed": (trade.realizedQuotePnl ?? 0) >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative
        case "canceled": TrendysseyColor.secondaryText
        default: TrendysseyColor.negative
        }
    }

    private func behaviorStatus(_ status: BehavioralSignalStatus?) -> String {
        status == .confirmed ? L10n.text("confirmed", "teyitli") : L10n.text("developing", "gelişiyor")
    }

    private func evidenceTitle(_ key: String) -> String {
        switch key {
        case "structural_reclaim": L10n.text("Structural reclaim", "Yapısal geri alım")
        case "failed_breakdown": L10n.text("Breakdown rejected", "Aşağı kırılım reddi")
        case "seller_exhaustion": L10n.text("Seller exhaustion", "Satıcı tükenişi")
        case "buyer_response": L10n.text("Buyer response", "Alıcı karşılığı")
        case "recovery_strengthening": L10n.text("Recovery strengthening", "Toparlanma güçleniyor")
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func exitReason(_ reason: String, trade: LiveTrade) -> String {
        switch reason {
        case "target": L10n.text("Closed at the profit target.", "Kâr hedefinde kapandı.")
        case "stop_loss" where trade.targetPrice == nil && trade.stopPrice != nil: L10n.text("Closed by the trailing stop.", "İz süren stopta kapandı.")
        case "stop_loss": L10n.text("Closed at the stop loss.", "Stop loss'ta kapandı.")
        case "time_limit": L10n.text("Closed at the holding limit.", "Açık kalma limitinde kapandı.")
        case "manual": L10n.text("Closed manually.", "Elle kapatıldı.")
        default: L10n.text("Closed after an executor error.", "İşlemci hatasından sonra kapandı.")
        }
    }

    @MainActor private func requestReset() async {
        isResetting = true; resetFailed = false
        defer { isResetting = false }
        do { try await LiveTradingService.shared.requestReset(); await load() }
        catch { resetFailed = true }
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
            let symbols = Array(Set(loadedTrades.filter { $0.status == "open" }.map(\.symbol)))
            currentPrices = (try? await LiveTradingService.shared.currentPrices(symbols: symbols)) ?? currentPrices
        }
        loadFailed = loadedTrades == nil
    }

    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)) }
    private static func price(_ value: Double) -> String {
        let digits = value >= 1000 ? 2 : value >= 1 ? 4 : 6
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(L10n.locale))
    }
    private static func signed(_ value: Double) -> String { "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(2)).locale(L10n.locale))) USDT" }
    private static func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale)) }
}
