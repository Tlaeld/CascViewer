import Foundation
import simd
import CascBridge

/// 把 WOModel(C++) 转成 ModelScene(Swift)并解析纹理。
actor ModelLoaderService {

    /// 文件读取抽象(生产用 CascModelFileProvider,测试用 Mock)。
    protocol FileProvider: Sendable {
        func readFile(path: String) -> Data?
        func readFileByDataId(_ id: UInt32) -> Data?
    }

    enum LoadError: Error {
        case fileNotFound(String)
        case parseFailed(String)
    }

    private let provider: any FileProvider
    /// 实例级缓存:键为 path,随 provider 隔离(静态缓存会让不同存储/测试互相污染)。
    private let cache = NSCache<NSString, ModelSceneBox>()

    init(provider: any FileProvider) {
        self.provider = provider
    }

    func load(path: String, format: ModelScene.Format) async throws -> ModelScene {
        let cacheKey = path as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.scene
        }
        guard let data = provider.readFile(path: path), !data.isEmpty else {
            throw LoadError.fileNotFound(path)
        }

        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        let cppModel: WhiteoutBridge.WOModel

        switch format {
        case .mdx:
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseMDX(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                                data.count, &error)
            }
        case .m3:
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseM3(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                               data.count, &error)
            }
        case .m2:
            let box = M2ReadBox(provider: provider)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<M2ReadBox>.fromOpaque(ctx).release() }
            let callback: WhiteoutBridge.WOM2ReadFileCallback = { ctx, fileDataId, outSize in
                guard let ctx = ctx, let outSize = outSize else { return nil }
                let box = Unmanaged<M2ReadBox>.fromOpaque(ctx).takeUnretainedValue()
                guard let bytes = box.provider.readFileByDataId(fileDataId),
                      !bytes.isEmpty else { return nil }
                box.retained[fileDataId] = bytes   // 保活,parse 返回前指针有效
                outSize.pointee = bytes.count
                return bytes.withUnsafeBytes {
                    $0.bindMemory(to: UInt8.self).baseAddress
                }
            }
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseM2(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                               data.count, ctx, callback, &error)
            }
        }

        guard error == .None else {
            throw LoadError.parseFailed(path)
        }

        var scene = ModelSceneConverter.convert(cppModel, format: format)
        await resolveTextures(&scene)
        cache.setObject(ModelSceneBox(scene: scene), forKey: cacheKey)
        return scene
    }

    /// 逐材质解析纹理引用并从存储读取解码;失败保留 nil(占位材质)。
    private func resolveTextures(_ scene: inout ModelScene) async {
        let coordinator = BLPDecoderCoordinator()
        for i in scene.materials.indices {
            let mat = scene.materials[i]
            let data: Data?
            if !mat.texturePath.isEmpty {
                data = provider.readFile(path: mat.texturePath)
            } else if mat.textureFileDataId != 0 {
                data = provider.readFileByDataId(mat.textureFileDataId)
            } else {
                data = nil
            }
            guard let textureData = data,
                  let decoded = try? await coordinator.decode(data: textureData),
                  let mip0 = decoded.frames.first else { continue }
            scene.materials[i].diffuseTexture = mip0
        }
    }
}

/// NSCache 需要 class 包装
final class ModelSceneBox: NSObject {
    let scene: ModelScene
    init(scene: ModelScene) { self.scene = scene }
}

/// M2 回调的保活盒
private final class M2ReadBox: @unchecked Sendable {
    let provider: any ModelLoaderService.FileProvider
    var retained: [UInt32: Data] = [:]
    init(provider: any ModelLoaderService.FileProvider) { self.provider = provider }
}

/// 生产环境 FileProvider:同步读 C++ 存储句柄(句柄内部有锁,线程安全)。
final class CascModelFileProvider: ModelLoaderService.FileProvider, @unchecked Sendable {
    private var handle: CascBridge.CascStorageHandle
    init(handle: CascBridge.CascStorageHandle) { self.handle = handle }

    func readFile(path: String) -> Data? {
        var error = CascBridge.CascError.None
        let buffer = handle.readFile(std.string(path), &error)
        guard error == .None else { return nil }
        return Data(buffer)
    }

    func readFileByDataId(_ id: UInt32) -> Data? {
        readFile(path: String(format: "FILE%08X.dat", id))
    }
}

#if DEBUG
final class MockModelFileProvider: ModelLoaderService.FileProvider, @unchecked Sendable {
    var files: [String: Data] = [:]
    func readFile(path: String) -> Data? { files[path] }
    func readFileByDataId(_ id: UInt32) -> Data? { files[String(format: "FILE%08X.dat", id)] }
}
#endif
