import Foundation

enum AnalysisTimeframe: String, CaseIterable, Identifiable, Sendable {
    case m15 = "15m", h1 = "1h", h4 = "4h", d1 = "1d"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .m15: L10n.text("15 minutes", "15 dakika")
        case .h1: L10n.text("1 hour", "1 saat")
        case .h4: L10n.text("4 hours", "4 saat")
        case .d1: L10n.text("1 day", "1 gün")
        }
    }
    static var selected: AnalysisTimeframe { AnalysisTimeframe(rawValue: UserDefaults.standard.string(forKey: "preferredTimeframe") ?? "15m") ?? .m15 }

    /// Candle length in minutes, used to work out how far back a fixed number of
    /// candles actually reaches.
    nonisolated var minutes: Int {
        switch self {
        case .m15: 15
        case .h1: 60
        case .h4: 240
        case .d1: 1_440
        }
    }

    /// The next timeframe up, used for the confluence ingredient of the confidence score.
    var higher: (interval: String, title: String) {
        switch self {
        case .m15: ("1h", L10n.text("1 hour", "1 saat"))
        case .h1: ("4h", L10n.text("4 hours", "4 saat"))
        case .h4: ("1d", L10n.text("1 day", "1 gün"))
        case .d1: ("1w", L10n.text("1 week", "1 hafta"))
        }
    }
}
