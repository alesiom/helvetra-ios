import SwiftUI

/// Helvetra color palette with semantic naming for light and dark modes.
public enum Colors {

    // MARK: - Brand Colors

    /// Swiss Red - primary brand color, used for CTAs only.
    public static let swissRed = Color(hex: 0xDA291C)

    /// Darker red for subtle accents and layer contrast.
    public static let swissRedDark = Color(hex: 0x8B1A12)

    // MARK: - Semantic Colors

    /// Primary background color (screen background).
    public static let background = Color("Background", bundle: .main)

    /// Card/surface background color.
    public static let surface = Color("Surface", bundle: .main)

    /// Primary text color.
    public static let textPrimary = Color("TextPrimary", bundle: .main)

    /// Secondary/muted text color.
    public static let textSecondary = Color("TextSecondary", bundle: .main)

    /// Divider/separator line color.
    public static let divider = Color("Divider", bundle: .main)

    /// Glass tint color for Liquid Glass effects.
    public static let glassTint = Color.white.opacity(0.1)

    // MARK: - Adaptive Colors (Fallbacks)

    /// Background with fallback for when asset catalog isn't set up.
    public static var backgroundAdaptive: Color {
        Color(light: .init(hex: 0xF2F2F7), dark: .black)
    }

    /// Surface with fallback.
    public static var surfaceAdaptive: Color {
        Color(light: .white, dark: .init(hex: 0x1C1C1E))
    }

    /// Primary text with fallback.
    public static var textPrimaryAdaptive: Color {
        Color(light: .black, dark: .white)
    }

    /// Secondary text with fallback.
    public static var textSecondaryAdaptive: Color {
        Color(light: .init(hex: 0x8E8E93), dark: .init(hex: 0x8E8E93))
    }

    /// Divider with fallback.
    public static var dividerAdaptive: Color {
        Color(light: .init(hex: 0xE5E5EA), dark: .init(hex: 0x38383A))
    }

    /// Language card background (slightly different from surface for layering).
    public static var languageCardAdaptive: Color {
        Color(light: .init(hex: 0xE5E5EA), dark: .init(hex: 0x121214))
    }

    /// Dropdown/picker background.
    public static var dropdownAdaptive: Color {
        Color(light: .init(hex: 0xE5E5EA), dark: .init(hex: 0x1C1C1E))
    }
}

// MARK: - Color Extensions

extension Color {
    /// Initialize color from hex value.
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// Create a color that adapts to light/dark mode.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension Colors {
    /// All semantic colors for preview swatches.
    static var allSemanticColors: [(String, Color)] {
        [
            ("Swiss Red", swissRed),
            ("Swiss Red Dark", swissRedDark),
            ("Background", backgroundAdaptive),
            ("Surface", surfaceAdaptive),
            ("Text Primary", textPrimaryAdaptive),
            ("Text Secondary", textSecondaryAdaptive),
            ("Divider", dividerAdaptive),
        ]
    }
}
#endif
