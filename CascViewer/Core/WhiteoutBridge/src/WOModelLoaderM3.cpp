#include "WOModelLoader.h"
#include "WOStringUtils.h"

#include <whiteout/models/m3/m3.h>
#include <whiteout/models/m3/parser.h>

#include <algorithm>
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

// 骨骼单个属性(位置/旋转/缩放)在单个 STC 中解析为轨道。
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

// 骨骼单个属性(位置/旋转/缩放)的轨道解析:在多个候选 STC 中逐个尝试,
// 第一个含此 animId 的 STC 胜出(一个动画的轨道可分散在多个 STC 中)。
template <typename TrackT>
TrackT resolveBoneTrack(const std::vector<const m3::SubTrackContainer*>& stcs,
                        u32 animId, u16 interpType, u32 wantSlot) {
    for (const m3::SubTrackContainer* stc : stcs) {
        TrackT t = resolveBoneTrack<TrackT>(stc, animId, interpType, wantSlot);
        if (!t.times.empty()) return t;
    }
    return TrackT{};
}

// 贴图路径是否为可解码位图(DDS/BLP/ImageIO 位图);.ogv 视频等不可解码
bool isDecodableImagePath(const std::string& p) {
    std::string ext;
    const size_t dot = p.find_last_of('.');
    if (dot != std::string::npos) {
        ext = p.substr(dot);
        for (auto& c : ext) c = (char)tolower((unsigned char)c);
    }
    static const char* kExts[] = {".dds", ".blp", ".tga", ".png", ".jpg", ".jpeg", ".bmp"};
    for (auto* e : kExts) if (ext == e) return true;
    return false;
}

// 把 StandardMaterial 的显示属性填进 WOMaterial(贴图/wrap/混合模式/双面/unlit)
void applyStandardMaterial(WOMaterial& wm, const m3::StandardMaterial& sm) {
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

    // 顶点布局自愈:旧资产的 MODL 顶点标志与真实数据布局不符——实测这批文件
    // (gridfloor/jungle/ground_grate 等)offset 24 起全是 UV 层(i16×2,每层 4B,
    // 无顶点色),tangent 槽恒为 0xFFFFFFFF;按 WhiteoutLib 标志语义算的 stride
    // 与 region 顶点引用总数矛盾,逐顶点读取滑位出 NaN、UV 错位。
    // 以 region 顶点总数为准反推 stride(数据块能整除时),按 24+4×numUVs+4
    // 反解 UV 层数重设标志;region 信息缺失时退回"不可整除"试探。
    {
        auto& vb = model.vertices;
        if (!vb.data.empty()) {
            const auto origFlags = vb.flags;
            const size_t curStride = vb.vertexSize();

            auto applyUVCount = [&](int numUVs) {
                vb.flags = m3::VertexFormatFlag::None;
                if (numUVs >= 1) vb.flags = vb.flags | m3::VertexFormatFlag::UV1;
                if (numUVs >= 2) vb.flags = vb.flags | m3::VertexFormatFlag::UV2;
                if (numUVs >= 3) vb.flags = vb.flags | m3::VertexFormatFlag::UV3;
                if (numUVs >= 4) vb.flags = vb.flags | m3::VertexFormatFlag::UV4;
                if (numUVs >= 5) vb.flags = vb.flags | m3::VertexFormatFlag::UV5;
                vb.initialize();
            };

            // region 顶点引用是连续分区,取最大 end 即总数
            size_t regionVerts = 0;
            if (!model.divisions.empty())
                for (const auto& r : model.divisions[0].regions)
                    regionVerts = std::max(regionVerts, size_t(r.firstVertex + r.vertexCount));

            bool healed = false;
            if (regionVerts > 0 && vb.data.size() % regionVerts == 0) {
                const size_t want = vb.data.size() / regionVerts;
                if (want != curStride && want >= 28 && want <= 48 && (want - 28) % 4 == 0) {
                    applyUVCount(int((want - 28) / 4));
                    healed = (vb.vertexSize() == want);
                }
            }
            if (!healed && curStride > 0 && vb.data.size() % curStride != 0) {
                // 兜底:region 不可用但按当前标志不可整除,在 1..5 层 UV 中找能整除的
                for (int n = 1; n <= 5 && !healed; ++n) {
                    applyUVCount(n);
                    healed = (vb.vertexSize() > 0 && vb.data.size() % vb.vertexSize() == 0);
                }
            }
            if (!healed && vb.vertexSize() != curStride) {
                vb.flags = origFlags;
                vb.initialize();
            }
        }
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
            applyStandardMaterial(wm, model.standardMaterials[mm.materialIndex]);
        }
        // Composite:从带贴图的 Standard 子材质中优先取可解码位图(跳过 .ogv 视频等),
        // 并继承其混合模式(贴图不可解码时占位色按混合模式不可见)。
        // 以 orphea_deathragdoll 验证:Mat_Dissipate 的 MATM[2]=Mat_Dissolve 携带贴图
        if (mm.materialType == m3::MaterialType::Composite &&
            mm.materialIndex < model.compositeMaterials.size()) {
            const m3::StandardMaterial* fallback = nullptr;
            const m3::StandardMaterial* pick = nullptr;
            for (const auto& sec : model.compositeMaterials[mm.materialIndex].sections) {
                if (sec.materialIndex >= model.materialMaps.size()) continue;
                const auto& smm = model.materialMaps[sec.materialIndex];
                if (smm.materialType != m3::MaterialType::Standard ||
                    smm.materialIndex >= model.standardMaterials.size()) continue;
                const auto& sm = model.standardMaterials[smm.materialIndex];
                if (!sm.diffuseLayer) continue;
                // LAYR 路径可能只含结尾 NUL(先 sanitized 再判空/判扩展名,
                // 否则 "无贴图" 材质会占住 fallback、真贴图被判不可解码)
                const std::string path = sanitized(sm.diffuseLayer->texturePath);
                if (path.empty()) continue;
                if (!fallback) fallback = &sm;
                if (isDecodableImagePath(path)) { pick = &sm; break; }
            }
            if (const m3::StandardMaterial* sm = pick ? pick : fallback)
                applyStandardMaterial(wm, *sm);
        }
        // Terrain:单一地形贴图层(terrain object 的主材质,如 jungle doodad)
        if (mm.materialType == m3::MaterialType::Terrain &&
            mm.materialIndex < model.terrainMaterials.size()) {
            const auto& tm = model.terrainMaterials[mm.materialIndex];
            if (tm.terrainMap) {
                wm.texturePath = sanitized(tm.terrainMap->texturePath);
                const u32 lf = static_cast<u32>(tm.terrainMap->flags);
                wm.wrapU = (lf & 0x4) != 0;
                wm.wrapV = (lf & 0x8) != 0;
            }
        }
        // BufferMaterial(MADD,MODL v30+):材质以键值扩展存储,纹理路径在 valueData
        // (SCHR 字符串数组,如 pajamathur 的 Emis/Norm/Spec/Diff/Dec 一组)。
        // 取 _Diff 作 diffuse;没有则取第一个非 Norm/Spec/Emis 的颜色贴图。
        // SCHR 字符串带结尾 NUL,必须先 sanitized 再做后缀判断,否则判扩展名恒失败。
        // MADD 无 LAYR 环绕标志,HotS 采样默认 wrap,否则 UV 平铺时 clamp 会拖边。
        if (mm.materialType == m3::MaterialType::BufferMaterial &&
            mm.materialIndex < model.materialAddData.size()) {
            std::string color, any;
            for (const auto& raw : model.materialAddData[mm.materialIndex].valueData) {
                const std::string s = sanitized(raw);
                if (!isDecodableImagePath(s)) continue;
                std::string lower = s;
                for (auto& c : lower) c = (char)tolower((unsigned char)c);
                if (lower.find("_diff.") != std::string::npos ||
                    lower.find("_diffuse.") != std::string::npos) {
                    color = s;
                    break;
                }
                const bool nonColor = lower.find("_norm.") != std::string::npos ||
                                      lower.find("_spec.") != std::string::npos ||
                                      lower.find("_emis.") != std::string::npos;
                if (!nonColor && color.empty()) color = s;
                if (any.empty()) any = s;
            }
            const std::string& pick = !color.empty() ? color : any;
            if (!pick.empty()) {
                wm.texturePath = pick;
                wm.wrapU = true;
                wm.wrapV = true;
            }
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

    // ── 动画:SEQ → STC 绑定。优先按 STG 组名匹配 SEQ 名,取组的 subtrackIndices
    // (一个动画的轨道可分散在多个 STC:实测 orphea_facialanims.m3a 为 22 STC/11 SEQ,
    // 每组含 "X_Eyes" 骨骼轨道 STC + "X_full" 空 STC;此时数量不等,若一律回退
    // STC[0],所有动画会解析成完全相同的数据)。
    // 数量相等时退化为按下标配对,再不行用 STC[0]。
    const bool pairByIndex = (model.subTrackCollections.size() == model.sequences.size());
    for (size_t si = 0; si < model.sequences.size(); ++si) {
        const auto& seq = model.sequences[si];
        std::vector<const m3::SubTrackContainer*> stcs;
        for (const auto& g : model.animationGroups) {
            if (g.name == seq.name) {
                for (u32 idx : g.subtrackIndices)
                    if (idx < model.subTrackCollections.size())
                        stcs.push_back(&model.subTrackCollections[idx]);
                break;
            }
        }
        if (stcs.empty() && !model.subTrackCollections.empty())
            stcs.push_back(&model.subTrackCollections[pairByIndex ? si : 0]);

        WOAnimation anim;
        anim.name = sanitized(seq.name);
        anim.durationMs = frameToMs((i32)(seq.endFrame > seq.startFrame
                                              ? seq.endFrame - seq.startFrame : 0));
        anim.loops = true;  // v1:M3 一律循环
        for (const auto& bone : model.bones) {
            anim.translations.push_back(resolveBoneTrack<WOVec3Track>(
                stcs, bone.position.animId, bone.position.interpType, 2 /* sd3v */));
            anim.rotations.push_back(resolveBoneTrack<WOQuatTrack>(
                stcs, bone.rotation.animId, bone.rotation.interpType, 3 /* sd4q */));
            anim.scales.push_back(resolveBoneTrack<WOVec3Track>(
                stcs, bone.scale.animId, bone.scale.interpType, 2 /* sd3v */));
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
