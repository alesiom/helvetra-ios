import SwiftUI

/// Liquid Glass effect helpers for iOS 26+.
public enum GlassEffect {

    // MARK: - Effect Styles

    /// Standard glass effect intensity.
    public enum Intensity {
        case subtle      // Light blur, barely visible
        case regular     // Standard glass look
        case prominent   // Strong glass effect
    }
}

// MARK: - Glass Background Modifier

extension View {
    /// Apply a glass background effect (iOS 26 Liquid Glass).
    ///
    /// Use on buttons and small UI elements for the frosted glass look.
    @ViewBuilder
    public func glassBackground(
        intensity: GlassEffect.Intensity = .regular,
        cornerRadius: CGFloat = Spacing.buttonRadius
    ) -> some View {
        self.background {
            GlassBackgroundView(intensity: intensity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Apply glass effect to a button-like element.
    public func glassPill() -> some View {
        self.glassBackground(intensity: .regular, cornerRadius: Spacing.pillRadius)
    }
}

// MARK: - Glass Background View

/// Internal view that renders the glass effect.
private struct GlassBackgroundView: View {
    let intensity: GlassEffect.Intensity

    var body: some View {
        // iOS 26 introduces .glassEffect() modifier
        // For now, we use the material system which provides similar blur effects
        switch intensity {
        case .subtle:
            Rectangle()
                .fill(.ultraThinMaterial)
        case .regular:
            Rectangle()
                .fill(.thinMaterial)
        case .prominent:
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}

// MARK: - Glass Button Style

/// Button style with glass background for language selector pills.
public struct GlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.labelMedium)
            .foregroundStyle(colorScheme == .dark ? .white : .primary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: Spacing.minTouchTarget)
            .background {
                RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                    .fill(.thinMaterial)
            }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Primary Button Style

/// Primary CTA button with Swiss Red background.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.labelLarge)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: Spacing.minTouchTarget)
            .background {
                RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                    .fill(Colors.swissRed)
            }
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Secondary Button Style

/// Secondary button with subtle background.
public struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.labelMedium)
            .foregroundStyle(Colors.swissRed)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.minTouchTarget)
            .background {
                RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                    .fill(Colors.swissRed.opacity(0.1))
            }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Button Style Extensions

extension ButtonStyle where Self == GlassButtonStyle {
    /// Glass pill button style for language selectors.
    public static var glassPill: GlassButtonStyle { GlassButtonStyle() }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// Primary CTA button style.
    public static var helvetraPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    /// Secondary button style.
    public static var helvetraSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
