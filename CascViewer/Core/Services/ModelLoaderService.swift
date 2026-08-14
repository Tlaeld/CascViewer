import Foundation
import simd
import CascBridge

/// 把 WOModel(C++) 转成 ModelScene(Swift)并解析纹理。
actor ModelLoaderService {

    /// 文件读取抽象(生产用 CascModelFileProvider,测试用 Mock)。
    protocol FileProvider: Sendable {
        func readFile(path: String) -> Data?
        func readFileByDataId(_ id: UInt32) -> Data?
        /// 把 assets 虚拟根相对引用(如 "Assets/Textures/X.dds")解析为存储内
        /// 实际存在的完整路径(跨 mod 兜底);无索引或找不到返回 nil。
        func resolveAssetsPath(_ ref: String) -> String?
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
        await resolveTextures(&scene, modelPath: path)
        cache.setObject(ModelSceneBox(scene: scene), forKey: cacheKey)
        return scene
    }

    /// 纹理路径候选列表。SC2/HotS 的 M3 纹理引用是相对 assets 虚拟根的逻辑路径
    /// (如 "Assets/Textures/Zealot_Diffuse.dds"),CASC 实际存储在 mod 前缀下
    /// (如 "mods/liberty.sc2mod/base.sc2assets/Assets/Textures/...")。
    /// 从模型自身路径的 "/assets/" 边界提取前缀构造候选;原样路径优先。
    static func textureCandidates(modelPath: String, texturePath: String) -> [String] {
        let ref = texturePath.replacingOccurrences(of: "\\", with: "/")
        let model = modelPath.replacingOccurrences(of: "\\", with: "/")
        var candidates = [ref]
        if let range = model.range(of: "/assets/", options: .caseInsensitive) {
            let prefix = String(model[..<range.lowerBound]) + "/"
            candidates.append(prefix + ref)
        }
        return candidates
    }

    /// 逐材质解析纹理引用并从存储读取解码;失败保留 nil(占位材质)。
    /// 各材质并行(读 + 解码),每任务独立解码器(静态纹理缓存共享,
    /// NSCache 线程安全;存储句柄内部有锁)。实测串行 18 张纹理 ~9.4s。
    private func resolveTextures(_ scene: inout ModelScene, modelPath: String) async {
        let materials = scene.materials
        let provider = self.provider
        let frames = await withTaskGroup(of: (Int, ImageDecodeResult.ImageFrame?).self) { group in
            for i in materials.indices {
                group.addTask {
                    let mat = materials[i]
                    var data: Data? = nil
                    if !mat.texturePath.isEmpty {
                        for candidate in Self.textureCandidates(modelPath: modelPath,
                                                                texturePath: mat.texturePath) {
                            if let d = provider.readFile(path: candidate) {
                                data = d
                                break
                            }
                        }
                        // 跨 mod 兜底:引用只存在于其他 mod(如战役模型引用基础 mod 共享纹理)
                        if data == nil {
                            let ref = mat.texturePath.replacingOccurrences(of: "\\", with: "/")
                            if let resolved = provider.resolveAssetsPath(ref) {
                                data = provider.readFile(path: resolved)
                            }
                        }
                    }
                    // 路径读取失败(M2 常空路径)时回退 FileDataId
                    if data == nil, mat.textureFileDataId != 0 {
                        data = provider.readFileByDataId(mat.textureFileDataId)
                    }
                    guard let textureData = data else { return (i, nil) }
                    let coordinator = BLPDecoderCoordinator()
                    guard let decoded = try? await coordinator.decode(data: textureData) else {
                        return (i, nil)
                    }
                    return (i, decoded.frames.first)
                }
            }
            var result: [Int: ImageDecodeResult.ImageFrame] = [:]
            for await (i, frame) in group {
                if let frame { result[i] = frame }
            }
            return result
        }
        for (i, frame) in frames {
            scene.materials[i].diffuseTexture = frame
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
    /// 预建 assets 索引:键 = 从 assets 段起的小写路径,值 = 完整原始路径。
    /// 大存储(如 HotS,1.6M 路径)构建一次 ~16s,必须由存储层共享,
    /// 不能每次打开模型重建。
    private let assetsIndex: [String: String]

    init(handle: CascBridge.CascStorageHandle, assetsIndex: [String: String] = [:]) {
        self.handle = handle
        self.assetsIndex = assetsIndex
    }

    /// 小规模/测试用:从路径列表立即构建索引。
    convenience init(handle: CascBridge.CascStorageHandle, allPaths: [String]) {
        self.init(handle: handle, assetsIndex: Self.buildAssetsIndex(fromPaths: allPaths))
    }

    /// 从完整路径列表构建 assets 索引(键为小写,支持大小写不敏感查找)。
    static func buildAssetsIndex(fromPaths paths: [String]) -> [String: String] {
        var index: [String: String] = [:]
        for path in paths {
            guard let range = path.range(of: "/assets/", options: .caseInsensitive) else { continue }
            let fromAssets = String(path[range.lowerBound...].dropFirst())
            index[fromAssets.lowercased()] = path
        }
        return index
    }

    func readFile(path: String) -> Data? {
        var error = CascBridge.CascError.None
        let buffer = handle.readFile(std.string(path), &error)
        guard error == .None else { return nil }
        return Data(buffer)
    }

    func readFileByDataId(_ id: UInt32) -> Data? {
        readFile(path: String(format: "FILE%08X.dat", id))
    }

    func resolveAssetsPath(_ ref: String) -> String? {
        assetsIndex[ref.lowercased()]
    }
}

#if DEBUG
final class MockModelFileProvider: ModelLoaderService.FileProvider, @unchecked Sendable {
    var files: [String: Data] = [:]
    func readFile(path: String) -> Data? { files[path] }
    func readFileByDataId(_ id: UInt32) -> Data? { files[String(format: "FILE%08X.dat", id)] }
    func resolveAssetsPath(_ ref: String) -> String? {
        let key = ref.lowercased()
        for path in files.keys {
            guard let range = path.range(of: "/assets/", options: .caseInsensitive) else { continue }
            let fromAssets = String(path[range.lowerBound...].dropFirst())
            if fromAssets.lowercased() == key { return path }
        }
        return nil
    }
}
#endif
