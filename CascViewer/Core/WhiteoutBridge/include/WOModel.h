#pragma once
#include "WOTypes.h"

namespace WhiteoutBridge {

enum class WOModelFormat : uint8_t { MDX, M3, M2 };

enum class WOBlendMode : uint8_t { Opaque, AlphaTest, Blend, Additive, Modulate };

enum class WOInterpolation : uint8_t { Constant, Linear, Hermite, Bezier };

struct WOVec2 { float x = 0, y = 0; };
struct WOVec3 { float x = 0, y = 0, z = 0; };
struct WOVec4 { float x = 0, y = 0, z = 0, w = 1; };

struct WOVec3Track {
    WOInterpolation interp = WOInterpolation::Constant;
    std::vector<uint32_t> times;        // 毫秒
    std::vector<WOVec3> keys;
    std::vector<WOVec3> inTangents;     // 仅 Hermite/Bezier
    std::vector<WOVec3> outTangents;
};

struct WOQuatTrack {
    WOInterpolation interp = WOInterpolation::Constant;
    std::vector<uint32_t> times;        // 毫秒
    std::vector<WOVec4> keys;           // XYZW
    std::vector<WOVec4> inTangents;
    std::vector<WOVec4> outTangents;
};

struct WOBone {
    std::string name;
    int32_t parentIndex = -1;
    WOVec3 pivot;
    std::vector<float> inverseBind;     // 16 个,row-major;空 = 单位阵
    WOVec3 restTranslation;
    WOVec4 restRotation;                // 默认 identity(0,0,0,1)
    WOVec3 restScale = {1, 1, 1};
};

struct WOMesh {
    std::vector<WOVec3> positions;
    std::vector<WOVec3> normals;
    std::vector<WOVec2> uvs;
    std::vector<uint32_t> indices;
    std::vector<uint8_t> boneIndices;   // 扁平,4 个/顶点
    std::vector<uint8_t> boneWeights;   // 扁平,4 个/顶点,每顶点合计 255
    int32_t materialIndex = -1;
    uint32_t materialType = 1;      // M3 MaterialType 原始值;无 batch 或越界时保持 1(fail-open 可见);MDX/M2 恒为 1(Standard)
};

struct WOMaterial {
    std::string texturePath;            // MDX/M3;M2 常为 ""
    uint32_t textureFileDataId = 0;     // M2 TXID;0 = 无
    WOBlendMode blendMode = WOBlendMode::Opaque;
    bool twoSided = false;
    bool unlit = false;
    bool wrapU = false;                 // M3 LAYR.UVWrapX;false = clamp
    bool wrapV = false;                 // M3 LAYR.UVWrapY
};

struct WOAnimation {
    std::string name;
    uint32_t durationMs = 0;
    bool loops = true;
    // 与 WOModel::bones 平行;空 times = 该骨骼无轨道
    std::vector<WOVec3Track> translations;
    std::vector<WOQuatTrack> rotations;
    std::vector<WOVec3Track> scales;
};

struct WOModel {
    std::string name;
    WOModelFormat format = WOModelFormat::MDX;
    std::vector<WOMesh> meshes;
    std::vector<WOMaterial> materials;
    std::vector<WOBone> bones;
    std::vector<WOAnimation> animations;
    WOVec3 boundsMin, boundsMax;
};

} // namespace WhiteoutBridge
