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
}
