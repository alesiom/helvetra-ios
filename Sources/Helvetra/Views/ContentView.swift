import SwiftUI

/// Root view demonstrating the design system.
struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Background
            Colors.backgroundAdaptive
                .ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                // Settings button (top right)
                HStack {
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .foregroundStyle(Colors.textSecondaryAdaptive)
                    }
                    .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                }
                .padding(.horizontal, Spacing.screenPadding)

                Spacer()

                // Main translation card
                VStack(spacing: 0) {
                    // Source area
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Type or paste here to translate")
                            .font(Typography.bodyLarge)
                            .foregroundStyle(Colors.textSecondaryAdaptive)

                        Button(action: {}) {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.helvetraSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.cardPadding)

                    // Divider
                    Rectangle()
                        .fill(Colors.dividerAdaptive)
                        .frame(height: Spacing.dividerHeight)
                        .padding(.horizontal, Spacing.cardPadding)

                    // Target area
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Translation appears here")
                            .font(Typography.bodyLarge)
                            .foregroundStyle(Colors.textSecondaryAdaptive)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    .padding(Spacing.cardPadding)
                }
                .background {
                    RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
                        .fill(Colors.surfaceAdaptive)
                        .shadow(
                            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
                            radius: 20,
                            y: 10
                        )
                }
                .padding(.horizontal, Spacing.screenPadding)

                Spacer()

                // Language bar
                HStack(spacing: Spacing.languageBarGap) {
                    Button("Detect") {}
                        .buttonStyle(.glassPill)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Colors.textSecondaryAdaptive)

                    Button("French") {}
                        .buttonStyle(.glassPill)
                }
                .padding(.bottom, Spacing.lg)
            }
        }
        .withTheme()
    }
}

#Preview("Light Mode") {
    ContentView()
        .preferredColorScheme(.light)
}

#Preview("Dark Mode") {
    ContentView()
        .preferredColorScheme(.dark)
}
