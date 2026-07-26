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
    case watching, preBreakout, breakoutDetected, confirmed, retest, failed, expired

    static var userSelectableCases: [SignalStatus] {
        allCases.filter { $0 != .watching }
    }

    static var scenarioEntryCases: [SignalStatus] {
        userSelectableCases.filter { $0 != .expired }
    }

    var title: String { title(.bullish) }

    /// Reversal models such as Double Top run the same lifecycle downward, so the
    /// phase names flip with the journey direction.
    func title(_ direction: JourneyDirection) -> String {
        switch self {
        case .watching: L10n.text("Being Watched", "İzleniyor")
        case .preBreakout: direction == .bullish
            ? L10n.text("Waiting for Breakout", "Kırılım Bekleniyor")
            : L10n.text("Waiting for Breakdown", "Düşüş Bekleniyor")
        case .breakoutDetected: direction == .bullish
            ? L10n.text("Breakout Started", "Kırılım Başladı")
            : L10n.text("Breakdown Started", "Düşüş Başladı")
        case .confirmed: direction == .bullish
            ? L10n.text("Breakout Strengthening", "Kırılım Güçleniyor")
            : L10n.text("Breakdown Strengthening", "Düşüş Güçleniyor")
        case .retest: L10n.text("Level Being Tested", "Seviye Test Ediliyor")
        case .failed: L10n.text("Signal Invalidated", "Sinyal Geçersiz Oldu")
        case .expired: L10n.text("Tracking Complete", "Takip Tamamlandı")
        }
    }

    var phaseTitle: String { phaseTitle(.bullish) }

    func phaseTitle(_ direction: JourneyDirection) -> String {
        direction == .bullish
            ? L10n.text("Breakout Journey", "Kırılım Süreci")
            : L10n.text("Breakdown Journey", "Düşüş Süreci")
    }

    /// User-facing progress only. Backend lifecycle states remain unchanged.
    var journeyStep: Int {
        switch self {
        case .watching: 0
        case .preBreakout: 1
        case .breakoutDetected: 2
        case .confirmed, .retest: 3
        case .failed, .expired: 4
        }
    }

    var journeyGuidance: String { journeyGuidance(.bullish) }

    func journeyGuidance(_ direction: JourneyDirection) -> String {
        switch self {
        case .watching:
            L10n.text("Market conditions are being monitored.", "Piyasa koşulları takip ediliyor.")
        case .preBreakout:
            direction == .bullish
                ? L10n.text("A closed candle above the tracked level is expected.", "İzlenen seviyenin üzerinde mum kapanışı bekleniyor.")
                : L10n.text("A closed candle below the tracked level is expected.", "İzlenen seviyenin altında mum kapanışı bekleniyor.")
        case .breakoutDetected:
            L10n.text("The move is being watched for staying power.", "Hareketin kalıcı olup olmadığı izleniyor.")
        case .confirmed:
            L10n.text("Strength and continuation are being monitored.", "Hareketin gücü ve devamlılığı izleniyor.")
        case .retest:
            direction == .bullish
                ? L10n.text("The broken level is being checked for support.", "Kırılan seviyenin destek olarak korunup korunmadığı izleniyor.")
                : L10n.text("The broken level is being checked for resistance.", "Kırılan seviyenin direnç olarak tutup tutmadığı izleniyor.")
        case .failed:
            L10n.text("Conditions weakened and this journey ended.", "Koşullar bozuldu ve bu süreç sonlandı.")
        case .expired:
            L10n.text("The monitoring window ended without a new transition.", "Yeni bir aşama oluşmadan takip süresi tamamlandı.")
        }
    }
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

struct SignalEvidence: Codable, Hashable, Sendable {
    let model: String?
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
}

/// One scored ingredient as the server stored it in the signal's evidence.
struct EvidenceConfidenceFactor: Codable, Hashable, Sendable {
    let key: String
    let score: Int
    let maxScore: Int
}

struct MarketSignal: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let journeyID: UUID?
    let symbol: String
    let name: String
    let iconURL: String?
    let price: Double
    let change24h: Double
    let quoteVolume24h: Double
    let confidence: Int
    let falseBreakoutRisk: Int
    let activityScore: Int
    let volumeRatio: Double
    let takerBuyRatio: Double
    let estimatedDelta: Double
    let status: SignalStatus
    let signalDate: Date
    let explanation: String
    let evidence: SignalEvidence?
    let hasScore: Bool

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
        falseBreakoutRisk: Int,
        activityScore: Int,
        volumeRatio: Double,
        takerBuyRatio: Double,
        estimatedDelta: Double,
        status: SignalStatus,
        signalDate: Date,
        explanation: String,
        evidence: SignalEvidence? = nil,
        hasScore: Bool = true
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
        self.falseBreakoutRisk = falseBreakoutRisk
        self.activityScore = activityScore
        self.volumeRatio = volumeRatio
        self.takerBuyRatio = takerBuyRatio
        self.estimatedDelta = estimatedDelta
        self.status = status
        self.signalDate = signalDate
        self.explanation = explanation
        self.evidence = evidence
        self.hasScore = hasScore
    }

    var baseSymbol: String { symbol.replacingOccurrences(of: "USDT", with: "") }
    var usesAdvancedJourneyModel: Bool { evidence?.model == "gpt-5-6-sol-v1" }
    var qualityTitle: String {
        L10n.text("Confidence score", "Güven puanı")
    }
}

struct MarketOverview: Sendable {
    let scannedCount: Int
    let newSignalCount: Int
    let lowRiskCount: Int
    let signals: [MarketSignal]
}
