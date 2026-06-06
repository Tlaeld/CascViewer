import Foundation

struct CDNProduct: Identifiable, Equatable, Sendable, Decodable {
    var id: String { code }
    let name: String
    let code: String
    var regions: [String] = []
    var isLoading = false
    var loadFailed = false

    enum CodingKeys: String, CodingKey {
        case name, code
    }

    static func == (lhs: CDNProduct, rhs: CDNProduct) -> Bool {
        lhs.name == rhs.name && lhs.code == rhs.code && lhs.regions == rhs.regions && lhs.isLoading == rhs.isLoading && lhs.loadFailed == rhs.loadFailed
    }

    static let builtInList: [CDNProduct] = {
        guard let url = Bundle.main.url(forResource: "CDNProducts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let products = try? JSONDecoder().decode([CDNProduct].self, from: data) else {
            return []
        }
        return products
    }()
}
