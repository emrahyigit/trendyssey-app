import SwiftUI

enum MarketCharacterCategory: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case successful
    case disappointing
    case overheated
    case depressed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .successful: L10n.text("Successful", "Başarılı")
        case .disappointing: L10n.text("Misleading", "Yanıltan")
        case .overheated: L10n.text("Overheated", "Isınmış")
        case .depressed: L10n.text("Depressed", "Baskılanmış")
        }
    }

    var fullTitle: String {
        switch self {
        case .successful: L10n.text("Consistent Breakouts", "İstikrarlı Kırılımlar")
        case .disappointing: L10n.text("Invalidated Breakouts", "Geçersiz Kırılımlar")
        case .overheated: L10n.text("Technically Overheated", "Teknik Olarak Isınmış")
        case .depressed: L10n.text("Technically Depressed", "Teknik Olarak Baskılanmış")
        }
    }

    var systemImage: String {
        switch self {
        case .successful: "checkmark.seal.fill"
        case .disappointing: "exclamationmark.triangle.fill"
        case .overheated: "flame.fill"
        case .depressed: "snowflake"
        }
    }

    var tint: Color {
        switch self {
        case .successful: TrendysseyColor.positive
        case .disappointing: TrendysseyColor.negative
        case .overheated: TrendysseyColor.warning
        case .depressed: .blue
        }
    }

    /// Persona-style badge names shown on the coin detail page when the coin
    /// appears in this category's ranking.
    var badgeTitle: String {
        switch self {
        case .successful: L10n.text("Success Hero", "Başarı Kahramanı")
        case .disappointing: L10n.text("Misleader", "Yanıltan")
        case .overheated: L10n.text("Hot Head", "Ateşli Kafa")
        case .depressed: L10n.text("Deep Freeze", "Derin Donuk")
        }
    }

    var badgeSummary: String {
        switch self {
        case .successful:
            L10n.text("Completed its breakout journeys consistently", "Kırılım yolculuklarını istikrarla tamamladı")
        case .disappointing:
            L10n.text("Its breakouts were often invalidated", "Kırılımları sık sık geçersiz kaldı")
        case .overheated:
            L10n.text("Technical indicators point to overheating", "Teknik göstergeler aşırı ısınmaya işaret ediyor")
        case .depressed:
            L10n.text("Technical indicators show a depressed position", "Teknik göstergeler baskılanmış bir konum gösteriyor")
        }
    }
}

struct MarketCharacterEntry: Identifiable, Hashable, Sendable {
    let category: MarketCharacterCategory
    let symbol: String
    let baseAsset: String
    let iconURL: String?
    let currentPrice: Double
    let change24h: Double
    let quoteVolume24h: Double
    let score: Double
    let rankScore: Double
    let sampleCount: Int
    let successCount: Int
    let failureCount: Int
    let medianReturnPercent: Double?
    let rsi: Double?
    let atrDistance: Double?

    var id: String { "\(category.rawValue)|\(symbol)" }
}

struct MarketCharacterRoute: Hashable {
    let category: MarketCharacterCategory
}
