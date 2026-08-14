import Foundation

enum MarketStateKind: String, Codable, CaseIterable, Sendable {
    case neutral
    case sellingDominant = "selling_dominant"
    case sellerImpactFading = "seller_impact_fading"
    case buySideAbsorption = "buy_side_absorption"
    case bounceAttempt = "bounce_attempt"
    case bullishConfirmation = "bullish_confirmation"
    case bullishMomentum = "bullish_momentum"
    case breakdownRisk = "breakdown_risk"

    var title: String {
        switch self {
        case .neutral: L10n.text("Neutral", "Nötr")
        case .sellingDominant: L10n.text("Selling Dominant", "Satış Baskın")
        case .sellerImpactFading: L10n.text("Seller Impact Fading", "Satıcı Etkisi Zayıflıyor")
        case .buySideAbsorption: L10n.text("Buy-side Absorption", "Alıcı Absorpsiyonu")
        case .bounceAttempt: L10n.text("Bounce Attempt", "Tepki Denemesi")
        case .bullishConfirmation: L10n.text("Bullish Confirmation", "Yukarı Yönlü Teyit")
        case .bullishMomentum: L10n.text("Strong Bullish Momentum", "Güçlü Yükseliş Momentumu")
        case .breakdownRisk: L10n.text("Breakdown Risk", "Aşağı Kırılım Riski")
        }
    }

    var explanation: String {
        switch self {
        case .neutral:
            L10n.text("Pressure and price response are balanced; no strong state is present.", "Baskı ve fiyat tepkisi dengeli; belirgin bir durum yok.")
        case .sellingDominant:
            L10n.text("Selling pressure is high and sellers are still moving price lower efficiently.", "Satış baskısı yüksek ve satıcılar fiyatı hâlâ etkili biçimde aşağı itiyor.")
        case .sellerImpactFading:
            L10n.text("Selling remains elevated, but its downside price impact is weakening.", "Satış yüksek kalırken aşağı yönlü fiyat etkisi zayıflıyor.")
        case .buySideAbsorption:
            L10n.text("Heavy selling persists, but buyers appear to be absorbing supply. Confirmation is still separate.", "Yoğun satış sürüyor; alıcılar arzı absorbe ediyor olabilir. Teyit henüz ayrı bir aşama.")
        case .bounceAttempt:
            L10n.text("Price has started reacting upward after absorption, but the response is not fully confirmed.", "Fiyat absorpsiyon sonrasında yukarı tepki vermeye başladı; hareket henüz tam teyitli değil.")
        case .bullishConfirmation:
            L10n.text("Buyer response has produced closed-candle confirmation after a weakening in seller impact.", "Satıcı etkisi zayıfladıktan sonra alıcı tepkisi kapanmış mum teyidi üretti.")
        case .bullishMomentum:
            L10n.text("Price is advancing with strong multi-candle momentum and direct closed-candle confirmation.", "Fiyat, güçlü çoklu mum momentumu ve doğrudan kapanmış mum teyidiyle yükseliyor.")
        case .breakdownRisk:
            L10n.text("Selling pressure and seller efficiency are both high; downside continuation risk is elevated.", "Satış baskısı ve satıcı etkinliği birlikte yüksek; düşüşün devam riski arttı.")
        }
    }

    var reversalPriority: Int {
        switch self {
        case .bullishConfirmation: 5
        case .bounceAttempt: 4
        case .buySideAbsorption: 3
        case .sellerImpactFading: 2
        case .neutral, .bullishMomentum, .sellingDominant, .breakdownRisk: 0
        }
    }
}

struct MarketStateSnapshot: Codable, Hashable, Sendable {
    static let aPlusMinimumScore = 75

    let state: MarketStateKind
    let stateScore: Int
    /// Strength of the named state on the preceding closed candle. Nil until
    /// the scanner has observed two closes with the current schema.
    let previousStateScore: Int?
    /// Explicit close-to-close change; kept separate from component momentum.
    let stateScoreChange: Int?
    let sellingPressure: Int
    let sellingPressureChange: Int?
    let downsideResponse: Int
    let downsideResponseChange: Int?
    let sellerEfficiency: Int
    let sellerEfficiencyChange: Int?
    let efficiencyChange: Int
    let absorption: Int
    let absorptionChange: Int?
    let priceResilience: Int
    let priceResilienceChange: Int?
    let bounceReadiness: Int
    let bounceReadinessChange: Int?
    let confirmation: Int
    let confirmationChange: Int?
    let bullishMomentum: Int
    let bullishMomentumChange: Int?
    let stateSince: Date
    let candleCloseTime: Date
    let scoringVersion: String

    var hasActiveState: Bool { state != .neutral }
    var supportsAPlus: Bool {
        (state == .bullishConfirmation || state == .bullishMomentum) &&
            stateScore >= Self.aPlusMinimumScore
    }
}
