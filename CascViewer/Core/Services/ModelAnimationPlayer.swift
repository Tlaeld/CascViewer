import Foundation
import SceneKit
import simd

/// CPU 求值骨骼动画轨道并赋给 SceneKit 骨骼节点。
/// 矩阵公式:
///  - M3:        local = T(t) R(r) S(s)
///  - MDX / M2:  local = T(pivot + t) R(r) S(s) T(-pivot)
final class ModelAnimationPlayer {
    private let scene: ModelScene
    private let built: BuiltModelScene
    private var animationIndex: Int = -1

    var animationNames: [String] { scene.animations.map(\.name) }

    init(scene: ModelScene, built: BuiltModelScene) {
        self.scene = scene
        self.built = built
    }

    func selectAnimation(index: Int) {
        animationIndex = (index >= 0 && index < scene.animations.count) ? index : -1
    }

    /// timeMs 为动画内时间(未取模);loops 由本函数按序列配置处理。
    func update(timeMs: Float) {
        guard animationIndex >= 0 else { return }
        let anim = scene.animations[animationIndex]
        let t: Float
        if anim.loops && anim.durationMs > 0 {
            t = timeMs.truncatingRemainder(dividingBy: anim.durationMs)
        } else {
            t = min(timeMs, anim.durationMs)
        }
        for (i, bone) in scene.bones.enumerated() {
            // M3 轨道值是完整局部位移(default 取 rest);
            // MDX/M2 锚点公式中位移是相对 pivot 的增量(default 取 0)。
            let translationDefault = (scene.format == .m3) ? bone.restTranslation : SIMD3<Float>.zero
            let translation = Self.evaluate(track: anim.translations[i], timeMs: t,
                                            default: translationDefault)
            let rotation = Self.evaluate(track: anim.rotations[i], timeMs: t,
                                         default: bone.restRotation)
            let scale = Self.evaluate(track: anim.scales[i], timeMs: t,
                                      default: bone.restScale)
            built.boneNodes[i].simdTransform =
                localMatrix(bone: bone, t: translation, r: rotation, s: scale)
        }
    }

    private func localMatrix(bone: ModelScene.Bone, t: SIMD3<Float>,
                             r: simd_quatf, s: SIMD3<Float>) -> simd_float4x4 {
        switch scene.format {
        case .m3:
            // M3:t 即完整局部 TRS(空轨道时 evaluate 已返回 restTranslation)
            return translationMatrix(t)
                * simd_float4x4(r)
                * scaleMatrix(s)
        case .mdx, .m2:
            return translationMatrix(bone.pivot + t)
                * simd_float4x4(r)
                * scaleMatrix(s)
                * translationMatrix(-bone.pivot)
        }
    }

    // ── 静态求值(供测试)──

    static func evaluate(track: ModelScene.Vec3Track, timeMs: Float,
                         default defaultValue: SIMD3<Float>) -> SIMD3<Float> {
        guard !track.times.isEmpty, track.keys.count == track.times.count else {
            return defaultValue
        }
        let (i, alpha) = segment(times: track.times, timeMs: timeMs)
        let a = track.keys[i]
        guard alpha > 0, i + 1 < track.keys.count else { return a }
        let b = track.keys[i + 1]
        switch track.interp {
        case .constant:
            return a
        case .linear:
            return simd_mix(a, b, SIMD3(repeating: alpha))
        case .hermite, .bezier:
            // 三次 Hermite:切线缺失时退化为线性
            guard track.outTangents.count > i, track.inTangents.count > i + 1 else {
                return simd_mix(a, b, SIMD3(repeating: alpha))
            }
            let dt = track.times[i + 1] - track.times[i]
            return cubicHermite(a, track.outTangents[i] * dt,
                                track.inTangents[i + 1] * dt, b, alpha)
        }
    }

    static func evaluate(track: ModelScene.QuatTrack, timeMs: Float,
                         default defaultValue: simd_quatf) -> simd_quatf {
        guard !track.times.isEmpty, track.keys.count == track.times.count else {
            return defaultValue
        }
        let (i, alpha) = segment(times: track.times, timeMs: timeMs)
        let a = track.keys[i]
        guard alpha > 0, i + 1 < track.keys.count else { return a }
        let b = track.keys[i + 1]
        switch track.interp {
        case .constant:
            return a
        case .linear:
            return simd_slerp(a, b, alpha)
        case .hermite, .bezier:
            // squad(q1, outTan, inTan, q2, t) 的常用近似:slerp(slerp(q1,q2,t), slerp(out,in,t), 2t(1-t))
            guard track.outTangents.count > i, track.inTangents.count > i + 1 else {
                return simd_slerp(a, b, alpha)
            }
            let s1 = simd_slerp(a, b, alpha)
            let s2 = simd_slerp(track.outTangents[i], track.inTangents[i + 1], alpha)
            return simd_slerp(s1, s2, 2 * alpha * (1 - alpha))
        }
    }

    /// 找到 timeMs 所在关键帧段(返回左端下标与 [0,1] 插值系数;越界 clamp)。
    private static func segment(times: [Float], timeMs: Float) -> (Int, Float) {
        if timeMs <= times[0] { return (0, 0) }
        for i in 0..<(times.count - 1) {
            if timeMs >= times[i] && timeMs < times[i + 1] {
                let span = times[i + 1] - times[i]
                return (i, span > 0 ? (timeMs - times[i]) / span : 0)
            }
        }
        return (times.count - 1, 0)
    }

    private static func cubicHermite(_ p0: SIMD3<Float>, _ m0: SIMD3<Float>,
                                     _ m1: SIMD3<Float>, _ p1: SIMD3<Float>,
                                     _ t: Float) -> SIMD3<Float> {
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
             + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
    }

    private func translationMatrix(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[3, 0] = v.x; m[3, 1] = v.y; m[3, 2] = v.z
        return m
    }

    private func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[0, 0] = s.x; m[1, 1] = s.y; m[2, 2] = s.z
        return m
    }
}
