import SwiftUI
import UIKit

/// Badge for a 75+ confirmed reversal state.
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

struct FeaturedSignalCard: View {
    let signal: MarketSignal

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
                        if signal.marketState == nil {
                            Text(L10n.text("State updating", "Durum güncelleniyor"))
                                .font(.caption).foregroundStyle(TrendysseyColor.secondaryText)
                        }
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
                if let state = signal.marketState {
                    MarketStateChip(snapshot: state)
                }
                HStack(alignment: .bottom) {
                    if let state = signal.marketState {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.hasActiveState
                                 ? L10n.text("STATE STRENGTH", "DURUM GÜCÜ")
                                 : L10n.text("CURRENT STATE", "GÜNCEL DURUM"))
                                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                            if state.hasActiveState {
                                Text("\(state.stateScore)")
                                    .font(.system(size: 52, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(state.state.color)
                                    + Text(" / 100").font(.subheadline).foregroundColor(TrendysseyColor.secondaryText)
                            } else {
                                Text(L10n.text("No active state", "Aktif durum yok"))
                                    .font(.title2.bold())
                                    .foregroundStyle(TrendysseyColor.secondaryText)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("CURRENT STATE", "GÜNCEL DURUM"))
                                .font(.caption2.bold()).foregroundStyle(TrendysseyColor.secondaryText)
                            Text(L10n.text("Updating", "Güncelleniyor"))
                                .font(.title2.bold())
                                .foregroundStyle(TrendysseyColor.secondaryText)
                        }
                    }
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

/// State strength as a chart-marked badge, for rows too tight to spell out the
/// state and its score separately.
struct StateScoreBadge: View {
    let snapshot: MarketStateSnapshot

    var body: some View {
        // Hand-built rather than a Label: in a tight row Label lets its title
        // compress until the number wraps onto its own lines, which is what
        // made the badge unreadable.
        HStack(spacing: 3) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 8, weight: .bold))
            Text("\(snapshot.stateScore)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(snapshot.state.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(snapshot.state.color.opacity(0.14), in: Capsule())
            .accessibilityLabel(L10n.text(
                "State strength \(snapshot.stateScore) of 100",
                "Durum gücü 100 üzerinden \(snapshot.stateScore)"
            ))
    }
}

struct SignalRow: View {
    let signal: MarketSignal
    /// The scanner lists every coin for lookup, so it does not pitch setups.
    var showsAPlus = true

    var body: some View {
        HStack(spacing: 13) {
            SymbolMark(symbol: signal.baseSymbol, iconURL: signal.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(signal.baseSymbol).font(.headline)
                        .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    if let state = signal.marketState, state.hasActiveState {
                        StateScoreBadge(snapshot: state)
                    }
                    if showsAPlus, signal.isAPlusSetup { APlusSetupBadge() }
                }
                if signal.hasScore {
                    Text(signal.marketState?.state.title ?? L10n.text("State updating", "Durum güncelleniyor"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(signal.marketState?.state.color ?? TrendysseyColor.secondaryText)
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

}

struct SymbolMark: View {
    let symbol: String
    let iconURL: String?
    @State private var icon: UIImage?
    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon).resizable().scaledToFit().padding(5)
            } else {
                // The public icon CDNs do not carry every listing, and a blank
                // 42pt hole reads as a broken row. A monogram always renders.
                Text(symbol.prefix(3))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(TrendysseyColor.secondaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TrendysseyColor.elevated, in: Circle())
                    .overlay(Circle().stroke(TrendysseyColor.border, lineWidth: 0.5))
            }
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
