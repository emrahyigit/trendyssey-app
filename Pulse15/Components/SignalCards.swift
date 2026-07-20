import SwiftUI
import UIKit

struct FeaturedSignalCard: View {
    let signal: MarketSignal
    @State private var analysis: EMAJourneyAnalysis?

    private var currentPhase: SignalStatus { analysis?.currentPhase ?? signal.status }
    private var confidence: Int { analysis?.confidence ?? signal.confidence }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signal.baseSymbol).font(.title2.bold())
                        Text(currentPhase.title).font(.caption).foregroundStyle(currentPhase == .watching ? PulseColor.secondaryText : PulseColor.positive)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6))))")
                            .font(.headline)
                            .monospacedDigit()
                        Text(signal.change24h / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.bold())
                            .foregroundStyle(signal.change24h >= 0 ? PulseColor.positive : PulseColor.negative)
                    }
                }
                SignalJourneyProgress(status: currentPhase, compact: true)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) { Text(signal.qualityTitle.uppercased()).font(.caption2.bold()).foregroundStyle(PulseColor.secondaryText); Text("\(confidence)").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit() + Text(" / 100").font(.subheadline).foregroundColor(PulseColor.secondaryText) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L10n.text("24H VOLUME", "24S HACİM"))
                            .font(.caption2.bold())
                            .foregroundStyle(PulseColor.secondaryText)
                        Text("$\(signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3))))")
                            .font(.title2.bold())
                            .monospacedDigit()
                            .foregroundStyle(PulseColor.accent)
                    }
                }
            }
        }
        .task(id: "\(signal.symbol)|\(AnalysisTimeframe.selected.rawValue)") {
            analysis = EMAAnalysisCache.shared.cached(for: signal.symbol)
            if analysis == nil { analysis = await EMAAnalysisCache.shared.analysis(for: signal.symbol) }
        }
    }
}

struct SignalRow: View {
    @Environment(AppEnvironment.self) private var environment
    let signal: MarketSignal
    @State private var analysis: EMAJourneyAnalysis?

    /// Coins outside the backend's high-volume universe get live on-device
    /// analysis only for Pro members.
    private var liveAnalysisAllowed: Bool {
        signal.hasScore || environment.subscriptionStore.isSubscribed
    }

    var body: some View {
        HStack(spacing: 13) {
            SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(signal.baseSymbol).font(.headline)
                if !liveAnalysisAllowed {
                    Label(L10n.text("Live analysis with Pro", "Canlı analiz Pro'da"), systemImage: "lock.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(PulseColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else if let analysis {
                    Text("\(analysis.currentPhase.title) (\(analysis.confidence))")
                        .font(.caption.weight(.semibold)).foregroundStyle(strengthColor)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(verbatim: "Watching (00)")
                        .font(.caption.weight(.semibold)).foregroundStyle(PulseColor.secondaryText)
                        .redacted(reason: .placeholder)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6))))")
                    .font(.subheadline.bold()).monospacedDigit()
                Text(L10n.text("Vol. $\(compactDailyVolume)", "Hacim $\(compactDailyVolume)"))
                    .font(.caption2.weight(.medium)).foregroundStyle(PulseColor.secondaryText).monospacedDigit()
            }
        }.padding(15).background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 18))
            .task(id: "\(signal.symbol)|\(AnalysisTimeframe.selected.rawValue)|\(liveAnalysisAllowed)") {
                guard liveAnalysisAllowed else { return }
                analysis = EMAAnalysisCache.shared.cached(for: signal.symbol)
                if analysis == nil { analysis = await EMAAnalysisCache.shared.analysis(for: signal.symbol) }
            }
    }

    private var compactDailyVolume: String {
        signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
    }

    private var strengthColor: Color {
        guard let analysis else { return PulseColor.secondaryText }
        guard analysis.currentPhase != .watching else { return PulseColor.secondaryText }
        return switch analysis.confidence {
        case 75...: PulseColor.positive
        case 55...: PulseColor.warning
        default: PulseColor.negative
        }
    }
}

struct SignalJourneyProgress: View {
    let status: SignalStatus
    var compact = false

    private let stepCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                Label(status.phaseTitle, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(PulseColor.primaryText)
                Spacer(minLength: 8)
                Text(L10n.text("Step \(status.journeyStep + 1) of \(stepCount)", "Aşama \(status.journeyStep + 1)/\(stepCount)"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PulseColor.secondaryText)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(PulseColor.border)
                    Capsule()
                        .fill(progressColor)
                        .frame(width: max(6, proxy.size.width * progress))
                }
            }
            .frame(height: 6)
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title).font(.headline).foregroundStyle(progressColor)
                    Text(status.journeyGuidance)
                        .font(.caption).foregroundStyle(PulseColor.secondaryText).lineSpacing(3)
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
        case .confirmed, .retest: PulseColor.positive
        case .failed, .expired: PulseColor.negative
        case .watching: PulseColor.secondaryText
        case .preBreakout, .breakoutDetected: PulseColor.accent
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
