import Foundation

/// Which side is holding control right now.
enum MarketControlSide: Sendable {
    case sellers
    case buyers
    case contested
}

/// Where a state sits on the control-transfer cycle. Each side runs the same
/// ladder: it takes control, its impact decays, the other side absorbs it, its
/// intensity dies, and control changes hands.
enum MarketControlStage: Int, Sendable {
    case dormant = 0
    case contested = 1
    case inControl = 2
    case impactFading = 3
    case absorbed = 4
    case exhausted = 5
    case handedOver = 6

    /// One word for what is happening to the side that holds control, short
    /// enough to sit beside that side's name.
    var label: String {
        switch self {
        case .dormant: L10n.text("QUIET", "DURGUN")
        case .contested: L10n.text("CONTESTED", "ÇEKİŞMELİ")
        case .inControl: L10n.text("DOMINANT", "BASKIN")
        case .impactFading: L10n.text("WEAKENING", "ZAYIFLIYOR")
        case .absorbed: L10n.text("ABSORBED", "EMİLİYOR")
        case .exhausted: L10n.text("EXHAUSTED", "TÜKENDİ")
        case .handedOver: L10n.text("TAKEN OVER", "DEVRALINDI")
        }
    }
}

enum MarketStateKind: String, Codable, CaseIterable, Sendable {
    case sellerDominance = "seller_dominance"
    case sellerImpactFading = "seller_impact_fading"
    case buySideAbsorption = "buy_side_absorption"
    case sellerExhaustion = "seller_exhaustion"
    case buyerTakeover = "buyer_takeover"
    case buyerDominance = "buyer_dominance"
    case buyerImpactFading = "buyer_impact_fading"
    case sellSideAbsorption = "sell_side_absorption"
    case buyerExhaustion = "buyer_exhaustion"
    case sellerTakeover = "seller_takeover"
    case balanced
    case lowParticipation = "low_participation"

    /// Dominance at or above this is emphatic enough to be named differently.
    static let riskScore = 75

    var title: String {
        switch self {
        case .sellerDominance: L10n.text("Sellers in Control", "Satıcılar Kontrolde")
        case .sellerImpactFading: L10n.text("Selling Impact Fading", "Satışın Etkisi Zayıflıyor")
        case .buySideAbsorption: L10n.text("Buyers Absorbing", "Alıcılar Satışı Topluyor")
        case .sellerExhaustion: L10n.text("Selling Force Running Out", "Satış Gücü Tükeniyor")
        case .buyerTakeover: L10n.text("Buyers Taking Control", "Kontrol Alıcılara Geçiyor")
        case .buyerDominance: L10n.text("Buyers in Control", "Alıcılar Kontrolde")
        case .buyerImpactFading: L10n.text("Buying Impact Fading", "Alımın Etkisi Zayıflıyor")
        case .sellSideAbsorption: L10n.text("Sellers Absorbing", "Satıcılar Alımı Karşılıyor")
        case .buyerExhaustion: L10n.text("Buying Force Running Out", "Alım Gücü Tükeniyor")
        case .sellerTakeover: L10n.text("Sellers Taking Control", "Kontrol Satıcılara Geçiyor")
        case .balanced: L10n.text("Both Sides Active", "İki Taraf da Sahada")
        case .lowParticipation: L10n.text("Market Is Quiet", "Piyasa Durgun")
        }
    }

    /// Shown instead of the plain title once one side's control is emphatic.
    /// It names the grip, not a verdict on price: a market is not risky for
    /// going up, and calling it that would smuggle a bearish frame back into a
    /// symmetric engine.
    func title(forScore score: Int) -> String {
        guard score >= Self.riskScore else { return title }
        switch self {
        case .sellerDominance:
            return L10n.text("Sellers Firmly in Control", "Satıcı Kontrolü Sağlam")
        case .buyerDominance:
            return L10n.text("Buyers Firmly in Control", "Alıcı Kontrolü Sağlam")
        default:
            return title
        }
    }

    /// Written as one plain sentence about what the two sides are doing, never
    /// as a verdict on where price goes next.
    var explanation: String {
        switch self {
        case .sellerDominance:
            L10n.text(
                "Sellers are hitting hard and getting paid for it — each wave of selling still moves price lower. Nothing here says the fall is finished; the useful reading is that trying to catch it is early.",
                "Satıcılar sert vuruyor ve karşılığını alıyor — her satış dalgası fiyatı hâlâ aşağı taşıyor. Buradaki hiçbir şey düşüşün bittiğini söylemiyor; asıl okuma şu: yakalamaya çalışmak için erken."
            )
        case .sellerImpactFading:
            L10n.text(
                "Selling has not slowed down, but it is buying less and less downside — the same effort now produces a smaller move. This is the first crack in a sell-off, before any buyer has done anything.",
                "Satış hız kesmedi ama giderek daha az düşüş satın alıyor — aynı çaba artık daha küçük bir hareket üretiyor. Bu, bir düşüşteki ilk çatlak; henüz hiçbir alıcı bir şey yapmış değil."
            )
        case .buySideAbsorption:
            L10n.text(
                "Heavy selling keeps arriving and price refuses to follow it down. Someone is taking the other side of every offer, which is what a floor looks like while it is still being built.",
                "Yoğun satış gelmeye devam ediyor ama fiyat aşağı gitmeyi reddediyor. Birileri her satışın karşı tarafını alıyor — bir taban inşa edilirken tam olarak böyle görünür."
            )
        case .sellerExhaustion:
            L10n.text(
                "The selling itself is drying up after a sell-off. This is not absorption — nobody is stepping in front of it — the supply has simply stopped coming, which often leaves price light enough to lift on little.",
                "Satışın kendisi bir düşüşün ardından kuruyor. Bu absorpsiyon değil — kimse önüne geçmiyor — arz sadece artık gelmiyor. Bu genelde fiyatı az bir şeyle kalkacak kadar hafif bırakır."
            )
        case .buyerTakeover:
            L10n.text(
                "Buyers are now both efficient and moving price, and closed candles confirm it. Control has changed hands: this is the point the earlier absorption or exhaustion was building toward.",
                "Alıcılar artık hem verimli hem de fiyatı taşıyor ve kapanmış mumlar bunu doğruluyor. Kontrol el değiştirdi: önceki absorpsiyon ya da tükenişin hazırladığı nokta burası."
            )
        case .buyerDominance:
            L10n.text(
                "Buyers are pressing hard and getting paid for it — each wave of buying still moves price higher. The move is working, which also means the good entry was earlier than here.",
                "Alıcılar sert bastırıyor ve karşılığını alıyor — her alım dalgası fiyatı hâlâ yukarı taşıyor. Hareket çalışıyor; bu aynı zamanda iyi girişin buradan önce olduğu anlamına geliyor."
            )
        case .buyerImpactFading:
            L10n.text(
                "Buying has not slowed down, but it is buying less and less upside — the same effort now produces a smaller move. This is the first crack in a rally, before any seller has done anything.",
                "Alım hız kesmedi ama giderek daha az yükseliş satın alıyor — aynı çaba artık daha küçük bir hareket üretiyor. Bu, bir yükselişteki ilk çatlak; henüz hiçbir satıcı bir şey yapmış değil."
            )
        case .sellSideAbsorption:
            L10n.text(
                "Heavy buying keeps arriving and price refuses to follow it up. Someone is selling into every bid, which is what a ceiling looks like while it is still being built.",
                "Yoğun alım gelmeye devam ediyor ama fiyat yukarı gitmeyi reddediyor. Birileri her alışa satış yapıyor — bir tavan inşa edilirken tam olarak böyle görünür."
            )
        case .buyerExhaustion:
            L10n.text(
                "The buying itself is drying up after a rally. Nobody is selling into it — demand has simply stopped arriving, which leaves price unsupported if any supply shows up.",
                "Alımın kendisi bir yükselişin ardından kuruyor. Kimse içine satmıyor — talep sadece artık gelmiyor. Bu, herhangi bir arz belirirse fiyatı desteksiz bırakır."
            )
        case .sellerTakeover:
            L10n.text(
                "Sellers are now both efficient and moving price, and closed candles confirm it. Control has changed hands: the rally that was being absorbed has given way.",
                "Satıcılar artık hem verimli hem de fiyatı taşıyor ve kapanmış mumlar bunu doğruluyor. Kontrol el değiştirdi: emilmekte olan yükseliş teslim oldu."
            )
        case .balanced:
            L10n.text(
                "Both sides are on the field and neither has met the bar for a named state. Real two-way trade, no edge to either — the tape has to break one way before it says anything.",
                "İki taraf da sahada ve hiçbiri isimli bir durumun eşiğini geçmiş değil. Gerçek çift yönlü işlem var, üstünlük yok — bir şey söylemesi için önce bir tarafa kırılması gerekiyor."
            )
        case .lowParticipation:
            L10n.text(
                "Little flow on either side and price is going nowhere with it. This is stillness rather than a standoff: there is not enough activity here to read anything from.",
                "İki tarafta da akış çok az ve fiyat da bununla bir yere gitmiyor. Bu bir çekişme değil, hareketsizlik: buradan bir şey okuyacak kadar aktivite yok."
            )
        }
    }

    var controlSide: MarketControlSide {
        switch self {
        case .sellerDominance, .sellerImpactFading, .sellerTakeover: .sellers
        case .buyerDominance, .buyerImpactFading, .buyerTakeover: .buyers
        case .buySideAbsorption, .sellerExhaustion: .sellers
        case .sellSideAbsorption, .buyerExhaustion: .buyers
        case .balanced, .lowParticipation: .contested
        }
    }

    var stage: MarketControlStage {
        switch self {
        case .lowParticipation: .dormant
        case .balanced: .contested
        case .sellerDominance, .buyerDominance: .inControl
        case .sellerImpactFading, .buyerImpactFading: .impactFading
        case .buySideAbsorption, .sellSideAbsorption: .absorbed
        case .sellerExhaustion, .buyerExhaustion: .exhausted
        case .buyerTakeover, .sellerTakeover: .handedOver
        }
    }

}

/// One dimension measured from both sides, so a screen can render the contest
/// rather than a column of unrelated numbers.
struct MarketMetricPair: Identifiable, Sendable {
    let id: String
    let title: String
    let sellerValue: Int
    let sellerChange: Int?
    let buyerValue: Int
    let buyerChange: Int?

    var leader: MarketControlSide {
        if sellerValue > buyerValue + 5 { return .sellers }
        if buyerValue > sellerValue + 5 { return .buyers }
        return .contested
    }
}

/// A forward-looking read plus the side it argues for, so a bare number is
/// never left for the reader to interpret.
struct MarketSetupRead: Identifiable, Sendable {
    let id: String
    let title: String
    let meaning: String
    let favours: MarketControlSide
    let value: Int?
    let change: Int?
    var withheldReason: String? = nil
}

enum BehavioralDirection: String, Codable, Hashable, Sendable {
    case bullish, bearish, neutral
}

enum BehavioralSignalStatus: String, Codable, Hashable, Sendable {
    case developing, confirmed
}

enum BehavioralTrend: String, Codable, Hashable, Sendable {
    case rising, falling, flat
}

enum BehavioralSignalKind: String, Codable, Hashable, Sendable {
    case lowerLowFailure = "lower_low_failure"
    case higherHighFailure = "higher_high_failure"
    case downsideProgressWeakening = "downside_progress_weakening"
    case upsideProgressWeakening = "upside_progress_weakening"
    case sellPressureDownsideDivergence = "sell_pressure_downside_divergence"
    case buyPressureUpsideDivergence = "buy_pressure_upside_divergence"
    case failedBreakdown = "failed_breakdown"
    case failedBreakout = "failed_breakout"
    case buyerRecoveryStrengthening = "buyer_recovery_strengthening"
    case sellerRecoveryStrengthening = "seller_recovery_strengthening"
    case sellerExhaustion = "seller_exhaustion"
    case buyerExhaustion = "buyer_exhaustion"
    case buyerTakeover = "buyer_takeover"
    case sellerTakeover = "seller_takeover"
    case spotFuturesDivergence = "spot_futures_divergence"

    var title: String {
        switch self {
        case .lowerLowFailure: L10n.text("Lower-low failure", "Yeni dip başarısız")
        case .higherHighFailure: L10n.text("Higher-high failure", "Yeni tepe başarısız")
        case .downsideProgressWeakening: L10n.text("Downside progress weakening", "Düşüş ilerlemesi zayıflıyor")
        case .upsideProgressWeakening: L10n.text("Upside progress weakening", "Yükseliş ilerlemesi zayıflıyor")
        case .sellPressureDownsideDivergence: L10n.text("Sell pressure / price divergence", "Satış baskısı / fiyat ayrışması")
        case .buyPressureUpsideDivergence: L10n.text("Buy pressure / price divergence", "Alım baskısı / fiyat ayrışması")
        case .failedBreakdown: L10n.text("Breakdown rejected", "Aşağı kırılım reddedildi")
        case .failedBreakout: L10n.text("Breakout rejected", "Yukarı kırılım reddedildi")
        case .buyerRecoveryStrengthening: L10n.text("Buyer recovery strengthening", "Alıcı toparlanması güçleniyor")
        case .sellerRecoveryStrengthening: L10n.text("Seller recovery strengthening", "Satıcı karşılığı güçleniyor")
        case .sellerExhaustion: L10n.text("Seller exhaustion", "Satıcı tükenişi")
        case .buyerExhaustion: L10n.text("Buyer exhaustion", "Alıcı tükenişi")
        case .buyerTakeover: L10n.text("Buyer takeover confirmed", "Alıcı devralımı doğrulandı")
        case .sellerTakeover: L10n.text("Seller takeover confirmed", "Satıcı devralımı doğrulandı")
        case .spotFuturesDivergence: L10n.text("Spot / futures divergence", "Spot / vadeli ayrışması")
        }
    }

    var explanation: String {
        switch self {
        case .lowerLowFailure:
            L10n.text("Sellers tested the prior low but could not create meaningful downside progress.", "Satıcılar önceki dibi test etti ancak anlamlı bir düşüş ilerlemesi üretemedi.")
        case .higherHighFailure:
            L10n.text("Buyers tested the prior high but could not create meaningful upside progress.", "Alıcılar önceki tepeyi test etti ancak anlamlı bir yükseliş ilerlemesi üretemedi.")
        case .downsideProgressWeakening:
            L10n.text("New downside extensions are becoming progressively shallower.", "Yeni aşağı uzamalar giderek sığlaşıyor.")
        case .upsideProgressWeakening:
            L10n.text("New upside extensions are becoming progressively shallower.", "Yeni yukarı uzamalar giderek sığlaşıyor.")
        case .sellPressureDownsideDivergence:
            L10n.text("Selling is intensifying while producing less downside.", "Satış baskısı artarken ürettiği düşüş azalıyor.")
        case .buyPressureUpsideDivergence:
            L10n.text("Buying is intensifying while producing less upside.", "Alım baskısı artarken ürettiği yükseliş azalıyor.")
        case .failedBreakdown:
            L10n.text("Price broke support but reclaimed it instead of continuing lower.", "Fiyat desteği kırdı ancak düşüşe devam etmek yerine geri aldı.")
        case .failedBreakout:
            L10n.text("Price broke resistance but fell back below it instead of continuing higher.", "Fiyat direnci kırdı ancak yükselişe devam etmek yerine altına döndü.")
        case .buyerRecoveryStrengthening:
            L10n.text("Buyers are recovering more of each sell wave, increasingly quickly.", "Alıcılar her satış dalgasının daha büyük bölümünü giderek daha hızlı geri alıyor.")
        case .sellerRecoveryStrengthening:
            L10n.text("Sellers are recovering more of each buy wave, increasingly quickly.", "Satıcılar her alım dalgasının daha büyük bölümünü giderek daha hızlı geri alıyor.")
        case .sellerExhaustion:
            L10n.text("Seller effectiveness is deteriorating; this does not yet prove buyer control.", "Satıcı etkinliği bozuluyor; bu henüz alıcı kontrolünü kanıtlamaz.")
        case .buyerExhaustion:
            L10n.text("Buyer effectiveness is deteriorating; this does not yet prove seller control.", "Alıcı etkinliği bozuluyor; bu henüz satıcı kontrolünü kanıtlamaz.")
        case .buyerTakeover:
            L10n.text("Seller exhaustion, buyer response and a structural reclaim are all present.", "Satıcı tükenişi, alıcı karşılığı ve yapısal geri alım birlikte mevcut.")
        case .sellerTakeover:
            L10n.text("Buyer exhaustion, seller response and a structural break are all present.", "Alıcı tükenişi, satıcı karşılığı ve yapısal kırılım birlikte mevcut.")
        case .spotFuturesDivergence:
            L10n.text("Spot demand and leveraged futures positioning are moving differently.", "Spot talep ile kaldıraçlı vadeli pozisyonlanma farklı yönde hareket ediyor.")
        }
    }
}

struct BehavioralSignal: Codable, Hashable, Sendable, Identifiable {
    let kind: BehavioralSignalKind
    let score: Int
    let direction: BehavioralDirection
    let status: BehavioralSignalStatus
    let trend: BehavioralTrend
    let evidence: [String]

    var id: BehavioralSignalKind { kind }
}

struct MarketBehaviorContext: Codable, Hashable, Sendable {
    enum Regime: String, Codable, Hashable, Sendable { case bullish, bearish, range }
    enum Position: String, Codable, Hashable, Sendable { case above, below }
    enum AverageTrend: String, Codable, Hashable, Sendable { case rising, falling, flat }
    enum FuturesAvailability: String, Codable, Hashable, Sendable { case unavailable }

    let regime: Regime
    let priceVsEma25: Position
    let priceVsEma99: Position
    let ema25Trend: AverageTrend
    let futuresAvailability: FuturesAvailability
    let summary: String

    nonisolated static let unavailable = MarketBehaviorContext(
        regime: .range,
        priceVsEma25: .above,
        priceVsEma99: .above,
        ema25Trend: .flat,
        futuresAvailability: .unavailable,
        summary: ""
    )

    var localizedSummary: String {
        switch regime {
        case .bullish:
            L10n.text("Broader structure is bullish above EMA25 and EMA99.", "Geniş yapı EMA25 ve EMA99 üzerinde yükseliş yönlü.")
        case .bearish:
            L10n.text("Broader structure is bearish below EMA25 and EMA99.", "Geniş yapı EMA25 ve EMA99 altında düşüş yönlü.")
        case .range:
            L10n.text("Broader structure is mixed around EMA25 and EMA99.", "Geniş yapı EMA25 ve EMA99 çevresinde karışık.")
        }
    }
}

struct BehavioralStateScores: Codable, Hashable, Sendable {
    let sellerExhaustion: Int
    let buyerExhaustion: Int
    let buyerResponse: Int
    let sellerResponse: Int
    let bullishExpansion: Int
    let bearishExpansion: Int

    nonisolated static let empty = BehavioralStateScores(
        sellerExhaustion: 0,
        buyerExhaustion: 0,
        buyerResponse: 0,
        sellerResponse: 0,
        bullishExpansion: 0,
        bearishExpansion: 0
    )
}

struct MarketStateSnapshot: Codable, Hashable, Sendable {
    nonisolated static let aPlusMinimumScore = 75

    let state: MarketStateKind
    let stateScore: Int
    /// Strength of the named state on the preceding closed candle. Nil until
    /// the scanner has observed two closes with the current schema.
    let previousStateScore: Int?
    /// Explicit close-to-close change; kept separate from the metric trends.
    let stateScoreChange: Int?

    let sellerPressure: Int
    let sellerPressureChange: Int?
    let buyerPressure: Int
    let buyerPressureChange: Int?
    let sellerEfficiency: Int
    let sellerEfficiencyChange: Int?
    let buyerEfficiency: Int
    let buyerEfficiencyChange: Int?
    let downsideResponse: Int
    let downsideResponseChange: Int?
    let upsideResponse: Int
    let upsideResponseChange: Int?
    let buySideAbsorption: Int
    let buySideAbsorptionChange: Int?
    let sellSideAbsorption: Int
    let sellSideAbsorptionChange: Int?
    let bullishConfirmation: Int
    let bullishConfirmationChange: Int?
    let bearishConfirmation: Int
    let bearishConfirmationChange: Int?

    /// Where a turn would start from: location in the range, how tightly it has
    /// coiled, and the rejection wick. Deliberately free of absorption, so it
    /// still reads once absorption has faded — which is when a base forms.
    let bounceReadiness: Int
    let bounceReadinessChange: Int?
    let rolloverReadiness: Int
    let rolloverReadinessChange: Int?

    /// Each side's defence, derived from the pressure it faced and the response
    /// price gave. A shorthand for two rows above it, not a third measurement.
    let buyerResilience: Int
    let buyerResilienceChange: Int?
    let sellerResilience: Int
    let sellerResilienceChange: Int?

    let context: MarketBehaviorContext
    let behavioralScores: BehavioralStateScores
    let behavioralSignals: [BehavioralSignal]

    /// Slopes over the recent series, which is what the ladder reads.
    let sellerEfficiencyTrend: Int
    let buyerEfficiencyTrend: Int
    let sellerPressureTrend: Int
    let buyerPressureTrend: Int

    let stateSince: Date
    let candleCloseTime: Date
    let scoringVersion: String

    /// Quiet is the only reading that carries no contest worth showing.
    var hasActiveState: Bool { state != .lowParticipation }

    /// A+ is a confirmed handover to buyers, strong enough to stand out.
    var supportsAPlus: Bool {
        if let takeover = behavioralSignals.first(where: {
            $0.kind == .buyerTakeover && $0.status == .confirmed
        }) {
            return takeover.score >= Self.aPlusMinimumScore
        }
        return state == .buyerTakeover && stateScore >= Self.aPlusMinimumScore
    }

    var headline: String { state.title(forScore: stateScore) }

    var leadingBehavioralSignal: BehavioralSignal? {
        behavioralSignals.sorted {
            if $0.status != $1.status { return $0.status == .confirmed }
            return $0.score > $1.score
        }.first
    }

    /// Bullish transitions lead the home-screen opportunity window. Exhaustion
    /// alone ranks below an actual structural rejection or confirmed takeover.
    var bullishTransitionRank: Int {
        guard let signal = behavioralSignals.first(where: {
            $0.direction == .bullish && $0.score >= 45
        }) else { return 0 }
        return switch signal.kind {
        case .buyerTakeover: 5
        case .failedBreakdown: 4
        case .sellerExhaustion: 3
        case .sellPressureDownsideDivergence, .lowerLowFailure: 2
        case .buyerRecoveryStrengthening, .downsideProgressWeakening: 1
        default: 0
        }
    }


    /// Every dimension as a seller/buyer contest. The left column always holds
    /// what argues for sellers and the right what argues for buyers, so a
    /// longer bar and a rising number always mean the same thing.
    var metricPairs: [MarketMetricPair] {
        [
            MarketMetricPair(
                id: "pressure",
                title: L10n.text("Pressure", "Baskı"),
                sellerValue: sellerPressure, sellerChange: sellerPressureChange,
                buyerValue: buyerPressure, buyerChange: buyerPressureChange
            ),
            MarketMetricPair(
                id: "efficiency",
                title: L10n.text("Efficiency", "Etkinlik"),
                sellerValue: sellerEfficiency, sellerChange: sellerEfficiencyChange,
                buyerValue: buyerEfficiency, buyerChange: buyerEfficiencyChange
            ),
            MarketMetricPair(
                id: "response",
                title: L10n.text("Price response", "Fiyat tepkisi"),
                sellerValue: downsideResponse, sellerChange: downsideResponseChange,
                buyerValue: upsideResponse, buyerChange: upsideResponseChange
            ),
            MarketMetricPair(
                id: "absorption",
                title: L10n.text("Absorption", "Absorpsiyon"),
                // Each column holds what that side is doing, matching every
                // other row: the sellers' column is the selling that meets
                // incoming demand, the buyers' column is the buying that meets
                // incoming supply.
                sellerValue: sellSideAbsorption, sellerChange: sellSideAbsorptionChange,
                buyerValue: buySideAbsorption, buyerChange: buySideAbsorptionChange
            ),
            MarketMetricPair(
                id: "readiness",
                title: L10n.text("Turn readiness", "Dönüş hazırlığı"),
                sellerValue: rolloverReadiness, sellerChange: rolloverReadinessChange,
                buyerValue: bounceReadiness, buyerChange: bounceReadinessChange
            ),
            MarketMetricPair(
                id: "resilience",
                title: L10n.text("Price defence", "Fiyat dayanıklılığı"),
                sellerValue: sellerResilience, sellerChange: sellerResilienceChange,
                buyerValue: buyerResilience, buyerChange: buyerResilienceChange
            )
        ]
    }
}
