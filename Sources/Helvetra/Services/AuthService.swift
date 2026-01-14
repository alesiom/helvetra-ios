import AuthenticationServices
import Foundation
import Security

// MARK: - Notifications

extension Notification.Name {
    static let authStateDidChange = Notification.Name("authStateDidChange")
}

// MARK: - Auth Models

/// User profile from authentication.
struct AuthUser: Codable, Equatable {
    let id: String
    let email: String
    let emailVerified: Bool
    let tier: String

    enum CodingKeys: String, CodingKey {
        case id, email, tier
        case emailVerified = "email_verified"
    }
}

/// Authentication tokens from backend.
struct AuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// Backend auth response structure.
private struct AuthAPIResponse: Decodable {
    let success: Bool
    let data: AuthResponseData?
    let error: [String: String]?
}

private struct AuthResponseData: Decodable {
    let user: AuthUser?
    let tokens: AuthTokens?
}

// MARK: - Keychain Helper

/// Secure storage for authentication tokens.
enum KeychainHelper {
    private static let service = "ch.helvetra.app"

    enum Key: String {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenExpiry = "token_expiry"
        case userId = "user_id"
        case userEmail = "user_email"
        case userTier = "user_tier"
    }

    static func save(_ value: String, for key: Key) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    static func delete(for key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        for key in [Key.accessToken, .refreshToken, .tokenExpiry, .userId, .userEmail, .userTier] {
            delete(for: key)
        }
    }
}

// MARK: - Auth Service

/// Manages user authentication with Sign in with Apple and backend integration.
@MainActor
final class AuthService: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = AuthService()

    /// Current authentication state.
    @Published private(set) var isAuthenticated: Bool = false

    /// Current user profile.
    @Published private(set) var currentUser: AuthUser?

    /// Loading state for auth operations.
    @Published private(set) var isLoading: Bool = false

    /// Error message from last operation.
    @Published var errorMessage: String?

    private let baseURL = "https://helvetra.ch/api/v1"
    private let session: URLSession
    private var signInContinuation: CheckedContinuation<ASAuthorization, Error>?

    // MARK: - Debug Mode

    /// Set to true to fake authenticated state for UI testing/screenshots.
    /// Remember to set back to false before release!
    private let debugFakeAuth = false

    private override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        super.init()

        if debugFakeAuth {
            // Fake authenticated state for UI testing
            currentUser = AuthUser(
                id: "debug-user",
                email: "alex@helvetra.ch",
                emailVerified: true,
                tier: "plus"
            )
            isAuthenticated = true
        } else {
            restoreSession()
        }
    }

    // MARK: - Session Restoration

    /// Restore session from Keychain on app launch.
    private func restoreSession() {
        guard let accessToken = KeychainHelper.load(for: .accessToken),
              let userId = KeychainHelper.load(for: .userId),
              let email = KeychainHelper.load(for: .userEmail),
              let tier = KeychainHelper.load(for: .userTier),
              !accessToken.isEmpty
        else {
            isAuthenticated = false
            currentUser = nil
            return
        }

        // Check if token is expired
        if let expiryString = KeychainHelper.load(for: .tokenExpiry),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 > expiry
        {
            // Token expired, try to refresh
            Task {
                await refreshTokenIfNeeded()
            }
            return
        }

        currentUser = AuthUser(
            id: userId,
            email: email,
            emailVerified: true,
            tier: tier
        )
        isAuthenticated = true

        // Sync subscription tier with StoreService
        NotificationCenter.default.post(name: .authStateDidChange, object: nil)
    }

    // MARK: - Sign in with Apple

    /// Initiate Sign in with Apple flow.
    func signInWithApple() async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let authorization = try await performAppleSignIn()

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            throw AuthError.invalidCredentials
        }

        // Get user name if provided (only on first sign-in)
        var userName: String?
        if let fullName = credential.fullName {
            let components = [fullName.givenName, fullName.familyName].compactMap { $0 }
            if !components.isEmpty {
                userName = components.joined(separator: " ")
            }
        }

        try await authenticateWithBackend(identityToken: identityToken, userName: userName)
    }

    private func performAppleSignIn() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.signInContinuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    // MARK: - Backend Authentication

    private func authenticateWithBackend(identityToken: String, userName: String?) async throws {
        let url = URL(string: "\(baseURL)/auth/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct AppleAuthRequest: Encodable {
            let identity_token: String
            let user_name: String?
            let use_cookie: Bool = false
        }

        let body = AppleAuthRequest(identity_token: identityToken, user_name: userName)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(AuthAPIResponse.self, from: data),
               let error = errorResponse.error
            {
                throw AuthError.serverError(error["detail"] ?? error["message"] ?? "Authentication failed")
            }
            throw AuthError.httpError(statusCode: httpResponse.statusCode)
        }

        let authResponse = try JSONDecoder().decode(AuthAPIResponse.self, from: data)

        guard authResponse.success,
              let responseData = authResponse.data,
              let user = responseData.user,
              let tokens = responseData.tokens
        else {
            throw AuthError.invalidResponse
        }

        saveSession(user: user, tokens: tokens)
    }

    // MARK: - Token Management

    private func saveSession(user: AuthUser, tokens: AuthTokens) {
        KeychainHelper.save(tokens.accessToken, for: .accessToken)
        KeychainHelper.save(tokens.refreshToken, for: .refreshToken)

        let expiry = Date().timeIntervalSince1970 + Double(tokens.expiresIn)
        KeychainHelper.save(String(expiry), for: .tokenExpiry)

        KeychainHelper.save(user.id, for: .userId)
        KeychainHelper.save(user.email, for: .userEmail)
        KeychainHelper.save(user.tier, for: .userTier)

        currentUser = user
        isAuthenticated = true

        // Sync subscription tier with StoreService (for web subscriptions)
        NotificationCenter.default.post(name: .authStateDidChange, object: nil)
    }

    /// Get current access token, refreshing if needed.
    func getAccessToken() async -> String? {
        // Check if token is expired or about to expire (within 60 seconds)
        if let expiryString = KeychainHelper.load(for: .tokenExpiry),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 > expiry - 60
        {
            await refreshTokenIfNeeded()
        }

        return KeychainHelper.load(for: .accessToken)
    }

    /// Refresh the access token using the refresh token.
    func refreshTokenIfNeeded() async {
        guard let refreshToken = KeychainHelper.load(for: .refreshToken),
              !refreshToken.isEmpty
        else {
            await signOut()
            return
        }

        do {
            let url = URL(string: "\(baseURL)/auth/refresh")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            struct RefreshRequest: Encodable {
                let refresh_token: String
            }

            request.httpBody = try JSONEncoder().encode(RefreshRequest(refresh_token: refreshToken))

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                await signOut()
                return
            }

            let authResponse = try JSONDecoder().decode(AuthAPIResponse.self, from: data)

            guard authResponse.success,
                  let responseData = authResponse.data,
                  let tokens = responseData.tokens
            else {
                await signOut()
                return
            }

            // Save new tokens
            KeychainHelper.save(tokens.accessToken, for: .accessToken)
            if !tokens.refreshToken.isEmpty {
                KeychainHelper.save(tokens.refreshToken, for: .refreshToken)
            }

            let expiry = Date().timeIntervalSince1970 + Double(tokens.expiresIn)
            KeychainHelper.save(String(expiry), for: .tokenExpiry)
        } catch {
            await signOut()
        }
    }

    // MARK: - Sign Out

    /// Sign out and clear all stored credentials.
    func signOut() async {
        isLoading = true
        defer { isLoading = false }

        // Notify backend
        if let refreshToken = KeychainHelper.load(for: .refreshToken) {
            do {
                let url = URL(string: "\(baseURL)/auth/logout")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                struct LogoutRequest: Encodable {
                    let refresh_token: String
                }

                request.httpBody = try JSONEncoder().encode(LogoutRequest(refresh_token: refreshToken))
                _ = try? await session.data(for: request)
            } catch {
                // Ignore logout errors
            }
        }

        // Clear local state
        KeychainHelper.deleteAll()
        currentUser = nil
        isAuthenticated = false

        // Sync subscription tier (revert to free)
        NotificationCenter.default.post(name: .authStateDidChange, object: nil)
    }

    // MARK: - Account Deletion

    /// Delete user account.
    func deleteAccount() async throws {
        guard let accessToken = await getAccessToken() else {
            throw AuthError.notAuthenticated
        }

        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/auth/account")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(AuthAPIResponse.self, from: data),
               let error = errorResponse.error
            {
                throw AuthError.serverError(error["detail"] ?? "Account deletion failed")
            }
            throw AuthError.httpError(statusCode: httpResponse.statusCode)
        }

        // Clear local state
        KeychainHelper.deleteAll()
        currentUser = nil
        isAuthenticated = false
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            signInContinuation?.resume(returning: authorization)
            signInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            signInContinuation?.resume(throwing: error)
            signInContinuation = nil
        }
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case invalidCredentials
    case networkError
    case httpError(statusCode: Int)
    case serverError(String)
    case invalidResponse
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Apple credentials"
        case .networkError:
            return "Network connection failed"
        case let .httpError(statusCode):
            return "Server error (\(statusCode))"
        case let .serverError(message):
            return message
        case .invalidResponse:
            return "Invalid server response"
        case .notAuthenticated:
            return "Not authenticated"
        }
    }
}
