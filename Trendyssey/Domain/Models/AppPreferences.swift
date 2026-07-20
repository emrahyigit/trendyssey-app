import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }
    var title: String { self == .turkish ? "Türkçe" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }

    nonisolated static var `default`: AppLanguage {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") == true ? .turkish : .english
    }
}

enum L10n {
    nonisolated static var isTurkish: Bool {
        (UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.default) == .turkish
    }

    nonisolated static func text(_ english: String, _ turkish: String) -> String {
        isTurkish ? turkish : english
    }

    /// Locale matching the in-app language so formatted values stay
    /// consistent with the UI language instead of the device locale.
    nonisolated static var locale: Locale {
        Locale(identifier: isTurkish ? "tr_TR" : "en_US")
    }

    nonisolated static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    nonisolated static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }
}

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.text("System Default", "Sistem Varsayılanı")
        case .light: L10n.text("Light", "Açık")
        case .dark: L10n.text("Dark", "Koyu")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
