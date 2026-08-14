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
        let (center, radius) = ModelSceneBuilder.framingBounds(
            of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        cameraNode.position = SCNVector3(center.x, center.y + radius * 0.4,
                                         center.z + radius * 2.5)
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
            let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
                of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
            zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.4,
                                       zcenter.z + zradius * 2.5)
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
            let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
                of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
            // 侧面 + 稍低机位,距离拉近
            zcam.position = SCNVector3(zcenter.x + zradius * 1.8,
                                       zcenter.y + zradius * 0.3,
                                       zcenter.z + zradius * 0.6)
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
        // loader 全量加载所有 region;region[5] 是 Displacement(type=2),其余为 Standard(type=1)。
        // 可见性过滤在构建期(ModelSceneBuilder)进行,不在 loader。
        XCTAssertEqual(scene.meshes.count, 8)
        XCTAssertEqual(scene.meshes.map(\.materialType), [1, 1, 1, 1, 1, 2, 1, 1])
        // 修复前 region≥1 的索引会下溢成巨大值;此处直接断言索引界内
        for (mi, mesh) in scene.meshes.enumerated() {
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.positions.count },
                          "mesh[\(mi)] 索引越界")
        }
        // 离屏渲染存档(人工查看);按默认隐藏集过滤,存档图不含 Displacement 网格
        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        // 默认隐藏集下 Displacement 网格被过滤:8 region → 7 个几何节点
        XCTAssertEqual(built.rootNode.childNodes.filter { $0.geometry != nil }.count, 7)
        let zs = SCNScene()
        zs.rootNode.addChildNode(built.rootNode)
        // 必须不透明背景:snapshot 在透明背景下 additive 混合会因 alpha
        // 累积产生纯黑像素(合成伪影),与真实 SCNView 表现不符
        zs.background.contents = NSColor(white: 0.1, alpha: 1)
        let zcam = SCNNode()
        zcam.camera = SCNCamera()
        let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
            of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.4,
                                   zcenter.z + zradius * 2.5)
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

    /// m3a 基础模型候选路径推导(HotS 命名规则)
    func testBaseModelCandidates() {
        let c1 = ModelLoaderService.baseModelCandidates(
            for: "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_orphea_facialanims/storm_hero_orphea_facialanims.m3a")
        XCTAssertEqual(c1, [
            "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_orphea/storm_hero_orphea.m3",
            "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_orphea_base/storm_hero_orphea_base.m3",
        ])
        let c2 = ModelLoaderService.baseModelCandidates(
            for: "a/b/storm_hero_orphea_school18_requiredanims/storm_hero_orphea_school18_requiredanims.m3a")
        XCTAssertEqual(c2, [
            "a/b/storm_hero_orphea_school18/storm_hero_orphea_school18.m3",
            "a/b/storm_hero_orphea_school18_base/storm_hero_orphea_school18_base.m3",
        ])
        XCTAssertTrue(ModelLoaderService.baseModelCandidates(for: "noslash.m3a").isEmpty)
    }

    /// 动画库轨道按骨骼名重映射到目标骨架;无名骨骼给空轨道(播放保持 rest)
    func testRemapAnimationByBoneName() {
        func bone(_ name: String) -> ModelScene.Bone {
            ModelScene.Bone(name: name, parentIndex: -1, pivot: .zero,
                            inverseBind: matrix_identity_float4x4,
                            restTranslation: .zero,
                            restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                            restScale: SIMD3(1, 1, 1))
        }
        func track(_ x: Float) -> ModelScene.Vec3Track {
            ModelScene.Vec3Track(interp: .linear, times: [0, 100],
                                 keys: [SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0)],
                                 inTangents: [], outTangents: [])
        }
        let quat = ModelScene.QuatTrack(interp: .constant, times: [], keys: [],
                                        inTangents: [], outTangents: [])
        // 源骨架 a,b;位移轨道 a→10、b→20;缩放轨道 a→30、b→40
        let anim = ModelScene.Animation(
            name: "Test", durationMs: 100, loops: true,
            translations: [track(10), track(20)],
            rotations: [quat, quat],
            scales: [track(30), track(40)])
        let remapped = ModelLoaderService.remapAnimation(
            anim, from: [bone("a"), bone("b")], to: [bone("b"), bone("a"), bone("c")])
        XCTAssertEqual(remapped.translations.count, 3)
        XCTAssertEqual(remapped.translations[0].keys.first?.x, 20)  // b ← 源 b
        XCTAssertEqual(remapped.translations[1].keys.first?.x, 10)  // a ← 源 a
        XCTAssertTrue(remapped.translations[2].times.isEmpty)       // c 无对应骨骼
        XCTAssertEqual(remapped.scales[1].keys.first?.x, 30)
        XCTAssertEqual(remapped.name, "Test")
        XCTAssertEqual(remapped.durationMs, 100)
    }

    /// m3a 增强:自动加载同命名基础模型网格,动画按骨骼名映射(orphea 表情库)
    func testOrpheaFacialAnimsMerge() async throws {
        let storagePath = "<hots-storage>"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("HotS 存储不存在,跳过")
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
        let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)
        let service = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        let scene = try await service.load(
            path: "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_orphea_facialanims/storm_hero_orphea_facialanims.m3a",
            format: .m3)
        // 网格与骨架来自基础模型 storm_hero_orphea_base.m3
        XCTAssertFalse(scene.meshes.isEmpty)
        // 动画列表只含 m3a 的 11 组表情
        XCTAssertEqual(scene.animations.count, 11)
        XCTAssertTrue(scene.animations.contains { $0.name == "HappyEyes" })
        // 骨骼名映射成功:至少存在非空轨道
        XCTAssertTrue(scene.animations.contains { anim in
            anim.rotations.contains { !$0.times.isEmpty }
                || anim.translations.contains { !$0.times.isEmpty }
        })
        // 离屏渲染存档:rest + 应用 HappyEyes 中间帧各一张
        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        let zs = SCNScene()
        zs.rootNode.addChildNode(built.rootNode)
        zs.background.contents = NSColor(white: 0.1, alpha: 1)
        let zcam = SCNNode()
        zcam.camera = SCNCamera()
        let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
            of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.2,
                                   zcenter.z + zradius * 2.2)
        zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
        zs.rootNode.addChildNode(zcam)
        let zr = SCNRenderer(device: nil, options: nil)
        zr.scene = zs
        zr.pointOfView = zcam
        func snap(_ file: String) throws {
            let img = zr.snapshot(atTime: 0, with: CGSize(width: 640, height: 640),
                                  antialiasingMode: .none)
            if let tif = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tif),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: file))
            }
        }
        try snap("/tmp/orphea_facial_rest.png")
        let player = ModelAnimationPlayer(scene: scene, built: built)
        if let idx = scene.animations.firstIndex(where: { $0.name == "HappyEyes" }) {
            player.selectAnimation(index: idx)
            player.update(timeMs: 16)
            try snap("/tmp/orphea_facial_happy.png")
        }
    }

    /// assets 索引构建:键为 assets 段起的小写路径,大小写不敏感
    func testBuildAssetsIndex() {
        let index = CascModelFileProvider.buildAssetsIndex(fromPaths: [
            "mods/a.sc2mod/base.sc2assets/Assets/Textures/Foo.dds",
            "mods/b.sc2mod/base.sc2assets/assets/textures/bar.dds",
            "noassets/x.txt",
        ])
        XCTAssertEqual(index["assets/textures/foo.dds"],
                       "mods/a.sc2mod/base.sc2assets/Assets/Textures/Foo.dds")
        XCTAssertEqual(index["assets/textures/bar.dds"],
                       "mods/b.sc2mod/base.sc2assets/assets/textures/bar.dds")
        XCTAssertNil(index["x.txt"])
    }

    /// 性能回归:大存储(HotS,1.6M 路径)上的模型打开耗时有界。
    /// 2026-08 排查:转换阶段因桥接 C++ vector 逐访问整体拷贝耗 56s、
    /// assets 索引每次打开重建 16s、纹理串行解码 9.4s;
    /// 修复后首次加载 ~3.7s、共享索引后二次加载 ~0.5s。取宽松上界防回归。
    func testHotSModelLoadPerformance() async throws {
        let storagePath = "<hots-storage>"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("HotS 存储不存在,跳过")
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
        // 镜像 app 流程:assets 索引只建一次,跨模型打开共享
        let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)
        let modelPath = "mods/heroes.stormmod/zhcn.stormassets/assets/buildings/"
            + "storm_building_kingscrest_core_ravenlord_death/"
            + "storm_building_kingscrest_core_ravenlord_death.m3"

        var t0 = Date()
        let service1 = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        let scene = try await service1.load(path: modelPath, format: .m3)
        let firstLoad = Date().timeIntervalSince(t0)
        print("PERF first load: \(firstLoad)s meshes=\(scene.meshes.count) mats=\(scene.materials.count)")

        // 第二次打开(新 provider 共享索引):不应再有索引构建开销
        t0 = Date()
        let service2 = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        _ = try await service2.load(path: modelPath, format: .m3)
        let secondLoad = Date().timeIntervalSince(t0)
        print("PERF second load: \(secondLoad)s")

        XCTAssertEqual(scene.meshes.count, 6)
        XCTAssertLessThan(firstLoad, 30, "首次加载耗时回归(修复前 ~79s)")
        XCTAssertLessThan(secondLoad, 30, "二次加载耗时回归")
    }

    /// HotS nova_widow 渲染回归:REGN v5 每 region UV 缩放/偏移 + LAYR wrap 标志。
    /// 修复前 UV 越界(绝对值 ~15),clamp 采样边缘像素,整模型涂成暗色带。
    func testNovaWidowRender() async throws {
        let storagePath = "<hots-storage>"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("HotS 存储不存在,跳过")
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
        let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)
        let service = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        let scene = try await service.load(
            path: "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_nova_widow/storm_hero_nova_widow_v05.m3",
            format: .m3)

        // M3 LAYR wrap 标志必须透传:该模型 UV 越界平铺,clamp 会采样边缘像素导致颜色异常
        XCTAssertTrue(scene.materials[0].wrapU)
        XCTAssertTrue(scene.materials[0].wrapV)

        // UV 回归:修复前 region 未应用 uvScale/uvOffset,原始值绝对值达 ~15;
        // 修复后应落在合理平铺范围内(本模型实测 |u|≤2,|v|≤1.1)
        for (mi, mesh) in scene.meshes.enumerated() {
            for (vi, uv) in mesh.uvs.enumerated() {
                XCTAssertLessThanOrEqual(abs(uv.x), 4, "mesh[\(mi)] uv[\(vi)].u 越界 \(uv.x)")
                XCTAssertLessThanOrEqual(abs(uv.y), 4, "mesh[\(mi)] uv[\(vi)].v 越界 \(uv.y)")
            }
        }
        // 纹理应成功解析(校验渲染有真贴图而非占位色)
        XCTAssertNotNil(scene.materials[0].diffuseTexture)

        func render(_ built: BuiltModelScene, _ file: String) throws {
            let zs = SCNScene()
            zs.rootNode.addChildNode(built.rootNode)
            zs.background.contents = NSColor(white: 0.1, alpha: 1)
            let zcam = SCNNode()
            zcam.camera = SCNCamera()
            let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
                of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
            // 模型正面朝 +Z(以 nova 实测验证),相机放 +Z 一侧看正面
            zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.2,
                                       zcenter.z + zradius * 2.2)
            zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
            zs.rootNode.addChildNode(zcam)
            let zr = SCNRenderer(device: nil, options: nil)
            zr.scene = zs
            zr.pointOfView = zcam
            let img = zr.snapshot(atTime: 0, with: CGSize(width: 640, height: 640),
                                  antialiasingMode: .none)
            if let t = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: t),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: file))
            }
        }

        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        try render(built, "/tmp/nova_lit.png")

        // unlit 版本:所有材质强制 constant 光照,显示纯贴图颜色
        let built2 = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        built2.rootNode.enumerateChildNodes { node, _ in
            if let geo = node.geometry {
                for m in geo.materials { m.lightingModel = .constant }
            }
        }
        try render(built2, "/tmp/nova_unlit.png")
    }

    /// orphea 死亡布娃娃回归:Composite 材质取子材质贴图 + 全 Composite 模型可渲染。
    /// 修复前 Composite 无贴图(占位灰);且用户侧若隐藏 Composite 会整个模型消失。
    func testOrpheaRagdollRender() async throws {
        let storagePath = "<hots-storage>"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("HotS 存储不存在,跳过")
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
        let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)
        let service = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        let scene = try await service.load(
            path: "mods/heroes.stormmod/base.stormassets/assets/units/heroes/storm_hero_orphea_base_deathragdoll/storm_hero_orphea_base_deathragdoll.m3",
            format: .m3)
        // 两个 region 都是 Composite(type=3);贴图应来自其子材质 Mat_Dissolve
        XCTAssertEqual(scene.meshes.count, 2)
        XCTAssertEqual(scene.meshes.map(\.materialType), [3, 3])
        let compMat = scene.materials[scene.meshes[0].materialIndex]
        XCTAssertTrue(compMat.texturePath.hasSuffix("Storm_Hero_Orphea_Base_Diff.dds"))
        XCTAssertTrue(compMat.wrapU && compMat.wrapV)
        XCTAssertNotNil(compMat.diffuseTexture)
        // 离屏渲染存档(人工查看)
        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        let zs = SCNScene()
        zs.rootNode.addChildNode(built.rootNode)
        zs.background.contents = NSColor(white: 0.1, alpha: 1)
        let zcam = SCNNode()
        zcam.camera = SCNCamera()
        let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
            of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.2,
                                   zcenter.z + zradius * 2.2)
        zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
        zs.rootNode.addChildNode(zcam)
        let zr = SCNRenderer(device: nil, options: nil)
        zr.scene = zs
        zr.pointOfView = zcam
        let img = zr.snapshot(atTime: 0, with: CGSize(width: 640, height: 640),
                              antialiasingMode: .none)
        if let tif = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tif),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/orphea_ragdoll.png"))
        }
    }

    /// HotS terrain object 顶点自愈回归:MODL 顶点标志与实际布局不符时,
    /// 按标志算的 stride 不能整除数据块(7596B % 32 = 12),补 VertexColor 位后
    /// 7596/36 = 211 恰等于 region 顶点数;修复前近半顶点 NaN、几何错乱。
    /// Terrain 材质本身不含贴图路径(地形贴图由地图贴图集运行时指定)。
    func testJungleDoodadVertexRepair() async throws {
        let storagePath = "<hots-storage>"
        guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else {
            throw XCTSkip("HotS 存储不存在,跳过")
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
        let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)
        let service = ModelLoaderService(
            provider: CascModelFileProvider(handle: handle, assetsIndex: assetsIndex))
        let scene = try await service.load(
            path: "mods/heroes.stormmod/base.stormassets/assets/terrainobjects/storm_doodad_hell1_jungle_a_to/storm_doodad_hell1_jungle_a_to.m3",
            format: .m3)
        XCTAssertEqual(scene.meshes.count, 1)
        XCTAssertEqual(scene.meshes[0].positions.count, 211)
        XCTAssertFalse(scene.meshes[0].positions.contains { $0.x.isNaN || $0.y.isNaN || $0.z.isNaN },
                       "顶点仍含 NaN,stride 自愈未生效")
        XCTAssertEqual(scene.meshes[0].materialType, 4)  // Terrain
        let mat = scene.materials[scene.meshes[0].materialIndex]
        // 该文件的 Terrain 材质不含贴图路径(全文无 .dds 引用):
        // 地形贴图由地图的贴图集在运行时指定,文件内本就没有 —— 白膜是数据使然
        XCTAssertTrue(mat.texturePath.isEmpty)
        // 离屏渲染存档(人工查看)
        let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        let zs = SCNScene()
        zs.rootNode.addChildNode(built.rootNode)
        zs.background.contents = NSColor(white: 0.1, alpha: 1)
        let zcam = SCNNode()
        zcam.camera = SCNCamera()
        let (zcenter, zradius) = ModelSceneBuilder.framingBounds(
            of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
        zcam.position = SCNVector3(zcenter.x, zcenter.y + zradius * 0.2,
                                   zcenter.z + zradius * 2.2)
        zcam.look(at: SCNVector3(zcenter.x, zcenter.y, zcenter.z))
        zs.rootNode.addChildNode(zcam)
        let zr = SCNRenderer(device: nil, options: nil)
        zr.scene = zs
        zr.pointOfView = zcam
        let img = zr.snapshot(atTime: 0, with: CGSize(width: 640, height: 640),
                              antialiasingMode: .none)
        if let tif = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tif),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/jungle_doodad.png"))
        }
    }

    /// war3 shrine 回归:Composite 材质的子材质是 .ogv 视频(不可解码),
    /// 修复前继承默认 opaque → 大灰板;现在继承子材质的 blend 模式,占位透明
    func testWar3ShrineCompositeBlend() async throws {
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
            path: "mods/war3.sc2mod/base.sc2assets/assets/buildings/naga/war3_shrineofashjara/war3_shrineofashjara.m3",
            format: .m3)
        // region[3] 是 Composite(materialMaps[3]);其子材质 Mat 引用 .ogv 视频贴图
        let compositeMeshes = scene.meshes.filter { $0.materialType == 3 }
        XCTAssertFalse(compositeMeshes.isEmpty)
        for mesh in compositeMeshes {
            let mat = scene.materials[mesh.materialIndex]
            XCTAssertTrue(mat.texturePath.hasSuffix(".ogv"), "应继承子材质的视频贴图路径")
            XCTAssertEqual(mat.blendMode, .blend, "应继承子材质的 AlphaBlend")
            XCTAssertNil(mat.diffuseTexture, "ogv 不可解码,纹理应为空(占位透明)")
        }
    }

    /// 批量巡检(仅当 /tmp/survey_enabled 存在时跑):两个存储按 assets 子目录分组抽样,
    /// 每个模型走完整管线 + 异常检测 + 离屏渲染原始 RGBA 落盘(/tmp/survey/NNN.rgba),
    /// 供人工拼图目检。不进常规套件(太慢)。
    func testModelSurvey() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/survey_enabled") else {
            throw XCTSkip("巡检模式未开启(touch /tmp/survey_enabled)")
        }
        try? FileManager.default.removeItem(atPath: "/tmp/survey")
        try FileManager.default.createDirectory(atPath: "/tmp/survey", withIntermediateDirectories: true)

        let storages: [(String, String)] = [
            ("SC2", "/Users/dev/Desktop/StarCraft II"),
            ("HotS", "<hots-storage>"),
        ]
        var seq = 0
        for (tag, storagePath) in storages {
            guard FileManager.default.fileExists(atPath: storagePath + "/.build.info") else { continue }
            var handle = CascBridge.CascStorageHandle.createLocal()
            guard handle.open(std.string(storagePath)) == .None else { continue }
            var listError = CascBridge.CascError.None
            let rawEntries = handle.listDirectory(std.string(""), &listError)
            var paths: [String] = []
            paths.reserveCapacity(rawEntries.size())
            for i in 0..<rawEntries.size() {
                paths.append(String(rawEntries[i].fullPath).replacingOccurrences(of: "\\", with: "/"))
            }
            let assetsIndex = CascModelFileProvider.buildAssetsIndex(fromPaths: paths)

            // 按 assets/ 下前两级目录分组,每组均匀抽至多 4 个
            func groupKey(_ p: String) -> String {
                guard let r = p.range(of: "/assets/", options: .caseInsensitive) else { return "" }
                let comps = p[r.upperBound...].split(separator: "/")
                return comps.prefix(2).joined(separator: "/")
            }
            var groups: [String: [String]] = [:]
            for p in paths where p.lowercased().hasSuffix(".m3") {
                groups[groupKey(p), default: []].append(p)
            }
            var sampled: [(String, String)] = []  // (group, path)
            for key in groups.keys.sorted() {
                let list = groups[key]!.sorted()
                let n = min(2, list.count)  // 每组 2 个,控制总时长
                for k in 0..<n {
                    sampled.append((key, list[k * list.count / n]))
                }
            }
            print("SURVEY \(tag): \(groups.count) 组,抽 \(sampled.count) 个")

            for (group, modelPath) in sampled {
                let provider = CascModelFileProvider(handle: handle, assetsIndex: assetsIndex)
                let service = ModelLoaderService(provider: provider)
                seq += 1
                guard let scene = try? await service.load(path: modelPath, format: .m3) else {
                    print("SURVEY \(seq) [\(tag) \(group)] \((modelPath as NSString).lastPathComponent) LOAD_FAIL")
                    continue
                }
                // 异常检测
                var flags: [String] = []
                var totalVerts = 0
                var hasNaN = false, idxOOB = false, uvBad = false
                for mesh in scene.meshes {
                    totalVerts += mesh.positions.count
                    for p in mesh.positions where !hasNaN {
                        if p.x.isNaN || p.y.isNaN || p.z.isNaN { hasNaN = true }
                    }
                    if mesh.indices.contains(where: { Int($0) >= mesh.positions.count }) { idxOOB = true }
                    for uv in mesh.uvs where !uvBad {
                        if abs(uv.x) > 4 || abs(uv.y) > 4 { uvBad = true }
                    }
                }
                if scene.meshes.isEmpty { flags.append("无网格") }
                if hasNaN { flags.append("NaN") }
                if idxOOB { flags.append("索引越界") }
                if uvBad { flags.append("UV越界") }
                let texMats = scene.materials.filter { !$0.texturePath.isEmpty }
                let texOK = texMats.filter { $0.diffuseTexture != nil }.count
                if !texMats.isEmpty && texOK * 2 < texMats.count { flags.append("贴图缺失多(\(texOK)/\(texMats.count))") }
                let (fc, fr) = ModelSceneBuilder.framingBounds(of: scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
                let headerDiag = simd_length(scene.boundsMax - scene.boundsMin)
                if headerDiag > fr * 2 * 3 { flags.append("头包围盒虚胖x\(String(format: "%.1f", headerDiag / max(fr * 2, 0.001)))") }

                // 渲染原始 RGBA 落盘
                let built = ModelSceneBuilder.build(scene, hiddenMaterialTypes: M3MaterialKind.defaultHidden)
                let zs = SCNScene()
                zs.rootNode.addChildNode(built.rootNode)
                zs.background.contents = NSColor(white: 0.1, alpha: 1)
                let zcam = SCNNode()
                zcam.camera = SCNCamera()
                zcam.position = SCNVector3(fc.x, fc.y + fr * 0.2, fc.z + fr * 2.2)
                zcam.look(at: SCNVector3(fc.x, fc.y, fc.z))
                zs.rootNode.addChildNode(zcam)
                let zr = SCNRenderer(device: nil, options: nil)
                zr.scene = zs
                zr.pointOfView = zcam
                let img = zr.snapshot(atTime: 0, with: CGSize(width: 400, height: 400),
                                      antialiasingMode: .none)
                if let tif = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tif),
                   let cg = rep.cgImage {
                    var buf = [UInt8](repeating: 0, count: 400 * 400 * 4)
                    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                    if let ctx = CGContext(data: &buf, width: 400, height: 400, bitsPerComponent: 8,
                                           bytesPerRow: 1600, space: cs,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 400, height: 400))
                        try? buf.withUnsafeBytes {
                            try? Data($0).write(to: URL(fileURLWithPath: String(format: "/tmp/survey/%03d.rgba", seq)))
                        }
                    }
                }
                print(String(format: "SURVEY %03d [%@ %@] %@ meshes=%d verts=%d tex=%d/%d %@",
                             seq, tag, group, (modelPath as NSString).lastPathComponent,
                             scene.meshes.count, totalVerts, texOK, texMats.count,
                             flags.joined(separator: ",")))
            }
            handle.close()
        }
        print("SURVEY 完成,共 \(seq) 个")
    }
}
