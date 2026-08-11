import Foundation
import simd
import CascBridge

/// WOModel(C++) → ModelScene(Swift) 转换。
enum ModelSceneConverter {

    static func convert(_ cpp: WhiteoutBridge.WOModel, format: ModelScene.Format) -> ModelScene {
        var scene = ModelScene(
            name: String(cpp.name),
            format: format,
            meshes: [],
            materials: [],
            bones: [],
            animations: [],
            boundsMin: SIMD3(cpp.boundsMin.x, cpp.boundsMin.y, cpp.boundsMin.z),
            boundsMax: SIMD3(cpp.boundsMax.x, cpp.boundsMax.y, cpp.boundsMax.z)
        )

        scene.materials = (0..<cpp.materials.size()).map { i in
            let m = cpp.materials[i]
            return ModelScene.Material(
                texturePath: String(m.texturePath),
                textureFileDataId: m.textureFileDataId,
                blendMode: convertBlend(m.blendMode),
                twoSided: m.twoSided,
                unlit: m.unlit,
                diffuseTexture: nil
            )
        }

        scene.bones = (0..<cpp.bones.size()).map { i in
            let b = cpp.bones[i]
            return ModelScene.Bone(
                name: String(b.name),
                parentIndex: Int(b.parentIndex),
                pivot: SIMD3(b.pivot.x, b.pivot.y, b.pivot.z),
                inverseBind: convertMat4((0..<b.inverseBind.size()).map { b.inverseBind[$0] }),
                restTranslation: SIMD3(b.restTranslation.x, b.restTranslation.y, b.restTranslation.z),
                restRotation: simd_quatf(ix: b.restRotation.x, iy: b.restRotation.y,
                                         iz: b.restRotation.z, r: b.restRotation.w),
                restScale: SIMD3(b.restScale.x, b.restScale.y, b.restScale.z)
            )
        }

        // M3:实测 WhiteoutLib 对部分文件(如 MODL v23)解析出的 IREF 是单位阵
        // (平移全零),直接用作 inverseBind 会把顶点按骨骼世界变换甩出去(模型散开)。
        // 改为从 rest 姿态链自算:worldBind = 父链 TRS 组合,inverseBind = 其逆。
        // 构造上保证 boneWorld(rest) * inverseBind = I,即静止姿态 = 绑定姿态。
        if format == .m3 && !scene.bones.isEmpty {
            let binds = computeInverseBindsFromRest(scene.bones)
            for i in scene.bones.indices {
                scene.bones[i].inverseBind = binds[i]
            }
        }

        scene.meshes = (0..<cpp.meshes.size()).map { i in
            let m = cpp.meshes[i]
            let vcount = m.positions.size()
            var mesh = ModelScene.Mesh(
                positions: (0..<vcount).map { SIMD3(m.positions[$0].x, m.positions[$0].y, m.positions[$0].z) },
                normals: (0..<m.normals.size()).map { SIMD3(m.normals[$0].x, m.normals[$0].y, m.normals[$0].z) },
                uvs: (0..<m.uvs.size()).map { SIMD2(m.uvs[$0].x, m.uvs[$0].y) },
                indices: (0..<m.indices.size()).map { m.indices[$0] },
                boneIndices: [],
                boneWeights: [],
                materialIndex: Int(m.materialIndex)
            )
            let quadCount = m.boneIndices.size() / 4
            mesh.boneIndices = (0..<quadCount).map {
                SIMD4(m.boneIndices[$0 * 4], m.boneIndices[$0 * 4 + 1],
                      m.boneIndices[$0 * 4 + 2], m.boneIndices[$0 * 4 + 3])
            }
            mesh.boneWeights = (0..<(m.boneWeights.size() / 4)).map {
                SIMD4(m.boneWeights[$0 * 4], m.boneWeights[$0 * 4 + 1],
                      m.boneWeights[$0 * 4 + 2], m.boneWeights[$0 * 4 + 3])
            }
            return mesh
        }

        scene.animations = (0..<cpp.animations.size()).map { i in
            let a = cpp.animations[i]
            return ModelScene.Animation(
                name: String(a.name),
                durationMs: Float(a.durationMs),
                loops: a.loops,
                translations: (0..<a.translations.size()).map { convertVec3Track(a.translations[$0]) },
                rotations: (0..<a.rotations.size()).map { convertQuatTrack(a.rotations[$0]) },
                scales: (0..<a.scales.size()).map { convertVec3Track(a.scales[$0]) }
            )
        }

        return scene
    }

    private static func convertBlend(_ b: WhiteoutBridge.WOBlendMode) -> ModelScene.BlendMode {
        switch b {
        case .Opaque: return .opaque
        case .AlphaTest: return .alphaTest
        case .Blend: return .blend
        case .Additive: return .additive
        default: return .modulate
        }
    }

    private static func convertMat4(_ v: [Float]) -> simd_float4x4 {
        // 16 个 row-major;空 = 单位阵
        guard v.count == 16 else { return matrix_identity_float4x4 }
        var m = matrix_identity_float4x4
        // simd_float4x4 为列主序存储,按转置填充
        for r in 0..<4 {
            for c in 0..<4 {
                m[c, r] = v[r * 4 + c]
            }
        }
        return m
    }

    private static func convertVec3Track(_ t: WhiteoutBridge.WOVec3Track) -> ModelScene.Vec3Track {
        ModelScene.Vec3Track(
            interp: convertInterp(t.interp),
            times: (0..<t.times.size()).map { Float(t.times[$0]) },
            keys: (0..<t.keys.size()).map { SIMD3(t.keys[$0].x, t.keys[$0].y, t.keys[$0].z) },
            inTangents: (0..<t.inTangents.size()).map { SIMD3(t.inTangents[$0].x, t.inTangents[$0].y, t.inTangents[$0].z) },
            outTangents: (0..<t.outTangents.size()).map { SIMD3(t.outTangents[$0].x, t.outTangents[$0].y, t.outTangents[$0].z) }
        )
    }

    private static func convertQuatTrack(_ t: WhiteoutBridge.WOQuatTrack) -> ModelScene.QuatTrack {
        ModelScene.QuatTrack(
            interp: convertInterp(t.interp),
            times: (0..<t.times.size()).map { Float(t.times[$0]) },
            keys: (0..<t.keys.size()).map {
                simd_quatf(ix: t.keys[$0].x, iy: t.keys[$0].y, iz: t.keys[$0].z, r: t.keys[$0].w)
            },
            inTangents: (0..<t.inTangents.size()).map {
                simd_quatf(ix: t.inTangents[$0].x, iy: t.inTangents[$0].y, iz: t.inTangents[$0].z, r: t.inTangents[$0].w)
            },
            outTangents: (0..<t.outTangents.size()).map {
                simd_quatf(ix: t.outTangents[$0].x, iy: t.outTangents[$0].y, iz: t.outTangents[$0].z, r: t.outTangents[$0].w)
            }
        )
    }

    private static func convertInterp(_ i: WhiteoutBridge.WOInterpolation) -> ModelScene.Interpolation {
        switch i {
        case .Constant: return .constant
        case .Linear: return .linear
        case .Hermite: return .hermite
        default: return .bezier
        }
    }

    /// 从 rest 姿态链计算 inverseBind(M3 用)。
    /// worldBind[i] = worldBind[parent] * (T·R·S)(rest[i]);inverseBind = simd_inverse(worldBind)。
    /// 与 ModelSceneBuilder/AnimationPlayer 的 TRS 组合顺序一致(平移·旋转·缩放)。
    static func computeInverseBindsFromRest(_ bones: [ModelScene.Bone]) -> [simd_float4x4] {
        var cache = [Int: simd_float4x4]()
        cache.reserveCapacity(bones.count)

        func localRest(_ b: ModelScene.Bone) -> simd_float4x4 {
            var t = matrix_identity_float4x4
            t[3, 0] = b.restTranslation.x; t[3, 1] = b.restTranslation.y; t[3, 2] = b.restTranslation.z
            var s = matrix_identity_float4x4
            s[0, 0] = b.restScale.x; s[1, 1] = b.restScale.y; s[2, 2] = b.restScale.z
            return t * simd_float4x4(b.restRotation) * s
        }

        // 带备忘的递归;parentIndex 越界或成环时按无父处理
        func worldBind(_ i: Int, _ visiting: inout Set<Int>) -> simd_float4x4 {
            if let cached = cache[i] { return cached }
            let b = bones[i]
            let local = localRest(b)
            let parent = b.parentIndex
            let world: simd_float4x4
            if parent >= 0 && parent < bones.count && parent != i && !visiting.contains(parent) {
                visiting.insert(i)
                world = worldBind(parent, &visiting) * local
                visiting.remove(i)
            } else {
                world = local
            }
            cache[i] = world
            return world
        }

        var visiting = Set<Int>()
        return bones.indices.map { simd_inverse(worldBind($0, &visiting)) }
    }
}
