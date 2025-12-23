import SwiftUI

/// Central theme providing access to all design tokens.
///
/// Usage: Access colors, typography, and spacing through direct static properties
/// or use the convenience accessors on Theme.shared.
public enum Theme {

    // MARK: - Color Accessors

    /// Primary brand color for CTAs.
    public static var accent: Color { Colors.swissRed }

    /// Subtle accent for layer contrast.
    public static var accentSubtle: Color { Colors.swissRedDark }

    /// Screen background.
    public static var background: Color { Colors.backgroundAdaptive }

    /// Card/surface background.
    public static var surface: Color { Colors.surfaceAdaptive }

    /// Primary text.
    public static var textPrimary: Color { Colors.textPrimaryAdaptive }

    /// Secondary text.
    public static var textSecondary: Color { Colors.textSecondaryAdaptive }

    /// Divider lines.
    public static var divider: Color { Colors.dividerAdaptive }

    /// Glass effect tint.
    public static var glassTint: Color { Colors.glassTint }
}

// MARK: - View Extension

extension View {
    /// Apply standard Helvetra theming (placeholder for future customization).
    public func withTheme() -> some View {
        self
    }
}
