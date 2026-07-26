import Foundation

/// Serves the candles every screen runs on, fetched straight from Binance —
/// the server keeps no candle store. Analysis (phases, scores, factors) is
/// still computed exclusively on the server; candles here only draw charts and
/// replay price for the breakout scenario. `liveChartCandles` includes the
/// still-forming candle for the detail page's live chart; `candles` returns
/// closed candles only, so nothing measured can repaint inside a bar.
struct CandleService: Sendable {
    private struct BinanceKline: Decodable {
        let openTime: Int64
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
        let closeTime: Int64
        let quoteVolume: Double

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            openTime = try values.decode(Int64.self)
            open = try Self.decodeDecimal(from: &values)
            high = try Self.decodeDecimal(from: &values)
            low = try Self.decodeDecimal(from: &values)
            close = try Self.decodeDecimal(from: &values)
            volume = try Self.decodeDecimal(from: &values)
            closeTime = try values.decode(Int64.self)
            quoteVolume = try Self.decodeDecimal(from: &values)
        }

        private static func decodeDecimal(from values: inout UnkeyedDecodingContainer) throws -> Double {
            let value = try values.decode(String.self)
            guard let decimal = Double(value) else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Binance geçersiz ondalık değer döndürdü.")
            }
            return decimal
        }
    }

    /// Chart-only: live candles from Binance, including the still-forming one.
    func liveChartCandles(for symbol: String, interval: String, limit: Int = 100) async throws -> [PriceCandle] {
        try await fetch(symbol: symbol, interval: interval, startingAt: nil, limit: limit)
    }

    func candles(for symbol: String, limit: Int = 100) async throws -> [PriceCandle] {
        try await candles(for: symbol, interval: AnalysisTimeframe.selected.rawValue, limit: limit)
    }

    /// Closed candles only, oldest first.
    func candles(for symbol: String, interval: String, limit: Int) async throws -> [PriceCandle] {
        try await fetch(symbol: symbol, interval: interval, startingAt: nil, limit: limit)
            .filter(\.isClosed)
    }

    func candles(
        for symbol: String,
        interval: String,
        startingAt startDate: Date,
        limit: Int = 100
    ) async throws -> [PriceCandle] {
        try await fetch(symbol: symbol, interval: interval, startingAt: startDate, limit: limit)
            .filter(\.isClosed)
    }

    private func fetch(
        symbol: String,
        interval: String,
        startingAt startDate: Date?,
        limit: Int
    ) async throws -> [PriceCandle] {
        var components = URLComponents(string: "https://data-api.binance.vision/api/v3/klines")!
        var queryItems: [URLQueryItem] = [
            .init(name: "symbol", value: symbol.uppercased()),
            .init(name: "interval", value: interval),
            .init(name: "limit", value: "\(max(1, min(limit, 1_000)))"),
        ]
        if let startDate {
            queryItems.append(.init(name: "startTime", value: "\(Int64(startDate.timeIntervalSince1970 * 1_000))"))
        }
        components.queryItems = queryItems
        let request = URLRequest(url: components.url!, timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let now = Date.now
        return try JSONDecoder().decode([BinanceKline].self, from: data).map { kline in
            let closeTime = Date(timeIntervalSince1970: Double(kline.closeTime) / 1_000)
            return PriceCandle(
                openTime: Date(timeIntervalSince1970: Double(kline.openTime) / 1_000),
                closeTime: closeTime,
                open: kline.open,
                high: kline.high,
                low: kline.low,
                close: kline.close,
                volume: kline.volume,
                quoteVolume: kline.quoteVolume,
                isClosed: closeTime < now
            )
        }
    }
}
