import XCTest
import SceneKit
@testable import CascViewer

final class ModelSceneBuilderTests: XCTestCase {

    private func makeScene() -> ModelScene {
        // 与 WOEncodeTestMDX 夹具同构:1 三角形 / 2 骨骼 / 1 材质
        let mesh = ModelScene.Mesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
            indices: [0, 1, 2],
            boneIndices: [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0)],
            boneWeights: [SIMD4(255, 0, 0, 0), SIMD4(255, 0, 0, 0), SIMD4(255, 0, 0, 0)],
            materialIndex: 0
        )
        let material = ModelScene.Material(
            texturePath: "", textureFileDataId: 0, blendMode: .opaque,
            twoSided: false, unlit: false, diffuseTexture: nil
        )
        let bone0 = ModelScene.Bone(
            name: "root", parentIndex: -1, pivot: .zero,
            inverseBind: matrix_identity_float4x4,
            restTranslation: .zero, restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            restScale: SIMD3(1, 1, 1)
        )
        let bone1 = ModelScene.Bone(
            name: "child", parentIndex: 0, pivot: SIMD3(0, 0, 1),
            inverseBind: matrix_identity_float4x4,
            restTranslation: .zero, restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            restScale: SIMD3(1, 1, 1)
        )
        return ModelScene(
            name: "t", format: .mdx, meshes: [mesh], materials: [material],
            bones: [bone0, bone1], animations: [],
            boundsMin: .zero, boundsMax: SIMD3(1, 1, 1)
        )
    }

    func testBuildStructure() {
        let built = ModelSceneBuilder.build(makeScene())
        XCTAssertEqual(built.boneNodes.count, 2)
        // 骨骼树根是 root 的直接子节点,child 骨骼挂在它下面
        let boneRoot = built.rootNode.childNodes.first { $0.name == "root" }
        XCTAssertNotNil(boneRoot)
        XCTAssertEqual(boneRoot?.childNodes.first?.name, "child")
        // 网格节点与骨骼树平级,直接挂 root(蒙皮网格的标准结构)
        let geometryNodes = built.rootNode.childNodes.filter { $0.geometry != nil }
        XCTAssertEqual(geometryNodes.count, 1)
        let skinner = geometryNodes[0].skinner
        XCTAssertNotNil(skinner)
        XCTAssertEqual(skinner?.bones.count, 2)
        XCTAssertEqual(skinner?.boneInverseBindTransforms?.count, 2)
        XCTAssertTrue(skinner?.skeleton === built.rootNode)
    }

    func testVertexPayloadRoundTrip() {
        let built = ModelSceneBuilder.build(makeScene())
        let geometryNode = built.rootNode.childNodes.first { $0.geometry != nil }!
        let geometry = geometryNode.geometry!

        func float3(at index: Int, in source: SCNGeometrySource) -> (Float, Float, Float) {
            let base = source.dataOffset + index * source.dataStride
            return source.data.withUnsafeBytes { ptr in
                let x = ptr.loadUnaligned(fromByteOffset: base, as: Float.self)
                let y = ptr.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                let z = ptr.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                return (x, y, z)
            }
        }

        // 位置源:读回应与夹具输入 (0,0,0) (1,0,0) (0,1,0) 完全一致
        let vertexSource = geometry.sources(for: .vertex).first!
        let expectedPositions: [(Float, Float, Float)] = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        XCTAssertEqual(vertexSource.vectorCount, expectedPositions.count)
        for (i, expected) in expectedPositions.enumerated() {
            let v = float3(at: i, in: vertexSource)
            XCTAssertEqual(v.0, expected.0, "vertex \(i).x")
            XCTAssertEqual(v.1, expected.1, "vertex \(i).y")
            XCTAssertEqual(v.2, expected.2, "vertex \(i).z")
        }

        // 法线源:全 (0,0,1)
        let normalSource = geometry.sources(for: .normal).first!
        XCTAssertEqual(normalSource.vectorCount, 3)
        for i in 0..<3 {
            let n = float3(at: i, in: normalSource)
            XCTAssertEqual(n.0, 0, "normal \(i).x")
            XCTAssertEqual(n.1, 0, "normal \(i).y")
            XCTAssertEqual(n.2, 1, "normal \(i).z")
        }
    }

    func testMaterialMapping() {
        let built = ModelSceneBuilder.build(makeScene())
        let geometryNode = built.rootNode.childNodes.first { $0.geometry != nil }!
        let material = geometryNode.geometry!.firstMaterial!
        XCTAssertFalse(material.isDoubleSided)
        XCTAssertEqual(material.lightingModel, .blinn)   // 非 unlit
    }

    /// 混合模式的占位色:blend 无贴图必须透明(视频水面等覆盖层否则成灰板)
    func testBlendPlaceholderIsTransparent() {
        var scene = makeScene()
        scene.materials[0].blendMode = .blend
        let built = ModelSceneBuilder.build(scene)
        let mat = built.rootNode.childNodes.first { $0.geometry != nil }!.geometry!.firstMaterial!
        XCTAssertEqual(mat.blendMode, .alpha)
        XCTAssertEqual((mat.diffuse.contents as? NSColor)?.alphaComponent ?? 1, 0)
    }

    func testBuildFiltersHiddenMaterialTypes() {
        var scene = makeScene()
        var extra = scene.meshes[0]
        extra.materialType = 2  // Displacement
        scene.meshes.append(extra)
        let unfiltered = ModelSceneBuilder.build(scene)
        XCTAssertEqual(unfiltered.rootNode.childNodes.filter { $0.geometry != nil }.count, 2)
        let filtered = ModelSceneBuilder.build(scene, hiddenMaterialTypes: [2])
        XCTAssertEqual(filtered.rootNode.childNodes.filter { $0.geometry != nil }.count, 1)
    }

    /// 取景范围按可见网格顶点计算,而非头部包围盒(头部常含特效范围,模型显小);
    /// 隐藏类型的网格不参与;无网格时回退头部包围盒
    func testFramingBounds() {
        var scene = makeScene()  // 1 三角形,顶点 (0,0,0) (1,0,0) (0,1,0)
        // 头部包围盒故意放大,不应影响取景
        scene.boundsMin = SIMD3(-10, -10, -10)
        scene.boundsMax = SIMD3(10, 10, 10)
        let (c0, r0) = ModelSceneBuilder.framingBounds(of: scene)
        // 网格范围 (0,0,0)-(1,1,0),中心 (0.5,0.5,0) 经 -90°X 旋转 → (0.5,0,-0.5)
        XCTAssertEqual(c0.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(c0.y, 0, accuracy: 1e-6)
        XCTAssertEqual(c0.z, -0.5, accuracy: 1e-6)
        XCTAssertEqual(r0, sqrt(2) / 2, accuracy: 1e-6)

        // 加一个 materialType=2 的远处网格:默认参与取景;隐藏后回到原范围
        var far = scene.meshes[0]
        far.materialType = 2
        far.positions = far.positions.map { $0 + SIMD3<Float>(100, 0, 0) }
        scene.meshes.append(far)
        let (_, rFar) = ModelSceneBuilder.framingBounds(of: scene)
        XCTAssertGreaterThan(rFar, 10)
        let (_, rHidden) = ModelSceneBuilder.framingBounds(of: scene, hiddenMaterialTypes: [2])
        XCTAssertEqual(rHidden, sqrt(2) / 2, accuracy: 1e-6)

        // 无网格场景:回退头部包围盒
        scene.meshes = []
        let (_, rEmpty) = ModelSceneBuilder.framingBounds(of: scene)
        XCTAssertEqual(rEmpty, simd_length(SIMD3<Float>(20, 20, 20)) / 2, accuracy: 1e-4)
    }
}

@MainActor
final class ModelViewerViewModelTests: XCTestCase {

    private func makeScene() -> ModelScene {
        let mesh = ModelScene.Mesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
            indices: [0, 1, 2],
            boneIndices: [], boneWeights: [],
            materialIndex: 0
        )
        let material = ModelScene.Material(
            texturePath: "", textureFileDataId: 0, blendMode: .opaque,
            twoSided: false, unlit: false, diffuseTexture: nil
        )
        return ModelScene(
            name: "t", format: .m3, meshes: [mesh], materials: [material],
            bones: [], animations: [],
            boundsMin: .zero, boundsMax: SIMD3(1, 1, 1)
        )
    }

    /// 重建后:场景被替换、隐藏类型不再有几何节点、相机节点复用(保留用户视角)
    func testRebuildSwapsSceneKeepsCameraAndFilters() {
        let vm = ModelViewerViewModel()
        let scene = makeScene()
        vm.setup(scene: scene, built: ModelSceneBuilder.build(scene))
        let camera = vm.cameraNode
        XCTAssertNotNil(camera)
        // 隐藏唯一网格的类型(1),重建后场景中不应再有几何节点
        vm.rebuild(with: ModelSceneBuilder.build(scene, hiddenMaterialTypes: [1]))
        XCTAssertTrue(vm.cameraNode === camera)
        XCTAssertTrue(vm.scnScene.rootNode.childNodes.contains { $0 === camera })
        var geoCount = 0
        vm.scnScene.rootNode.enumerateChildNodes { node, _ in
            if node.geometry != nil { geoCount += 1 }
        }
        XCTAssertEqual(geoCount, 0)
    }
}
