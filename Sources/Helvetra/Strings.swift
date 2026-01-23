import Foundation

/// Localized string helpers for type-safe access to translations.
enum L10n {

    // MARK: - Translation Screen

    static let inputPlaceholder = NSLocalizedString("translation.placeholder.input", comment: "")
    static let outputPlaceholder = NSLocalizedString("translation.placeholder.output", comment: "")
    static let translating = NSLocalizedString("translation.status.translating", comment: "")
    static let paste = NSLocalizedString("translation.button.paste", comment: "")
    static let clearText = NSLocalizedString("translation.button.clear", comment: "")
    static let copyTranslation = NSLocalizedString("translation.button.copy", comment: "")
    static let shareTranslation = NSLocalizedString("translation.button.share", comment: "")
    static let copiedToClipboard = NSLocalizedString("translation.toast.copied", comment: "")

    // MARK: - Languages

    static func languageName(_ code: String) -> String {
        NSLocalizedString("language.\(code)", comment: "")
    }

    static let selectLanguage = NSLocalizedString("language.picker.title", comment: "")
    static let swapLanguages = NSLocalizedString("language.picker.swap", comment: "")

    static func sourceLanguageLabel(_ name: String) -> String {
        String(format: NSLocalizedString("language.picker.source", comment: ""), name)
    }

    static func targetLanguageLabel(_ name: String) -> String {
        String(format: NSLocalizedString("language.picker.target", comment: ""), name)
    }

    static func sourceLanguageDetected(_ name: String) -> String {
        String(format: NSLocalizedString("language.picker.source.detected", comment: ""), name)
    }

    // MARK: - Dialects

    static let dialectTitle = NSLocalizedString("dialect.title", comment: "")
    static let dialectFooter = NSLocalizedString("dialect.footer", comment: "")

    static func dialectName(_ code: String) -> String {
        NSLocalizedString("dialect.\(code)", comment: "")
    }

    // MARK: - Formality

    static let formalityTitle = NSLocalizedString("formality.title", comment: "")
    static let formalityFormal = NSLocalizedString("formality.formal", comment: "")
    static let formalityInformal = NSLocalizedString("formality.informal", comment: "")

    // MARK: - Settings

    static let settings = NSLocalizedString("settings.title", comment: "")
    static let closeSettings = NSLocalizedString("settings.close", comment: "")
    static let openSettings = NSLocalizedString("settings.open", comment: "")

    // Account
    static let accountTitle = NSLocalizedString("settings.account.title", comment: "")
    static func planName(_ tier: String) -> String {
        String(format: NSLocalizedString("settings.account.plan", comment: ""), tier)
    }
    static let upgrade = NSLocalizedString("settings.account.upgrade", comment: "")
    static let signOut = NSLocalizedString("settings.account.signout", comment: "")

    // Preferences
    static let preferencesTitle = NSLocalizedString("settings.preferences.title", comment: "")
    static let hapticFeedback = NSLocalizedString("settings.preferences.haptics", comment: "")

    // About
    static let aboutTitle = NSLocalizedString("settings.about.title", comment: "")
    static let version = NSLocalizedString("settings.about.version", comment: "")
    static let aboutWebsite = NSLocalizedString("settings.about.website", comment: "")
    static let privacyPolicy = NSLocalizedString("settings.about.privacy", comment: "")
    static let termsOfService = NSLocalizedString("settings.about.terms", comment: "")
    static let sendFeedback = NSLocalizedString("settings.about.feedback", comment: "")
    static let emailCopied = NSLocalizedString("settings.about.feedback.copied", comment: "")
    static let madeInSwitzerland = NSLocalizedString("settings.about.footer", comment: "")

    // Danger Zone
    static let dangerZoneTitle = NSLocalizedString("settings.danger.title", comment: "")
    static let deleteAccount = NSLocalizedString("settings.danger.delete", comment: "")
    static let deleteAccountTitle = NSLocalizedString("settings.danger.delete.title", comment: "")
    static let deleteAccountMessage = NSLocalizedString("settings.danger.delete.message", comment: "")
    static let deleteAccountConfirm = NSLocalizedString("settings.danger.delete.confirm", comment: "")

    // MARK: - Subscription

    static let subscriptionTitle = NSLocalizedString("subscription.title", comment: "")
    static func currentPlan(_ tier: String) -> String {
        String(format: NSLocalizedString("subscription.current", comment: ""), tier)
    }
    static let monthly = NSLocalizedString("subscription.monthly", comment: "")
    static let yearly = NSLocalizedString("subscription.yearly", comment: "")
    static let save20 = NSLocalizedString("subscription.save", comment: "")
    static let billedYearly = NSLocalizedString("subscription.billed.yearly", comment: "")
    static let subscribe = NSLocalizedString("subscription.subscribe", comment: "")
    static let currentPlanLabel = NSLocalizedString("subscription.current.plan", comment: "")
    static let restorePurchases = NSLocalizedString("subscription.restore", comment: "")
    static let noPurchasesFound = NSLocalizedString("subscription.restore.none", comment: "")

    // Features
    static let featureCharacters = NSLocalizedString("subscription.feature.characters", comment: "")
    static let featurePriority = NSLocalizedString("subscription.feature.priority", comment: "")
    static let featureSupport = NSLocalizedString("subscription.feature.support", comment: "")

    // MARK: - Usage

    static let usageWeekly = NSLocalizedString("usage.period.weekly", comment: "")
    static let usageMonthly = NSLocalizedString("usage.period.monthly", comment: "")

    // MARK: - Common

    static let done = NSLocalizedString("common.done", comment: "")
    static let back = NSLocalizedString("common.back", comment: "")
    static let ok = NSLocalizedString("common.ok", comment: "")
    static let cancel = NSLocalizedString("common.cancel", comment: "")

    // MARK: - Limit Reached

    static let limitTitle = NSLocalizedString("limit.title", comment: "")
    static let limitMessage = NSLocalizedString("limit.message", comment: "")
    static let limitMonthlyMessage = NSLocalizedString("limit.message.monthly", comment: "")
    static let limitUpgrade = NSLocalizedString("limit.upgrade", comment: "")

    // MARK: - Errors

    static let errorGeneric = NSLocalizedString("error.generic", comment: "")
    static let errorNetwork = NSLocalizedString("error.network", comment: "")
    static func errorServer(_ code: Int) -> String {
        String(format: NSLocalizedString("error.server", comment: ""), code)
    }
    static let errorInvalidResponse = NSLocalizedString("error.invalid.response", comment: "")
    static let errorTranslationFailed = NSLocalizedString("error.translation.failed", comment: "")
    static let errorVerificationFailed = NSLocalizedString("error.verification.failed", comment: "")
    static let errorPurchaseFailed = NSLocalizedString("error.purchase.failed", comment: "")
}
