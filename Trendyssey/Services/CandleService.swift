import Foundation

/// Serves the candles every screen and analyzer runs on — from the server's
/// candle store, which is the same input the backend derives signals from.
/// The single deliberate exception is the detail page's price chart, which
/// streams live candles straight from Binance (`liveChartCandles`) so the
/// forming candle ticks in real time; everything analytical still reads the
/// server, so a chart can never change a score or a phase.
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
        var components = URLComponents(string: "https://data-api.binance.vision/api/v3/klines")!
        components.queryItems = [
            .init(name: "symbol", value: symbol.uppercased()),
            .init(name: "interval", value: interval),
            .init(name: "limit", value: "\(max(1, min(limit, 1_000)))"),
        ]
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

    private struct StoredCandle: Decodable {
        let open_time: String
        let close_time: String
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
        let quote_volume: Double
    }

    private struct SymbolRow: Decodable {
        let id: UUID
    }

    /// Symbol-name → id, resolved once per session. Querying candles by id hits
    /// the (symbol_id, timeframe, open_time) index directly; joining through
    /// `symbols` instead lets the planner pick a plan that times out on a
    /// millions-of-rows table.
    private actor SymbolDirectory {
        static let shared = SymbolDirectory()
        private var ids: [String: UUID] = [:]

        func id(for symbol: String, resolve: @Sendable (String) async throws -> UUID?) async throws -> UUID? {
            if let cached = ids[symbol] { return cached }
            guard let resolved = try await resolve(symbol) else { return nil }
            ids[symbol] = resolved
            return resolved
        }
    }

    func candles(for symbol: String, limit: Int = 100) async throws -> [PriceCandle] {
        try await fetchCandles(
            for: symbol,
            interval: AnalysisTimeframe.selected.rawValue,
            startingAt: nil,
            limit: limit
        )
    }

    func candles(for symbol: String, interval: String, limit: Int) async throws -> [PriceCandle] {
        try await fetchCandles(for: symbol, interval: interval, startingAt: nil, limit: limit)
    }

    func candles(
        for symbol: String,
        interval: String,
        startingAt startDate: Date,
        limit: Int = 100
    ) async throws -> [PriceCandle] {
        try await fetchCandles(
            for: symbol,
            interval: interval,
            startingAt: startDate,
            limit: limit
        )
    }

    /// An empty result is meaningful, not an error: the coin is outside the
    /// store's sweep, and callers surface that instead of a spinner.
    private func fetchCandles(
        for symbol: String,
        interval: String,
        startingAt startDate: Date?,
        limit: Int
    ) async throws -> [PriceCandle] {
        guard let symbolID = try await SymbolDirectory.shared.id(for: symbol.uppercased(), resolve: resolveSymbolID) else {
            return []
        }
        let cappedLimit = max(1, min(limit, 1_000))
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/candles"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            .init(name: "select", value: "open_time,close_time,open,high,low,close,volume,quote_volume"),
            .init(name: "symbol_id", value: "eq.\(symbolID.uuidString)"),
            .init(name: "timeframe", value: "eq.\(interval)"),
            .init(name: "limit", value: "\(cappedLimit)"),
        ]
        if let startDate {
            queryItems.append(.init(name: "open_time", value: "gt.\(Self.iso8601(startDate))"))
            queryItems.append(.init(name: "order", value: "open_time.asc"))
        } else {
            queryItems.append(.init(name: "order", value: "open_time.desc"))
        }
        components.queryItems = queryItems
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let rows = try JSONDecoder().decode([StoredCandle].self, from: data)
        let mapped = try rows.map { row -> PriceCandle in
            guard let openTime = Self.date(row.open_time), let closeTime = Self.date(row.close_time) else {
                throw URLError(.cannotDecodeContentData)
            }
            return PriceCandle(
                openTime: openTime,
                closeTime: closeTime,
                open: row.open,
                high: row.high,
                low: row.low,
                close: row.close,
                volume: row.volume,
                quoteVolume: row.quote_volume,
                isClosed: true
            )
        }
        return startDate == nil ? mapped.reversed() : mapped
    }

    private func resolveSymbolID(_ symbol: String) async throws -> UUID? {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/symbols"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id"),
            .init(name: "symbol", value: "eq.\(symbol)"),
            .init(name: "limit", value: "1"),
        ]
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([SymbolRow].self, from: data).first?.id
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// PostgREST emits fractional seconds only when they are non-zero, so both
    /// shapes appear in one response.
    private static func date(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value)
    }

    private static func iso8601(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }
}
