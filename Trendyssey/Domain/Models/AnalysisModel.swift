import Foundation

enum AnalysisModelSelection {
    nonisolated static let defaultSlug = "ema-7-25-99-v1"

    /// The backend model to query for the selected journey model. There is one
    /// model choice in the app, so this is derived rather than picked separately;
    /// models that only run on the device fall back to the default so preference
    /// sync keeps sending a slug the backend recognises.
    nonisolated static var selectedSlug: String {
        JourneyModel.selected.serverSlug ?? defaultSlug
    }
}
