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
        /// UV 环绕(M3 LAYR.UVWrapX/Y);false = clamp。默认 false 保持既有构造点不变。
        var wrapU: Bool = false
        var wrapV: Bool = false
        /// M3 细节层路径(法线/高光/自发光);空 = 无。默认空保持既有构造点不变。
        var normalPath: String = ""
        var specularPath: String = ""
        var emissivePath: String = ""
        var diffuseTexture: ImageDecodeResult.ImageFrame?  // 加载阶段填充,nil = 缺失
        var normalTexture: ImageDecodeResult.ImageFrame? = nil    // 已按 DXT5nm 还原成标准 RGB 法线
        var specularTexture: ImageDecodeResult.ImageFrame? = nil
        var emissiveTexture: ImageDecodeResult.ImageFrame? = nil
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

/// M3 材质类型(MAT_ 等 chunk 的 materialType 原始值)。
/// 仅用于按类型过滤渲染;MDX/M2 无此概念,网格恒为 1(Standard)。
enum M3MaterialKind: Int, CaseIterable, Identifiable {
    case standard = 1
    case displacement = 2
    case composite = 3
    case terrain = 4
    case volume = 5
    case volumeNoise = 6
    case creep = 7
    case hair = 8
    case splatTerrainBake = 9
    case reflection = 10
    case lensFlare = 11
    case bufferMaterial = 12

    var id: Int { rawValue }

    /// 默认隐藏的类型:非实体表面(地面压平/体积特效等)。
    /// Standard(1)/Composite(3)/Terrain(4)默认可见——Terrain 是 terrain object
    /// 的主材质(如 jungle doodad),藏掉会让整个模型消失。
    /// BufferMaterial(12,MADD)是 MODL v30+ 模型的主材质载体(如 pajamathur 皮肤),
    /// 同样默认可见。
    static let defaultHidden: Set<Int> = [2, 5, 6, 7, 8, 9, 10, 11]

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .displacement: return "Displacement"
        case .composite: return "Composite"
        case .terrain: return "Terrain"
        case .volume: return "Volume"
        case .volumeNoise: return "Volume Noise"
        case .creep: return "Creep"
        case .hair: return "Hair"
        case .splatTerrainBake: return "Splat Terrain Bake"
        case .reflection: return "Reflection"
        case .lensFlare: return "Lens Flare"
        case .bufferMaterial: return "Buffer Material"
        }
    }

    /// Localizable.strings 中的说明文案键(m3mat_desc_1 ~ m3mat_desc_12)
    var descriptionKey: String { "m3mat_desc_\(rawValue)" }
}
