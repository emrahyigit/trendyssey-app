import Foundation
import Security

actor UserSyncService {
    static let shared = UserSyncService()

    struct AccountSnapshot: Sendable, Equatable {
        let id: UUID?
        let displayName: String
        let email: String?
        let isAnonymous: Bool
        let avatarKey: String

        static let anonymous = AccountSnapshot(id: nil, displayName: "Anonymous", email: nil, isAnonymous: true, avatarKey: "orbit")
    }

    private struct AuthUser: Decodable {
        struct Metadata: Decodable {
            let full_name: String?
            let avatar_key: String?
        }
        let id: String
        let email: String?
        let is_anonymous: Bool?
        let user_metadata: Metadata?
    }

    private struct AuthSession: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: AuthUser?
    }

    private struct AppleIdentityBody: Encodable {
        let provider = "apple"
        let idToken: String
        let nonce: String
        var linkIdentity: Bool?

        enum CodingKeys: String, CodingKey {
            case provider, nonce
            case idToken = "id_token"
            case linkIdentity = "link_identity"
        }
    }

    private struct Preferences: Encodable {
        let notificationsEnabled: Bool
        let preferredTimeframe: String
        let analysisModelSlug: String
        /// Legacy alias retained while older sync-user deployments roll over.
        let minimumScore: Int
        let minimumRegimeScore: Int
        let minimumReadinessScore: Int
        let minimumBreakoutQualityScore: Int
        let minimumConfirmationScore: Int
        let minimumSignalStrength: Int
        let minimumSuccessRate: Int
        let maximumRisk: Int
        let minimumVolumeRatio: Double
        let minimumQuoteVolume24h: Double
        let minimumStateScore: Int
        let alertScope: String
        let preferredLanguage: String
        let marketStates: [String]
        /// Only push for journeys whose breakout candle was the A+ setup.
        let aplusEntriesOnly: Bool
    }

    private struct Device: Encodable {
        let token: String
        let identifier: String
        let environment: String
    }

    private struct SubscriptionEntitlement: Decodable {
        let is_active: Bool
        let expires_at: String
    }

    private struct SyncBody: Encodable {
        var preferences: Preferences?
        var watchlist: [String]?
        var device: Device?
    }

    private enum Key {
        static let accessToken = "trendyssey.auth.access-token"
        static let refreshToken = "trendyssey.auth.refresh-token"
        static let expiration = "trendyssey.auth.expiration"
    }

    func syncCurrentState(watchlist: [String]) async {
        let defaults = UserDefaults.standard
        let marketStates = (defaults.string(forKey: "notificationMarketStates")
            ?? MarketStateKind.allCases.map(\.rawValue).joined(separator: ","))
            .split(separator: ",")
            .map(String.init)
            .filter { MarketStateKind(rawValue: $0) != nil }
        let minimumQuality = defaults.integer(forKey: "notificationMinimumScore")
        let preferences = Preferences(
            notificationsEnabled: defaults.bool(forKey: "notificationsEnabled"),
            preferredTimeframe: defaults.string(forKey: "preferredTimeframe") ?? "15m",
            analysisModelSlug: AnalysisModelSelection.selectedSlug,
            minimumScore: minimumQuality,
            minimumRegimeScore: defaults.integer(forKey: "notificationMinimumRegimeScore"),
            minimumReadinessScore: defaults.integer(forKey: "notificationMinimumReadinessScore"),
            minimumBreakoutQualityScore: minimumQuality,
            minimumConfirmationScore: defaults.integer(forKey: "notificationMinimumConfirmationScore"),
            // Trend Score is retained for internal validation, not as a user
            // notification gate. Zero also clears thresholds from older builds.
            minimumSignalStrength: 0,
            minimumSuccessRate: defaults.integer(forKey: "notificationMinimumSuccessRate"),
            maximumRisk: 100,
            minimumVolumeRatio: 0.0,
            minimumQuoteVolume24h: Double(defaults.integer(forKey: "notificationMinimumVolumeMillions")) * 1_000_000,
            minimumStateScore: defaults.integer(forKey: "notificationMinimumStateScore"),
            alertScope: defaults.string(forKey: "notificationScope") ?? "favorites",
            preferredLanguage: defaults.string(forKey: "appLanguage") ?? AppLanguage.default.rawValue,
            marketStates: marketStates,
            aplusEntriesOnly: false
        )
        try? await sync(SyncBody(preferences: preferences, watchlist: watchlist.sorted(), device: nil))
    }

    func syncDeviceToken(_ token: String, identifier: String, environment: String) async {
        try? await sync(SyncBody(preferences: nil, watchlist: nil, device: Device(token: token, identifier: identifier, environment: environment)))
    }

    func accountSnapshot() async -> AccountSnapshot {
        do {
            return try await fetchAccount(accessToken: accessToken())
        } catch {
            return .anonymous
        }
    }

    func linkAppleIdentity(idToken: String, nonce: String, fullName: String?) async throws -> AccountSnapshot {
        // First try to attach the Apple identity to the current anonymous user.
        // If Apple ID is already bound to an existing account (e.g. after a
        // sign-out), fall back to signing in to that account instead.
        let currentToken = try await accessToken()
        let session: AuthSession
        if let linked = try? await appleTokenExchange(idToken: idToken, nonce: nonce, linkTo: currentToken) {
            session = linked
        } else {
            session = try await appleTokenExchange(idToken: idToken, nonce: nonce, linkTo: nil)
        }
        store(session)

        let cleanedName = fullName
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { String($0.prefix(24)) }
        if let cleanedName, !cleanedName.isEmpty {
            try await updateUserMetadata(fullName: cleanedName, accessToken: session.access_token)
        }
        return try await fetchAccount(accessToken: session.access_token)
    }

    private func appleTokenExchange(idToken: String, nonce: String, linkTo bearerToken: String?) async throws -> AuthSession {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "grant_type", value: "id_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AppleIdentityBody(idToken: idToken, nonce: nonce, linkIdentity: bearerToken != nil ? true : nil)
        )
        return try await authRequest(request)
    }

    func updateProfile(displayName: String, avatarKey: String) async throws -> AccountSnapshot {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedAvatars: Set<String> = [
            "orbit", "nova", "flare", "wave", "prism", "void",
            "builder", "medic", "reporter", "operator", "chef", "pharmacist",
        ]
        guard (2...24).contains(name.count), allowedAvatars.contains(avatarKey) else {
            throw URLError(.badURL)
        }
        let token = try await accessToken()
        let account = try await fetchAccount(accessToken: token)
        guard account.id != nil, !account.isAnonymous else { throw URLError(.userAuthenticationRequired) }

        var authRequest = URLRequest(url: SupabaseConfig.projectURL.appending(path: "auth/v1/user"))
        authRequest.httpMethod = "PUT"
        authRequest.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        authRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authRequest.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["full_name": name, "avatar_key": avatarKey]])
        let (_, authResponse) = try await URLSession.shared.data(for: authRequest)
        guard let authHTTP = authResponse as? HTTPURLResponse, 200..<300 ~= authHTTP.statusCode else { throw URLError(.badServerResponse) }

        var profileRequest = URLRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/sync_my_public_profile"))
        profileRequest.httpMethod = "POST"
        profileRequest.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        profileRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        profileRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        profileRequest.httpBody = Data("{}".utf8)
        let (_, profileResponse) = try await URLSession.shared.data(for: profileRequest)
        guard let profileHTTP = profileResponse as? HTTPURLResponse, 200..<300 ~= profileHTTP.statusCode else { throw URLError(.badServerResponse) }
        return try await fetchAccount(accessToken: token)
    }

    func syncSubscription(signedTransaction: String) async throws {
        let token = try await accessToken()
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "functions/v1/sync-subscription"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["signedTransaction": signedTransaction])
        request.timeoutInterval = 25
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
    }

    func hasActiveProEntitlement() async -> Bool {
        do {
            let token = try await accessToken()
            var components = URLComponents(
                url: SupabaseConfig.projectURL.appending(path: "rest/v1/subscription_entitlements"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                .init(name: "select", value: "is_active,expires_at"),
                .init(name: "limit", value: "1"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return false
            }
            guard let entitlement = try JSONDecoder().decode([SubscriptionEntitlement].self, from: data).first,
                  entitlement.is_active,
                  let expiry = Self.entitlementDate(entitlement.expires_at) else {
                return false
            }
            return expiry > .now
        } catch {
            return false
        }
    }

    private func sync(_ body: SyncBody) async throws {
        let token = try await accessToken()
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "functions/v1/sync-user"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }

    /// Ends the current session and clears stored tokens. The next request
    /// starts a fresh anonymous session.
    func signOut() async {
        if let token = Keychain.read(Key.accessToken) {
            var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "auth/v1/logout"))
            request.httpMethod = "POST"
            request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: request)
        }
        Keychain.delete(Key.accessToken)
        Keychain.delete(Key.refreshToken)
        Keychain.delete(Key.expiration)
    }

    /// Permanently deletes the signed-in account server-side, then clears the
    /// local session. Required by App Review 5.1.1(v) for account-based apps.
    func deleteAccount() async throws {
        let token = try await accessToken()
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "functions/v1/delete-account"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 25
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        Keychain.delete(Key.accessToken)
        Keychain.delete(Key.refreshToken)
        Keychain.delete(Key.expiration)
    }

    func accessToken() async throws -> String {
        if let token = Keychain.read(Key.accessToken),
           let expiration = Keychain.read(Key.expiration).flatMap(Double.init),
           expiration > Date().timeIntervalSince1970 + 60 {
            return token
        }
        if let refreshToken = Keychain.read(Key.refreshToken),
           let refreshed = try? await refresh(refreshToken) {
            store(refreshed)
            return refreshed.access_token
        }
        let session = try await createAnonymousSession()
        store(session)
        return session.access_token
    }

    private static func entitlementDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func createAnonymousSession() async throws -> AuthSession {
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "auth/v1/signup"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return try await authRequest(request)
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        return try await authRequest(request)
    }

    private func authRequest(_ request: URLRequest) async throws -> AuthSession {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    private func fetchAccount(accessToken: String) async throws -> AccountSnapshot {
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "auth/v1/user"))
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.userAuthenticationRequired) }
        return snapshot(from: try JSONDecoder().decode(AuthUser.self, from: data))
    }

    private func updateUserMetadata(fullName: String, accessToken: String) async throws {
        var request = URLRequest(url: SupabaseConfig.projectURL.appending(path: "auth/v1/user"))
        request.httpMethod = "PUT"
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["full_name": fullName]])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
    }

    private func snapshot(from user: AuthUser) -> AccountSnapshot {
        let name = user.user_metadata?.full_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountSnapshot(
            id: UUID(uuidString: user.id),
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? (user.is_anonymous == false ? user.email ?? "Apple User" : "Anonymous"),
            email: user.email,
            isAnonymous: user.is_anonymous ?? true,
            avatarKey: user.user_metadata?.avatar_key ?? "orbit"
        )
    }

    private func store(_ session: AuthSession) {
        Keychain.write(session.access_token, key: Key.accessToken)
        Keychain.write(session.refresh_token, key: Key.refreshToken)
        Keychain.write(String(Date().timeIntervalSince1970 + session.expires_in), key: Key.expiration)
    }

}

private enum Keychain {
    nonisolated static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.trendyssey.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.trendyssey.app",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated static func write(_ value: String, key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.trendyssey.app",
            kSecAttrAccount as String: key,
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
