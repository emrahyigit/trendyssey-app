import Foundation

/// Display-only overlays calculated from the same live Binance candles drawn by
/// the detail chart. Signal state and scores remain server-owned; this service
/// only prevents a sparse snapshot history from leaving the live chart blank.
struct JourneyChartOverlay: Sendable {
    let series: [JourneySeries]
    let levels: [JourneyLevel]
    let markers: [JourneyMarker]

    static let empty = JourneyChartOverlay(series: [], levels: [], markers: [])
}

enum ChartOverlayService {
    static func overlay(
        model: JourneyModel,
        candles: [PriceCandle],
        serverAnalysis: JourneyAnalysis?
    ) -> JourneyChartOverlay {
        guard !candles.isEmpty else { return .empty }

        var series: [JourneySeries] = []
        var levels = serverAnalysis?.levels ?? []
        var markers = serverAnalysis?.markers ?? []

        switch model {
        case .emaCross:
            series = emaSeries(candles: candles)

        case .donchian20:
            series = emaSeries(candles: candles)
            series.append(donchianSeries(candles: candles, period: 20))

        case .donchian50:
            series = emaSeries(candles: candles)
            series.append(donchianSeries(candles: candles, period: 50))

        case .horizontalLevel:
            series = emaSeries(candles: candles)
            if levels.isEmpty, let resistance = horizontalResistance(candles: candles) {
                levels = [JourneyLevel(
                    key: "horizontalResistance",
                    title: L10n.text("Horizontal resistance", "Yatay direnç"),
                    price: resistance
                )]
            }

        case .consolidation:
            series = emaSeries(candles: candles)
            if let range = consolidationRange(candles: candles) {
                if levels.isEmpty {
                    levels.append(JourneyLevel(
                        key: "rangeUpper",
                        title: L10n.text("Range upper", "Aralık üstü"),
                        price: range.upper
                    ))
                }
                levels.append(JourneyLevel(
                    key: "rangeLower",
                    title: L10n.text("Range lower", "Aralık altı"),
                    price: range.lower
                ))
            }

        case .doubleBottom, .doubleTop:
            // EMA 99 is the pattern engine's long-term trend filter.
            let long = EMAJourneyAnalyzer.ema(candles.map(\.close), period: EMAJourneyAnalyzer.longPeriod)
            series = [JourneySeries(key: "ema99", title: "EMA 99", values: long)]
            if levels.isEmpty && markers.isEmpty {
                let closed = candles.filter(\.isClosed)
                if let local = JourneyAnalyzer.analyze(model: model, candles: closed) {
                    levels = local.levels
                    markers = local.markers
                }
            }
        }

        return JourneyChartOverlay(
            series: series.filter { $0.values.contains(where: { $0 != nil }) },
            levels: deduplicated(levels),
            markers: markers
        )
    }

    private static func emaSeries(candles: [PriceCandle]) -> [JourneySeries] {
        let closes = candles.map(\.close)
        return [
            JourneySeries(key: "ema7", title: "EMA 7", values: EMAJourneyAnalyzer.ema(closes, period: EMAJourneyAnalyzer.fastPeriod)),
            JourneySeries(key: "ema25", title: "EMA 25", values: EMAJourneyAnalyzer.ema(closes, period: EMAJourneyAnalyzer.mediumPeriod)),
            JourneySeries(key: "ema99", title: "EMA 99", values: EMAJourneyAnalyzer.ema(closes, period: EMAJourneyAnalyzer.longPeriod)),
        ]
    }

    /// For candle i, the line uses only the preceding N candles. The forming
    /// candle can therefore update live without moving its own breakout level.
    private static func donchianSeries(candles: [PriceCandle], period: Int) -> JourneySeries {
        let values: [Double?] = candles.indices.map { index in
            guard index >= period else { return nil }
            return candles[(index - period)..<index].map(\.high).max()
        }
        return JourneySeries(
            key: "donchianUpper",
            title: "Donchian \(period)",
            values: values
        )
    }

    /// Mirrors the server's confirmed-pivot clustering closely enough for a
    /// chart aid. The stored server level replaces it as soon as it is present.
    private static func horizontalResistance(candles: [PriceCandle]) -> Double? {
        let history = candles.filter(\.isClosed)
        guard history.count >= 12 else { return nil }
        let window = 3
        let currentPrice = candles.last?.close ?? history.last!.close
        let currentATR = max(averageTrueRange(history), .leastNonzeroMagnitude)
        let tolerance = currentATR * 0.35
        var pivots: [(index: Int, price: Double)] = []

        for index in window..<(history.count - window) {
            let price = history[index].high
            let neighbors = history[(index - window)...(index + window)]
            if neighbors.allSatisfy({ $0.openTime == history[index].openTime || $0.high <= price }),
               price >= currentPrice - currentATR * 0.5 {
                pivots.append((index, price))
            }
        }

        var best: (quality: Double, lastIndex: Int, level: Double)?
        for pivot in pivots {
            let cluster = pivots.filter { abs($0.price - pivot.price) <= tolerance }
            guard cluster.count >= 2 else { continue }
            let level = cluster.map(\.price).reduce(0, +) / Double(cluster.count)
            let dispersion = cluster.map { abs($0.price - level) }.reduce(0, +) / Double(cluster.count)
            let quality = Double(min(cluster.count, 5) * 13) + max(0, 20 * (1 - dispersion / tolerance))
            let lastIndex = cluster.map(\.index).max() ?? 0
            if best == nil || quality > best!.quality || (quality == best!.quality && lastIndex > best!.lastIndex) {
                best = (quality, lastIndex, level)
            }
        }
        return best?.level
    }

    private static func consolidationRange(candles: [PriceCandle]) -> (upper: Double, lower: Double)? {
        let history = Array(candles.filter(\.isClosed).suffix(20))
        guard history.count == 20,
              let upper = history.map(\.high).max(),
              let lower = history.map(\.low).min() else { return nil }
        return (upper, lower)
    }

    private static func averageTrueRange(_ candles: [PriceCandle], period: Int = 14) -> Double {
        guard candles.count > 1 else { return 0 }
        let start = max(1, candles.count - period)
        let ranges = (start..<candles.count).map { index in
            let candle = candles[index]
            let previousClose = candles[index - 1].close
            return max(
                candle.high - candle.low,
                abs(candle.high - previousClose),
                abs(candle.low - previousClose)
            )
        }
        return ranges.reduce(0, +) / Double(max(ranges.count, 1))
    }

    private static func deduplicated(_ levels: [JourneyLevel]) -> [JourneyLevel] {
        var result: [JourneyLevel] = []
        for level in levels where level.price.isFinite && level.price > 0 {
            let duplicate = result.contains { existing in
                existing.key == level.key || abs(existing.price - level.price) <= max(level.price, existing.price) * 0.000_001
            }
            if !duplicate { result.append(level) }
        }
        return result
    }
}
