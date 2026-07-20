import Foundation

struct CoinChatMessage: Identifiable, Decodable, Sendable {
    let id: UUID
    let symbol: String
    let userID: UUID
    let body: String
    let languageCode: String
    let authorDisplayName: String
    let authorAvatarKey: String
    let createdAt: Date
    let hasReported: Bool
    let thumbsUpCount: Int
    let hasThumbedUp: Bool

    enum CodingKeys: String, CodingKey {
        case id, symbol, body
        case userID = "user_id"
        case languageCode = "language_code"
        case authorDisplayName = "author_display_name"
        case authorAvatarKey = "author_avatar_key"
        case createdAt = "created_at"
        case hasReported = "has_reported"
        case thumbsUpCount = "thumbs_up_count"
        case hasThumbedUp = "has_thumbed_up"
    }
}

actor CoinChatService {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func messages(symbol: String, language: AppLanguage, limit: Int = 50) async throws -> [CoinChatMessage] {
        var components = URLComponents(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/get_coin_chat_messages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "p_symbol", value: symbol.uppercased()),
            .init(name: "p_language", value: language.rawValue),
            .init(name: "p_limit", value: String(min(max(limit, 1), 100))),
        ]
        var request = try await authorizedRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try decoder.decode([CoinChatMessage].self, from: data)
    }

    func toggleThumbsUp(messageID: UUID) async throws {
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/toggle_coin_chat_thumbs_up"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_message_id": messageID.uuidString])
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func report(messageID: UUID) async throws {
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/rpc/report_coin_chat_message"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_message_id": messageID.uuidString])
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func send(_ body: String, symbol: String, language: AppLanguage) async throws {
        let account = await UserSyncService.shared.accountSnapshot()
        guard let userID = account.id, !account.isAnonymous else { throw ChatError.appleAccountRequired }
        var request = try await authorizedRequest(url: SupabaseConfig.projectURL.appending(path: "rest/v1/coin_chat_messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "symbol": symbol.uppercased(), "user_id": userID.uuidString, "body": body,
            "language_code": language.rawValue,
            "author_display_name": account.displayName, "author_avatar_key": account.avatarKey,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw ChatError.requestFailed }
    }

    enum ChatError: Error { case appleAccountRequired, requestFailed }
}
