import Foundation

struct CDNProduct: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let code: String
    var regions: [String] = []
    var isLoading = false
    var loadFailed = false

    static let builtInList: [CDNProduct] = [
        CDNProduct(name: "Battle.net Agent", code: "agent"),
        CDNProduct(name: "Battle.net Agent beta", code: "agent_beta"),
        CDNProduct(name: "Battle.net App", code: "bna"),
        CDNProduct(name: "Bootstrapper", code: "bts"),
        CDNProduct(name: "Catalog", code: "catalogs"),
        CDNProduct(name: "Client", code: "clnt"),
        CDNProduct(name: "Blizzard Arcade Collection", code: "rtro"),
        CDNProduct(name: "Blizzard Arcade Collection Dev", code: "rtrodev"),
        CDNProduct(name: "Diablo 2 Resurrected Retail", code: "osi"),
        CDNProduct(name: "Diablo 2 Resurrected Beta", code: "osib"),
        CDNProduct(name: "Diablo 2 Resurrected Alpha", code: "osia"),
        CDNProduct(name: "Diablo 2 Resurrected Dev", code: "osidev"),
        CDNProduct(name: "Diablo 3", code: "d3"),
        CDNProduct(name: "Diablo 3 Beta (2013)", code: "d3b"),
        CDNProduct(name: "Diablo 3 China", code: "d3cn"),
        CDNProduct(name: "Diablo Immortal", code: "anbs"),
        CDNProduct(name: "Hearthstone", code: "hsb"),
        CDNProduct(name: "Hearthstone Beta", code: "hsbt"),
        CDNProduct(name: "Heroes of the Storm", code: "hero"),
        CDNProduct(name: "Heroes of the Storm Dev", code: "herot"),
        CDNProduct(name: "Overwatch", code: "pro"),
        CDNProduct(name: "Overwatch Dev", code: "prodev"),
        CDNProduct(name: "Overwatch 2", code: "pro2"),
        CDNProduct(name: "StarCraft", code: "s1"),
        CDNProduct(name: "StarCraft II", code: "s2"),
        CDNProduct(name: "StarCraft II China", code: "s2c"),
        // CDNProduct(name: "StarCraft II China vendor", code: "s2v"),
        CDNProduct(name: "Warcraft III: Reforged", code: "w3"),
        CDNProduct(name: "Warcraft III Classic", code: "w3t"),
        CDNProduct(name: "World of Warcraft", code: "wow"),
        CDNProduct(name: "WoW Beta", code: "wow_beta"),
        CDNProduct(name: "WoW PTR", code: "wowt"),
        CDNProduct(name: "WoW Classic", code: "wow_classic"),
        CDNProduct(name: "WoW Classic Era", code: "wow_classic_era"),
        CDNProduct(name: "WoW Classic PTR", code: "wow_classic_ptr"),
    ]
}
