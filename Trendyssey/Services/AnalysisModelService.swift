import Foundation

struct AnalysisModelService {
    func activeModels() async throws -> [AnalysisModelOption] {
        var components = URLComponents(
            url: SupabaseConfig.projectURL.appending(path: "rest/v1/analysis_models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "select", value: "id,slug,display_name,provider,authoring_model,version,description,required_tier,is_default"),
            .init(name: "is_active", value: "eq.true"),
            .init(name: "order", value: "sort_order.asc")
        ]
        let token = try await UserSyncService.shared.accessToken()
        var request = URLRequest(url: components.url!)
        request.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([AnalysisModelOption].self, from: data)
    }
}
