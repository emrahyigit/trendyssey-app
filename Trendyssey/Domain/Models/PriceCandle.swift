import Foundation

struct PriceCandle: Identifiable, Decodable, Sendable {
    var id: Date { openTime }
    let openTime: Date
    let closeTime: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let quoteVolume: Double
    let isClosed: Bool
    var isRising: Bool { close >= open }
}
