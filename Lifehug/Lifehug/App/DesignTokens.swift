import SwiftUI

enum Theme {

    // MARK: - Colors

    static let cream = Color(hex: 0xFBF8F3)
    static let warmCharcoal = Color(hex: 0x2C2420)
    static let walnut = Color(hex: 0x3A3632)
    static let warmGray = Color(hex: 0x6B5E54)
    static let softGray = Color(hex: 0x9E9389)
    static let terracotta = Color(hex: 0xC67B5C)
    static let softCoral = Color(hex: 0xE8856C)
    static let sageGreen = Color(hex: 0x7BA17D)
    static let amber = Color(hex: 0xD4A855)
    static let mutedRose = Color(hex: 0xC47070)
    static let cardBackground = Color.white
    static let cardShadow = Color.black.opacity(0.05)

    // MARK: - Typography

    static let displayFont: Font = .system(size: 36, weight: .light, design: .serif)
    static let titleFont: Font = .system(size: 24, weight: .regular, design: .serif)
    static let title2Font: Font = .system(size: 22, weight: .regular, design: .serif)
    static let title3Font: Font = .system(size: 20, weight: .regular, design: .serif)
    static let headlineFont: Font = .system(size: 17, weight: .semibold, design: .serif)
    static let bodySerifFont: Font = .system(size: 17, weight: .regular, design: .serif)
    static let subheadlineSerifFont: Font = .system(size: 15, weight: .regular, design: .serif)
    static let captionSerifFont: Font = .system(size: 13, weight: .regular, design: .serif)

    // MARK: - Spacing

    static let cardCornerRadius: CGFloat = 16
    static let buttonCornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
