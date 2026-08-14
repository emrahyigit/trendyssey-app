import Foundation

enum CryptoAssetUniverse {
    nonisolated private static let excludedBaseAssets: Set<String> = [
        // Fiat currencies and exchange-issued fiat representations.
        "AED", "ARS", "AUD", "BIDR", "BRL", "COP", "CZK", "EUR", "GBP", "GHS", "HKD",
        "HUF", "IDRT", "INR", "JPY", "KES", "KZT", "MXN", "NGN", "NZD", "PEN", "PHP",
        "PLN", "RON", "RUB", "SAR", "TRY", "UAH", "UGX", "VND", "ZAR",

        // Stablecoins and synthetic fiat units.
        "AEUR", "BUSD", "CRVUSD", "DAI", "EURI", "EURS", "EURC", "FDUSD", "FRAX", "GHO",
        "GUSD", "LUSD", "MIM", "PYUSD", "RLUSD", "SUSD", "TUSD", "U", "USD1", "USDC",
        "USDP", "USDS", "UST", "USTC", "XUSD",

        // Gold and commodity-backed tokens.
        "DGX", "PAXG", "PMGT", "XAUT"
    ]

    nonisolated static func includes(baseAsset: String) -> Bool {
        let asset = baseAsset.uppercased()
        // Any base asset containing "USD" is a stablecoin or fiat proxy (USDE, USDD, XUSD…).
        guard !asset.contains("USD") else { return false }
        guard !excludedBaseAssets.contains(asset) else { return false }
        return !["UP", "DOWN", "BULL", "BEAR"].contains { suffix in
            asset.count >= 5 && asset.count > suffix.count && asset.hasSuffix(suffix)
        }
    }

    nonisolated static func includes(symbol: String) -> Bool {
        let normalized = symbol.uppercased()
        let baseAsset = normalized.hasSuffix("USDT") ? String(normalized.dropLast(4)) : normalized
        return includes(baseAsset: baseAsset)
    }
}

enum SignalStatus: String, CaseIterable, Codable, Sendable {
    case watching, preBreakout, breakoutDetected, confirmed, failed, expired
}

struct SignalScoreComponent: Codable, Hashable, Sendable, Identifiable {
    let metric: String
    let key: String
    let name: String
    let rawValue: Double?
    let normalizedValue: Double
    let contribution: Double
    let maximumScore: Double
    let explanation: String

    var id: String { key }
}

struct TrendScoreComponents: Codable, Hashable, Sendable {
    let breakout: Int
    let regime: Int
    let momentum: Int
    let health: Int
}

/// The backend trend model (supabase `_shared/trend_score.ts`): Donchian-55
/// breakout + EMA25/99 regime + 20-candle momentum vs BTC + chandelier health.
/// The four components always sum to `score`.
struct TrendScoreFacts: Codable, Hashable, Sendable {
    let score: Int
    let entrySignal: Bool
    let components: TrendScoreComponents
    let breakoutLevel: Double?
    let clearanceAtr: Double?
    let freshBreakout: Bool?
    let regimeAligned: Bool?
    let momentumExcess: Double?
    /// Suggested trailing invalidation: 22-candle high minus 3×ATR.
    let chandelierStop: Double?
}

struct SignalEvidence: Codable, Hashable, Sendable {
    let model: String?
    let engineKind: String?
    let nearBreakout: Bool?
    let priceBrokeOut: Bool?
    let brokeOut: Bool?
    let setupType: String?
    let setupScore: Int?
    let distanceToLevelAtr: Double?
    let breakoutClearanceAtr: Double?
    let bodyRatio: Double?
    let upperWickRatio: Double?
    let tradeRatio: Double?
    let rangeAtrRatio: Double?
    let volumeContractionRatio: Double?
    let retestVolumeRatio: Double?
    let atr: Double?
    let atrChangePercent: Double?
    let rsi: Double?
    let rsiDelta3: Double?
    let emaFast: Double?
    let emaSlow: Double?
    let emaLong: Double?
    let emaFastSlope: Double?
    let emaSlowSlope: Double?
    let emaCrossAge: Int?
    let emaRetest: Bool?
    let emaRetestAge: Int?
    let adx: Double?
    let adxDelta3: Double?
    let plusDI: Double?
    let minusDI: Double?
    let bollingerBandWidthChangePercent: Double?
    let quoteVolume24h: Double?
    let scoreComponents: [SignalScoreComponent]?
    // Chart-pattern models: the levels and scored ingredients the server
    // recorded, so the detail page draws and explains without recomputing.
    let neckline: Double?
    let firstPivotPrice: Double?
    let secondPivotPrice: Double?
    let patternDepth: Double?
    let pivotDifference: Double?
    let firstPivotOpenTime: String?
    let necklineOpenTime: String?
    let secondPivotOpenTime: String?
    let confidenceFactors: [EvidenceConfidenceFactor]?
    let scoreLayers: SignalScoreLayers?
    let trendScore: TrendScoreFacts?
}

struct SignalScoreLayers: Codable, Hashable, Sendable {
    let regimeScore: Int
    let readinessScore: Int
    let breakoutQualityScore: Int
    let confirmationScore: Int
    let breakoutTriggered: Bool
    let scoringVersion: String?
}

/// One scored ingredient as the server stored it in the signal's evidence.
struct EvidenceConfidenceFactor: Codable, Hashable, Sendable {
    let key: String
    let score: Int
    let maxScore: Int
}

struct MarketSignal: Identifiable, Hashable, Sendable {
    let id: UUID
    let journeyID: UUID?
    let symbol: String
    let name: String
    let iconURL: String?
    let price: Double
    let change24h: Double
    let quoteVolume24h: Double
    let confidence: Int
    let regimeScore: Int
    let readinessScore: Int
    let breakoutQualityScore: Int
    let confirmationScore: Int
    /// 0-100: the coin's ~24h excess return vs BTC, 50 = moving with BTC.
    /// Nil until the first scan after the score shipped reaches this
    /// symbol/timeframe — shown as "—", never as a fake neutral 50.
    let relativeStrengthScore: Int?
    let breakoutTriggered: Bool
    let falseBreakoutRisk: Int
    let activityScore: Int
    let volumeRatio: Double
    let takerBuyRatio: Double
    let estimatedDelta: Double
    let signalDate: Date
    let explanation: String
    let evidence: SignalEvidence?
    let hasScore: Bool
    let trendScore: Int?
    let trendEntry: Bool
    let marketState: MarketStateSnapshot?

    nonisolated init(
        id: UUID,
        journeyID: UUID? = nil,
        symbol: String,
        name: String,
        iconURL: String? = nil,
        price: Double,
        change24h: Double,
        quoteVolume24h: Double = 0,
        confidence: Int,
        regimeScore: Int = 0,
        readinessScore: Int = 0,
        breakoutQualityScore: Int? = nil,
        confirmationScore: Int = 0,
        relativeStrengthScore: Int? = nil,
        breakoutTriggered: Bool = false,
        falseBreakoutRisk: Int,
        activityScore: Int,
        volumeRatio: Double,
        takerBuyRatio: Double,
        estimatedDelta: Double,
        signalDate: Date,
        explanation: String,
        evidence: SignalEvidence? = nil,
        hasScore: Bool = true,
        trendScore: Int? = nil,
        trendEntry: Bool = false,
        marketState: MarketStateSnapshot? = nil
    ) {
        self.id = id
        self.journeyID = journeyID
        self.symbol = symbol
        self.name = name
        self.iconURL = iconURL
        self.price = price
        self.change24h = change24h
        self.quoteVolume24h = quoteVolume24h
        self.confidence = confidence
        self.regimeScore = regimeScore
        self.readinessScore = readinessScore
        self.breakoutQualityScore = breakoutQualityScore ?? confidence
        self.confirmationScore = confirmationScore
        self.relativeStrengthScore = relativeStrengthScore
        self.breakoutTriggered = breakoutTriggered
        self.falseBreakoutRisk = falseBreakoutRisk
        self.activityScore = activityScore
        self.volumeRatio = volumeRatio
        self.takerBuyRatio = takerBuyRatio
        self.estimatedDelta = estimatedDelta
        self.signalDate = signalDate
        self.explanation = explanation
        self.evidence = evidence
        self.hasScore = hasScore
        self.trendScore = trendScore
        self.trendEntry = trendEntry
        self.marketState = marketState
    }

    var trendFacts: TrendScoreFacts? { evidence?.trendScore }
    /// Prefers the dedicated column; falls back to the explanation facts.
    var effectiveTrendScore: Int? { trendScore ?? trendFacts?.score }
    /// A+ belongs entirely to a 75+ bullish Market State: either a confirmed
    /// rebound or an independently strong continuation momentum state.
    var isAPlusSetup: Bool {
        marketState?.supportsAPlus == true
    }

    var baseSymbol: String { symbol.replacingOccurrences(of: "USDT", with: "") }
    var usesAdvancedJourneyModel: Bool { evidence?.model == "ema-7-25-99-v1" }
}

struct MarketOverview: Sendable {
    let scannedCount: Int
    let newSignalCount: Int
    let lowRiskCount: Int
    let signals: [MarketSignal]
}
