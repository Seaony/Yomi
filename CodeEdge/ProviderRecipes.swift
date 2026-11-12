import Foundation

nonisolated struct ProviderRecipe: Sendable {
    enum Authorization: Sendable {
        case bearer
        case header(String)
        case cookie
    }

    let endpoint: String
    let method: String
    let authorization: Authorization
    let body: String?

    init(
        _ endpoint: String,
        method: String = "GET",
        authorization: Authorization = .bearer,
        body: String? = nil
    ) {
        self.endpoint = endpoint
        self.method = method
        self.authorization = authorization
        self.body = body
    }
}

nonisolated enum ProviderRecipes {
    static func recipe(for id: ProviderID) -> ProviderRecipe? {
        recipes[id.rawValue]
    }

    private static let recipes: [String: ProviderRecipe] = [
        "claude": ProviderRecipe(
            "https://api.anthropic.com/api/oauth/usage",
            authorization: .bearer),
        "clinepass": ProviderRecipe("https://api.cline.bot/api/v1/users/me/plan/usage-limits"),
        "openai": ProviderRecipe("https://api.openai.com/v1/dashboard/billing/credit_grants"),
    ]
}
