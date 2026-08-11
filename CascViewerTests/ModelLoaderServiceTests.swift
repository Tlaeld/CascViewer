import XCTest
import CascBridge
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
}
