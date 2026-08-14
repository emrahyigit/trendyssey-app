import Foundation

/// Which way a journey resolves. Reversal patterns such as Double Top run the
/// same lifecycle as a breakout but complete downward.
enum JourneyDirection: String, Sendable {
    case bullish, bearish
}

/// An on-device chart detector. Its internal phases build overlays and are not
/// exposed as product states; Market State is the only user-facing status.
enum JourneyModel: String, CaseIterable, Identifiable, Sendable {
    case emaCross
    case donchian20, donchian50, horizontalLevel, consolidation
    case doubleBottom, doubleTop

    nonisolated static let storageKey = "preferredJourneyModel"

    nonisolated static var selected: JourneyModel {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let model = JourneyModel(rawValue: raw),
              selectableCases.contains(model) else { return .emaCross }
        return model
    }

    /// EMA Cross remains decodable for existing installs and historical rows,
    /// but is now a shared trend feature rather than a selectable breakout.
    /// Double Bottom/Top were retired as standalone models the same way: they
    /// live on as directional evidence inside every level engine's quality
    /// score instead of running their own journeys.
    /// Narrowed to the EMA 7/25/99 crossover alone; model choice left the UI.
    /// The other engines remain decodable for history — widen this list to
    /// bring the choice back.
    nonisolated static let selectableCases: [JourneyModel] = [
        .emaCross,
    ]

    var id: String { rawValue }

    nonisolated var direction: JourneyDirection {
        switch self {
        case .emaCross, .donchian20, .donchian50, .horizontalLevel, .consolidation, .doubleBottom: .bullish
        case .doubleTop: .bearish
        }
    }

    /// The backend model that mirrors this one, when there is one. Everything the
    /// server produces — recorded signal history and push notifications — exists
    /// only for models with a slug here; the others run on the device alone.
    nonisolated var serverSlug: String? {
        switch self {
        case .emaCross: "ema-7-25-99-v1"
        case .donchian20: "donchian-20-v1"
        case .donchian50: "donchian-50-v1"
        case .horizontalLevel: "horizontal-level-v1"
        case .consolidation: "consolidation-v1"
        case .doubleBottom: "double-bottom-v1"
        case .doubleTop: "double-top-v1"
        }
    }

    /// Whether the backend can raise alerts for this model.
    nonisolated var deliversAlerts: Bool { serverSlug != nil }

    nonisolated var title: String {
        switch self {
        case .emaCross: L10n.text("Market State", "Piyasa Durumu")
        case .donchian20: L10n.text("Price Channel 20", "Fiyat Kanalı 20")
        case .donchian50: L10n.text("Price Channel 50", "Fiyat Kanalı 50")
        case .horizontalLevel: L10n.text("Horizontal Level", "Yatay Seviye")
        case .consolidation: L10n.text("Consolidation", "Konsolidasyon")
        case .doubleBottom: L10n.text("Double Bottom", "Çift Dip")
        case .doubleTop: L10n.text("Double Top", "Çift Tepe")
        }
    }

    nonisolated var summary: String {
        switch self {
        case .emaCross:
            L10n.text(
                "Measures the current balance between selling pressure, absorption, resilience and confirmation on closed candles.",
                "Kapanmış mumlarda satış baskısı, absorpsiyon, dayanıklılık ve teyit arasındaki güncel dengeyi ölçer."
            )
        case .donchian20:
            L10n.text(
                "Tracks closes beyond the highest level of the previous 20 completed candles.",
                "Önceki 20 tamamlanmış mumun en yüksek seviyesinin üzerindeki kapanışları izler."
            )
        case .donchian50:
            L10n.text(
                "Uses a slower 50-candle price channel for more selective breakouts.",
                "Daha seçici kırılımlar için 50 mumluk daha yavaş bir fiyat kanalı kullanır."
            )
        case .horizontalLevel:
            L10n.text(
                "Groups confirmed pivot highs into ATR-sized resistance zones.",
                "Doğrulanmış pivot tepelerini ATR genişliğinde direnç bölgelerinde kümeler."
            )
        case .consolidation:
            L10n.text(
                "Finds compact trading ranges and follows the close above their upper boundary.",
                "Dar işlem aralıklarını bulur ve üst sınırları üzerindeki kapanışı izler."
            )
        case .doubleBottom:
            L10n.text(
                "Finds two lows at a similar level and follows the break above the neckline between them.",
                "Benzer seviyedeki iki dibi bulur ve aralarındaki boyun çizgisinin yukarı kırılmasını izler."
            )
        case .doubleTop:
            L10n.text(
                "Finds two highs at a similar level and follows the break below the neckline between them.",
                "Benzer seviyedeki iki tepeyi bulur ve aralarındaki boyun çizgisinin aşağı kırılmasını izler."
            )
        }
    }
}

/// A single lifecycle transition produced by a journey model.
struct JourneyEvent: Identifiable, Hashable, Sendable {
    let status: SignalStatus
    let time: Date
    let price: Double

    var id: Date { time }
}

/// One scored ingredient of the overall confidence score, e.g. "Volume support 4/20".
struct ConfidenceFactor: Identifiable, Sendable {
    let key: String
    let title: String
    let detail: String
    let score: Int
    let maxScore: Int

    var id: String { key }
    var strength: Double { maxScore > 0 ? Double(score) / Double(maxScore) : 0 }
}

/// A value series drawn over the candle chart, aligned index-by-index with
/// `JourneyAnalysis.candles`; nil entries are gaps (warm-up periods).
struct JourneySeries: Identifiable, Sendable {
    let key: String
    let title: String
    let values: [Double?]

    var id: String { key }
}

/// A horizontal reference price the model watches, such as a pattern neckline.
struct JourneyLevel: Identifiable, Sendable {
    let key: String
    let title: String
    let price: Double

    var id: String { key }
}

/// A single highlighted candle, such as a pattern pivot.
struct JourneyMarker: Identifiable, Sendable {
    let key: String
    let title: String
    let time: Date
    let price: Double

    var id: String { key }
}

/// Result of running one journey model over a symbol's closed candles.
struct JourneyAnalysis: Sendable {
    let model: JourneyModel
    /// Closed candles the analysis ran on, oldest first.
    let candles: [PriceCandle]
    let series: [JourneySeries]
    let levels: [JourneyLevel]
    let markers: [JourneyMarker]
    let events: [JourneyEvent]
    let currentPhase: SignalStatus
    let confidence: Int
    let factors: [ConfidenceFactor]
    let volumeRatio: Double
    var scoreLayers: SignalScoreLayers? = nil
    /// The directional evidence rows that adjusted the quality score, shown as
    /// a collapsed sub-section rather than among the main factors.
    var directionalFactors: [ConfidenceFactor] = []
    /// The tournament model's 0–100 score for the latest candle.
    var trendScore: Int? = nil
    /// Entry-event times of journeys that qualified as the A+ setup.
    var aPlusEventTimes: Set<Date> = []

    nonisolated var direction: JourneyDirection { model.direction }

    func events(lastHours hours: Double, now: Date = .now) -> [JourneyEvent] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return events.filter { $0.time >= cutoff }
    }
}

/// The seam every journey model plugs into. A detector turns closed candles into
/// the shared lifecycle, so new patterns reuse the whole presentation layer.
protocol JourneyDetector {
    nonisolated static var model: JourneyModel { get }

    nonisolated static func analyze(
        candles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]?,
        higherTimeframeTitle: String?
    ) -> JourneyAnalysis?
}

/// Routes analysis to the detector backing the selected model.
enum JourneyAnalyzer {
    nonisolated static func analyze(
        model: JourneyModel,
        candles: [PriceCandle],
        higherTimeframeCandles: [PriceCandle]? = nil,
        higherTimeframeTitle: String? = nil
    ) -> JourneyAnalysis? {
        switch model {
        case .emaCross:
            TournamentJourneyAnalyzer.analyze(
                candles: candles,
                higherTimeframeCandles: higherTimeframeCandles,
                higherTimeframeTitle: higherTimeframeTitle
            )
        case .doubleBottom:
            DoubleBottomAnalyzer.analyze(
                candles: candles,
                higherTimeframeCandles: higherTimeframeCandles,
                higherTimeframeTitle: higherTimeframeTitle
            )
        case .doubleTop:
            DoubleTopAnalyzer.analyze(
                candles: candles,
                higherTimeframeCandles: higherTimeframeCandles,
                higherTimeframeTitle: higherTimeframeTitle
            )
        case .donchian20, .donchian50, .horizontalLevel, .consolidation:
            // Server-only models: the backend owns detection and all four
            // scores, so an offline fallback cannot invent a different result.
            nil
        }
    }

    /// Normalizes scored ingredients onto a 0–100 scale so a model stays
    /// comparable even when an optional ingredient is unavailable.
    nonisolated static func confidence(from factors: [ConfidenceFactor]) -> Int {
        let achieved = factors.reduce(0) { $0 + $1.score }
        let achievable = factors.reduce(0) { $0 + $1.maxScore }
        return min(100, max(0, Int((Double(achieved) * 100 / Double(max(achievable, 1))).rounded())))
    }

    nonisolated static func latestVolumeRatio(candles: [PriceCandle]) -> Double {
        guard let last = candles.last, candles.count > 1 else { return 0 }
        let history = candles.dropLast().suffix(20)
        let average = history.map(\.volume).reduce(0, +) / Double(max(history.count, 1))
        guard average > 0 else { return 0 }
        return last.volume / average
    }

    /// Shared volume ingredient: every model rewards a breakout that trades on
    /// above-average volume the same way.
    nonisolated static func volumeFactor(ratio: Double, maxScore: Int = 20) -> ConfidenceFactor {
        let formatted = ratio.formatted(.number.precision(.fractionLength(1)))
        let (score, title): (Int, String) = switch ratio {
        case 2...: (maxScore, L10n.text("Volume very strong", "Hacim çok güçlü"))
        case 1.5..<2: (Int(Double(maxScore) * 0.75), L10n.text("Volume strong", "Hacim güçlü"))
        case 1..<1.5: (Int(Double(maxScore) * 0.55), L10n.text("Volume normal", "Hacim normal"))
        case 0.7..<1: (Int(Double(maxScore) * 0.3), L10n.text("Volume below average", "Hacim ortalamanın altında"))
        default: (Int(Double(maxScore) * 0.1), L10n.text("Volume low", "Hacim düşük"))
        }
        return ConfidenceFactor(
            key: "volume",
            title: title,
            detail: L10n.text(
                "The last closed candle traded \(formatted)x the 20-candle average volume.",
                "Son kapanan mumda hacim, 20 mum ortalamasının \(formatted) katıydı."
            ),
            score: score,
            maxScore: maxScore
        )
    }
}
