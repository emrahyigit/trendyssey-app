import Foundation

/// The venue behind the trade button on the coin page, fixed to Binance.
/// Trendyssey never talks to it — it only builds the deep link, so the user
/// lands on the right pair.
enum PreferredExchange: String, Sendable {
    case binance

    nonisolated var title: String { "Binance" }

    /// The trade button keeps the Binance mark.
    nonisolated var usesBinanceMark: Bool { true }

    /// The venue's native URL scheme, tried first. A scheme that is not
    /// installed (or not registered) simply fails to open, and the caller
    /// falls back to the web URL below — so attempting one is always safe.
    nonisolated func appURL(symbol: String) -> URL? {
        URL(string: "bnc://app.binance.com/trade/trade?at=spot&symbol=\(symbol.lowercased())")
    }

    nonisolated func webURL(baseAsset: String) -> URL {
        URL(string: "https://www.binance.com/en/trade/\(baseAsset.uppercased())_USDT?type=spot")!
    }
}
