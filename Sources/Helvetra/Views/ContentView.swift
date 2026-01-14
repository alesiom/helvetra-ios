import StoreKit
import SwiftUI

// MARK: - Store Service

/// Manages in-app purchases and subscriptions using StoreKit 2.
@MainActor
class StoreService: ObservableObject {

    /// Subscription tiers available for purchase.
    enum SubscriptionTier: String, CaseIterable {
        case free = "Free"
        case plus = "Helvetra+"

        /// Monthly character limit (matches backend tiers.py).
        var characterLimit: Int {
            switch self {
            case .free: return 20_000
            case .plus: return 500_000
            }
        }

        /// Per-request character limit (matches backend tiers.py).
        var perRequestLimit: Int {
            switch self {
            case .free: return 1_000
            case .plus: return 5_000
            }
        }

        var productId: String? {
            switch self {
            case .free: return nil
            case .plus: return "ch.helvetra.pro.monthly"
            }
        }
    }

    static let shared = StoreService()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var currentTier: SubscriptionTier = .free
    @Published private(set) var isLoading: Bool = false

    private var updateListenerTask: Task<Void, Error>?
    private let baseURL = "https://helvetra.ch/api/v1"
    private let session: URLSession

    private let productIDs: Set<String> = [
        "ch.helvetra.pro.monthly",
        "ch.helvetra.pro.yearly"
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)

        updateListenerTask = listenForTransactions()
        Task { await loadProducts() }

        // Listen for auth state changes to sync web subscriptions
        NotificationCenter.default.addObserver(
            forName: .authStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncFromAuth()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    /// Load available products from App Store.
    func loadProducts() async {
        isLoading = true
        do {
            products = try await Product.products(for: productIDs)
        } catch {
            print("Failed to load products: \(error)")
        }
        isLoading = false
    }

    /// Purchase a product.
    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            print("[StoreKit] Purchase successful: \(transaction.productID)")

            // Verify with backend to sync subscription status
            let isAuth = AuthService.shared.isAuthenticated
            print("[StoreKit] User authenticated: \(isAuth)")

            if isAuth {
                await verifyWithBackend(verification: verification)
            } else {
                print("[StoreKit] Skipping backend verification - user not logged in")
            }

            await updatePurchasedProducts()
            await transaction.finish()

            // Refresh usage data to reflect new subscription
            print("[StoreKit] Refreshing usage data...")
            await UsageService.shared.fetchUsage()
            print("[StoreKit] Usage limit now: \(UsageService.shared.charactersLimit)")

        case .pending:
            break

        case .userCancelled:
            break

        @unknown default:
            break
        }
    }

    /// Restore previous purchases and sync with backend.
    func restorePurchases() async {
        print("[StoreKit] Restoring purchases...")

        // Sync any existing entitlements with backend
        if AuthService.shared.isAuthenticated {
            for await result in Transaction.currentEntitlements {
                if case .verified = result {
                    print("[StoreKit] Found entitlement, verifying with backend...")
                    await verifyWithBackend(verification: result)
                }
            }
        }

        await updatePurchasedProducts()
        await UsageService.shared.fetchUsage()
        print("[StoreKit] Restore complete, limit: \(UsageService.shared.charactersLimit)")
    }

    /// Update the set of purchased products.
    func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                purchased.insert(transaction.productID)
            }
        }

        purchasedProductIDs = purchased
        updateCurrentTier()
    }

    /// Listen for transaction updates (renewals, etc.).
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    // Verify renewal with backend
                    if await AuthService.shared.isAuthenticated {
                        await self.verifyWithBackend(verification: result)
                    }
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                    await UsageService.shared.fetchUsage()

                case .unverified:
                    break
                }
            }
        }
    }

    /// Verify a transaction result.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    /// Update current tier based on purchases and backend subscription.
    private func updateCurrentTier() {
        // Check StoreKit purchases (App Store subscriptions)
        if purchasedProductIDs.contains(where: { $0.contains("pro") }) {
            currentTier = .plus
            return
        }

        // Check backend tier (web subscriptions via Payrexx)
        if let backendTier = AuthService.shared.currentUser?.tier,
           backendTier.lowercased().contains("plus") || backendTier.lowercased().contains("pro") {
            currentTier = .plus
            return
        }

        currentTier = .free
    }

    /// Sync tier from backend auth state. Call when auth state changes.
    func syncFromAuth() {
        updateCurrentTier()

        // If user just logged in, sync any existing StoreKit purchases with backend
        if AuthService.shared.isAuthenticated {
            Task {
                await syncStoreKitWithBackend()
            }
        }
    }

    /// Get the JWS representation of the current subscription entitlement.
    /// Used to include in translation requests for anonymous users with StoreKit subscriptions.
    func getCurrentEntitlementJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            // Only return JWS for pro/plus subscriptions
            if case .verified(let transaction) = result,
               transaction.productID.contains("pro") {
                return result.jwsRepresentation
            }
        }
        return nil
    }

    /// Sync existing StoreKit entitlements with backend (called after login).
    private func syncStoreKitWithBackend() async {
        print("[StoreKit] Syncing existing entitlements with backend after login...")

        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                print("[StoreKit] Found existing entitlement, verifying...")
                await verifyWithBackend(verification: result)
            }
        }

        await UsageService.shared.fetchUsage()
        print("[StoreKit] Sync complete, limit: \(UsageService.shared.charactersLimit)")
    }

    /// Verify a StoreKit transaction with the backend to sync subscription status.
    private func verifyWithBackend(verification: VerificationResult<StoreKit.Transaction>) async {
        print("[StoreKit] Starting backend verification...")

        guard let accessToken = await AuthService.shared.getAccessToken() else {
            print("[StoreKit] ERROR: No access token available")
            return
        }
        print("[StoreKit] Got access token")

        // Get the JWS representation from the verification result
        let jwsRepresentation = verification.jwsRepresentation
        print("[StoreKit] JWS length: \(jwsRepresentation.count) chars")

        let url = URL(string: "\(baseURL)/subscription/apple/verify")!
        print("[StoreKit] Calling: \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["signed_transaction": jwsRepresentation]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[StoreKit] ERROR: Invalid response type")
                return
            }

            print("[StoreKit] Backend response: HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                if let result = try? JSONDecoder().decode(AppleVerifyResponse.self, from: data),
                   result.success {
                    print("[StoreKit] SUCCESS: Backend verified subscription as \(result.tier ?? "unknown")")
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "no data"
                    print("[StoreKit] FAILED: Backend returned: \(responseStr)")
                }
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "no data"
                print("[StoreKit] ERROR: HTTP \(httpResponse.statusCode) - \(responseStr)")
            }
        } catch {
            print("[StoreKit] ERROR: Network request failed: \(error)")
        }
    }
}

/// Response from backend Apple verification endpoint.
private struct AppleVerifyResponse: Decodable {
    let success: Bool
    let tier: String?
    let expires_at: String?
    let message: String?
}

/// Store-related errors.
enum StoreError: LocalizedError {
    case verificationFailed
    case purchaseFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "Transaction verification failed"
        case .purchaseFailed:
            return "Purchase could not be completed"
        }
    }
}

// MARK: - Haptic Service

/// Centralized haptic feedback manager.
enum HapticService {
    /// Light feedback for selections and toggles.
    static func selection() {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    /// Medium impact for confirmations and actions.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    /// Success notification for completed actions.
    static func success() {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// Light impact for subtle confirmations.
    static func light() {
        impact(.light)
    }
}

/// Root view with layer-based UI system.
struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel = TranslationViewModel()
    @State private var showSourceLanguagePicker = false
    @State private var showTargetLanguagePicker = false
    @State private var selectedSourceLanguage: String = "auto"
    @State private var selectedTargetLanguage: String = "gsw"

    /// Persisted formality preference.
    @AppStorage("selectedFormality") private var selectedFormality: String = "informal"

    /// Persisted dialect preference.
    @AppStorage("selectedDialect") private var selectedDialect: String = "zurich"

    /// Haptic feedback enabled setting.
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true


    @FocusState private var isSourceFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var isSettingsOpen: Bool = false
    @State private var showCopyConfirmation: Bool = false
    @State private var inputFontSize: CGFloat = 28

    // MARK: - Helpers

    /// Get localized language name for a language code.
    private func languageName(for code: String) -> String {
        L10n.languageName(code)
    }

    /// Dynamic font sizing: reduces from 28px to 18px based on text length before enabling scroll.
    private func dynamicFont(for text: String) -> Font {
        let length = text.count
        let baseSize: CGFloat = 28
        let minSize: CGFloat = 18

        // Start reducing at 50 chars, reach minimum at 200 chars
        if length < 50 {
            return .system(size: baseSize, weight: .regular)
        } else if length > 200 {
            return .system(size: minSize, weight: .regular)
        } else {
            // Linear interpolation between 50 and 200 chars
            let progress = CGFloat(length - 50) / 150.0
            let size = baseSize - (progress * (baseSize - minSize))
            return .system(size: size, weight: .regular)
        }
    }

    /// Space above L1 when keyboard hidden.
    private let settingsAreaHeight: CGFloat = 16

    /// Height of L2 language switcher.
    private let l2Height: CGFloat = 100

    /// Extra bleed below keyboard to cover rounded corners.
    private let bottomBleed: CGFloat = 50

    /// Per-request character limit based on current subscription tier.
    private var perRequestLimit: Int {
        StoreService.shared.currentTier.perRequestLimit
    }

    /// Show counter when approaching per-request limit.
    private let counterWarningThreshold: Int = 800

    // MARK: - Computed Properties

    /// Whether to show the character counter (> 800 chars).
    private var showCharacterCounter: Bool {
        viewModel.sourceText.count > counterWarningThreshold
    }

    /// Whether text exceeds per-request limit.
    private var isOverPerRequestLimit: Bool {
        viewModel.sourceText.count > perRequestLimit
    }

    /// Whether source language was auto-detected.
    private var isLanguageDetected: Bool {
        selectedSourceLanguage == "auto" && viewModel.detectedLanguage != nil
    }

    private var sourceLanguageName: String {
        // Show detected language name when auto-detect found a result
        if selectedSourceLanguage == "auto",
           let detected = viewModel.detectedLanguage {
            return languageName(for: detected)
        }
        return languageName(for: selectedSourceLanguage)
    }

    private var targetLanguageName: String {
        languageName(for: selectedTargetLanguage)
    }

    private var isKeyboardVisible: Bool { keyboardHeight > 0 }

    /// Languages that have formality or dialect settings.
    private let languagesWithSettings: Set<String> = ["de", "fr", "it", "gsw"]

    /// Whether source language has additional settings (formality/dialect).
    private var sourceHasSettings: Bool {
        languagesWithSettings.contains(selectedSourceLanguage)
    }

    /// Whether target language has additional settings (formality/dialect).
    private var targetHasSettings: Bool {
        languagesWithSettings.contains(selectedTargetLanguage)
    }

    private var bottomPadding: CGFloat {
        keyboardHeight > 0 ? keyboardHeight - bottomBleed : 0
    }

    /// L2 needs different positioning than L1.
    private var l2BottomPadding: CGFloat {
        keyboardHeight > 0 ? keyboardHeight - bottomBleed + 25 : -20
    }

    /// iPad landscape uses side-by-side layout.
    private var useSideBySideLayout: Bool {
        horizontalSizeClass == .regular
    }

    // MARK: - Actions

    private func swapLanguages() {
        HapticService.light()
        let temp = selectedSourceLanguage
        selectedSourceLanguage = selectedTargetLanguage
        selectedTargetLanguage = temp
    }

    /// Sync local settings to ViewModel before translation.
    private func syncViewModelSettings() {
        migrateDialectIfNeeded()
        viewModel.sourceLang = selectedSourceLanguage
        viewModel.targetLang = selectedTargetLanguage
        viewModel.formality = selectedFormality
        viewModel.dialect = selectedDialect
    }

    /// Migrate old dialect display names to API codes.
    private func migrateDialectIfNeeded() {
        let migrations: [String: String] = [
            "Zürich": "zurich",
            "Bern": "bern",
            "Basel": "basel",
            "Luzern": "luzern",
            "St. Gallen": "stgallen",
            "Graubünden": "wallis",
        ]
        if let newCode = migrations[selectedDialect] {
            selectedDialect = newCode
        }
    }

    /// Paste text from clipboard.
    private func pasteFromClipboard() {
        if let string = UIPasteboard.general.string {
            viewModel.sourceText = string
        }
    }

    /// Copy translation to clipboard with haptic feedback.
    private func copyTranslation() {
        UIPasteboard.general.string = viewModel.translatedText
        HapticService.impact()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCopyConfirmation = false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top

            ZStack {
                // L0: Background (static, never moves)
                Colors.backgroundAdaptive
                    .ignoresSafeArea()

                // L0: Settings button + settings content (static, never moves)
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                isSettingsOpen.toggle()
                                if isSettingsOpen {
                                    isSourceFocused = false
                                }
                            }
                        }) {
                            if isSettingsOpen {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                            } else {
                                HelvetraIcon(size: 24)
                            }
                        }
                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                        .accessibilityLabel(isSettingsOpen ? L10n.closeSettings : L10n.openSettings)
                        .accessibilityHint(isSettingsOpen ? "Double tap to close settings" : "Double tap to open settings")

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)

                    // Settings content (revealed when L1 slides down)
                    SettingsView(hapticsEnabled: $hapticsEnabled)

                    Spacer()
                }

                // L1: Translation card
                VStack(spacing: 0) {
                    // Top spacer - shrinks to 0 when keyboard appears, expands when settings open
                    let topSpacing = useSideBySideLayout ? safeTop + 50 : safeTop + settingsAreaHeight
                    // Visible card height when settings open - enough to show first line of text
                    let settingsOffset: CGFloat = AuthService.shared.isAuthenticated ? 200 : 160
                    Color.clear
                        .frame(height: isSettingsOpen ? geometry.size.height - settingsOffset : (isKeyboardVisible ? 0 : topSpacing))

                    // Swipe-down indicator (visible when keyboard is open)
                    if isKeyboardVisible && !isSettingsOpen {
                        Button(action: {
                            isSourceFocused = false
                        }) {
                            Image(systemName: "chevron.compact.down")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Colors.textSecondaryAdaptive.opacity(0.6))
                        }
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }

                    // Card content
                    VStack(spacing: 0) {
                        // Translation areas layout (vertical on iPhone, horizontal on iPad)
                        let layout = useSideBySideLayout
                            ? AnyLayout(HStackLayout(spacing: 0))
                            : AnyLayout(VStackLayout(spacing: 0))

                        layout {
                            // L1T: Input area
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                ZStack(alignment: .topTrailing) {
                                    ScrollViewReader { scrollProxy in
                                        ScrollView {
                                            TextField(L10n.inputPlaceholder, text: $viewModel.sourceText, axis: .vertical)
                                                .font(.system(size: inputFontSize, weight: .regular))
                                                .foregroundStyle(Colors.textPrimaryAdaptive)
                                                .focused($isSourceFocused)
                                                .lineLimit(1...)
                                                .padding(.trailing, viewModel.sourceText.isEmpty ? 0 : 28)
                                                .onChange(of: viewModel.sourceText) { _, newValue in
                                                    syncViewModelSettings()
                                                    viewModel.sourceTextChanged()
                                                    // Update font size based on text length
                                                    let length = newValue.count
                                                    let baseSize: CGFloat = 28
                                                    let minSize: CGFloat = 18
                                                    if length < 50 {
                                                        inputFontSize = baseSize
                                                    } else if length > 200 {
                                                        inputFontSize = minSize
                                                    } else {
                                                        let progress = CGFloat(length - 50) / 150.0
                                                        inputFontSize = baseSize - (progress * (baseSize - minSize))
                                                    }
                                                    // Auto-scroll to bottom when typing
                                                    scrollProxy.scrollTo("inputBottom", anchor: .bottom)
                                                }
                                                .onChange(of: selectedSourceLanguage) { oldValue, newValue in
                                                    // Prevent same language on both sides
                                                    if newValue != "auto" && newValue == selectedTargetLanguage {
                                                        selectedTargetLanguage = oldValue
                                                    }
                                                    syncViewModelSettings()
                                                    viewModel.retranslate()
                                                }
                                                .onChange(of: selectedTargetLanguage) { oldValue, newValue in
                                                    // Prevent same language on both sides
                                                    // Check both explicit source and auto-detected source
                                                    let effectiveSource = selectedSourceLanguage == "auto"
                                                        ? viewModel.detectedLanguage
                                                        : selectedSourceLanguage
                                                    if newValue == effectiveSource {
                                                        // Swap: source becomes old target, turn off auto-detect
                                                        selectedSourceLanguage = oldValue
                                                    }
                                                    syncViewModelSettings()
                                                    viewModel.retranslate()
                                                }
                                                .onChange(of: selectedFormality) { _, _ in
                                                    syncViewModelSettings()
                                                    viewModel.retranslate()
                                                }
                                                .onChange(of: selectedDialect) { _, _ in
                                                    syncViewModelSettings()
                                                    viewModel.retranslate()
                                                }
                                                .onChange(of: isSourceFocused) { _, focused in
                                                    if focused && isSettingsOpen {
                                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                                            isSettingsOpen = false
                                                        }
                                                    }
                                                }

                                            // Invisible anchor for auto-scroll
                                            Color.clear
                                                .frame(height: 1)
                                                .id("inputBottom")
                                        }
                                    }
                                    .scrollDismissesKeyboard(.interactively)

                                    // Clear button - fixed position, doesn't scroll
                                    if !viewModel.sourceText.isEmpty {
                                        Button(action: { viewModel.clear() }) {
                                            Image(systemName: "xmark.circle")
                                                .font(.system(size: 22))
                                        }
                                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                        .accessibilityLabel(L10n.clearText)
                                        .accessibilityHint("Double tap to clear source text")
                                        .offset(x: 8)
                                    }
                                }
                                .layoutPriority(1)

                                if viewModel.sourceText.isEmpty {
                                    Button(action: { pasteFromClipboard() }) {
                                        Label(L10n.paste, systemImage: "doc.on.clipboard")
                                    }
                                    .buttonStyle(.helvetraSecondary)
                                    .offset(y: isSettingsOpen ? 100 : 0)
                                    .accessibilityHint("Double tap to paste text from clipboard")
                                }

                                Spacer(minLength: 0)

                                if showCharacterCounter {
                                    Text("\(viewModel.sourceText.count)/\(perRequestLimit)")
                                        .font(Typography.caption)
                                        .foregroundStyle(Colors.swissRed)
                                        .offset(y: isSettingsOpen ? 100 : 0)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(Spacing.cardPadding)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isSourceFocused = true
                            }

                            // Divider (horizontal on iPhone, vertical on iPad)
                            Rectangle()
                                .fill(Colors.dividerAdaptive)
                                .frame(
                                    width: useSideBySideLayout ? Spacing.dividerHeight : nil,
                                    height: useSideBySideLayout ? nil : Spacing.dividerHeight
                                )
                                .padding(useSideBySideLayout ? .vertical : .horizontal, Spacing.cardPadding)
                                .offset(y: isSettingsOpen ? 100 : 0)

                            // L1B: Output area (same height as L1T)
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                ZStack(alignment: .topTrailing) {
                                    ScrollViewReader { scrollProxy in
                                        ScrollView {
                                            HStack(alignment: .top) {
                                                if viewModel.sourceText.isEmpty {
                                                    Text(L10n.outputPlaceholder)
                                                        .font(dynamicFont(for: ""))
                                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                                        .offset(y: isSettingsOpen ? 100 : 0)
                                                } else if isOverPerRequestLimit {
                                                    // Show upgrade prompt when over per-request limit
                                                    VStack(alignment: .leading, spacing: Spacing.md) {
                                                        Text("Text too long for free plan")
                                                            .font(Typography.bodyMedium)
                                                            .foregroundStyle(Colors.textPrimaryAdaptive)
                                                        Text("Upgrade to Helvetra+ for up to 5,000 characters per translation.")
                                                            .font(Typography.caption)
                                                            .foregroundStyle(Colors.textSecondaryAdaptive)
                                                        Button(action: { isSettingsOpen = true }) {
                                                            Label("Upgrade", systemImage: "arrow.up.circle.fill")
                                                        }
                                                        .buttonStyle(.helvetraPrimary)
                                                    }
                                                } else if viewModel.isTranslating {
                                                    HStack(spacing: Spacing.sm) {
                                                        ProgressView()
                                                        Text(L10n.translating)
                                                            .font(dynamicFont(for: ""))
                                                            .foregroundStyle(Colors.textSecondaryAdaptive)
                                                    }
                                                } else if let error = viewModel.errorMessage {
                                                    Text(error)
                                                        .font(Typography.bodyMedium)
                                                        .foregroundStyle(Colors.swissRed)
                                                } else if !viewModel.translatedText.isEmpty {
                                                    Text(viewModel.translatedText)
                                                        .font(dynamicFont(for: viewModel.translatedText))
                                                        .foregroundStyle(Colors.textPrimaryAdaptive)
                                                        .textSelection(.enabled)
                                                        .padding(.trailing, 28)
                                                }

                                                Spacer()
                                            }

                                            // Invisible anchor for auto-scroll
                                            Color.clear
                                                .frame(height: 1)
                                                .id("outputBottom")
                                        }
                                        .onChange(of: viewModel.translatedText) { _, _ in
                                            scrollProxy.scrollTo("outputBottom", anchor: .bottom)
                                        }
                                    }

                                    // Copy button - fixed position, doesn't scroll
                                    if !viewModel.translatedText.isEmpty && !viewModel.isTranslating {
                                        Button(action: { copyTranslation() }) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 22))
                                        }
                                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                        .accessibilityLabel(L10n.copyTranslation)
                                        .accessibilityHint("Double tap to copy translation to clipboard")
                                        .offset(x: 8)
                                    }
                                }
                                .layoutPriority(1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(Spacing.cardPadding)
                        }

                        // Space for L2 overlay
                        Color.clear.frame(height: useSideBySideLayout ? 60 : l2Height)
                    }
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: Spacing.cardRadius,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: Spacing.cardRadius,
                            style: .continuous
                        )
                        .fill(Colors.surfaceAdaptive)
                        .shadow(
                            color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12),
                            radius: 24,
                            y: -8
                        )
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSettingsOpen {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                isSettingsOpen = false
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                }
                .padding(.bottom, bottomPadding)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: keyboardHeight)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isSettingsOpen)
                .ignoresSafeArea(edges: .bottom)

                // L2: Language switcher (sticky to keyboard) - hidden when settings open
                if !isSettingsOpen {
                VStack {
                    Spacer()
                        .allowsHitTesting(false)

                    VStack(spacing: Spacing.sm) {
                        HStack(spacing: 0) {
                            Button(action: { showSourceLanguagePicker = true }) {
                                HStack(spacing: 4) {
                                    Text(sourceLanguageName)
                                    if isLanguageDetected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Colors.swissRed.opacity(0.8))
                                    }
                                }
                            }
                            .buttonStyle(.glassPill)
                            .accessibilityLabel(isLanguageDetected ? L10n.sourceLanguageDetected(sourceLanguageName) : L10n.sourceLanguageLabel(sourceLanguageName))
                            .accessibilityHint("Double tap to change source language")

                            Spacer()

                            Button(action: { swapLanguages() }) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                            }
                            .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                            .accessibilityLabel(L10n.swapLanguages)
                            .accessibilityHint("Double tap to swap source and target languages")

                            Spacer()

                            Button(action: { showTargetLanguagePicker = true }) {
                                Text(targetLanguageName)
                            }
                            .buttonStyle(.glassPill)
                            .accessibilityLabel(L10n.targetLanguageLabel(targetLanguageName))
                            .accessibilityHint("Double tap to change target language")
                        }
                        .padding(.horizontal, Spacing.sm)

                    }
                    .padding(.vertical, Spacing.sm)
                    .padding(.bottom, Spacing.lg)
                    .frame(maxWidth: useSideBySideLayout ? 400 : .infinity)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: Spacing.cardRadius,
                            bottomLeadingRadius: useSideBySideLayout ? Spacing.cardRadius : 0,
                            bottomTrailingRadius: useSideBySideLayout ? Spacing.cardRadius : 0,
                            topTrailingRadius: Spacing.cardRadius,
                            style: .continuous
                        )
                        .fill(Colors.languageCardAdaptive)
                        .shadow(
                            color: .black.opacity(colorScheme == .dark ? 0.5 : 0.15),
                            radius: 20,
                            y: -6
                        )
                    }
                    .padding(.horizontal, useSideBySideLayout ? 0 : Spacing.screenPadding + Spacing.sm)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, l2BottomPadding)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: keyboardHeight)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Copy confirmation toast
                if showCopyConfirmation {
                    VStack {
                        Spacer()

                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(L10n.copiedToClipboard)
                                .font(Typography.labelMedium)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.md)
                        .background {
                            Capsule()
                                .fill(Colors.surfaceAdaptive)
                                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        }
                        .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 20 : 150)
                    }
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(100)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .sheet(isPresented: $showSourceLanguagePicker) {
            LanguagePickerSheet(
                selectedLanguage: $selectedSourceLanguage,
                selectedFormality: $selectedFormality,
                selectedDialect: $selectedDialect,
                isSourcePicker: true
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTargetLanguagePicker) {
            LanguagePickerSheet(
                selectedLanguage: $selectedTargetLanguage,
                selectedFormality: $selectedFormality,
                selectedDialect: $selectedDialect,
                isSourcePicker: false
            )
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Language Picker Sheet

struct LanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedLanguage: String
    @Binding var selectedFormality: String
    @Binding var selectedDialect: String
    let isSourcePicker: Bool

    @State private var pendingLanguage: String? = nil

    /// Language codes in display order.
    let languageCodes = ["en", "de", "fr", "it", "gsw", "rm"]

    /// Dialect codes in display order.
    let dialectCodes = ["zurich", "bern", "basel", "luzern", "stgallen", "wallis"]

    private let languagesWithDialect: Set<String> = ["gsw"]
    private let languagesWithFormality: Set<String> = ["de", "fr", "it", "gsw"]

    private var showingSettings: Bool { pendingLanguage != nil }
    private var needsDialect: Bool { languagesWithDialect.contains(pendingLanguage ?? "") }
    private var needsFormality: Bool { languagesWithFormality.contains(pendingLanguage ?? "") }

    var body: some View {
        NavigationStack {
            Group {
                if let pending = pendingLanguage {
                    settingsView(for: pending)
                } else {
                    languageListView
                }
            }
            .navigationTitle(showingSettings ? L10n.settings : L10n.selectLanguage)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if showingSettings {
                        Button(L10n.back) {
                            pendingLanguage = nil
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.done) {
                        if let pending = pendingLanguage {
                            selectedLanguage = pending
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    private var languageListView: some View {
        List {
            if isSourcePicker {
                Button(action: {
                    selectedLanguage = "auto"
                    dismiss()
                }) {
                    HStack {
                        Text(L10n.languageName("auto"))
                            .font(Typography.bodyLarge)
                            .foregroundStyle(Colors.textPrimaryAdaptive)
                        Spacer()
                        if selectedLanguage == "auto" {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Colors.swissRed)
                        }
                    }
                }
            }

            ForEach(languageCodes, id: \.self) { code in
                Button(action: { selectLanguage(code) }) {
                    HStack {
                        Text(L10n.languageName(code))
                            .font(Typography.bodyLarge)
                            .foregroundStyle(Colors.textPrimaryAdaptive)
                        Spacer()
                        if code == selectedLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Colors.swissRed)
                        }
                        // Show chevron for target picker languages with settings (formality or dialect)
                        if !isSourcePicker && (languagesWithFormality.contains(code) || languagesWithDialect.contains(code)) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Colors.textSecondaryAdaptive)
                        }
                    }
                }
            }
        }
    }

    private func settingsView(for languageCode: String) -> some View {
        List {
            // Formality section (for DE, FR, IT, GSW)
            if languagesWithFormality.contains(languageCode) {
                Section {
                    Button(action: { selectedFormality = "formal" }) {
                        HStack {
                            Text(L10n.formalityFormal)
                                .font(Typography.bodyLarge)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                            Spacer()
                            if selectedFormality == "formal" {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Colors.swissRed)
                            }
                        }
                    }
                    Button(action: { selectedFormality = "informal" }) {
                        HStack {
                            Text(L10n.formalityInformal)
                                .font(Typography.bodyLarge)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                            Spacer()
                            if selectedFormality == "informal" {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Colors.swissRed)
                            }
                        }
                    }
                } header: {
                    Text(L10n.formalityTitle)
                }
            }

            // Dialect section (for GSW only)
            if languagesWithDialect.contains(languageCode) {
                Section {
                    ForEach(dialectCodes, id: \.self) { code in
                        Button(action: { selectedDialect = code }) {
                            HStack {
                                Text(L10n.dialectName(code))
                                    .font(Typography.bodyLarge)
                                    .foregroundStyle(Colors.textPrimaryAdaptive)
                                Spacer()
                                if code == selectedDialect {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Colors.swissRed)
                                }
                            }
                        }
                    }
                } header: {
                    Text(L10n.dialectTitle)
                } footer: {
                    Text(L10n.dialectFooter)
                }
            }
        }
    }

    private func selectLanguage(_ code: String) {
        HapticService.selection()
        // Show settings screen only for target picker with formality or dialect options
        if !isSourcePicker && (languagesWithFormality.contains(code) || languagesWithDialect.contains(code)) {
            pendingLanguage = code
        } else {
            selectedLanguage = code
            dismiss()
        }
    }
}

// MARK: - Subscription View

/// Screen for upgrading subscription plans.
struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storeService = StoreService.shared
    @State private var isYearly: Bool = true
    @State private var isPurchasing: Bool = false
    @State private var purchaseError: String?
    @State private var showSuccess: Bool = false

    private var plusProduct: Product? {
        storeService.products.first { $0.id.contains(isYearly ? "yearly" : "monthly") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Current tier badge
                    HStack {
                        Text(L10n.currentPlan(storeService.currentTier.rawValue))
                            .font(Typography.labelMedium)
                            .foregroundStyle(Colors.textSecondaryAdaptive)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background {
                                Capsule().fill(.thinMaterial)
                            }
                    }
                    .padding(.top, Spacing.md)

                    // Billing toggle
                    HStack(spacing: Spacing.sm) {
                        Text(L10n.monthly)
                            .font(Typography.labelMedium)
                            .foregroundStyle(isYearly ? Colors.textSecondaryAdaptive : Colors.swissRed)

                        Toggle("", isOn: $isYearly)
                            .labelsHidden()
                            .tint(Colors.swissRed)

                        Text(L10n.yearly)
                            .font(Typography.labelMedium)
                            .foregroundStyle(isYearly ? Colors.swissRed : Colors.textSecondaryAdaptive)

                        if isYearly {
                            Text(L10n.save20)
                                .font(Typography.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(Colors.swissRed) }
                        }
                    }

                    // Helvetra+ plan
                    PlanCard(
                        name: "Helvetra+",
                        price: plusProduct?.displayPrice ?? (isYearly ? "CHF 4.99/month" : "CHF 7.99/month"),
                        billingNote: isYearly ? L10n.billedYearly : nil,
                        features: [
                            L10n.featureCharacters,
                            L10n.featurePriority,
                            L10n.featureSupport
                        ],
                        isCurrentPlan: storeService.currentTier == .plus,
                        isLoading: isPurchasing,
                        onPurchase: { await purchasePlus() }
                    )

                    // Restore purchases
                    Button(action: { Task { await restorePurchases() } }) {
                        Text(L10n.restorePurchases)
                            .font(Typography.labelMedium)
                            .foregroundStyle(Colors.textSecondaryAdaptive)
                    }
                    .padding(.top, Spacing.sm)

                    // Error message
                    if let error = purchaseError {
                        Text(error)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.swissRed)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
            .navigationTitle(L10n.subscriptionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.done) { dismiss() }
                }
            }
            .alert(L10n.purchaseSuccessTitle, isPresented: $showSuccess) {
                Button(L10n.ok) { dismiss() }
            } message: {
                Text(L10n.purchaseSuccessMessage)
            }
        }
    }

    private func purchasePlus() async {
        guard let product = plusProduct else { return }
        await purchase(product)
    }

    private func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        do {
            try await storeService.purchase(product)
            HapticService.success()
            showSuccess = true
        } catch {
            HapticService.impact(.heavy)
            purchaseError = error.localizedDescription
        }
        isPurchasing = false
    }

    private func restorePurchases() async {
        isPurchasing = true
        await storeService.restorePurchases()
        isPurchasing = false
        if storeService.currentTier != .free {
            HapticService.success()
            showSuccess = true
        }
    }
}

/// Card showing a subscription plan.
struct PlanCard: View {
    let name: String
    let price: String
    var billingNote: String? = nil
    let features: [String]
    var isCurrentPlan: Bool = false
    var isLoading: Bool = false
    let onPurchase: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text(name)
                    .font(Typography.headingMedium)
                    .foregroundStyle(Colors.textPrimaryAdaptive)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(price)
                        .font(Typography.labelLarge)
                        .foregroundStyle(Colors.swissRed)

                    if let note = billingNote {
                        Text(note)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondaryAdaptive)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Colors.swissRed)
                            .font(.system(size: 14))
                        Text(feature)
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Colors.textPrimaryAdaptive)
                    }
                }
            }

            if isCurrentPlan {
                Text(L10n.currentPlanLabel)
                    .font(Typography.labelMedium)
                    .foregroundStyle(Colors.textSecondaryAdaptive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: Spacing.buttonRadius, style: .continuous)
                            .fill(Colors.textSecondaryAdaptive.opacity(0.1))
                    }
            } else {
                Button(action: { Task { await onPurchase() } }) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(L10n.subscribe)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.helvetraPrimary)
                .disabled(isLoading)
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
                .fill(.thinMaterial)
        }
    }
}

// MARK: - Settings View

/// Settings screen with account, preferences, and about sections.
struct SettingsView: View {
    @Binding var hapticsEnabled: Bool
    @ObservedObject private var storeService = StoreService.shared
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var usageService = UsageService.shared
    @State private var showSubscription: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showEmailCopied: Bool = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                Text(L10n.settings)
                    .font(Typography.headingLarge)
                    .foregroundStyle(Colors.textPrimaryAdaptive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.md)

                // Account section
                SettingsSection(title: L10n.accountTitle) {
                    if authService.isAuthenticated, let user = authService.currentUser {
                        // Signed in state
                        SettingsRow(
                            icon: "person.circle.fill",
                            title: user.email,
                            subtitle: L10n.planName(storeService.currentTier.rawValue)
                        )
                    } else {
                        // Signed out state
                        SettingsRow(
                            icon: "person.circle",
                            title: L10n.planName(storeService.currentTier.rawValue),
                            subtitle: nil
                        )
                    }

                    // Usage bar (shown for all users)
                    UsageBarView(usageService: usageService)

                    if storeService.currentTier == .free {
                        Button(action: { showSubscription = true }) {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(Colors.swissRed)
                                Text(L10n.upgrade)
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Colors.swissRed)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    }

                    if authService.isAuthenticated {
                        Button(action: {
                            Task { await authService.signOut() }
                        }) {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                                Text(L10n.signOut)
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Colors.textPrimaryAdaptive)
                                Spacer()
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    }
                }

                // Preferences section
                SettingsSection(title: L10n.preferencesTitle) {
                    Toggle(isOn: $hapticsEnabled) {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: "waveform")
                                .font(.system(size: 18))
                                .foregroundStyle(Colors.textSecondaryAdaptive)
                                .frame(width: 24)
                            Text(L10n.hapticFeedback)
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                        }
                    }
                    .tint(Colors.swissRed)
                }

                // About section
                SettingsSection(title: L10n.aboutTitle) {
                    SettingsRow(
                        icon: "info.circle",
                        title: L10n.version,
                        value: "\(appVersion) (\(buildNumber))"
                    )

                    Link(destination: URL(string: "https://helvetra.ch/privacy")!) {
                        SettingsRow(
                            icon: "hand.raised",
                            title: L10n.privacyPolicy,
                            showChevron: true
                        )
                    }

                    Link(destination: URL(string: "https://helvetra.ch/terms")!) {
                        SettingsRow(
                            icon: "doc.text",
                            title: L10n.termsOfService,
                            showChevron: true
                        )
                    }

                    Button(action: openFeedbackEmail) {
                        SettingsRow(
                            icon: "envelope",
                            title: L10n.sendFeedback,
                            showChevron: true
                        )
                    }
                }

                // Danger zone (only for authenticated users)
                if authService.isAuthenticated {
                    SettingsSection(title: L10n.dangerZoneTitle) {
                        Button(action: { showDeleteConfirmation = true }) {
                            HStack {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                Text(L10n.deleteAccount)
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    }
                }

                // Footer
                VStack(spacing: Spacing.xs) {
                    Text(L10n.madeInSwitzerland)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondaryAdaptive)
                }
                .padding(.top, Spacing.md)
            }
            .padding(.horizontal, Spacing.screenPadding)
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionView()
        }
        .confirmationDialog(
            L10n.deleteAccountTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.deleteAccountConfirm, role: .destructive) {
                Task {
                    do {
                        try await authService.deleteAccount()
                        HapticService.success()
                    } catch {
                        authService.errorMessage = error.localizedDescription
                    }
                }
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.deleteAccountMessage)
        }
        .onAppear {
            Task { await usageService.fetchUsage() }
        }
        .alert(L10n.sendFeedback, isPresented: $showEmailCopied) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(L10n.emailCopied)
        }
    }

    /// Opens mail app for feedback, or copies email if unavailable.
    private func openFeedbackEmail() {
        let email = "gruezi@helvetra.ch"
        guard let url = URL(string: "mailto:\(email)?subject=Helvetra%20App%20Feedback") else { return }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            UIPasteboard.general.string = email
            showEmailCopied = true
            HapticService.success()
        }
    }
}

// MARK: - Usage Bar View

/// Progress bar showing character usage against limit.
struct UsageBarView: View {
    @ObservedObject var usageService: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Colors.textSecondaryAdaptive.opacity(0.2))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor)
                        .frame(width: geometry.size.width * usageService.usagePercentage)
                }
            }
            .frame(height: 8)

            // Labels
            HStack {
                Text(usageService.usageText)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondaryAdaptive)

                Spacer()

                Text(usageService.periodText)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondaryAdaptive)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var progressColor: Color {
        if usageService.usagePercentage >= 0.9 {
            return Colors.swissRed
        } else if usageService.usagePercentage >= 0.7 {
            return .orange
        }
        return Colors.swissRed.opacity(0.7)
    }
}

/// Settings section container with title and glass background.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(Typography.labelSmall)
                .foregroundStyle(Colors.textSecondaryAdaptive)

            VStack(spacing: 0) {
                content
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
                    .fill(.thinMaterial)
            }
        }
    }
}

/// Single row in settings section.
struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var showChevron: Bool = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Colors.textSecondaryAdaptive)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Colors.textPrimaryAdaptive)

                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondaryAdaptive)
                }
            }

            Spacer()

            if let value {
                Text(value)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Colors.textSecondaryAdaptive)
            }

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Colors.textSecondaryAdaptive)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Helvetra Icon

/// The Helvetra "H" brand icon.
struct HelvetraIcon: View {
    let size: CGFloat
    var color: Color = Colors.swissRed

    var body: some View {
        HelvetraIconShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Shape for the Helvetra H icon (from brand SVG).
struct HelvetraIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Scale factors (original viewBox: 301x301)
        let sx = w / 301
        let sy = h / 301

        // Top part of H
        path.move(to: CGPoint(x: 120.879 * sx, y: 33 * sy))
        path.addLine(to: CGPoint(x: 120.879 * sx, y: 92.716 * sy))
        path.addLine(to: CGPoint(x: 181.181 * sx, y: 92.716 * sy))
        path.addLine(to: CGPoint(x: 181.181 * sx, y: 33 * sy))
        path.addLine(to: CGPoint(x: 240.825 * sx, y: 33 * sy))
        path.addLine(to: CGPoint(x: 240.825 * sx, y: 121.182 * sy))
        path.addLine(to: CGPoint(x: 61.234 * sx, y: 121.182 * sy))
        path.addLine(to: CGPoint(x: 61.234 * sx, y: 33 * sy))
        path.closeSubpath()

        // Bottom part of H
        path.move(to: CGPoint(x: 181.181 * sx, y: 269 * sy))
        path.addLine(to: CGPoint(x: 181.181 * sx, y: 209.284 * sy))
        path.addLine(to: CGPoint(x: 120.879 * sx, y: 209.284 * sy))
        path.addLine(to: CGPoint(x: 120.879 * sx, y: 269 * sy))
        path.addLine(to: CGPoint(x: 61.234 * sx, y: 269 * sy))
        path.addLine(to: CGPoint(x: 61.234 * sx, y: 180.818 * sy))
        path.addLine(to: CGPoint(x: 240.825 * sx, y: 180.818 * sy))
        path.addLine(to: CGPoint(x: 240.825 * sx, y: 269 * sy))
        path.closeSubpath()

        return path
    }
}

// MARK: - Translation ViewModel

/// Manages translation state with debounced auto-translate.
@MainActor
class TranslationViewModel: ObservableObject {

    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var detectedLanguage: String?

    var sourceLang: String = "auto"
    var targetLang: String = "gsw"
    var formality: String = "informal"
    var dialect: String = "zurich"

    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: UInt64 = 500_000_000 // 500ms

    func sourceTextChanged() {
        debounceTask?.cancel()
        errorMessage = nil

        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            detectedLanguage = nil
            return
        }

        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceDelay)
                await performTranslation()
            } catch {
                // Cancelled
            }
        }
    }

    func clear() {
        debounceTask?.cancel()
        sourceText = ""
        translatedText = ""
        errorMessage = nil
        detectedLanguage = nil
        isTranslating = false
    }

    /// Re-translate with current settings (called when language changes).
    func retranslate() {
        debounceTask?.cancel()

        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Short debounce to handle rapid language switching
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                await performTranslation()
            } catch {
                // Cancelled
            }
        }
    }

    private func performTranslation() async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Skip translation if over per-request limit (UI shows upgrade prompt)
        let perRequestLimit = StoreService.shared.currentTier.perRequestLimit
        guard text.count <= perRequestLimit else { return }

        isTranslating = true
        errorMessage = nil

        // Client-side language detection (like webapp's franc)
        var effectiveSourceLang = sourceLang
        if sourceLang == "auto" {
            if let detected = LanguageDetectionService.detectLanguage(text) {
                effectiveSourceLang = detected
                detectedLanguage = detected
            }
        }

        do {
            let result = try await TranslationService.shared.translate(
                text: text,
                sourceLang: effectiveSourceLang,
                targetLang: targetLang,
                formality: formality,
                dialect: dialect
            )
            translatedText = result.translation
            // Use client-side detection if available, fallback to backend detection
            if detectedLanguage == nil {
                detectedLanguage = result.detectedSourceLang
            }
            HapticService.success()
            // Record usage locally for anonymous users, then refresh counter
            UsageService.shared.recordLocalUsage(text.count)
            await UsageService.shared.fetchUsage()
        } catch let error as TranslationError {
            errorMessage = error.errorDescription
            translatedText = ""
        } catch {
            errorMessage = "Translation failed"
            translatedText = ""
        }

        isTranslating = false
    }
}

// MARK: - Translation Service

/// Handles translation API requests.
actor TranslationService {

    static let shared = TranslationService()

    private let baseURL = "https://helvetra.ch/api/v1"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func translate(
        text: String,
        sourceLang: String,
        targetLang: String,
        formality: String = "auto",
        dialect: String? = nil
    ) async throws -> TranslationResult {
        let request = TranslateAPIRequest(
            text: text,
            source_lang: sourceLang,
            target_lang: targetLang,
            formality: formality,
            dialect: dialect
        )

        let url = URL(string: "\(baseURL)/translate")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("helvetra-ios", forHTTPHeaderField: "X-Client")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        // Include auth token for authenticated users (enables usage tracking)
        if let accessToken = await AuthService.shared.getAccessToken() {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        // Include StoreKit subscription JWS for anonymous users with in-app purchases
        // This allows the backend to verify the subscription without requiring login
        if let jwsString = await StoreService.shared.getCurrentEntitlementJWS() {
            urlRequest.setValue(jwsString, forHTTPHeaderField: "X-StoreKit-JWS")
            print("[Translation] Including StoreKit JWS for subscription verification")
        }

        // Debug: print request body
        if let body = urlRequest.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            print("[Translation] Request: \(bodyString)")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.networkError
        }

        // Debug: print response
        print("[Translation] Status: \(httpResponse.statusCode)")
        if let responseString = String(data: data, encoding: .utf8) {
            print("[Translation] Response: \(responseString)")
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(TranslateAPIResponse.self, from: data),
               let error = errorResponse.error {
                throw TranslationError.apiError(
                    code: error["code"] ?? "UNKNOWN",
                    message: error["message"] ?? "Unknown error"
                )
            }
            throw TranslationError.httpError(statusCode: httpResponse.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(TranslateAPIResponse.self, from: data)

        guard apiResponse.success, let responseData = apiResponse.data else {
            throw TranslationError.invalidResponse
        }

        return TranslationResult(
            translation: responseData["translation"]?.stringValue ?? "",
            sourceLang: responseData["source_lang"]?.stringValue ?? sourceLang,
            targetLang: responseData["target_lang"]?.stringValue ?? targetLang,
            detectedSourceLang: responseData["detected_source_lang"]?.stringValue
        )
    }
}

// MARK: - API Models

private struct TranslateAPIRequest: Encodable {
    let text: String
    let source_lang: String
    let target_lang: String
    let formality: String
    let dialect: String?
}

private struct TranslateAPIResponse: Decodable {
    let success: Bool
    let data: [String: AnyCodableValue]?
    let error: [String: String]?
}

private struct AnyCodableValue: Decodable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else {
            stringValue = nil
        }
    }
}

struct TranslationResult {
    let translation: String
    let sourceLang: String
    let targetLang: String
    let detectedSourceLang: String?
}

enum TranslationError: LocalizedError {
    case networkError
    case httpError(statusCode: Int)
    case invalidResponse
    case apiError(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .networkError:
            return L10n.errorNetwork
        case .httpError(let code):
            return L10n.errorServer(code)
        case .invalidResponse:
            return L10n.errorInvalidResponse
        case .apiError(_, let message):
            return message
        }
    }
}

#Preview("Light") {
    ContentView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
