import XCTest
import simd
@testable import CascViewer

final class ModelAnimationPlayerTests: XCTestCase {

    private func vec3Track(_ interp: ModelScene.Interpolation,
                           times: [Float], keys: [SIMD3<Float>]) -> ModelScene.Vec3Track {
        ModelScene.Vec3Track(interp: interp, times: times, keys: keys,
                             inTangents: [], outTangents: [])
    }

    func testConstantTrack() {
        let t = vec3Track(.constant, times: [0, 1000], keys: [SIMD3(1, 2, 3), SIMD3(4, 5, 6)])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 500, default: .zero), SIMD3(1, 2, 3))
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 1500, default: .zero), SIMD3(4, 5, 6))
    }

    func testLinearTrack() {
        let t = vec3Track(.linear, times: [0, 1000], keys: [SIMD3(0, 0, 0), SIMD3(0, 10, 0)])
        let v = ModelAnimationPlayer.evaluate(track: t, timeMs: 500, default: .zero)
        XCTAssertEqual(v.y, 5, accuracy: 0.001)
    }

    func testLinearClampAndLoop() {
        // 播放器外层处理 loop;evaluate 本身按 clamp
        let t = vec3Track(.linear, times: [0, 1000], keys: [SIMD3(0, 0, 0), SIMD3(10, 0, 0)])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 2000, default: .zero).x, 10)
    }

    func testEmptyTrackUsesDefault() {
        let t = vec3Track(.linear, times: [], keys: [])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 100, default: SIMD3(7, 8, 9)),
                       SIMD3(7, 8, 9))
    }

    func testQuatSlerp() {
        let q0 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let q1 = simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        let track = ModelScene.QuatTrack(interp: .linear, times: [0, 1000],
                                         keys: [q0, q1], inTangents: [], outTangents: [])
        let q = ModelAnimationPlayer.evaluate(track: track, timeMs: 500, default: q0)
        // 半程应绕 z 转 90°
        let rotated = q.act(SIMD3(1, 0, 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 0.01)
        XCTAssertEqual(rotated.y, 1, accuracy: 0.01)
    }

    func testPlayerAppliesToBoneNodes() {
        // 1 骨骼,位移轨道 0→(0,1,0)
        let track = ModelScene.Vec3Track(interp: .linear, times: [0, 1000],
                                         keys: [.zero, SIMD3(0, 1, 0)],
                                         inTangents: [], outTangents: [])
        let bone = ModelScene.Bone(name: "b", parentIndex: -1, pivot: .zero,
                                   inverseBind: matrix_identity_float4x4,
                                   restTranslation: .zero,
                                   restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                   restScale: SIMD3(1, 1, 1))
        let anim = ModelScene.Animation(name: "a", durationMs: 1000, loops: false,
                                        translations: [track],
                                        rotations: [ModelScene.QuatTrack(interp: .constant, times: [], keys: [], inTangents: [], outTangents: [])],
                                        scales: [ModelScene.Vec3Track(interp: .constant, times: [], keys: [], inTangents: [], outTangents: [])])
        let scene = ModelScene(name: "s", format: .mdx, meshes: [], materials: [],
                               bones: [bone], animations: [anim],
                               boundsMin: .zero, boundsMax: .zero)
        let built = ModelSceneBuilder.build(scene)
        let player = ModelAnimationPlayer(scene: scene, built: built)
        player.selectAnimation(index: 0)
        player.update(timeMs: 1000)
        // MDX 公式:local = T(pivot + t) R S T(-pivot);pivot=0 → 平移 (0,1,0)
        XCTAssertEqual(built.boneNodes[0].simdPosition.y, 1, accuracy: 0.001)
    }
}
