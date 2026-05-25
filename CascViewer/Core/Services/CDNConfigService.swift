import Foundation
import CascBridge

actor CDNConfigService {
    func fetchBuildConfig(product: String, region: String) async throws -> CDNBuildConfig {
        // Offload synchronous network I/O to a detached task so the actor
        // executor is preserved after the await (Swift 6 compatibility).
        return try await Task.detached(priority: .userInitiated) {
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
        }.value
    }
}

struct CDNBuildConfig {
    let buildName: String
    let buildConfigHash: String
    let cdnConfigHash: String
    let productConfig: String
}
