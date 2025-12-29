import AuthenticationServices
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

        var characterLimit: Int {
            switch self {
            case .free: return 1_000
            case .plus: return 20_000
            }
        }

        var productId: String? {
            switch self {
            case .free: return nil
            case .plus: return "ch.helvetra.plus.monthly"
            }
        }
    }

    static let shared = StoreService()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var currentTier: SubscriptionTier = .free
    @Published private(set) var isLoading: Bool = false

    private var updateListenerTask: Task<Void, Error>?

    private let productIDs: Set<String> = [
        "ch.helvetra.plus.monthly",
        "ch.helvetra.plus.yearly"
    ]

    private init() {
        updateListenerTask = listenForTransactions()
        Task { await loadProducts() }
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
            await updatePurchasedProducts()
            await transaction.finish()

        case .pending:
            break

        case .userCancelled:
            break

        @unknown default:
            break
        }
    }

    /// Restore previous purchases.
    func restorePurchases() async {
        await updatePurchasedProducts()
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

    /// Listen for transaction updates.
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.updatePurchasedProducts()
                    await transaction.finish()
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

    /// Update current tier based on purchases.
    private func updateCurrentTier() {
        if purchasedProductIDs.contains(where: { $0.contains("plus") }) {
            currentTier = .plus
        } else {
            currentTier = .free
        }
    }
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

    // MARK: - Constants

    private let languageNames: [String: String] = [
        "auto": "Auto-detect",
        "en": "English",
        "de": "German",
        "fr": "French",
        "it": "Italian",
        "gsw": "Swiss German",
        "rm": "Romansh"
    ]

    /// Space above L1 when keyboard hidden.
    private let settingsAreaHeight: CGFloat = 16

    /// Height of L2 language switcher.
    private let l2Height: CGFloat = 100

    /// Extra bleed below keyboard to cover rounded corners.
    private let bottomBleed: CGFloat = 50

    /// Character limit based on current subscription tier.
    private var characterLimit: Int {
        StoreService.shared.currentTier.characterLimit
    }

    /// Show counter when usage exceeds this percentage.
    private let counterThreshold: Double = 0.8

    // MARK: - Computed Properties

    /// Whether to show the character counter (approaching limit).
    private var showCharacterCounter: Bool {
        Double(viewModel.sourceText.count) / Double(characterLimit) >= counterThreshold
    }

    private var sourceLanguageName: String {
        languageNames[selectedSourceLanguage] ?? selectedSourceLanguage
    }

    private var targetLanguageName: String {
        languageNames[selectedTargetLanguage] ?? selectedTargetLanguage
    }

    private var isKeyboardVisible: Bool { keyboardHeight > 0 }

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

    /// Share both source and translation via system share sheet.
    private func shareTranslation() {
        let shareText = """
        \(viewModel.sourceText)

        ↓

        \(viewModel.translatedText)

        — Translated with Helvetra
        """

        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
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
                        .accessibilityLabel(isSettingsOpen ? "Close settings" : "Open settings")
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
                    Color.clear
                        .frame(height: isSettingsOpen ? geometry.size.height - 120 : (isKeyboardVisible ? 0 : topSpacing))

                    // Card content
                    VStack(spacing: 0) {
                        // Translation areas layout (vertical on iPhone, horizontal on iPad)
                        let layout = useSideBySideLayout
                            ? AnyLayout(HStackLayout(spacing: 0))
                            : AnyLayout(VStackLayout(spacing: 0))

                        layout {
                            // L1T: Input area
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack(alignment: .top) {
                                    TextField("Type or paste here to translate", text: $viewModel.sourceText, axis: .vertical)
                                        .font(Typography.translationText)
                                        .foregroundStyle(Colors.textPrimaryAdaptive)
                                        .focused($isSourceFocused)
                                        .lineLimit(1...10)
                                        .onChange(of: viewModel.sourceText) { _, _ in
                                            syncViewModelSettings()
                                            viewModel.sourceTextChanged()
                                        }
                                        .onChange(of: isSourceFocused) { _, focused in
                                            if focused && isSettingsOpen {
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                                    isSettingsOpen = false
                                                }
                                            }
                                        }

                                    if !viewModel.sourceText.isEmpty {
                                        Button(action: { viewModel.clear() }) {
                                            Image(systemName: "xmark.circle")
                                                .font(.system(size: 22))
                                        }
                                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                        .accessibilityLabel("Clear text")
                                        .accessibilityHint("Double tap to clear source text")
                                    }
                                }

                                if viewModel.sourceText.isEmpty {
                                    Button(action: { pasteFromClipboard() }) {
                                        Label("Paste", systemImage: "doc.on.clipboard")
                                    }
                                    .buttonStyle(.helvetraSecondary)
                                    .offset(y: isSettingsOpen ? 100 : 0)
                                    .accessibilityHint("Double tap to paste text from clipboard")
                                }

                                Spacer()

                                if showCharacterCounter {
                                    Text("\(viewModel.sourceText.count) / \(characterLimit)")
                                        .font(Typography.caption)
                                        .foregroundStyle(viewModel.sourceText.count > characterLimit ? Colors.swissRed : Colors.textSecondaryAdaptive)
                                        .offset(y: isSettingsOpen ? 100 : 0)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(Spacing.cardPadding)

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
                                HStack(alignment: .top) {
                                    if viewModel.sourceText.isEmpty {
                                        Text("Translation appears here")
                                            .font(Typography.translationText)
                                            .foregroundStyle(Colors.textSecondaryAdaptive)
                                            .offset(y: isSettingsOpen ? 100 : 0)
                                    } else if viewModel.isTranslating {
                                        HStack(spacing: Spacing.sm) {
                                            ProgressView()
                                            Text("Translating...")
                                                .font(Typography.translationText)
                                                .foregroundStyle(Colors.textSecondaryAdaptive)
                                        }
                                    } else if let error = viewModel.errorMessage {
                                        Text(error)
                                            .font(Typography.bodyMedium)
                                            .foregroundStyle(Colors.swissRed)
                                    } else if !viewModel.translatedText.isEmpty {
                                        Text(viewModel.translatedText)
                                            .font(Typography.translationText)
                                            .foregroundStyle(Colors.textPrimaryAdaptive)
                                            .textSelection(.enabled)
                                    }

                                    Spacer()
                                }

                                Spacer()

                                if !viewModel.translatedText.isEmpty && !viewModel.isTranslating {
                                    HStack(spacing: Spacing.sm) {
                                        Spacer()

                                        Button(action: { copyTranslation() }) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 22))
                                        }
                                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                        .accessibilityLabel("Copy translation")
                                        .accessibilityHint("Double tap to copy translation to clipboard")

                                        Button(action: { shareTranslation() }) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 22))
                                        }
                                        .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                                        .foregroundStyle(Colors.textSecondaryAdaptive)
                                        .accessibilityLabel("Share translation")
                                        .accessibilityHint("Double tap to share translation")
                                    }
                                    .padding(.bottom, isKeyboardVisible ? 10 : -20)
                                }
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
                                Text(sourceLanguageName)
                            }
                            .buttonStyle(.glassPill)
                            .accessibilityLabel("Source language: \(sourceLanguageName)")
                            .accessibilityHint("Double tap to change source language")

                            Spacer()

                            Button(action: { swapLanguages() }) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                            }
                            .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                            .accessibilityLabel("Swap languages")
                            .accessibilityHint("Double tap to swap source and target languages")

                            Spacer()

                            Button(action: { showTargetLanguagePicker = true }) {
                                Text(targetLanguageName)
                            }
                            .buttonStyle(.glassPill)
                            .accessibilityLabel("Target language: \(targetLanguageName)")
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
                            Text("Copied to clipboard")
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

    let languages = [
        ("English", "en"),
        ("German", "de"),
        ("French", "fr"),
        ("Italian", "it"),
        ("Swiss German", "gsw"),
        ("Romansh", "rm"),
    ]

    /// Dialects with display name and API code.
    let dialects: [(String, String)] = [
        ("Zürich", "zurich"),
        ("Bern", "bern"),
        ("Basel", "basel"),
        ("Luzern", "luzern"),
        ("St. Gallen", "stgallen"),
        ("Wallis", "wallis"),
    ]

    private let languagesWithDialect: Set<String> = ["gsw"]

    private var showingSettings: Bool { pendingLanguage != nil }
    private var needsDialect: Bool { languagesWithDialect.contains(pendingLanguage ?? "") }

    var body: some View {
        NavigationStack {
            Group {
                if let pending = pendingLanguage {
                    settingsView(for: pending)
                } else {
                    languageListView
                }
            }
            .navigationTitle(showingSettings ? "Settings" : "Select Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if showingSettings {
                        Button("Back") {
                            pendingLanguage = nil
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
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
                        Text("Auto-detect")
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

            ForEach(languages, id: \.1) { language in
                Button(action: { selectLanguage(language.1) }) {
                    HStack {
                        Text(language.0)
                            .font(Typography.bodyLarge)
                            .foregroundStyle(Colors.textPrimaryAdaptive)
                        Spacer()
                        if language.1 == selectedLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Colors.swissRed)
                        }
                    }
                }
            }
        }
    }

    private func settingsView(for languageCode: String) -> some View {
        List {
            Section {
                ForEach(dialects, id: \.1) { dialect in
                    Button(action: { selectedDialect = dialect.1 }) {
                        HStack {
                            Text(dialect.0)
                                .font(Typography.bodyLarge)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                            Spacer()
                            if dialect.1 == selectedDialect {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Colors.swissRed)
                            }
                        }
                    }
                }
            } header: {
                Text("Dialect")
            } footer: {
                Text("Select the regional dialect for your Swiss German translation.")
            }
        }
    }

    private func selectLanguage(_ code: String) {
        HapticService.selection()
        if languagesWithDialect.contains(code) {
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
                        Text("Current: \(storeService.currentTier.rawValue)")
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
                        Text("Monthly")
                            .font(Typography.labelMedium)
                            .foregroundStyle(isYearly ? Colors.textSecondaryAdaptive : Colors.swissRed)

                        Toggle("", isOn: $isYearly)
                            .labelsHidden()
                            .tint(Colors.swissRed)

                        Text("Yearly")
                            .font(Typography.labelMedium)
                            .foregroundStyle(isYearly ? Colors.swissRed : Colors.textSecondaryAdaptive)

                        if isYearly {
                            Text("Save 20%")
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
                        billingNote: isYearly ? "billed yearly" : nil,
                        features: [
                            "20,000 characters per translation",
                            "All dialects included",
                            "Priority support"
                        ],
                        isCurrentPlan: storeService.currentTier == .plus,
                        isLoading: isPurchasing,
                        onPurchase: { await purchasePlus() }
                    )

                    // Restore purchases
                    Button(action: { Task { await restorePurchases() } }) {
                        Text("Restore Purchases")
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
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Purchase Successful", isPresented: $showSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you for upgrading! Your new plan is now active.")
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
                Text("Current Plan")
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
                        Text("Subscribe")
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
    @State private var showSubscription: Bool = false
    @State private var showDeleteConfirmation: Bool = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var tierDescription: String {
        let limit = storeService.currentTier.characterLimit
        let formatted = limit >= 1000 ? "\(limit / 1000)k" : "\(limit)"
        return "\(formatted) characters per translation"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                Text("Settings")
                    .font(Typography.headingLarge)
                    .foregroundStyle(Colors.textPrimaryAdaptive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.md)

                // Account section
                SettingsSection(title: "Account") {
                    if authService.isAuthenticated, let user = authService.currentUser {
                        // Signed in state
                        SettingsRow(
                            icon: "person.circle.fill",
                            title: user.email,
                            subtitle: "\(storeService.currentTier.rawValue) Plan"
                        )

                        if storeService.currentTier == .free {
                            Button(action: { showSubscription = true }) {
                                HStack {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(Colors.swissRed)
                                    Text("Upgrade to Helvetra+")
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

                        Button(action: {
                            Task { await authService.signOut() }
                        }) {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .foregroundStyle(Colors.textSecondaryAdaptive)
                                Text("Sign Out")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Colors.textPrimaryAdaptive)
                                Spacer()
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    } else {
                        // Signed out state
                        SettingsRow(
                            icon: "person.circle",
                            title: "\(storeService.currentTier.rawValue) Plan",
                            subtitle: tierDescription
                        )

                        SignInWithAppleButton(.signIn, onRequest: { request in
                            request.requestedScopes = [.email, .fullName]
                        }, onCompletion: { _ in })
                        .frame(height: 50)
                        .cornerRadius(Spacing.buttonRadius)
                        .overlay {
                            // Custom tap handler since SwiftUI's completion doesn't work well
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        do {
                                            try await authService.signInWithApple()
                                            HapticService.success()
                                        } catch {
                                            authService.errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                        }
                        .disabled(authService.isLoading)
                        .opacity(authService.isLoading ? 0.6 : 1.0)

                        if let error = authService.errorMessage {
                            Text(error)
                                .font(Typography.caption)
                                .foregroundStyle(.red)
                                .padding(.top, Spacing.xs)
                        }
                    }
                }

                // Preferences section
                SettingsSection(title: "Preferences") {
                    Toggle(isOn: $hapticsEnabled) {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: "waveform")
                                .font(.system(size: 18))
                                .foregroundStyle(Colors.textSecondaryAdaptive)
                                .frame(width: 24)
                            Text("Haptic feedback")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Colors.textPrimaryAdaptive)
                        }
                    }
                    .tint(Colors.swissRed)
                }

                // About section
                SettingsSection(title: "About") {
                    SettingsRow(
                        icon: "info.circle",
                        title: "Version",
                        value: "\(appVersion) (\(buildNumber))"
                    )

                    Link(destination: URL(string: "https://helvetra.ch/privacy")!) {
                        SettingsRow(
                            icon: "hand.raised",
                            title: "Privacy Policy",
                            showChevron: true
                        )
                    }

                    Link(destination: URL(string: "https://helvetra.ch/terms")!) {
                        SettingsRow(
                            icon: "doc.text",
                            title: "Terms of Service",
                            showChevron: true
                        )
                    }
                }

                // Danger zone (only for authenticated users)
                if authService.isAuthenticated {
                    SettingsSection(title: "Danger Zone") {
                        Button(action: { showDeleteConfirmation = true }) {
                            HStack {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                Text("Delete Account")
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
                    Text("Made with ❤️ in Switzerland")
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
            "Delete Account",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task {
                    do {
                        try await authService.deleteAccount()
                        HapticService.success()
                    } catch {
                        authService.errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your account and all associated data. This action cannot be undone.")
        }
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

    private func performTranslation() async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isTranslating = true
        errorMessage = nil

        do {
            let result = try await TranslationService.shared.translate(
                text: text,
                sourceLang: sourceLang,
                targetLang: targetLang,
                formality: formality,
                dialect: dialect
            )
            translatedText = result.translation
            detectedLanguage = result.detectedSourceLang
            HapticService.success()
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
        urlRequest.httpBody = try JSONEncoder().encode(request)

        // Include auth token for authenticated users (enables usage tracking)
        if let accessToken = await AuthService.shared.getAccessToken() {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.networkError
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
            return "Network connection failed"
        case .httpError(let code):
            return "Server error (\(code))"
        case .invalidResponse:
            return "Invalid response from server"
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
