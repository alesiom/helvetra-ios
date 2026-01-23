import Combine
import Foundation

/// Tracks character usage against subscription limits.
@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var charactersUsed: Int = 0
    @Published private(set) var charactersLimit: Int = 20_000
    @Published private(set) var charactersRemaining: Int = 20_000
    @Published private(set) var periodType: String = "monthly"
    @Published private(set) var resetAt: Date?
    @Published private(set) var isLoading: Bool = false

    private let baseURL = "https://helvetra.ch/api/v1"
    private let session: URLSession

    // Local storage keys for anonymous iOS user tracking
    private let localUsageKey = "helvetra.local.charactersUsed"
    private let localPeriodStartKey = "helvetra.local.periodStart"
    // Separate keys for Plus subscribers (so upgrading starts fresh)
    private let localPlusUsageKey = "helvetra.local.plus.charactersUsed"
    private let localPlusPeriodStartKey = "helvetra.local.plus.periodStart"

    /// Usage as a percentage (0.0 to 1.0).
    var usagePercentage: Double {
        guard charactersLimit > 0 else { return 0 }
        return min(1.0, Double(charactersUsed) / Double(charactersLimit))
    }

    /// Formatted usage string (e.g., "5.2k / 20k").
    var usageText: String {
        "\(formatNumber(charactersUsed)) / \(formatNumber(charactersLimit))"
    }

    /// Period description showing reset date (e.g., "Resets Feb 15").
    var periodText: String {
        guard let resetDate = resetAt else {
            return periodType == "weekly"
                ? NSLocalizedString("usage.period.weekly", comment: "")
                : NSLocalizedString("usage.period.monthly", comment: "")
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let dateString = formatter.string(from: resetDate)
        return String(format: NSLocalizedString("usage.period.date", comment: ""), dateString)
    }

    private var storeServiceObserver: AnyCancellable?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)

        // Listen for auth changes to refresh usage
        NotificationCenter.default.addObserver(
            forName: .authStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.fetchUsage() }
        }

        // Listen for StoreKit tier changes to refresh usage (skip initial value)
        storeServiceObserver = StoreService.shared.$currentTier
            .dropFirst()  // Prevent unnecessary fetch on init
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.fetchUsage() }
            }
    }

    /// Fetch current usage, prioritizing local StoreKit entitlements.
    func fetchUsage() async {
        isLoading = true
        defer { isLoading = false }

        // First, check if user has an active StoreKit subscription
        // This takes priority over backend - Apple already verified the purchase
        let storeKitTier = StoreService.shared.currentTier
        print("[Usage] StoreKit tier: \(storeKitTier.rawValue)")

        if storeKitTier == .plus {
            // User has active StoreKit subscription - trust it
            applyStoreKitSubscription()
            print("[Usage] Using StoreKit subscription limits: \(charactersLimit)")
            return
        }

        // No StoreKit subscription - check backend for authenticated users
        let isAuth = AuthService.shared.isAuthenticated
        print("[Usage] No StoreKit subscription, checking backend (authenticated: \(isAuth))")

        do {
            if isAuth {
                try await fetchAuthenticatedUsage()
            } else {
                // iOS app anonymous users get FREE tier limits (20k/month)
                // No need to call backend - we don't track usage for iOS anonymous users
                applyFreeUserLimits()
            }
            print("[Usage] Updated: \(charactersUsed)/\(charactersLimit)")
        } catch {
            print("[Usage] ERROR: Failed to fetch usage: \(error)")
        }
    }

    /// Apply local StoreKit subscription limits (500k/month, rolling 30-day period).
    private func applyStoreKitSubscription() {
        let defaults = UserDefaults.standard
        let now = Date()
        let periodDays = 30

        // Pro tier limits (matches backend tiers.py)
        charactersLimit = 500_000

        // Check if we need to reset the period (30 days elapsed)
        if let periodStart = defaults.object(forKey: localPlusPeriodStartKey) as? Date {
            let daysSincePeriodStart = Calendar.current.dateComponents([.day], from: periodStart, to: now).day ?? 0

            // Reset if 30+ days have passed since period start
            if daysSincePeriodStart >= periodDays {
                defaults.set(0, forKey: localPlusUsageKey)
                defaults.set(now, forKey: localPlusPeriodStartKey)
                print("[Usage] 30 days elapsed - reset Plus usage counter")
            }
        } else {
            // First time as Plus subscriber - initialize period start
            defaults.set(now, forKey: localPlusPeriodStartKey)
            defaults.set(0, forKey: localPlusUsageKey)
        }

        // Load usage from local storage
        charactersUsed = defaults.integer(forKey: localPlusUsageKey)
        charactersRemaining = max(0, charactersLimit - charactersUsed)
        periodType = "monthly"

        // Calculate reset date (30 days from period start)
        if let periodStart = defaults.object(forKey: localPlusPeriodStartKey) as? Date {
            resetAt = Calendar.current.date(byAdding: .day, value: periodDays, to: periodStart)
        }

        print("[Usage] Local Plus tier: \(charactersUsed)/\(charactersLimit)")
    }

    /// Apply FREE tier limits for iOS anonymous users (20k/month, rolling 30-day period).
    private func applyFreeUserLimits() {
        let defaults = UserDefaults.standard
        let now = Date()
        let periodDays = 30

        // Check if we need to reset the period (30 days elapsed)
        if let periodStart = defaults.object(forKey: localPeriodStartKey) as? Date {
            let daysSincePeriodStart = Calendar.current.dateComponents([.day], from: periodStart, to: now).day ?? 0

            // Reset if 30+ days have passed since period start
            if daysSincePeriodStart >= periodDays {
                defaults.set(0, forKey: localUsageKey)
                defaults.set(now, forKey: localPeriodStartKey)
                print("[Usage] 30 days elapsed - reset local usage counter")
            }
        } else {
            // First time - initialize period start
            defaults.set(now, forKey: localPeriodStartKey)
            defaults.set(0, forKey: localUsageKey)
        }

        // Load usage from local storage
        charactersUsed = defaults.integer(forKey: localUsageKey)
        charactersLimit = 20_000
        charactersRemaining = max(0, charactersLimit - charactersUsed)
        periodType = "monthly"

        // Calculate reset date (30 days from period start)
        if let periodStart = defaults.object(forKey: localPeriodStartKey) as? Date {
            resetAt = Calendar.current.date(byAdding: .day, value: periodDays, to: periodStart)
        }

        print("[Usage] Local FREE tier: \(charactersUsed)/\(charactersLimit)")
    }

    /// Record usage locally for anonymous iOS users (both Free and Plus tiers).
    func recordLocalUsage(_ characters: Int) {
        // Skip if authenticated - backend tracks usage for logged-in users
        guard !AuthService.shared.isAuthenticated else { return }

        let defaults = UserDefaults.standard
        let isPlus = StoreService.shared.currentTier == .plus
        let usageKey = isPlus ? localPlusUsageKey : localUsageKey

        let currentUsage = defaults.integer(forKey: usageKey)
        let newUsage = currentUsage + characters
        defaults.set(newUsage, forKey: usageKey)

        charactersUsed = newUsage
        charactersRemaining = max(0, charactersLimit - newUsage)

        print("[Usage] Recorded \(characters) chars locally (\(isPlus ? "Plus" : "Free")). Total: \(newUsage)/\(charactersLimit)")
    }

    /// Fetch usage for authenticated users.
    private func fetchAuthenticatedUsage() async throws {
        guard let accessToken = await AuthService.shared.getAccessToken() else {
            print("[Usage] ERROR: No access token for authenticated fetch")
            return
        }

        let url = URL(string: "\(baseURL)/subscription")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[Usage] ERROR: Invalid response type")
            return
        }

        print("[Usage] Backend /subscription returned HTTP \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let responseStr = String(data: data, encoding: .utf8) ?? "no data"
            print("[Usage] ERROR: \(responseStr)")
            return
        }

        // Debug: print raw response
        if let responseStr = String(data: data, encoding: .utf8) {
            print("[Usage] Raw response: \(responseStr)")
        }

        let usage = try JSONDecoder().decode(AuthenticatedUsageResponse.self, from: data)
        print("[Usage] Parsed: tier=\(usage.tier), limit=\(usage.characters_limit)")

        charactersUsed = usage.characters_used
        charactersLimit = usage.characters_limit
        charactersRemaining = usage.credits_remaining
        periodType = "monthly"

        if let endTimestamp = usage.period_end {
            resetAt = Date(timeIntervalSince1970: TimeInterval(endTimestamp))
        }
    }

    /// Fetch usage for anonymous users (tracked by IP).
    private func fetchAnonymousUsage() async throws {
        let url = URL(string: "\(baseURL)/subscription/anonymous-usage")!
        let (data, response) = try await session.data(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return
        }

        let usage = try JSONDecoder().decode(AnonymousUsageResponse.self, from: data)
        charactersUsed = usage.characters_used
        charactersLimit = usage.characters_limit
        charactersRemaining = usage.characters_remaining
        periodType = "weekly"
        resetAt = Date(timeIntervalSince1970: TimeInterval(usage.reset_at))
    }

    /// Format number with k suffix (e.g., 5200 -> "5.2k").
    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            if k == floor(k) {
                return "\(Int(k))k"
            }
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }
}

// MARK: - API Response Models

private struct AuthenticatedUsageResponse: Decodable {
    let tier: String
    let status: String
    let characters_used: Int
    let characters_limit: Int
    let credits_remaining: Int
    let can_translate: Bool
    let period_start: Int?
    let period_end: Int?
}

private struct AnonymousUsageResponse: Decodable {
    let characters_used: Int
    let characters_limit: Int
    let characters_remaining: Int
    let reset_at: Int
}
