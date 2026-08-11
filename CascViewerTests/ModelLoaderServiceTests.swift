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
        scnScene.background.contents = NSColor(white: 0.1, alpha: 1)  // 不透明背景,避免 additive 合成伪影
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let size = scene.boundsMax - scene.boundsMin
        let center = ModelSceneBuilder.visualCenter(of: scene)
        let radius = max(simd_length(size) / 2, 0.001)
        cameraNode.position = SCNVector3(center.x, center.y + radius * 0.4,
                                         center.z - radius * 2.5)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
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

    /// 蒙皮正确性验证(SC2 在本机存在才运行):
    /// rest 姿态的蒙皮渲染必须与无蒙皮(绑定空间)渲染几乎一致——
    /// 因为 boneWorld(rest) * inverseBind 应等于单位阵。同时导出 Stand 动画中段渲染。
    func testZealotSkinnedRestMatchesUnskinned() async throws {
        let storagePath = "/Users/dev/Desktop/StarCraft II"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("真实 SC2 存储不存在,跳过")
        }
        var handle = CascBridge.CascStorageHandle.createLocal()
        guard handle.open(std.string(storagePath)) == .None else { throw XCTSkip("存储打开失败") }
        defer { handle.close() }
        var listError = CascBridge.CascError.None
        let rawEntries = handle.listDirectory(std.string(""), &listError)
        var paths: [String] = []
        paths.reserveCapacity(rawEntries.size())
        for i in 0..<rawEntries.size() {
            paths.append(String(rawEntries[i].fullPath).replacingOccurrences(of: "\\", with: "/"))
        }
        let provider = CascModelFileProvider(handle: handle, allPaths: paths)
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(
            path: "mods/liberty.sc2mod/base.sc2assets/assets/units/protoss/zealot/zealot.m3",
            format: .m3)

        // 渲染辅助:把节点包装成场景、按包围盒取景、离屏渲染,返回 RGBA 字节并写 PNG
        func render(_ root: SCNNode, _ file: String) throws -> [UInt8] {
            let zs = SCNScene()
            zs.rootNode.addChildNode(root)
            zs.background.contents = NSColor(white: 0.1, alpha: 1)  // 不透明背景,避免 additive 合成伪影
            let zcam = SCNNode()
            zcam.camera = SCNCamera()
            let zsize = scene.boundsMax - scene.boundsMin
            let zcenter = ModelSceneBuilder.visualCenter(of: scene)
            let zradius = max(simd_length(zsize) / 2, 0.001)
            zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.4,
                                       zcenter.z - zradius * 2.5)
            zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
            zs.rootNode.addChildNode(zcam)
            let zr = SCNRenderer(device: nil, options: nil)
            zr.scene = zs
            zr.pointOfView = zcam
            let img = zr.snapshot(atTime: 0, with: CGSize(width: 512, height: 512),
                                  antialiasingMode: .none)
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("渲染产物转换失败")
                return []
            }
            try png.write(to: URL(fileURLWithPath: file))
            guard let cg = rep.cgImage else { return [] }
            let w = cg.width, h = cg.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return [] }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }

        // 1. 无蒙皮(绑定空间)渲染:单独构建一份并剥掉 skinner
        let builtUnskinned = ModelSceneBuilder.build(scene)
        for child in builtUnskinned.rootNode.childNodes where child.geometry != nil {
            child.skinner = nil
        }
        let unskinned = try render(builtUnskinned.rootNode, "/tmp/zealot_unskinned.png")

        // 2. 蒙皮 + rest 姿态渲染(应≈无蒙皮)
        let built = ModelSceneBuilder.build(scene)
        let skinnedRest = try render(built.rootNode, "/tmp/zealot_skinned_rest.png")

        // 3. 蒙皮 + Stand 多个时间点渲染(动画装配与动态检查,人工看 PNG)
        let player = ModelAnimationPlayer(scene: scene, built: built)
        let standIndex = scene.animations.firstIndex(where: { $0.name == "Stand" }) ?? 0
        player.selectAnimation(index: standIndex)
        for (t, file) in [(Float(500), "/tmp/zealot_anim_t500.png"),
                          (Float(1500), "/tmp/zealot_anim_t1500.png"),
                          (Float(3000), "/tmp/zealot_anim_t3000.png")] {
            player.update(timeMs: t)
            _ = try render(built.rootNode, file)
        }

        // 4. 侧面近景(检查腿脚姿态)
        do {
            player.update(timeMs: 1500)
            let zs = SCNScene()
            zs.rootNode.addChildNode(built.rootNode)
            let zcam = SCNNode()
            zcam.camera = SCNCamera()
            let zsize = scene.boundsMax - scene.boundsMin
            let zcenter = ModelSceneBuilder.visualCenter(of: scene)
            let zradius = max(simd_length(zsize) / 2, 0.001)
            // 侧面 + 稍低机位,距离拉近
            zcam.position = SCNVector3(zcenter.x + zradius * 1.8,
                                       zcenter.y + zradius * 0.3,
                                       zcenter.z - zradius * 0.6)
            zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
            zs.rootNode.addChildNode(zcam)
            let zr = SCNRenderer(device: nil, options: nil)
            zr.scene = zs
            zr.pointOfView = zcam
            let img = zr.snapshot(atTime: 0, with: CGSize(width: 512, height: 512),
                                  antialiasingMode: .none)
            if let t = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: t),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/zealot_side.png"))
            }
        }

        // rest 蒙皮 ≈ 无蒙皮:逐像素平均差应很小
        XCTAssertEqual(unskinned.count, skinnedRest.count)
        guard !unskinned.isEmpty, unskinned.count == skinnedRest.count else { return }
        var diffSum = 0
        for i in 0..<unskinned.count {
            diffSum += abs(Int(unskinned[i]) - Int(skinnedRest[i]))
        }
        let meanDiff = Double(diffSum) / Double(unskinned.count)
        print("SKIN meanPixelDiff=\(meanDiff)")
        XCTAssertLessThan(meanDiff, 3.0,
                          "rest 蒙皮渲染与绑定空间渲染差异过大(\(meanDiff)),inverseBind 不正确")
    }

    /// 多 region 模型的网格完整性验证(zealot_golden_death 有 8 个 region,
    /// M3 面下标是 region 局部索引,修复前 region≥1 的网格全是乱三角形)。
    func testGoldenDeathRender() async throws {
        let storagePath = "/Users/dev/Desktop/StarCraft II"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("真实 SC2 存储不存在,跳过")
        }
        var handle = CascBridge.CascStorageHandle.createLocal()
        guard handle.open(std.string(storagePath)) == .None else { throw XCTSkip("存储打开失败") }
        defer { handle.close() }
        var listError = CascBridge.CascError.None
        let rawEntries = handle.listDirectory(std.string(""), &listError)
        var paths: [String] = []
        paths.reserveCapacity(rawEntries.size())
        for i in 0..<rawEntries.size() {
            paths.append(String(rawEntries[i].fullPath).replacingOccurrences(of: "\\", with: "/"))
        }
        let provider = CascModelFileProvider(handle: handle, allPaths: paths)
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(
            path: "mods/liberty.sc2mod/base.sc2assets/assets/units/protoss/zealot_golden_death/zealot_golden_death.m3",
            format: .m3)
        // 8 个 region 中 1 个是 Displacement(地面压平)材质,不可渲染已跳过
        XCTAssertEqual(scene.meshes.count, 7)
        // 修复前 region≥1 的索引会下溢成巨大值;此处直接断言索引界内
        for (mi, mesh) in scene.meshes.enumerated() {
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.positions.count },
                          "mesh[\(mi)] 索引越界")
        }
        // 离屏渲染存档(人工查看)
        let built = ModelSceneBuilder.build(scene)
        let zs = SCNScene()
        zs.rootNode.addChildNode(built.rootNode)
        // 必须不透明背景:snapshot 在透明背景下 additive 混合会因 alpha
        // 累积产生纯黑像素(合成伪影),与真实 SCNView 表现不符
        zs.background.contents = NSColor(white: 0.1, alpha: 1)
        let zcam = SCNNode()
        zcam.camera = SCNCamera()
        let zsize = scene.boundsMax - scene.boundsMin
        let zcenter = ModelSceneBuilder.visualCenter(of: scene)
        let zradius = max(simd_length(zsize) / 2, 0.001)
        zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.4,
                                   zcenter.z - zradius * 2.5)
        zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
        zs.rootNode.addChildNode(zcam)
        let zr = SCNRenderer(device: nil, options: nil)
        zr.scene = zs
        zr.pointOfView = zcam
        let img = zr.snapshot(atTime: 0, with: CGSize(width: 512, height: 512),
                              antialiasingMode: .none)
        if let t = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: t),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/golden_death_render.png"))
        }
    }
}
