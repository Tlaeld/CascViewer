import Foundation
import CascBridge

actor CDNConfigService {
    func fetchBuildConfig(product: String, region: String) async throws -> CDNBuildConfig {
        // Offload synchronous network I/O to a non-actor queue so the actor
        // remains responsive to concurrent callers.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var config = CascBridge.CDNConfig()
                var error = CascBridge.CascError.None
                let buildConfig = config.fetchConfig(std.string(product), std.string(region), &error)
                if error != .None {
                    continuation.resume(throwing: CASCError.cdnConfigError)
                } else {
                    continuation.resume(returning: CDNBuildConfig(
                        buildName: String(buildConfig.buildName),
                        buildConfigHash: String(buildConfig.buildConfigHash),
                        cdnConfigHash: String(buildConfig.cdnConfigHash),
                        productConfig: String(buildConfig.productConfig)
                    ))
                }
            }
        }
    }
}

struct CDNBuildConfig {
    let buildName: String
    let buildConfigHash: String
    let cdnConfigHash: String
    let productConfig: String
}
