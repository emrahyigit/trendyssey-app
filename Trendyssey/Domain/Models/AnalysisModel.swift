import Foundation

struct AnalysisModelOption: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let slug: String
    let displayName: String
    let provider: String
    let authoringModel: String
    let version: Int
    let description: String
    let requiredTier: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, slug, provider, version, description
        case displayName = "display_name"
        case authoringModel = "authoring_model"
        case requiredTier = "required_tier"
        case isDefault = "is_default"
    }

    static let fallback = AnalysisModelOption(
        id: UUID(uuidString: "56000000-0000-4000-8000-000000000001")!,
        slug: "gpt-5-6-sol-v1",
        displayName: "EMA Cross 7/25/99",
        provider: "Trendyssey",
        authoringModel: "gpt-5.6-sol",
        version: 1,
        description: L10n.text(
            "Tracks the breakout journey from EMA 7/25/99 crossovers and produces a single confidence score from volume, trend and momentum.",
            "EMA 7/25/99 kesişimlerinden kırılım sürecini izler; hacim, trend ve momentum ile tek güven puanı üretir."
        ),
        requiredTier: "pro",
        isDefault: true
    )
}

enum AnalysisModelSelection {
    nonisolated static let storageKey = "preferredAnalysisModel"
    nonisolated static let defaultSlug = "gpt-5-6-sol-v1"
    nonisolated static var selectedSlug: String {
        UserDefaults.standard.string(forKey: storageKey) ?? defaultSlug
    }
}
