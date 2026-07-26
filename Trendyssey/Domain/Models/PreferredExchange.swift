import Foundation

/// The exchange the user trades on. Trendyssey never talks to it — it only
/// builds the deep link behind the trade button on the coin page, so the user
/// lands on the right pair at the venue they actually use.
enum PreferredExchange: String, CaseIterable, Identifiable, Sendable {
    case binance, binanceTR, okx, coinbase

    nonisolated static let storageKey = "preferredExchange"

    nonisolated static var selected: PreferredExchange {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PreferredExchange.init(rawValue:)) ?? .binance
    }

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .binance: "Binance"
        case .binanceTR: "Binance TR"
        case .okx: "OKX"
        case .coinbase: "Coinbase"
        }
    }

    /// Whether the venue shares Binance branding, so the button can keep the
    /// Binance mark for both global and TR.
    nonisolated var usesBinanceMark: Bool {
        self == .binance || self == .binanceTR
    }

    /// The venue's native URL scheme, tried first. A scheme that is not
    /// installed (or not registered) simply fails to open, and the caller
    /// falls back to the web URL below — so attempting one is always safe.
    nonisolated func appURL(symbol: String) -> URL? {
        let base = String(symbol.uppercased().replacingOccurrences(of: "USDT", with: ""))
        return switch self {
        case .binance:
            URL(string: "bnc://app.binance.com/trade/trade?at=spot&symbol=\(symbol.lowercased())")
        case .binanceTR:
            URL(string: "trbinance://trade?symbol=\(base)_USDT")
        case .okx:
            URL(string: "okx://main/trade?instId=\(base)-USDT")
        case .coinbase:
            URL(string: "coinbase://asset/\(base.lowercased())")
        }
    }

    nonisolated func webURL(baseAsset: String) -> URL {
        let base = baseAsset.uppercased()
        let url: String = switch self {
        case .binance: "https://www.binance.com/en/trade/\(base)_USDT?type=spot"
        case .binanceTR: "https://www.trbinance.com/trade/\(base)_USDT"
        case .okx: "https://www.okx.com/trade-spot/\(base.lowercased())-usdt"
        case .coinbase: "https://www.coinbase.com/advanced-trade/spot/\(base)-USDT"
        }
        return URL(string: url)!
    }
}
