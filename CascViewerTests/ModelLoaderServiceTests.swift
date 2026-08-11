import XCTest
import CascBridge
import SceneKit
import AppKit
@testable import CascViewer

final class ModelLoaderServiceTests: XCTestCase {

    /// 内存文件提供者:MDX 模型 + 一张 BLP 纹理
    private func makeProvider() -> MockModelFileProvider {
        let provider = MockModelFileProvider()
        provider.files["models/test.mdx"] = Data(WhiteoutBridge.WOEncodeTestMDX())
        provider.files["Textures/test.blp"] = Data(WhiteoutBridge.WOEncodeTestImage(8, 8, 1))
        return provider
    }

    func testLoadMDXScene() async throws {
        let service = ModelLoaderService(provider: makeProvider())
        let scene = try await service.load(path: "models/test.mdx", format: .mdx)

        XCTAssertEqual(scene.format, .mdx)
        XCTAssertEqual(scene.meshes.count, 1)
        XCTAssertEqual(scene.meshes[0].positions.count, 3)
        XCTAssertEqual(scene.bones.count, 3)
        XCTAssertEqual(scene.animations.count, 1)
        XCTAssertEqual(scene.animations[0].name, "Stand")
        XCTAssertEqual(scene.animations[0].durationMs, 1000)
        // 材质纹理已解析并解码
        XCTAssertEqual(scene.materials.count, 1)
        XCTAssertNotNil(scene.materials[0].diffuseTexture)
        XCTAssertEqual(scene.materials[0].diffuseTexture?.width, 8)
    }

    func testMissingModelThrows() async {
        let service = ModelLoaderService(provider: MockModelFileProvider())
        do {
            _ = try await service.load(path: "nope.mdx", format: .mdx)
            XCTFail("应当抛错")
        } catch {
            // 预期
        }
    }

    func testMissingTextureKeepsMaterial() async throws {
        let provider = MockModelFileProvider()
        provider.files["models/test.mdx"] = Data(WhiteoutBridge.WOEncodeTestMDX())
        // 不放纹理文件
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(path: "models/test.mdx", format: .mdx)
        XCTAssertNil(scene.materials[0].diffuseTexture)  // 纹理缺失但材质还在
    }

    /// SC2/HotS 布局:M3 纹理引用是相对 assets 虚拟根的逻辑路径,
    /// 真实文件在 mod 前缀下(mods/.../base.sc2assets/)。
    func testSC2AssetRootPrefix() async throws {
        let provider = MockModelFileProvider()
        let modelPath = "mods/liberty.sc2mod/base.sc2assets/assets/units/protoss/zealot/zealot.m3"
        provider.files[modelPath] = Data(WhiteoutBridge.WOEncodeTestM3())
        // 夹具纹理引用是 "Assets/Textures/test.dds",只存在于带前缀位置
        provider.files["mods/liberty.sc2mod/base.sc2assets/Assets/Textures/test.dds"] =
            Data(WhiteoutBridge.WOEncodeTestImage(8, 8, 2))
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(path: modelPath, format: .m3)
        XCTAssertEqual(scene.materials.count, 1)
        XCTAssertNotNil(scene.materials[0].diffuseTexture)
        XCTAssertEqual(scene.materials[0].diffuseTexture?.width, 8)
    }

    /// 纯函数:候选路径生成规则
    func testTextureCandidates() {
        // 无 /assets/ 边界 → 只按原样尝试
        XCTAssertEqual(
            ModelLoaderService.textureCandidates(modelPath: "models/test.mdx",
                                                 texturePath: "Textures/test.blp"),
            ["Textures/test.blp"])
        // 有 /assets/ 边界 → 原样优先,加 mod 前缀候选
        XCTAssertEqual(
            ModelLoaderService.textureCandidates(
                modelPath: "mods/liberty.sc2mod/base.sc2assets/assets/units/z.m3",
                texturePath: "Assets/Textures/T.dds"),
            ["Assets/Textures/T.dds",
             "mods/liberty.sc2mod/base.sc2assets/Assets/Textures/T.dds"])
        // 反斜杠归一
        XCTAssertEqual(
            ModelLoaderService.textureCandidates(modelPath: "m/a/x.m3",
                                                 texturePath: "A\\B.dds").first,
            "A/B.dds")
    }

    /// 跨 mod 引用:战役模型引用基础 mod 的共享纹理
    /// (artifact1.m3 引用只存在于 mods/liberty.sc2mod 下的贴图)。
    func testCrossModTextureFallback() async throws {
        let provider = MockModelFileProvider()
        let modelPath = "campaigns/liberty.sc2campaign/base.sc2assets/assets/campaign/terran/artifact1/artifact1.m3"
        provider.files[modelPath] = Data(WhiteoutBridge.WOEncodeTestM3())
        // 夹具纹理引用是 "Assets/Textures/test.dds",只存在于另一个 mod 下
        provider.files["mods/liberty.sc2mod/base.sc2assets/Assets/Textures/test.dds"] =
            Data(WhiteoutBridge.WOEncodeTestImage(8, 8, 2))
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(path: modelPath, format: .m3)
        XCTAssertNotNil(scene.materials[0].diffuseTexture)
    }

    /// 真实存储端到端验证(SC2 在本机存在才运行,否则跳过)。
    /// 覆盖:真实 CascLib 打开 + 全量枚举 + 跨 mod 索引 + 真实 DDS 解码。
    func testRealSC2StorageCrossModTexture() async throws {
        let storagePath = "/Users/dev/Desktop/StarCraft II"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("真实 SC2 存储不存在,跳过")
        }
        var handle = CascBridge.CascStorageHandle.createLocal()
        let openError = handle.open(std.string(storagePath))
        guard openError == .None else {
            throw XCTSkip("存储打开失败: \(openError)")
        }
        defer { handle.close() }

        var listError = CascBridge.CascError.None
        let rawEntries = handle.listDirectory(std.string(""), &listError)
        XCTAssertEqual(listError, .None)
        var paths: [String] = []
        paths.reserveCapacity(rawEntries.size())
        for i in 0..<rawEntries.size() {
            paths.append(String(rawEntries[i].fullPath)
                .replacingOccurrences(of: "\\", with: "/"))
        }

        let provider = CascModelFileProvider(handle: handle, allPaths: paths)
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(
            path: "campaigns/liberty.sc2campaign/base.sc2assets/assets/campaign/terran/artifact1/artifact1.m3",
            format: .m3)
        XCTAssertGreaterThan(scene.materials.count, 0)
        // 回归:WhiteoutLib 对真实 M3 的 CHAR ref 会带结尾 NUL,桥内必须清除,
        // 否则 assets 索引查找永不命中(此用例在修复前失败)
        XCTAssertNotNil(scene.materials[0].diffuseTexture,
                        "主材质纹理应经跨 mod 索引解析并解码成功")
    }

    /// 真实存储 + 离屏渲染验证:artifact1 的渲染结果不应近黑
    /// (SC2 纹理 alpha 是遮罩非透明度,若被当透明度处理会渲染成近黑色)。
    /// 渲染 PNG 同时写到 /tmp/artifact_render.png 供人工查看。
    func testOffscreenRenderArtifact() async throws {
        let storagePath = "/Users/dev/Desktop/StarCraft II"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("真实 SC2 存储不存在,跳过")
        }
        var handle = CascBridge.CascStorageHandle.createLocal()
        guard handle.open(std.string(storagePath)) == .None else {
            throw XCTSkip("存储打开失败")
        }
        defer { handle.close() }

        var listError = CascBridge.CascError.None
        let rawEntries = handle.listDirectory(std.string(""), &listError)
        var paths: [String] = []
        paths.reserveCapacity(rawEntries.size())
        for i in 0..<rawEntries.size() {
            paths.append(String(rawEntries[i].fullPath)
                .replacingOccurrences(of: "\\", with: "/"))
        }
        let provider = CascModelFileProvider(handle: handle, allPaths: paths)
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(
            path: "campaigns/liberty.sc2campaign/base.sc2assets/assets/campaign/terran/artifact1/artifact1.m3",
            format: .m3)

        let built = ModelSceneBuilder.build(scene)
        let scnScene = SCNScene()
        scnScene.rootNode.addChildNode(built.rootNode)
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let size = scene.boundsMax - scene.boundsMin
        let center = (scene.boundsMax + scene.boundsMin) / 2
        let radius = max(simd_length(size) / 2, 0.001)
        cameraNode.position = SCNVector3(center.x, center.y, center.z + radius * 3)
        scnScene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scnScene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512),
                                      antialiasingMode: .none)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("离屏渲染产物转换失败")
            return
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/artifact_render.png"))

        // 亮度统计:修复前因 alpha 当透明度,模型区近黑
        guard let cg = rep.cgImage else { XCTFail("无 cgImage"); return }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { XCTFail("上下文创建失败"); return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0, maxLum = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let lum = (Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])) / 3
            sum += lum
            maxLum = max(maxLum, lum)
        }
        let mean = sum / (w * h)
        print("RENDER mean=\(mean) max=\(maxLum)")
        // artifact1 的 diffuse 本身就是近黑深蓝纹(diffuse-only 渲染 max≈33);
        // alpha 修复前因透明化处理整片近黑(max=4)。阈值取 20 作为回归信号。
        XCTAssertGreaterThan(maxLum, 20, "渲染近黑(max=\(maxLum)),纹理 alpha 可能被误作透明度")
    }
}
