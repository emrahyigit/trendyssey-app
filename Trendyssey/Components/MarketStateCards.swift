import SwiftUI

extension MarketControlSide {
    var color: Color {
        switch self {
        case .sellers: TrendysseyColor.negative
        case .buyers: TrendysseyColor.positive
        case .contested: TrendysseyColor.secondaryText
        }
    }

    var label: String {
        switch self {
        case .sellers: L10n.text("Sellers", "Satıcılar")
        case .buyers: L10n.text("Buyers", "Alıcılar")
        case .contested: L10n.text("Neither", "Hiçbiri")
        }
    }
}

extension BehavioralDirection {
    var color: Color {
        switch self {
        case .bullish: TrendysseyColor.positive
        case .bearish: TrendysseyColor.negative
        case .neutral: TrendysseyColor.secondaryText
        }
    }

    var icon: String {
        switch self {
        case .bullish: "arrow.up.right"
        case .bearish: "arrow.down.right"
        case .neutral: "arrow.left.and.right"
        }
    }
}

extension MarketStateKind {
    var color: Color {
        switch self {
        case .sellerDominance, .sellerTakeover, .sellSideAbsorption, .buyerExhaustion:
            TrendysseyColor.negative
        case .buyerDominance, .buyerTakeover, .buySideAbsorption, .sellerExhaustion:
            TrendysseyColor.positive
        case .sellerImpactFading, .buyerImpactFading:
            TrendysseyColor.accent
        case .balanced, .lowParticipation:
            TrendysseyColor.secondaryText
        }
    }

    var systemImage: String {
        switch self {
        case .sellerDominance: "arrow.down.circle.fill"
        case .sellerImpactFading: "waveform.path.ecg"
        case .buySideAbsorption: "shield.lefthalf.filled"
        case .sellerExhaustion: "battery.25"
        case .buyerTakeover: "arrow.turn.up.right"
        case .buyerDominance: "arrow.up.circle.fill"
        case .buyerImpactFading: "waveform.path.ecg"
        case .sellSideAbsorption: "shield.righthalf.filled"
        case .buyerExhaustion: "battery.25"
        case .sellerTakeover: "arrow.turn.down.right"
        case .balanced: "arrow.left.arrow.right"
        case .lowParticipation: "moon.zzz"
        }
    }
}

struct MarketStateChip: View {
    let snapshot: MarketStateSnapshot

    var body: some View {
        Label(snapshot.headline, systemImage: snapshot.state.systemImage)
            .font(.caption2.bold())
            .foregroundStyle(snapshot.state.color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(snapshot.state.color.opacity(0.12), in: Capsule())
    }
}

/// Product-facing behavioral read. The old control grid is intentionally not
/// rendered here: users first see what is developing, why, and what evidence
/// is still missing before a transition can be considered confirmed.
struct CurrentMarketStateCard: View {
    let snapshot: MarketStateSnapshot

    private var leading: BehavioralSignal? { snapshot.leadingBehavioralSignal }
    private var confirmed: Bool { leading?.status == .confirmed }
    private var direction: BehavioralDirection { leading?.direction ?? .neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            context
            behaviorPath
            if let leading {
                evidence(for: leading)
            }
            transitionRead
            if snapshot.behavioralSignals.count > 1 {
                otherSignals
            }
            footer
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("BEHAVIORAL READ", "DAVRANIŞSAL OKUMA"))
                        .font(.caption2.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                    if let leading {
                        Label(leading.kind.title, systemImage: direction.icon)
                            .font(.title3.bold())
                            .foregroundStyle(direction.color)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(
                            L10n.text("No distinct transition", "Belirgin geçiş yok"),
                            systemImage: "waveform.path"
                        )
                        .font(.title3.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if let leading {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(leading.score)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(direction.color)
                        Text(confirmed
                             ? L10n.text("CONFIRMED", "DOĞRULANDI")
                             : L10n.text("DEVELOPING", "GELİŞİYOR"))
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(confirmed ? Color.black : direction.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                confirmed ? direction.color : direction.color.opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
            }
            Text(leading?.kind.explanation ?? L10n.text(
                "The latest closed candles do not show a strong behavioral divergence yet.",
                "Son kapanmış mumlarda henüz güçlü bir davranışsal ayrışma görülmüyor."
            ))
            .font(.subheadline)
            .foregroundStyle(TrendysseyColor.secondaryText)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(direction.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(direction.color.opacity(0.22), lineWidth: 1))
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(L10n.text("CONTEXT", "BAĞLAM"))
            HStack(spacing: 8) {
                contextPill(title: regimeTitle, icon: regimeIcon, tint: regimeColor)
                contextPill(
                    title: snapshot.context.priceVsEma99 == .above
                        ? L10n.text("Above EMA99", "EMA99 üzerinde")
                        : L10n.text("Below EMA99", "EMA99 altında"),
                    icon: "point.3.connected.trianglepath.dotted",
                    tint: snapshot.context.priceVsEma99 == .above
                        ? TrendysseyColor.positive
                        : TrendysseyColor.negative
                )
            }
            Text(snapshot.context.localizedSummary)
                .font(.caption)
                .foregroundStyle(TrendysseyColor.secondaryText)
        }
    }

    private var behaviorPath: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(L10n.text("WHAT IS CHANGING", "NE DEĞİŞİYOR"))
            HStack(spacing: 10) {
                behaviorStep(
                    title: L10n.text("Seller exhaustion", "Satıcı tükenişi"),
                    value: snapshot.behavioralScores.sellerExhaustion,
                    tint: TrendysseyColor.positive,
                    threshold: 65
                )
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TrendysseyColor.secondaryText)
                behaviorStep(
                    title: L10n.text("Buyer response", "Alıcı karşılığı"),
                    value: snapshot.behavioralScores.buyerResponse,
                    tint: TrendysseyColor.positive,
                    threshold: 60
                )
            }
            HStack(spacing: 10) {
                behaviorStep(
                    title: L10n.text("Buyer exhaustion", "Alıcı tükenişi"),
                    value: snapshot.behavioralScores.buyerExhaustion,
                    tint: TrendysseyColor.negative,
                    threshold: 65
                )
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TrendysseyColor.secondaryText)
                behaviorStep(
                    title: L10n.text("Seller response", "Satıcı karşılığı"),
                    value: snapshot.behavioralScores.sellerResponse,
                    tint: TrendysseyColor.negative,
                    threshold: 60
                )
            }
            Text(L10n.text(
                "Weakness and the opposite side's response are measured separately; one does not imply the other.",
                "Zayıflık ile karşı tarafın cevabı ayrı ölçülür; biri diğerini otomatik olarak göstermez."
            ))
            .font(.caption2)
            .foregroundStyle(TrendysseyColor.secondaryText)
        }
    }

    private func evidence(for signal: BehavioralSignal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(L10n.text("EVIDENCE", "KANITLAR"))
            FlowLayout(spacing: 7) {
                ForEach(signal.evidence, id: \.self) { item in
                    Label(evidenceTitle(item), systemImage: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(direction.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(direction.color.opacity(0.10), in: Capsule())
                }
            }
        }
    }

    private var transitionRead: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(L10n.text("CONFIRMATION", "DOĞRULAMA"))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: confirmed ? "checkmark.seal.fill" : "hourglass")
                    .foregroundStyle(confirmed ? direction.color : TrendysseyColor.warning)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmed
                         ? L10n.text("Structural transition confirmed", "Yapısal geçiş doğrulandı")
                         : L10n.text("Transition not confirmed yet", "Geçiş henüz doğrulanmadı"))
                        .font(.subheadline.bold())
                        .foregroundStyle(confirmed ? direction.color : TrendysseyColor.warning)
                    Text(transitionExplanation)
                        .font(.caption)
                        .foregroundStyle(TrendysseyColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (confirmed ? direction.color : TrendysseyColor.warning).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
    }

    private var otherSignals: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(L10n.text("OTHER READS", "DİĞER OKUMALAR"))
            ForEach(Array(snapshot.behavioralSignals.dropFirst().prefix(4))) { signal in
                HStack(spacing: 9) {
                    Image(systemName: signal.status == .confirmed ? "checkmark.seal.fill" : "waveform.path.ecg")
                        .foregroundStyle(signal.direction.color)
                    Text(signal.kind.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text("\(signal.score)")
                        .font(.caption.bold())
                        .monospacedDigit()
                        .foregroundStyle(signal.direction.color)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(L10n.text("Closed candle: ", "Kapanmış mum: "))
            Text(snapshot.candleCloseTime, style: .relative)
            Spacer()
            Text(L10n.text("Not investment advice", "Yatırım tavsiyesi değil"))
        }
        .font(.caption2)
        .foregroundStyle(TrendysseyColor.secondaryText)
    }

    private func behaviorStep(title: String, value: Int, tint: Color, threshold: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(value)")
                    .font(.headline.bold())
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            ProgressView(value: Double(value), total: 100)
                .tint(tint)
            Text(value >= threshold
                 ? L10n.text("Threshold met", "Eşik geçildi")
                 : L10n.text("Needs \(threshold)", "\(threshold) gerekli"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(value >= threshold ? tint : TrendysseyColor.secondaryText)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(TrendysseyColor.elevated, in: RoundedRectangle(cornerRadius: 13))
    }

    private func contextPill(title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.bold())
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tint.opacity(0.09), in: Capsule())
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .tracking(0.7)
            .foregroundStyle(TrendysseyColor.secondaryText)
    }

    private var regimeTitle: String {
        switch snapshot.context.regime {
        case .bullish: L10n.text("Bullish regime", "Yükseliş rejimi")
        case .bearish: L10n.text("Bearish regime", "Düşüş rejimi")
        case .range: L10n.text("Range regime", "Yatay rejim")
        }
    }

    private var regimeIcon: String {
        switch snapshot.context.regime {
        case .bullish: "chart.line.uptrend.xyaxis"
        case .bearish: "chart.line.downtrend.xyaxis"
        case .range: "arrow.left.and.right"
        }
    }

    private var regimeColor: Color {
        switch snapshot.context.regime {
        case .bullish: TrendysseyColor.positive
        case .bearish: TrendysseyColor.negative
        case .range: TrendysseyColor.secondaryText
        }
    }

    private var transitionExplanation: String {
        if confirmed {
            return L10n.text(
                "Weakness, opposite-side response and a structural break now agree.",
                "Zayıflık, karşı tarafın cevabı ve yapısal kırılım artık aynı şeyi söylüyor."
            )
        }
        if direction == .bullish {
            if snapshot.behavioralScores.sellerExhaustion < 65 {
                return L10n.text("Seller effectiveness must deteriorate further before a bullish handover can qualify.", "Yükseliş yönlü devralım için satıcı etkinliğinin daha fazla bozulması gerekiyor.")
            }
            if snapshot.behavioralScores.buyerResponse < 60 {
                return L10n.text("Sellers are weakening, but buyers have not responded strongly enough yet.", "Satıcılar zayıflıyor ancak alıcıların cevabı henüz yeterince güçlü değil.")
            }
            return L10n.text("Behavior is aligned, but price still needs a structural reclaim.", "Davranış uyumlu ancak fiyatın hâlâ yapısal bir seviyeyi geri alması gerekiyor.")
        }
        if direction == .bearish {
            if snapshot.behavioralScores.buyerExhaustion < 65 {
                return L10n.text("Buyer effectiveness must deteriorate further before a bearish handover can qualify.", "Düşüş yönlü devralım için alıcı etkinliğinin daha fazla bozulması gerekiyor.")
            }
            if snapshot.behavioralScores.sellerResponse < 60 {
                return L10n.text("Buyers are weakening, but sellers have not responded strongly enough yet.", "Alıcılar zayıflıyor ancak satıcıların cevabı henüz yeterince güçlü değil.")
            }
            return L10n.text("Behavior is aligned, but price still needs a structural breakdown.", "Davranış uyumlu ancak fiyatın hâlâ yapısal bir seviyeyi kırması gerekiyor.")
        }
        return L10n.text("No side has assembled enough evidence for a handover.", "Hiçbir taraf devralım için yeterli kanıtı bir araya getirmedi.")
    }

    private func evidenceTitle(_ key: String) -> String {
        switch key {
        case "seller_pressure_present": L10n.text("Seller pressure present", "Satıcı baskısı var")
        case "buyer_pressure_present": L10n.text("Buyer pressure present", "Alıcı baskısı var")
        case "no_meaningful_new_low": L10n.text("No meaningful new low", "Anlamlı yeni dip yok")
        case "no_meaningful_new_high": L10n.text("No meaningful new high", "Anlamlı yeni tepe yok")
        case "downside_extensions_shrinking": L10n.text("Downside extensions shrinking", "Aşağı uzamalar küçülüyor")
        case "upside_extensions_shrinking": L10n.text("Upside extensions shrinking", "Yukarı uzamalar küçülüyor")
        case "seller_pressure_rising": L10n.text("Seller pressure rising", "Satıcı baskısı artıyor")
        case "buyer_pressure_rising": L10n.text("Buyer pressure rising", "Alıcı baskısı artıyor")
        case "downside_response_falling": L10n.text("Downside response falling", "Düşüş tepkisi azalıyor")
        case "upside_response_falling": L10n.text("Upside response falling", "Yükseliş tepkisi azalıyor")
        case "support_broken": L10n.text("Support was broken", "Destek kırıldı")
        case "support_reclaimed": L10n.text("Support reclaimed", "Destek geri alındı")
        case "resistance_broken": L10n.text("Resistance was broken", "Direnç kırıldı")
        case "resistance_rejected": L10n.text("Resistance rejected", "Direnç reddedildi")
        case "recovery_ratio_rising": L10n.text("Recovery ratio rising", "Toparlanma oranı artıyor")
        case "recovery_speed_measured": L10n.text("Recovery speed improving", "Toparlanma hızı iyileşiyor")
        case "seller_efficiency_falling": L10n.text("Seller efficiency falling", "Satıcı etkinliği düşüyor")
        case "buyer_efficiency_falling": L10n.text("Buyer efficiency falling", "Alıcı etkinliği düşüyor")
        case "downside_progress_falling": L10n.text("Downside progress fading", "Düşüş ilerlemesi zayıflıyor")
        case "upside_progress_falling": L10n.text("Upside progress fading", "Yükseliş ilerlemesi zayıflıyor")
        case "seller_exhaustion": L10n.text("Seller exhaustion", "Satıcı tükenişi")
        case "buyer_exhaustion": L10n.text("Buyer exhaustion", "Alıcı tükenişi")
        case "buyer_response": L10n.text("Buyer response", "Alıcı karşılığı")
        case "seller_response": L10n.text("Seller response", "Satıcı karşılığı")
        case "structure_reclaimed": L10n.text("Structure reclaimed", "Yapı geri alındı")
        case "structure_broken": L10n.text("Structure broken", "Yapı kırıldı")
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// A compact wrapping layout for evidence chips without truncating longer
/// Turkish labels or committing the screen to a fixed grid.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
