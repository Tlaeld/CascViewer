import Foundation
import CascBridge

actor CDNConfigService {
    func fetchBuildConfig(product: String, region: String) async throws -> CDNBuildConfig {
        var config = CascBridge.CDNConfig()
        var error = CascBridge.CascError.None
        let buildConfig = config.fetchConfig(std.string(product), std.string(region), &error)
        if error != .None {
            throw CASCError.cdnConfigError
        }
        return CDNBuildConfig(
            buildName: String(buildConfig.buildName),
            buildConfigHash: String(buildConfig.buildConfigHash),
            cdnConfigHash: String(buildConfig.cdnConfigHash),
            productConfig: String(buildConfig.productConfig)
        )
    }
}

struct CDNBuildConfig {
    let buildName: String
    let buildConfigHash: String
    let cdnConfigHash: String
    let productConfig: String
}
