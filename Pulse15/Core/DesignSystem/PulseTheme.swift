import SwiftUI
import UIKit

enum PulseColor {
    /// Binance's brighter brand yellow — #FCD535.
    static let binanceYellow = Color(red: 252.0 / 255.0, green: 213.0 / 255.0, blue: 53.0 / 255.0)
    static let canvas = adaptive(light: UIColor(red: 0.976, green: 0.968, blue: 0.941, alpha: 1), dark: UIColor(red: 0.055, green: 0.063, blue: 0.082, alpha: 1))
    static let surface = adaptive(light: UIColor(white: 1, alpha: 0.94), dark: UIColor(red: 0.105, green: 0.118, blue: 0.145, alpha: 1))
    static let elevated = adaptive(light: UIColor(red: 0.969, green: 0.947, blue: 0.882, alpha: 1), dark: UIColor(red: 0.165, green: 0.153, blue: 0.105, alpha: 1))
    static let accent = binanceYellow
    static let positive = Color(red: 0.20, green: 0.62, blue: 0.48)
    static let negative = Color(red: 0.84, green: 0.34, blue: 0.40)
    static let warning = Color(red: 0.86, green: 0.58, blue: 0.22)
    static let chatIncoming = adaptive(light: UIColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1), dark: UIColor(red: 0.17, green: 0.18, blue: 0.21, alpha: 1))
    static let primaryText = adaptive(light: UIColor(red: 0.11, green: 0.14, blue: 0.22, alpha: 1), dark: UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
    static let secondaryText = adaptive(light: UIColor(red: 0.36, green: 0.40, blue: 0.49, alpha: 1), dark: UIColor(red: 0.64, green: 0.67, blue: 0.73, alpha: 1))
    static let border = adaptive(light: UIColor(red: 0.84, green: 0.79, blue: 0.67, alpha: 0.48), dark: UIColor(red: 0.34, green: 0.31, blue: 0.23, alpha: 0.72))

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(PulseColor.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(PulseColor.border, lineWidth: 1)
            }
    }
}

struct ScorePill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(PulseColor.secondaryText).lineLimit(1)
            Text(value).fontWeight(.semibold).foregroundStyle(PulseColor.primaryText).lineLimit(1)
        }
        .font(.caption2)
        .minimumScaleFactor(0.8)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(color.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func pulseBackground() -> some View {
        scrollContentBackground(.hidden).background(PulseColor.canvas.ignoresSafeArea())
    }
}
