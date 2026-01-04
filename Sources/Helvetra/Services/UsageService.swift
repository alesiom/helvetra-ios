import Foundation

/// Tracks character usage against subscription limits.
@MainActor
class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var charactersUsed: Int = 0
    @Published private(set) var charactersLimit: Int = 20_000
    @Published private(set) var charactersRemaining: Int = 20_000
    @Published private(set) var periodType: String = "monthly"
    @Published private(set) var resetAt: Date?
    @Published private(set) var isLoading: Bool = false

    private let baseURL = "https://helvetra.ch/api/v1"
    private let session: URLSession

    /// Usage as a percentage (0.0 to 1.0).
    var usagePercentage: Double {
        guard charactersLimit > 0 else { return 0 }
        return min(1.0, Double(charactersUsed) / Double(charactersLimit))
    }

    /// Formatted usage string (e.g., "5.2k / 20k").
    var usageText: String {
        "\(formatNumber(charactersUsed)) / \(formatNumber(charactersLimit))"
    }

    /// Period description (e.g., "Resets monthly" or "Resets Jan 6").
    var periodText: String {
        if let resetAt = resetAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Resets \(formatter.string(from: resetAt))"
        }
        return periodType == "weekly" ? "Resets weekly" : "Resets monthly"
    }

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
    }

    /// Fetch current usage from backend.
    func fetchUsage() async {
        isLoading = true
        defer { isLoading = false }

        let isAuth = AuthService.shared.isAuthenticated
        print("[Usage] Fetching usage, authenticated: \(isAuth)")

        do {
            if isAuth {
                try await fetchAuthenticatedUsage()
            } else {
                try await fetchAnonymousUsage()
            }
            print("[Usage] Updated: \(charactersUsed)/\(charactersLimit)")
        } catch {
            print("[Usage] ERROR: Failed to fetch usage: \(error)")
        }
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
