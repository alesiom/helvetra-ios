import SwiftUI

/// Consistent spacing scale based on 4pt grid system.
public enum Spacing {

    // MARK: - Base Unit

    /// Base spacing unit (4pt).
    public static let unit: CGFloat = 4

    // MARK: - Scale

    /// Extra extra small spacing (4pt).
    public static let xxs: CGFloat = unit * 1      // 4pt

    /// Extra small spacing (8pt).
    public static let xs: CGFloat = unit * 2       // 8pt

    /// Small spacing (12pt).
    public static let sm: CGFloat = unit * 3       // 12pt

    /// Medium spacing (16pt) - default padding.
    public static let md: CGFloat = unit * 4       // 16pt

    /// Large spacing (24pt).
    public static let lg: CGFloat = unit * 6       // 24pt

    /// Extra large spacing (32pt).
    public static let xl: CGFloat = unit * 8       // 32pt

    /// Extra extra large spacing (48pt).
    public static let xxl: CGFloat = unit * 12     // 48pt

    /// Huge spacing (64pt) - for major sections.
    public static let huge: CGFloat = unit * 16    // 64pt

    // MARK: - Semantic Spacing

    /// Card internal padding.
    public static let cardPadding: CGFloat = md    // 16pt

    /// Card corner radius.
    public static let cardRadius: CGFloat = 20

    /// Button corner radius.
    public static let buttonRadius: CGFloat = 12

    /// Small button corner radius (pills).
    public static let pillRadius: CGFloat = 20

    /// Screen edge padding.
    public static let screenPadding: CGFloat = md  // 16pt

    /// Space between language buttons and swap icon.
    public static let languageBarGap: CGFloat = sm // 12pt

    /// Divider line height (normal state).
    public static let dividerHeight: CGFloat = 1

    /// Divider line height (loading state max).
    public static let dividerHeightLoading: CGFloat = 3

    // MARK: - Hit Targets

    /// Minimum touch target size (Apple HIG: 44pt).
    public static let minTouchTarget: CGFloat = 44

    /// Comfortable touch target size.
    public static let touchTarget: CGFloat = 48
}

// MARK: - View Extensions

extension View {
    /// Apply standard card padding.
    func cardPadding() -> some View {
        self.padding(Spacing.cardPadding)
    }

    /// Apply standard screen edge padding.
    func screenPadding() -> some View {
        self.padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - EdgeInsets Helpers

extension EdgeInsets {
    /// Standard card insets.
    static var card: EdgeInsets {
        EdgeInsets(
            top: Spacing.cardPadding,
            leading: Spacing.cardPadding,
            bottom: Spacing.cardPadding,
            trailing: Spacing.cardPadding
        )
    }

    /// Horizontal-only padding.
    static func horizontal(_ value: CGFloat) -> EdgeInsets {
        EdgeInsets(top: 0, leading: value, bottom: 0, trailing: value)
    }

    /// Vertical-only padding.
    static func vertical(_ value: CGFloat) -> EdgeInsets {
        EdgeInsets(top: value, leading: 0, bottom: value, trailing: 0)
    }
}
