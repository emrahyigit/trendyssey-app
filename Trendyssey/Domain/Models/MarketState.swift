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

struct MarketStateSnapshot: Codable, Hashable, Sendable {
    static let aPlusMinimumScore = 75

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
        state == .buyerTakeover && stateScore >= Self.aPlusMinimumScore
    }

    var headline: String { state.title(forScore: stateScore) }


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
