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

extension MarketStateKind {
    /// Coloured by who the state favours, not by who is currently pressing:
    /// sellers absorbing a rally is a warning, not a green light.
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
            .accessibilityLabel(snapshot.hasActiveState
                ? "\(snapshot.headline), \(snapshot.stateScore) / 100"
                : L10n.text("Market is quiet", "Piyasa durgun"))
    }
}

/// The contest as one row: both sides of a dimension on a shared 0-100 scale,
/// meeting in the middle so the longer bar is the side winning that dimension.
private struct ContestRow: View {
    let pair: MarketMetricPair

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each side's number sits on its own side of the title, matching
            // the bar underneath. Reading them both from the right, as they
            // were, fought the geometry they describe.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    Text("\(pair.sellerValue)")
                        .font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(TrendysseyColor.negative)
                    deltaBadge(pair.sellerChange, side: .sellers)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(pair.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)

                HStack(spacing: 4) {
                    deltaBadge(pair.buyerChange, side: .buyers)
                    Text("\(pair.buyerValue)")
                        .font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(TrendysseyColor.positive)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GeometryReader { proxy in
                let half = proxy.size.width / 2
                ZStack {
                    Capsule().fill(TrendysseyColor.border)
                    HStack(spacing: 1) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Capsule()
                                .fill(TrendysseyColor.negative)
                                .frame(width: max(2, half * CGFloat(pair.sellerValue) / 100))
                        }
                        .frame(width: half)
                        HStack(spacing: 0) {
                            Capsule()
                                .fill(TrendysseyColor.positive)
                                .frame(width: max(2, half * CGFloat(pair.buyerValue) / 100))
                            Spacer(minLength: 0)
                        }
                        .frame(width: half)
                    }
                }
            }
            .frame(height: 5)
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(TrendysseyColor.secondaryText)
                .lineSpacing(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(pair.title): \(L10n.text("sellers", "satıcılar")) \(pair.sellerValue)\(spoken(pair.sellerChange)), \(L10n.text("buyers", "alıcılar")) \(pair.buyerValue)\(spoken(pair.buyerChange))"
        )
    }

    /// Movement since the previous close. A metric that did not move needs no
    /// badge — the level already says where it stands — and a first reading has
    /// nothing to compare against, so both render as nothing.
    @ViewBuilder private func deltaBadge(_ change: Int?, side: MarketControlSide) -> some View {
        if let change, change != 0 {
            // Coloured by whether the move helps the reader, who can only be
            // long: buyers gaining is green, sellers gaining is red. Every
            // column argues for its own side, so this holds on all six rows.
            let helpsReader = side == .buyers ? change > 0 : change < 0
            let tint = helpsReader ? TrendysseyColor.positive : TrendysseyColor.negative
            // A true minus sign rather than a hyphen, so it matches the weight
            // of the plus beside it instead of reading as a stub.
            Text(change > 0 ? "+\(change)" : "\u{2212}\(abs(change))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule())
        }
    }

    private func spoken(_ change: Int?) -> String {
        guard let change, change != 0 else { return "" }
        return change > 0
            ? L10n.text(", up \(change)", ", \(change) arttı")
            : L10n.text(", down \(abs(change))", ", \(abs(change)) azaldı")
    }

    private var explanation: String {
        switch pair.id {
        case "pressure":
            switch pair.leader {
            case .sellers: L10n.text(
                "Sellers are swinging harder than buyers right now.",
                "Şu anda satıcılar alıcılardan daha sert vuruyor."
            )
            case .buyers: L10n.text(
                "Buyers are swinging harder than sellers right now.",
                "Şu anda alıcılar satıcılardan daha sert vuruyor."
            )
            case .contested: L10n.text(
                "Both sides are pressing with about the same force.",
                "İki taraf da yaklaşık aynı güçle bastırıyor."
            )
            }
        case "efficiency":
            switch pair.leader {
            case .sellers: L10n.text(
                "Sellers get more price movement per unit of flow than buyers do.",
                "Satıcılar, harcadıkları akış başına alıcılardan daha fazla fiyat hareketi alıyor."
            )
            case .buyers: L10n.text(
                "Buyers get more price movement per unit of flow than sellers do.",
                "Alıcılar, harcadıkları akış başına satıcılardan daha fazla fiyat hareketi alıyor."
            )
            case .contested: L10n.text(
                "Neither side converts its flow into price better than the other.",
                "Hiçbir taraf akışını fiyata diğerinden daha iyi çeviremiyor."
            )
            }
        case "response":
            switch pair.leader {
            case .sellers: L10n.text(
                "Price has travelled further down than up over the window.",
                "Fiyat, pencere boyunca aşağı yönde yukarıdan daha çok yol aldı."
            )
            case .buyers: L10n.text(
                "Price has travelled further up than down over the window.",
                "Fiyat, pencere boyunca yukarı yönde aşağıdan daha çok yol aldı."
            )
            case .contested: L10n.text(
                "Price has gone nowhere in particular; the two directions cancel out.",
                "Fiyat belirli bir yere gitmedi; iki yön birbirini götürüyor."
            )
            }
        case "absorption":
            switch pair.leader {
            case .sellers: L10n.text(
                "Sellers are quietly selling into the buying.",
                "Satıcılar sessizce alımın içine satıyor."
            )
            case .buyers: L10n.text(
                "Buyers are quietly taking the other side of the selling.",
                "Alıcılar sessizce satışın karşı tarafını alıyor."
            )
            case .contested: L10n.text(
                "Neither side is absorbing the other in any meaningful amount.",
                "Hiçbir taraf diğerini anlamlı ölçüde emmiyor."
            )
            }
        case "readiness":
            switch pair.leader {
            case .sellers: L10n.text(
                "Price is coiled nearer its high, where a turn down would start.",
                "Fiyat, aşağı dönüşün başlayacağı tepeye yakın bir yerde sıkışmış."
            )
            case .buyers: L10n.text(
                "Price is coiled nearer its low, where a turn up would start.",
                "Fiyat, yukarı dönüşün başlayacağı dibe yakın bir yerde sıkışmış."
            )
            case .contested: L10n.text(
                "Price is mid-range and still wide; neither turn has a floor yet.",
                "Fiyat aralığın ortasında ve hâlâ geniş; iki dönüşün de henüz zemini yok."
            )
            }
        case "resilience":
            switch pair.leader {
            case .sellers: L10n.text(
                "Sellers held price down better than buyers held it up.",
                "Satıcılar fiyatı aşağıda tutmayı, alıcıların yukarıda tutmasından daha iyi başardı."
            )
            case .buyers: L10n.text(
                "Buyers held price up better than sellers held it down.",
                "Alıcılar fiyatı yukarıda tutmayı, satıcıların aşağıda tutmasından daha iyi başardı."
            )
            case .contested: L10n.text(
                "Both sides defended price about equally well.",
                "İki taraf da fiyatı yaklaşık aynı ölçüde savundu."
            )
            }
        default:
            ""
        }
    }
}

struct CurrentMarketStateCard: View {
    let snapshot: MarketStateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            Text(snapshot.state.explanation)
                .font(.caption)
                .foregroundStyle(TrendysseyColor.secondaryText)
                .lineSpacing(2)
            Divider()
            Text(L10n.text("WHO IS WINNING WHAT", "HANGİ BOYUTU KİM KAZANIYOR"))
                .font(.caption2.bold())
                .foregroundStyle(TrendysseyColor.secondaryText)
            ForEach(snapshot.metricPairs) { pair in
                ContestRow(pair: pair)
            }
            Text(L10n.text(
                "Calculated from closed candles. This describes the current balance of buying and selling, not a buy or sell instruction.",
                "Kapanmış mumlardan hesaplanır. Bu, alım ve satımın güncel dengesini anlatır; alım veya satım talimatı değildir."
            ))
            .font(.caption2)
            .foregroundStyle(TrendysseyColor.secondaryText)
            .lineSpacing(2)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("MARKET CONTROL", "PİYASA KONTROLÜ"))
                        .font(.caption2.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                    Label(snapshot.headline, systemImage: snapshot.state.systemImage)
                        .font(.subheadline.bold())
                        .foregroundStyle(snapshot.state.color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if snapshot.hasActiveState {
                    Text("\(snapshot.stateScore)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        + Text(" / 100")
                        .font(.caption)
                        .foregroundColor(TrendysseyColor.secondaryText)
                }
            }
            // Two facts, not one sentence: who holds control, and what is
            // happening to their grip. "SELLERS · WEAKENING" reads faster than
            // the state name it is built from.
            HStack(spacing: 8) {
                factBox(
                    caption: L10n.text("CONTROL", "KONTROL"),
                    value: snapshot.state.controlSide == .contested
                        ? L10n.text("SPLIT", "PAYLAŞILMIŞ")
                        : snapshot.state.controlSide.label.uppercased(),
                    tint: snapshot.state.controlSide.color,
                    icon: snapshot.state.controlSide == .sellers
                        ? "arrow.down"
                        : snapshot.state.controlSide == .buyers ? "arrow.up" : "arrow.left.arrow.right"
                )
                factBox(
                    caption: L10n.text("PHASE", "DURUM"),
                    value: snapshot.state.stage.label,
                    tint: snapshot.state.color,
                    icon: snapshot.state.systemImage
                )
            }
        }
    }

    private func factBox(caption: String, value: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TrendysseyColor.secondaryText)
            Label(value, systemImage: icon)
                .font(.footnote.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    private func changeBadgeColor(_ value: Int) -> Color {
        if value > 0 { return TrendysseyColor.positive }
        if value < 0 { return TrendysseyColor.negative }
        return TrendysseyColor.warning
    }
}
