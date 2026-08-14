import Foundation
import simd

/// 渲染无关的模型场景描述(WOModel 的 Swift 值类型镜像)。
struct ModelScene: Sendable {
    var name: String
    var format: Format
    var meshes: [Mesh]
    var materials: [Material]
    var bones: [Bone]
    var animations: [Animation]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    enum Format: Sendable { case mdx, m3, m2 }

    struct Mesh: Sendable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]
        var boneIndices: [SIMD4<UInt8>]  // 每顶点 4 个
        var boneWeights: [SIMD4<UInt8>]  // 每顶点合计 255
        var materialIndex: Int           // -1 = 无
        /// M3 材质类型原始值(1~12,见 M3MaterialKind);默认 Standard,
        /// 使现有构造点与 MDX/M2 路径无需修改。
        var materialType: Int = 1
    }

    struct Material: Sendable {
        var texturePath: String
        var textureFileDataId: UInt32    // M2 TXID;0 = 无
        var blendMode: BlendMode
        var twoSided: Bool
        var unlit: Bool
        var diffuseTexture: ImageDecodeResult.ImageFrame?  // 加载阶段填充,nil = 缺失
    }

    enum BlendMode: Sendable { case opaque, alphaTest, blend, additive, modulate }

    struct Bone: Sendable {
        var name: String
        var parentIndex: Int             // -1 = root
        var pivot: SIMD3<Float>          // 父空间(MDX/M2 的锚点公式用)
        var inverseBind: simd_float4x4
        var restTranslation: SIMD3<Float>
        var restRotation: simd_quatf
        var restScale: SIMD3<Float>
    }

    enum Interpolation: Sendable { case constant, linear, hermite, bezier }

    struct Vec3Track: Sendable {
        var interp: Interpolation
        var times: [Float]               // 毫秒
        var keys: [SIMD3<Float>]
        var inTangents: [SIMD3<Float>]
        var outTangents: [SIMD3<Float>]
    }

    struct QuatTrack: Sendable {
        var interp: Interpolation
        var times: [Float]
        var keys: [simd_quatf]
        var inTangents: [simd_quatf]
        var outTangents: [simd_quatf]
    }

    struct Animation: Sendable {
        var name: String
        var durationMs: Float
        var loops: Bool
        var translations: [Vec3Track]    // 与 bones 平行
        var rotations: [QuatTrack]
        var scales: [Vec3Track]
    }
}
