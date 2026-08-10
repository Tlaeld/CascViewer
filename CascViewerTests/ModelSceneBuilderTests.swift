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
        // 父子关系:child 挂在 root 下,root 挂在场景根下
        XCTAssertEqual(built.rootNode.childNodes.count, 1)
        XCTAssertEqual(built.rootNode.childNodes[0].childNodes.first?.name, "child")
        // 网格节点带几何与蒙皮器
        let geometryNodes = built.rootNode.childNodes.filter { $0.geometry != nil }
        // 网格直接挂场景根(不是骨骼下)
        XCTAssertEqual(geometryNodes.count, 1)
        let skinner = geometryNodes[0].skinner
        XCTAssertNotNil(skinner)
        XCTAssertEqual(skinner?.bones.count, 2)
        XCTAssertEqual(skinner?.boneInverseBindTransforms?.count, 2)
    }

    func testMaterialMapping() {
        let built = ModelSceneBuilder.build(makeScene())
        let geometryNode = built.rootNode.childNodes.first { $0.geometry != nil }!
        let material = geometryNode.geometry!.firstMaterial!
        XCTAssertFalse(material.isDoubleSided)
        XCTAssertEqual(material.lightingModel, .blinn)   // 非 unlit
    }
}
