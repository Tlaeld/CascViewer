#include "WOModelLoader.h"
#include "WOStringUtils.h"

#include <whiteout/models/m3/m3.h>
#include <whiteout/models/m3/parser.h>

#include <cstring>
#include <type_traits>

using namespace whiteout;

namespace WhiteoutBridge {

namespace {

// M3 时间戳单位即毫秒——以真实文件验证(Walk 循环 733、Attack 2000、Death 10000,
// 均为合理毫秒时长;SEQS.blendTime 字段同样以 ms 计)。不做帧率换算。
WOVec2 toWO(const Vector2f& v) { return {v.x, v.y}; }
WOVec3 toWO(const Vector3f& v) { return {v.x, v.y, v.z}; }
WOVec4 toWO(const Quaternion& q) { return {q.x, q.y, q.z, q.w}; }

uint32_t frameToMs(i32 frame) {
    return frame > 0 ? (uint32_t)frame : 0;
}

// 在指定 STC 中解析 AnimRef → AnimBlock(slot/index 解码)。
// 返回 false 表示该 STC 不含此 animId。
bool resolveAnimId(const m3::SubTrackContainer& stc, u32 animId,
                   u32& outSlot, u32& outIndex) {
    for (size_t k = 0; k < stc.animIds.size() && k < stc.animRefs.size(); ++k) {
        if (stc.animIds[k] == animId) {
            const u32 ref = stc.animRefs[k];
            outSlot = ref >> 16;
            outIndex = ref & 0xFFFF;
            return true;
        }
    }
    return false;
}

WOVec3Track convertSD3V(const m3::AnimBlock<Vector3f>& block, u16 interpType) {
    WOVec3Track out;
    out.interp = (interpType == 0) ? WOInterpolation::Constant
                                   : WOInterpolation::Linear;  // v1:Hermite/Bezier 按 Linear
    for (size_t k = 0; k < block.keys.size() && k < block.timestamps.size(); ++k) {
        out.times.push_back(frameToMs(block.timestamps[k]));
        out.keys.push_back(toWO(block.keys[k]));
    }
    return out;
}

WOQuatTrack convertSD4Q(const m3::AnimBlock<Quaternion>& block, u16 interpType) {
    WOQuatTrack out;
    out.interp = (interpType == 0) ? WOInterpolation::Constant
                                   : WOInterpolation::Linear;
    for (size_t k = 0; k < block.keys.size() && k < block.timestamps.size(); ++k) {
        out.times.push_back(frameToMs(block.timestamps[k]));
        out.keys.push_back(toWO(block.keys[k]));
    }
    return out;
}

// 骨骼单个属性(位置/旋转/缩放)在 STC 中解析为轨道。
template <typename TrackT>
TrackT resolveBoneTrack(const m3::SubTrackContainer* stc, u32 animId, u16 interpType,
                        u32 wantSlot) {
    TrackT out;
    if (!stc || animId == 0) return out;
    u32 slot = 0, index = 0;
    if (!resolveAnimId(*stc, animId, slot, index) || slot != wantSlot) return out;
    if constexpr (std::is_same_v<TrackT, WOVec3Track>) {
        if (index < stc->sd3v.size()) return convertSD3V(stc->sd3v[index], interpType);
    } else {
        if (index < stc->sd4q.size()) return convertSD4Q(stc->sd4q[index], interpType);
    }
    return out;
}

} // namespace

WOModel WOModelLoader::parseM3(const uint8_t* data, size_t length, WOError& error) {
    error = WOError::None;
    WOModel out;
    out.format = WOModelFormat::M3;
    if (!data || length == 0) { error = WOError::EmptyData; return out; }

    m3::Model model;
    try {
        m3::Parser parser;
        model = parser.parse(std::span<const u8>(data, length));
    } catch (const std::exception&) {
        error = WOError::ParseFailed;
        return out;
    }

    out.name = sanitized(model.name);
    out.boundsMin = toWO(model.bounds.min);
    out.boundsMax = toWO(model.bounds.max);

    // ── 材质:batch → materialMaps → standardMaterials,只取 diffuseLayer ──
    // WOMaterial 下标与 materialMaps 下标对齐(非 Standard 的 map 也占位,保证索引一致)
    for (const auto& mm : model.materialMaps) {
        WOMaterial wm;
        if (mm.materialType == m3::MaterialType::Standard &&
            mm.materialIndex < model.standardMaterials.size()) {
            const auto& sm = model.standardMaterials[mm.materialIndex];
            if (sm.diffuseLayer) {
                wm.texturePath = sanitized(sm.diffuseLayer->texturePath);
                const u32 lf = static_cast<u32>(sm.diffuseLayer->flags);
                wm.wrapU = (lf & 0x4) != 0;  // TextureLayerFlag::UVWrapX
                wm.wrapV = (lf & 0x8) != 0;  // TextureLayerFlag::UVWrapY
            }
            switch (sm.blendMode) {
                case m3::BlendMode::Opaque:     wm.blendMode = WOBlendMode::Opaque; break;
                case m3::BlendMode::AlphaBlend: wm.blendMode = WOBlendMode::Blend; break;
                case m3::BlendMode::Add:
                case m3::BlendMode::AlphaAdd:   wm.blendMode = WOBlendMode::Additive; break;
                case m3::BlendMode::Mod:
                case m3::BlendMode::Mod2x:      wm.blendMode = WOBlendMode::Modulate; break;
            }
            const u32 mf = static_cast<u32>(sm.flags);
            wm.twoSided = (mf & 0x8) != 0;   // MaterialFlag::TwoSided
            wm.unlit = (mf & 0x10) != 0;     // MaterialFlag::Unshaded
        }
        out.materials.push_back(std::move(wm));
    }

    // ── 骨骼 ──
    for (const auto& b : model.bones) {
        WOBone wb;
        wb.name = sanitized(b.name);
        wb.parentIndex = (b.parentIndex == 0xFFFF) ? -1 : (int32_t)b.parentIndex;
        wb.restTranslation = toWO(b.position.initValue);
        wb.restRotation = toWO(b.rotation.initValue);
        wb.restScale = toWO(b.scale.initValue);
        out.bones.push_back(std::move(wb));
    }
    // inverse bind:IREF 与骨骼按下标对齐
    for (size_t i = 0; i < out.bones.size() && i < model.initialReference.size(); ++i) {
        const Matrix44f& m = model.initialReference[i].matrix;
        auto& ib = out.bones[i].inverseBind;
        ib.assign(16, 0.0f);
        for (int r = 0; r < 4; ++r)
            for (int c = 0; c < 4; ++c)
                ib[r * 4 + c] = m.data[r][c];
    }

    // ── 网格:顶点缓冲按 Region 拆分,骨骼索引经 boneLookup 重映射 ──
    auto positions = model.vertices.getPositions();
    auto normals = model.vertices.getNormals();
    auto boneIdx = model.vertices.getBoneIndices();   // region-local
    auto boneWts = model.vertices.getBoneWeights();   // 合计 255

    if (!model.divisions.empty()) {
        const auto& div = model.divisions[0];
        for (size_t ri = 0; ri < div.regions.size(); ++ri) {
            const auto& region = div.regions[ri];
            WOMesh mesh;
            const size_t v0 = region.firstVertex;
            const size_t vc = region.vertexCount;
            if (v0 + vc > positions.size()) continue;
            mesh.positions.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.positions.push_back(toWO(positions[k]));
            mesh.normals.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.normals.push_back(k < normals.size() ? toWO(normals[k]) : WOVec3{0, 0, 1});
            // UV:REGN v5+ 携带每 region 缩放/偏移,uv = raw_i16 × uvScale/32768 + uvOffset
            // (scale=16, offset=0 时等价于旧版 /2048;以真实文件验证:
            // golden_death 16/0 与新行为一致,nova 0.999/0.999 修复越界 UV)。
            // v5 之前无此字段,沿用 /2048。
            float uvMul = 1.0f / 2048.0f, uvOff = 0.0f;
            if (region.getVersion() >= 5) {
                uvMul = region.uvScale / 32768.0f;
                uvOff = region.uvOffset;
            }
            auto uvs = model.vertices.getUVs(0, uvMul, uvOff);
            mesh.uvs.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.uvs.push_back(k < uvs.size() ? toWO(uvs[k]) : WOVec2{0, 0});

            const size_t i0 = region.firstIndex;
            const size_t ic = region.indexCount;
            // M3 面下标是 region 局部索引(已相对 firstVertex),直接使用。
            // 以真实文件验证:region 面引用范围恰为 [0, vertexCount)。
            for (size_t k = i0; k < i0 + ic && k < div.faces.size(); ++k) {
                const u32 local = div.faces[k];
                if (local < vc) mesh.indices.push_back(local);
            }

            // 材质:找引用该 region 的 batch;记录 M3 材质类型供上层按类型过滤渲染
            // (无 batch 或索引越界保持默认 1;显式标 0 的语义留给未来,当前不设)
            for (const auto& batch : div.batches) {
                if (batch.regionIndex == ri) {
                    mesh.materialIndex = (int32_t)batch.materialIndex;  // 与 materialMaps 对齐
                    if (batch.materialIndex < model.materialMaps.size())
                        mesh.materialType = (uint32_t)model.materialMaps[batch.materialIndex].materialType;
                    break;
                }
            }

            mesh.boneIndices.resize(vc * 4, 0);
            mesh.boneWeights.resize(vc * 4, 0);
            for (size_t k = 0; k < vc; ++k) {
                const size_t gv = v0 + k;
                if (gv >= boneIdx.size()) break;
                for (size_t j = 0; j < 4; ++j) {
                    const size_t lu = (size_t)region.firstBoneLookup + boneIdx[gv][j];
                    const u8 real = (lu < model.boneLookup.size())
                                        ? (u8)model.boneLookup[lu] : 0;
                    mesh.boneIndices[k * 4 + j] = real;
                    mesh.boneWeights[k * 4 + j] = (gv < boneWts.size()) ? boneWts[gv][j] : (j == 0 ? 255 : 0);
                }
            }
            out.meshes.push_back(std::move(mesh));
        }
    }

    // ── 动画:STC 与 sequence 配对(数量相等按下标,否则用 STC[0])──
    const bool pairByIndex = (model.subTrackCollections.size() == model.sequences.size());
    for (size_t si = 0; si < model.sequences.size(); ++si) {
        const auto& seq = model.sequences[si];
        const m3::SubTrackContainer* stc = nullptr;
        if (!model.subTrackCollections.empty())
            stc = &model.subTrackCollections[pairByIndex ? si : 0];

        WOAnimation anim;
        anim.name = sanitized(seq.name);
        anim.durationMs = frameToMs((i32)(seq.endFrame > seq.startFrame
                                              ? seq.endFrame - seq.startFrame : 0));
        anim.loops = true;  // v1:M3 一律循环
        for (const auto& bone : model.bones) {
            anim.translations.push_back(resolveBoneTrack<WOVec3Track>(
                stc, bone.position.animId, bone.position.interpType, 2 /* sd3v */));
            anim.rotations.push_back(resolveBoneTrack<WOQuatTrack>(
                stc, bone.rotation.animId, bone.rotation.interpType, 3 /* sd4q */));
            anim.scales.push_back(resolveBoneTrack<WOVec3Track>(
                stc, bone.scale.animId, bone.scale.interpType, 2 /* sd3v */));
        }
        out.animations.push_back(std::move(anim));
    }

    return out;
}

// ── 测试夹具:1 三角网格 / 1 骨骼 / 1 个位移动画 ──
std::vector<uint8_t> WOEncodeTestM3() {
    m3::Model model{};
    model.setVersion(30);
    model.name = "TestM3";

    // 骨骼:带 animId=7 的位移动画引用
    m3::Bone bone{};
    bone.setVersion(30);
    bone.name = "root";
    bone.parentIndex = 0xFFFF;
    bone.position.initValue = Vector3f{0, 0, 0};
    bone.rotation.initValue = Quaternion::identity();
    bone.scale.initValue = Vector3f{1, 1, 1};
    bone.position.animId = 7;
    bone.position.interpType = 1;  // linear
    model.bones = {bone};
    model.skinBoneCount = 1;

    // IREF(单位阵)
    m3::InitialReference iref{};
    iref.setVersion(30);
    for (int r = 0; r < 4; ++r) iref.matrix.data[r][r] = 1.0f;
    model.initialReference = {iref};

    // 顶点缓冲:3 顶点,UV1 布局,stride = 12+4+4+4+4+4 = 32
    m3::VertexBuffer vb;
    vb.flags = m3::VertexFormatFlag::UV1;
    const size_t stride = 32, vcount = 3;
    vb.data.resize(stride * vcount, 0);
    const float pos[3][3] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}};
    for (size_t v = 0; v < vcount; ++v) {
        u8* base = vb.data.data() + v * stride;
        std::memcpy(base, pos[v], 12);            // position
        base[12] = 255;                           // weight0 = 255,其余 0
        base[16] = 127;                           // boneIndices[0](实际布局:权重 12-15,boneIndices 16-19,normal 20-23);
                                                  // 127 经 boneLookup(大小 1)查找越界回退为 0,不影响断言
        // normal(20-23)全 0;uv(24-27)全 0;tangent(28-31)全 0
    }
    model.vertices = vb;
    model.vertices.initialize();

    // 网格划分:1 region + 1 batch
    m3::MeshDivision div{};
    div.setVersion(30);
    div.faces = {0, 1, 2};
    m3::Region region{};
    region.setVersion(30);
    region.firstVertex = 0;
    region.vertexCount = 3;
    region.firstIndex = 0;
    region.indexCount = 3;
    region.firstBoneLookup = 0;
    region.boneLookupCount = 1;
    div.regions = {region};
    m3::Batch batch{};
    batch.setVersion(30);
    batch.regionIndex = 0;
    batch.materialIndex = 0;
    div.batches = {batch};
    model.divisions = {div};
    model.boneLookup = {0};

    // 材质
    m3::MaterialMap mm{};
    mm.setVersion(30);
    mm.materialType = m3::MaterialType::Standard;
    mm.materialIndex = 0;
    model.materialMaps = {mm};
    m3::StandardMaterial sm{};
    sm.setVersion(30);
    sm.name = "TestMat";
    sm.blendMode = m3::BlendMode::Opaque;
    m3::TextureLayer tl{};
    tl.setVersion(30);
    tl.texturePath = "Assets/Textures/test.dds";
    sm.diffuseLayer = tl;
    model.standardMaterials = {sm};

    // 动画:1 sequence + 1 STC(animId=7 → sd3v[0],2 帧)
    m3::Sequence seq{};
    seq.setVersion(30);
    seq.name = "Stand";
    seq.startFrame = 0;
    seq.endFrame = 30;
    model.sequences = {seq};

    m3::SubTrackContainer stc{};
    stc.setVersion(30);
    stc.animIds = {7};
    stc.animRefs = {(2u << 16) | 0u};  // slot 2 (sd3v),index 0
    m3::AnimBlock<Vector3f> block{};
    block.timestamps = {0, 30};
    block.keys = {Vector3f{0, 0, 0}, Vector3f{0, 1, 0}};
    stc.sd3v = {block};
    model.subTrackCollections = {stc};

    m3::Writer writer;
    return writer.write(model);
}

} // namespace WhiteoutBridge
