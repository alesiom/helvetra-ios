import SwiftUI

/// Typography scale using SF Pro (system font) with semantic naming.
public enum Typography {

    // MARK: - Display

    /// Large display text for splash/hero elements.
    public static let displayLarge = Font.system(size: 34, weight: .bold, design: .default)

    /// Medium display text.
    public static let displayMedium = Font.system(size: 28, weight: .bold, design: .default)

    // MARK: - Headings

    /// Primary heading (screen titles).
    public static let headingLarge = Font.system(size: 22, weight: .semibold, design: .default)

    /// Secondary heading (section titles).
    public static let headingMedium = Font.system(size: 20, weight: .semibold, design: .default)

    /// Small heading (card titles).
    public static let headingSmall = Font.system(size: 17, weight: .semibold, design: .default)

    // MARK: - Body

    /// Primary body text for translation content.
    public static let bodyLarge = Font.system(size: 17, weight: .regular, design: .default)

    /// Standard body text.
    public static let bodyMedium = Font.system(size: 15, weight: .regular, design: .default)

    /// Small body text.
    public static let bodySmall = Font.system(size: 13, weight: .regular, design: .default)

    // MARK: - Labels

    /// Button labels and emphasized UI elements.
    public static let labelLarge = Font.system(size: 17, weight: .medium, design: .default)

    /// Standard labels (language picker buttons).
    public static let labelMedium = Font.system(size: 15, weight: .medium, design: .default)

    /// Small labels (hints, captions).
    public static let labelSmall = Font.system(size: 13, weight: .medium, design: .default)

    // MARK: - Caption

    /// Footnotes and tertiary information.
    public static let caption = Font.system(size: 12, weight: .regular, design: .default)

    /// Tiny text for version numbers, etc.
    public static let captionSmall = Font.system(size: 11, weight: .regular, design: .default)
}

// MARK: - View Extension for Typography

extension View {
    /// Apply Helvetra typography style.
    func typography(_ font: Font) -> some View {
        self.font(font)
    }
}

// MARK: - Text Styles Enum (for dynamic type support)

extension Typography {
    /// Semantic text styles mapped to dynamic type.
    public enum Style {
        case displayLarge
        case displayMedium
        case headingLarge
        case headingMedium
        case headingSmall
        case bodyLarge
        case bodyMedium
        case bodySmall
        case labelLarge
        case labelMedium
        case labelSmall
        case caption
        case captionSmall

        /// Returns the corresponding Font.
        public var font: Font {
            switch self {
            case .displayLarge: Typography.displayLarge
            case .displayMedium: Typography.displayMedium
            case .headingLarge: Typography.headingLarge
            case .headingMedium: Typography.headingMedium
            case .headingSmall: Typography.headingSmall
            case .bodyLarge: Typography.bodyLarge
            case .bodyMedium: Typography.bodyMedium
            case .bodySmall: Typography.bodySmall
            case .labelLarge: Typography.labelLarge
            case .labelMedium: Typography.labelMedium
            case .labelSmall: Typography.labelSmall
            case .caption: Typography.caption
            case .captionSmall: Typography.captionSmall
            }
        }
    }
}
