# Helvetra iOS

Native iOS app for [Helvetra](https://helvetra.ch), a privacy-first Swiss translation app.

## Features

- Translation with real-time auto-translate
- Swiss German dialect support (Zurich, Bern, Basel, Luzern, St. Gallen, Wallis)
- Language auto-detection
- Formality toggle (du/Sie, tu/vous, tu/Lei)
- Sign in with Apple
- StoreKit 2 in-app subscriptions
- VoiceOver accessibility
- Localized in 5 languages (EN, DE, FR, IT, RM)

## Tech Stack

- **Framework:** SwiftUI
- **Minimum:** iOS 16+
- **Auth:** Sign in with Apple + Keychain
- **Payments:** StoreKit 2
- **Architecture:** MVVM with ObservableObject services

## Setup

1. Open `Helvetra.xcodeproj` in Xcode 15+
2. Select your development team in Signing & Capabilities
3. Build and run on simulator or device

For StoreKit testing, the `Helvetra.storekit` configuration is included for local sandbox testing.

## Project Structure

```
Sources/Helvetra/
├── App/             # App entry point
├── Views/           # SwiftUI views
├── Services/        # Business logic (Auth, Store, Usage)
├── DesignSystem/    # Colors, typography, spacing
└── Resources/       # Assets and Info.plist
```

## License

MIT
