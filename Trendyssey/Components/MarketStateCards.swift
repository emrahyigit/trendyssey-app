import SwiftUI

extension MarketStateKind {
    var color: Color {
        switch self {
        case .neutral: TrendysseyColor.secondaryText
        case .sellingDominant: TrendysseyColor.warning
        case .sellerImpactFading: TrendysseyColor.accent
        case .buySideAbsorption: TrendysseyColor.accent
        case .bounceAttempt: TrendysseyColor.positive
        case .bullishConfirmation: TrendysseyColor.positive
        case .bullishMomentum: TrendysseyColor.positive
        case .breakdownRisk: TrendysseyColor.negative
        }
    }

    var systemImage: String {
        switch self {
        case .neutral: "equal.circle"
        case .sellingDominant: "arrow.down.circle.fill"
        case .sellerImpactFading: "waveform.path.ecg"
        case .buySideAbsorption: "shield.lefthalf.filled"
        case .bounceAttempt: "arrow.turn.up.right"
        case .bullishConfirmation: "checkmark.circle.fill"
        case .bullishMomentum: "bolt.circle.fill"
        case .breakdownRisk: "exclamationmark.triangle.fill"
        }
    }
}

struct MarketStateChip: View {
    let snapshot: MarketStateSnapshot

    var body: some View {
        Label(snapshot.state.title, systemImage: snapshot.state.systemImage)
            .font(.caption2.bold())
            .foregroundStyle(snapshot.state.color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(snapshot.state.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(snapshot.hasActiveState
                ? "\(snapshot.state.title), \(snapshot.stateScore) / 100"
                : L10n.text("Neutral, no active state", "Nötr, aktif durum yok"))
    }
}

struct CurrentMarketStateCard: View {
    let snapshot: MarketStateSnapshot

    private struct Metric: Identifiable {
        let id: String
        let title: String
        let value: Int
        let change: Int?
    }

    private var metrics: [Metric] {
        [
            Metric(id: "pressure", title: L10n.text("Selling pressure", "Satış baskısı"), value: snapshot.sellingPressure, change: snapshot.sellingPressureChange),
            Metric(id: "efficiency", title: L10n.text("Seller efficiency", "Satıcı etkinliği"), value: snapshot.sellerEfficiency, change: snapshot.sellerEfficiencyChange),
            Metric(id: "response", title: L10n.text("Downside response", "Aşağı yönlü tepki"), value: snapshot.downsideResponse, change: snapshot.downsideResponseChange),
            Metric(id: "absorption", title: L10n.text("Buy-side absorption", "Alıcı absorpsiyonu"), value: snapshot.absorption, change: snapshot.absorptionChange),
            Metric(id: "resilience", title: L10n.text("Price resilience", "Fiyat dayanıklılığı"), value: snapshot.priceResilience, change: snapshot.priceResilienceChange),
            Metric(id: "readiness", title: L10n.text("Bounce readiness", "Tepki hazırlığı"), value: snapshot.bounceReadiness, change: snapshot.bounceReadinessChange),
            Metric(id: "confirmation", title: L10n.text("Confirmation", "Teyit"), value: snapshot.confirmation, change: snapshot.confirmationChange),
            Metric(id: "momentum", title: L10n.text("Bullish momentum", "Yükseliş momentumu"), value: snapshot.bullishMomentum, change: snapshot.bullishMomentumChange)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("CURRENT MARKET STATE", "GÜNCEL PİYASA DURUMU"))
                        .font(.caption2.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                    Label(snapshot.state.title, systemImage: snapshot.state.systemImage)
                        .font(.title3.bold())
                        .foregroundStyle(snapshot.state.color)
                }
                Spacer(minLength: 8)
                if snapshot.hasActiveState {
                    Text("\(snapshot.stateScore)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        + Text(" / 100")
                        .font(.caption)
                        .foregroundColor(TrendysseyColor.secondaryText)
                } else {
                    Text(L10n.text("No active state", "Aktif durum yok"))
                        .font(.subheadline.bold())
                        .foregroundStyle(TrendysseyColor.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
            }
            Text(overallSummary)
                .font(.caption)
                .foregroundStyle(TrendysseyColor.secondaryText)
                .lineSpacing(2)
            Divider()
            ForEach(metrics) { metric in
                metricRow(metric)
            }
            Text(L10n.text(
                "Calculated from closed candles. This is a current statistical state, not a buy or sell instruction.",
                "Kapanmış mumlardan hesaplanır. Bu güncel istatistiksel bir durumdur; alım veya satım talimatı değildir."
            ))
            .font(.caption2)
            .foregroundStyle(TrendysseyColor.secondaryText)
            .lineSpacing(2)
        }
    }

    private func metricRow(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(metric.value)")
                    .font(.caption.bold())
                    .monospacedDigit()
                if let change = metric.change {
                    Text(signed(change))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(changeBadgeColor(change))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(changeBadgeColor(change).opacity(0.14), in: Capsule())
                        .accessibilityLabel(L10n.text("Change \(signed(change))", "Değişim \(signed(change))"))
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TrendysseyColor.border)
                    Capsule()
                        .fill(metricColor(metric))
                        .frame(width: max(3, proxy.size.width * CGFloat(metric.value) / 100))
                }
            }
            .frame(height: 5)
            Text(metricExplanation(metric))
                .font(.caption2)
                .foregroundStyle(TrendysseyColor.secondaryText)
                .lineSpacing(2)
        }
    }

    private var overallSummary: String {
        switch snapshot.state {
        case .neutral:
            L10n.text("Buyers and sellers are balanced; there is no clear market advantage right now.", "Alıcılar ve satıcılar dengeli; şu anda belirgin bir piyasa üstünlüğü yok.")
        case .sellingDominant:
            L10n.text("Sellers currently have the stronger influence on price.", "Şu anda fiyat üzerinde satıcıların etkisi daha güçlü.")
        case .sellerImpactFading:
            L10n.text("Selling continues, but it is becoming less effective at pushing price down.", "Satış sürüyor ancak fiyatı aşağı itme gücü zayıflıyor.")
        case .buySideAbsorption:
            L10n.text("Buyers are meeting the incoming supply and limiting price damage.", "Alıcılar gelen satışı karşılıyor ve fiyat üzerindeki hasarı sınırlıyor.")
        case .bounceAttempt:
            L10n.text("An upward response has started, but it still needs stronger confirmation.", "Yukarı yönlü bir tepki başladı ancak daha güçlü teyide ihtiyaç duyuyor.")
        case .bullishConfirmation:
            L10n.text("Buyer control is strengthening and the upward move is gaining confirmation.", "Alıcı kontrolü güçleniyor ve yukarı yönlü hareket teyit kazanıyor.")
        case .bullishMomentum:
            L10n.text("Price is advancing with strong, sustained upward momentum.", "Fiyat güçlü ve sürdürülebilir yükseliş momentumuyla ilerliyor.")
        case .breakdownRisk:
            L10n.text("Selling remains effective, so the risk of further downside is elevated.", "Satış etkili kalıyor; bu nedenle aşağı yönün devam riski yüksek.")
        }
    }

    private func metricExplanation(_ metric: Metric) -> String {
        let level = metric.value < 35
            ? ("low", "düşük")
            : metric.value < 65 ? ("moderate", "orta") : ("high", "yüksek")
        let subject: (String, String)
        let rising: (String, String)
        let falling: (String, String)
        switch metric.id {
        case "pressure":
            subject = ("Selling pressure", "Satış baskısı")
            rising = ("strengthening", "güçleniyor")
            falling = ("easing", "hafifliyor")
        case "efficiency":
            subject = ("Seller efficiency", "Satıcı etkinliği")
            rising = ("strengthening", "güçleniyor")
            falling = ("weakening", "zayıflıyor")
        case "response":
            subject = ("Downside response", "Aşağı yönlü tepki")
            rising = ("intensifying", "şiddetleniyor")
            falling = ("easing", "hafifliyor")
        case "absorption":
            subject = ("Buyer absorption", "Alıcı absorpsiyonu")
            rising = ("strengthening", "güçleniyor")
            falling = ("weakening", "zayıflıyor")
        case "resilience":
            subject = ("Price resilience", "Fiyat dayanıklılığı")
            rising = ("improving", "iyileşiyor")
            falling = ("weakening", "zayıflıyor")
        case "readiness":
            subject = ("Rebound readiness", "Tepki hazırlığı")
            rising = ("improving", "iyileşiyor")
            falling = ("losing strength", "güç kaybediyor")
        case "confirmation":
            subject = ("Upward confirmation", "Yukarı yönlü teyit")
            rising = ("strengthening", "güçleniyor")
            falling = ("fading", "zayıflıyor")
        case "momentum":
            subject = ("Bullish momentum", "Yükseliş momentumu")
            rising = ("accelerating", "hızlanıyor")
            falling = ("slowing", "yavaşlıyor")
        default:
            subject = (metric.title, metric.title)
            rising = ("rising", "artıyor")
            falling = ("falling", "azalıyor")
        }

        guard let change = metric.change else {
            return L10n.text(
                "\(subject.0) is \(level.0).",
                "\(subject.1) \(level.1)."
            )
        }
        if change == 0 {
            return L10n.text(
                "\(subject.0) is \(level.0) and unchanged from the previous close.",
                "\(subject.1) \(level.1) ve önceki kapanışla aynı."
            )
        }
        let points = abs(change)
        let movement = change > 0 ? rising : falling
        return L10n.text(
            "\(subject.0) is \(level.0) and \(movement.0) after a \(points)-point \(change > 0 ? "increase" : "decrease").",
            "\(subject.1) \(level.1) ve \(points) puan \(change > 0 ? "artarak" : "azalarak") \(movement.1)."
        )
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    private func changeBadgeColor(_ value: Int) -> Color {
        if value > 0 { return TrendysseyColor.positive }
        if value < 0 { return TrendysseyColor.negative }
        return TrendysseyColor.warning
    }

    private func metricColor(_ metric: Metric) -> Color {
        switch metric.id {
        case "pressure", "response": metric.value >= 70 ? TrendysseyColor.negative : TrendysseyColor.warning
        case "efficiency": metric.value >= 65 ? TrendysseyColor.negative : TrendysseyColor.accent
        case "absorption", "resilience", "readiness", "confirmation", "momentum": metric.value >= 65 ? TrendysseyColor.positive : TrendysseyColor.accent
        default: TrendysseyColor.accent
        }
    }
}
