import SwiftUI
import UIKit

enum TrendScoreStyle {
    static func color(_ score: Int) -> Color {
        switch score {
        case 70...: TrendysseyColor.positive
        case 45..<70: TrendysseyColor.warning
        default: TrendysseyColor.secondaryText
        }
    }

    static func levelTitle(_ score: Int) -> String {
        switch score {
        case 70...: L10n.text("Strong trend", "Güçlü trend")
        case 45..<70: L10n.text("Developing trend", "Gelişen trend")
        default: L10n.text("Weak trend", "Zayıf trend")
        }
    }
}

/// Badge for the backtested A+ entry: fresh 55-candle breakout with regime
/// and momentum aligned (`trend_entry` on the backend).
struct APlusSetupBadge: View {
    var body: some View {
        Text(verbatim: "A+")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(TrendysseyColor.accent, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityLabel(L10n.text("A+ setup", "A+ kurulum"))
    }
}

struct TrendScoreChip: View {
    let score: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 8, weight: .bold))
            Text("\(score)").monospacedDigit()
        }
        .font(.caption2.bold())
        .foregroundStyle(TrendScoreStyle.color(score))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(TrendScoreStyle.color(score).opacity(0.12), in: Capsule())
        .accessibilityLabel(L10n.text("Trend score \(score)", "Trend puanı \(score)"))
    }
}

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
                        HStack(spacing: 6) {
                            Text(signal.baseSymbol).font(.title2.bold())
                            if signal.isAPlusSetup { APlusSetupBadge() }
                        }
                        Text(currentPhase.title).font(.caption).foregroundStyle(currentPhase == .watching ? TrendysseyColor.secondaryText : TrendysseyColor.positive)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6))))")
                            .font(.headline)
                            .monospacedDigit()
                        Text(signal.change24h / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.bold())
                            .foregroundStyle(signal.change24h >= 0 ? TrendysseyColor.positive : TrendysseyColor.negative)
                    }
                }
                SignalJourneyProgress(status: currentPhase, compact: true)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) { Text(signal.qualityTitle.uppercased()).font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText); Text("\(confidence)").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit() + Text(" / 100").font(.subheadline).foregroundColor(TrendysseyColor.secondaryText) }
                    Spacer()
                    if let trendScore = signal.effectiveTrendScore {
                        VStack(spacing: 3) {
                            Text(L10n.text("TREND", "TREND"))
                                .font(.caption2.bold())
                                .foregroundStyle(TrendysseyColor.secondaryText)
                            Text("\(trendScore)")
                                .font(.title2.bold())
                                .monospacedDigit()
                                .foregroundStyle(TrendScoreStyle.color(trendScore))
                        }
                        .accessibilityLabel(L10n.text("Trend score \(trendScore)", "Trend puanı \(trendScore)"))
                        Spacer()
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L10n.text("24H VOLUME", "24S HACİM"))
                            .font(.caption2.bold())
                            .foregroundStyle(TrendysseyColor.secondaryText)
                        Text("$\(signal.quoteVolume24h.formatted(.number.notation(.compactName).precision(.significantDigits(3))))")
                            .font(.title2.bold())
                            .monospacedDigit()
                            .foregroundStyle(TrendysseyColor.accent)
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
                HStack(spacing: 6) {
                    Text(signal.baseSymbol).font(.headline)
                    if let trendScore = signal.effectiveTrendScore { TrendScoreChip(score: trendScore) }
                    if signal.isAPlusSetup { APlusSetupBadge() }
                }
                if !liveAnalysisAllowed {
                    Label(L10n.text("Live analysis with Pro", "Canlı analiz Pro'da"), systemImage: "lock.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(TrendysseyColor.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else if let analysis {
                    Text("\(analysis.currentPhase.title) (\(analysis.confidence))")
                        .font(.caption.weight(.semibold)).foregroundStyle(strengthColor)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(verbatim: "Watching (00)")
                        .font(.caption.weight(.semibold)).foregroundStyle(TrendysseyColor.secondaryText)
                        .redacted(reason: .placeholder)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(signal.price.formatted(.number.precision(.fractionLength(2...6))))")
                    .font(.subheadline.bold()).monospacedDigit()
                Text(L10n.text("Vol. $\(compactDailyVolume)", "Hacim $\(compactDailyVolume)"))
                    .font(.caption2.weight(.medium)).foregroundStyle(TrendysseyColor.secondaryText).monospacedDigit()
            }
        }.padding(15).background(TrendysseyColor.surface, in: RoundedRectangle(cornerRadius: 18))
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
        guard let analysis else { return TrendysseyColor.secondaryText }
        guard analysis.currentPhase != .watching else { return TrendysseyColor.secondaryText }
        return switch analysis.confidence {
        case 75...: TrendysseyColor.positive
        case 55...: TrendysseyColor.warning
        default: TrendysseyColor.negative
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
                    Text(status.title).font(.headline).foregroundStyle(progressColor)
                    Text(status.journeyGuidance)
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
