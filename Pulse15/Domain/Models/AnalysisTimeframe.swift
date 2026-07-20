import Foundation

enum AnalysisTimeframe: String, CaseIterable, Identifiable, Sendable {
    case m15 = "15m", m30 = "30m", h1 = "1h", h2 = "2h", h4 = "4h", h6 = "6h", d1 = "1d"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .m15: L10n.text("15 minutes", "15 dakika")
        case .m30: L10n.text("30 minutes", "30 dakika")
        case .h1: L10n.text("1 hour", "1 saat")
        case .h2: L10n.text("2 hours", "2 saat")
        case .h4: L10n.text("4 hours", "4 saat")
        case .h6: L10n.text("6 hours", "6 saat")
        case .d1: L10n.text("1 day", "1 gün")
        }
    }
    static var selected: AnalysisTimeframe { AnalysisTimeframe(rawValue: UserDefaults.standard.string(forKey: "preferredTimeframe") ?? "15m") ?? .m15 }

    /// The next timeframe up, used for the confluence ingredient of the confidence score.
    var higher: (interval: String, title: String) {
        switch self {
        case .m15: ("1h", L10n.text("1 hour", "1 saat"))
        case .m30: ("2h", L10n.text("2 hours", "2 saat"))
        case .h1: ("4h", L10n.text("4 hours", "4 saat"))
        case .h2: ("6h", L10n.text("6 hours", "6 saat"))
        case .h4, .h6: ("1d", L10n.text("1 day", "1 gün"))
        case .d1: ("1w", L10n.text("1 week", "1 hafta"))
        }
    }
}
