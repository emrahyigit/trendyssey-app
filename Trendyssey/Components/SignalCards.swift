import SwiftUI
import UIKit

struct FeaturedSignalCard: View {
    let signal: MarketSignal
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    // Phase and score come straight from the server's signal row — the same
    // values that drove the push notification and the lists.
    private var currentPhase: SignalStatus { signal.status }
    private var direction: JourneyDirection { (JourneyModel(rawValue: journeyModel) ?? .emaCross).direction }
    private var confidence: Int { signal.confidence }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signal.baseSymbol).font(.title2.bold())
                        Text(currentPhase.title(direction)).font(.caption).foregroundStyle(currentPhase == .watching ? TrendysseyColor.secondaryText : TrendysseyColor.positive)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6)).locale(L10n.locale)))")
                            .font(.headline)
                            .monospacedDigit()
                        Text(signal.change24h / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.bold())
                            .foregroundStyle(signal.change24h >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                    }
                }
                SignalJourneyProgress(status: currentPhase, direction: direction, compact: true)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) { Text(signal.qualityTitle.uppercased()).font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText); Text("\(confidence)").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit() + Text(" / 100").font(.subheadline).foregroundColor(TrendysseyColor.secondaryText) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L10n.text("24H VOLUME", "24S HACİM"))
                            .font(.caption2.bold())
                            .foregroundStyle(TrendysseyColor.secondaryText)
                        Text("$\(signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale)))")
                            .font(.title2.bold())
                            .monospacedDigit()
                            .foregroundStyle(TrendysseyColor.accent)
                    }
                }
            }
        }
    }
}

struct SignalRow: View {
    let signal: MarketSignal
    @AppStorage(JourneyModel.storageKey) private var journeyModel = JourneyModel.emaCross.rawValue

    private var direction: JourneyDirection { (JourneyModel(rawValue: journeyModel) ?? .emaCross).direction }

    var body: some View {
        HStack(spacing: 13) {
            SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(signal.baseSymbol).font(.headline)
                if signal.hasScore {
                    Text("\(signal.status.title(direction)) (\(signal.confidence))")
                        .font(.caption.weight(.semibold)).foregroundStyle(strengthColor)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Label(L10n.text("Not enough volume to analyze", "Analiz için yeterli hacim yok"), systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption.weight(.semibold)).foregroundStyle(TrendysseyColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6)).locale(L10n.locale)))")
                    .font(.subheadline.bold()).monospacedDigit()
                Text(L10n.text("Vol. $\(compactDailyVolume)", "Hacim $\(compactDailyVolume)"))
                    .font(.caption2.weight(.medium)).foregroundStyle(TrendysseyColor.secondaryText).monospacedDigit()
            }
        }.padding(15).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var compactDailyVolume: String {
        signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3)).locale(L10n.locale))
    }

    private var strengthColor: Color {
        guard signal.status != .watching else { return TrendysseyColor.secondaryText }
        return switch signal.confidence {
        case 75...: TrendysseyColor.positive
        case 55...: TrendysseyColor.warning
        default: TrendysseyColor.negative
        }
    }
}

struct SignalJourneyProgress: View {
    let status: SignalStatus
    var direction: JourneyDirection = .bullish
    var compact = false

    private let stepCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                Label(status.phaseTitle(direction), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.primaryText)
                Spacer(minLength: 8)
                Text(L10n.text("Step \(status.journeyStep + 1) of \(stepCount)", "Aşama \(status.journeyStep + 1)/\(stepCount)"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TrendysseyColor.secondaryText)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TrendysseyColor.border)
                    Capsule()
                        .fill(progressColor)
                        .frame(width: max(6, proxy.size.width * progress))
                }
            }
            .frame(height: 6)
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title(direction)).font(.headline).foregroundStyle(progressColor)
                    Text(status.journeyGuidance(direction))
                        .font(.caption).foregroundStyle(TrendysseyColor.secondaryText).lineSpacing(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: CGFloat {
        CGFloat(status.journeyStep + 1) / CGFloat(stepCount)
    }

    private var progressColor: Color {
        switch status {
        case .confirmed, .retest: TrendysseyColor.positive
        case .failed, .expired: TrendysseyColor.negative
        case .watching: TrendysseyColor.secondaryText
        case .preBreakout, .breakoutDetected: TrendysseyColor.accent
        }
    }
}

struct SymbolMark: View {
    let symbol: String
    let iconURL: String?
    @State private var icon: UIImage?
    var body: some View {
        Group {
            if let icon { Image(uiImage: icon).resizable().scaledToFit().padding(5) }
            else { Color.clear }
        }
        .frame(width: 42, height: 42)
        .accessibilityLabel(L10n.text("\(symbol) icon", "\(symbol) ikonu"))
        .task(id: "\(symbol)|\(iconURL ?? "")") { icon = await loadIcon() }
    }

    private func loadIcon() async -> UIImage? {
        let code = symbol.lowercased()
        let candidates = [iconURL].compactMap { $0 } + [
            "https://assets.coincap.io/assets/icons/\(code)@2x.png",
            "https://raw.githubusercontent.com/spothq/cryptocurrency-icons/master/128/color/\(code).png"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate), let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200, let image = UIImage(data: data) else { continue }
            return image
        }
        return nil
    }
}
