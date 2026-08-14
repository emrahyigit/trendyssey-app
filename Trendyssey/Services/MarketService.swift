import Foundation

protocol MarketService: Sendable {
    func overview() async throws -> MarketOverview
    func allSymbols() async throws -> [MarketSignal]
}

struct FixtureMarketService: MarketService {
    func allSymbols() async throws -> [MarketSignal] { Self.signals }
    func overview() async throws -> MarketOverview {
        try await Task.sleep(for: .milliseconds(280))
        try Task.checkCancellation()
        return MarketOverview(scannedCount: 286, newSignalCount: 12, lowRiskCount: 7, signals: Self.signals)
    }

    static let signals: [MarketSignal] = [
        .init(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, symbol: "SOLUSDT", name: "Solana", price: 167.42, change24h: 6.84, confidence: 88, falseBreakoutRisk: 18, activityScore: 92, volumeRatio: 3.2, takerBuyRatio: 0.67, estimatedDelta: 2_840_000, status: .confirmed, signalDate: .now.addingTimeInterval(-540), explanation: "SOLUSDT son 20 mumun direnç seviyesini kapanışla geçti. Hacim ortalamanın 3,2 katına ulaşırken taker alıcıları baskın kaldı. ATR genişlemesi hareketi destekliyor."),
        .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, symbol: "BTCUSDT", name: "Bitcoin", price: 107_284.10, change24h: 2.31, confidence: 81, falseBreakoutRisk: 24, activityScore: 84, volumeRatio: 2.4, takerBuyRatio: 0.62, estimatedDelta: 8_520_000, status: .breakoutDetected, signalDate: .now.addingTimeInterval(-1120), explanation: "BTCUSDT Donchian üst bandının üzerinde kapandı. Hacim ve tahmini alım/satım deltası kırılımı destekliyor; sonraki mum onayı henüz oluşmadı."),
        .init(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, symbol: "LINKUSDT", name: "Chainlink", price: 15.86, change24h: 4.12, confidence: 76, falseBreakoutRisk: 29, activityScore: 79, volumeRatio: 2.1, takerBuyRatio: 0.59, estimatedDelta: 690_000, status: .retest, signalDate: .now.addingTimeInterval(-2640), explanation: "LINKUSDT kırılan seviyeyi yeniden test ediyor. Fiyat seviye üzerinde kalırken hacim normalin üzerinde; teyit için mum kapanışı izleniyor."),
        .init(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, symbol: "AVAXUSDT", name: "Avalanche", price: 23.48, change24h: -1.14, confidence: 63, falseBreakoutRisk: 47, activityScore: 67, volumeRatio: 1.8, takerBuyRatio: 0.48, estimatedDelta: -170_000, status: .preBreakout, signalDate: .now.addingTimeInterval(-3860), explanation: "AVAXUSDT direnç bölgesine yaklaştı. Hacim artıyor ancak taker tarafı dengeli ve momentum henüz güçlü bir onay üretmiyor.")
    ]
}
