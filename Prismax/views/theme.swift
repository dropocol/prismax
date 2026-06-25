import SwiftUI

/// Centralized design tokens for PrismaX.
///
/// Inspired by the restrained, content-first aesthetic of Notion and Xcode:
/// neutral surfaces, a single deliberate accent, hairline borders, and a tight
/// typographic scale. All colors adapt to light/dark mode automatically.
enum Theme {
    // MARK: - Accent

    /// The single brand accent (indigo-ish). Used for primary actions, the
    /// selected tab, the active run, and emphasis.
    static let accent = Color("AppAccent", bundle: nil)

    // MARK: - Surfaces

    /// Hairline border color (adapts to light/dark).
    static let hairline = Color.primary.opacity(0.08)

    /// Subtle card/row background fill.
    static let cardFill = Color.primary.opacity(0.03)

    /// Elevated card background (slightly stronger).
    static let cardFillStrong = Color.primary.opacity(0.05)

    // MARK: - Status

    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color(red: 0.92, green: 0.26, blue: 0.21)
    static let running = Color(red: 0.24, green: 0.55, blue: 0.95)

    // MARK: - Console

    /// The terminal panel's top bar background (adapts to light/dark).
    static let consoleBar = Color(red: 0.16, green: 0.16, blue: 0.17)

    /// The terminal panel's body background.
    static let consoleBody = Color(red: 0.11, green: 0.11, blue: 0.12)
}

// MARK: - Typography scale

extension Font {
    /// Large screen title (project name in header).
    static let appTitle = Font.system(size: 18, weight: .semibold, design: .default)

    /// Section headers.
    static let sectionHeader = Font.system(size: 12, weight: .semibold, design: .default)

    /// Regular body row text.
    static let rowPrimary = Font.system(size: 13.5, weight: .medium, design: .default)

    /// Secondary/muted row text.
    static let rowSecondary = Font.system(size: 11.5, weight: .regular, design: .default)

    /// Monospaced command args / code.
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// Tiny tags/captions.
    static let micro = Font.system(size: 10, weight: .semibold, design: .default)
}

// MARK: - Reusable surface modifiers

/// A card with a hairline border, subtle fill, and rounded corners.
struct CardBackground: ViewModifier {
    var fillOpacity: Double = 0.03
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

/// A soft drop shadow used on elevated elements.
struct SoftShadow: ViewModifier {
    var radius: CGFloat = 6
    var y: CGFloat = 2
    var opacity: Double = 0.08

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(opacity), radius: radius, y: y)
    }
}

extension View {
    func cardStyle(fillOpacity: Double = 0.03, cornerRadius: CGFloat = 10) -> some View {
        modifier(CardBackground(fillOpacity: fillOpacity, cornerRadius: cornerRadius))
    }

    func softShadow(radius: CGFloat = 6, y: CGFloat = 2, opacity: Double = 0.08) -> some View {
        modifier(SoftShadow(radius: radius, y: y, opacity: opacity))
    }
}
