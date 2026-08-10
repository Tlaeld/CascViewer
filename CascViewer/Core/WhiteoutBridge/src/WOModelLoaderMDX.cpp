#include "WOModelLoader.h"

#include <whiteout/models/mdx/mdx.h>

#include <cstring>
#include <unordered_map>

using namespace whiteout;

namespace WhiteoutBridge {

namespace {

WOVec2 toWO(const Vector2f& v) { return {v.x, v.y}; }
WOVec3 toWO(const Vector3f& v) { return {v.x, v.y, v.z}; }
WOVec4 toWO(const Quaternion& q) { return {q.x, q.y, q.z, q.w}; }

// MDX Track 的 keys()/tangentKeys() 非 const,先复制再访问。
WOVec3Track convertVec3Track(const mdx::Track<Vector3f>& src, u32 start, u32 end) {
    WOVec3Track out;
    if (!src.isUsed || src.keyCount == 0) return out;
    mdx::Track<Vector3f> tr = src;

    switch (tr.interpolationType) {
        case mdx::InterpolationType::None:   out.interp = WOInterpolation::Constant; break;
        case mdx::InterpolationType::Linear: out.interp = WOInterpolation::Linear; break;
        case mdx::InterpolationType::Hermite: out.interp = WOInterpolation::Hermite; break;
        case mdx::InterpolationType::Bezier: out.interp = WOInterpolation::Bezier; break;
    }
    const bool smooth = (out.interp == WOInterpolation::Hermite ||
                         out.interp == WOInterpolation::Bezier);
    const bool isGlobal = (tr.globalSequenceId != mdx::Track<Vector3f>::kNoGlobalSequence);

    for (size_t k = 0; k < tr.keyCount; ++k) {
        u32 t = tr.timestamps[k];
        if (!isGlobal) {
            if (t < start || t > end) continue;   // end 处关键帧保留(rebase 后 = duration)
            t -= start;
        }
        out.times.push_back(t);
        if (smooth) {
            const auto& tk = tr.tangentKeys()[k];
            out.keys.push_back(toWO(tk.value));
            out.inTangents.push_back(toWO(tk.inTan));
            out.outTangents.push_back(toWO(tk.outTan));
        } else {
            out.keys.push_back(toWO(tr.keys()[k]));
        }
    }
    return out;
}

WOQuatTrack convertQuatTrack(const mdx::Track<Quaternion>& src, u32 start, u32 end) {
    WOQuatTrack out;
    if (!src.isUsed || src.keyCount == 0) return out;
    mdx::Track<Quaternion> tr = src;

    switch (tr.interpolationType) {
        case mdx::InterpolationType::None:   out.interp = WOInterpolation::Constant; break;
        case mdx::InterpolationType::Linear: out.interp = WOInterpolation::Linear; break;
        case mdx::InterpolationType::Hermite: out.interp = WOInterpolation::Hermite; break;
        case mdx::InterpolationType::Bezier: out.interp = WOInterpolation::Bezier; break;
    }
    const bool smooth = (out.interp == WOInterpolation::Hermite ||
                         out.interp == WOInterpolation::Bezier);
    const bool isGlobal = (tr.globalSequenceId != mdx::Track<Quaternion>::kNoGlobalSequence);

    for (size_t k = 0; k < tr.keyCount; ++k) {
        u32 t = tr.timestamps[k];
        if (!isGlobal) {
            if (t < start || t > end) continue;   // end 处关键帧保留(rebase 后 = duration)
            t -= start;
        }
        out.times.push_back(t);
        if (smooth) {
            const auto& tk = tr.tangentKeys()[k];
            out.keys.push_back(toWO(tk.value));
            out.inTangents.push_back(toWO(tk.inTan));
            out.outTangents.push_back(toWO(tk.outTan));
        } else {
            out.keys.push_back(toWO(tr.keys()[k]));
        }
    }
    return out;
}

// 绑定姿态语义:MDX 顶点存的就是绑定位置,骨骼绑定变换 = 恒等。
// 动画时用锚点公式 local = T(pivot + t) R S T(-pivot),绑定(t=0,R=I,S=I)即恒等。
// 因此 inverseBind 一律为单位阵(无需 BPOS)。
void setIdentityInverseBinds(WOModel& out) {
    for (auto& bone : out.bones) {
        bone.inverseBind.assign(16, 0.0f);
        bone.inverseBind[0] = bone.inverseBind[5] = 1.0f;
        bone.inverseBind[10] = bone.inverseBind[15] = 1.0f;
    }
}

} // namespace

WOModel WOModelLoader::parseMDX(const uint8_t* data, size_t length, WOError& error) {
    error = WOError::None;
    WOModel out;
    out.format = WOModelFormat::MDX;
    if (!data || length == 0) { error = WOError::EmptyData; return out; }

    // WhiteoutLib 的 mdx::Parser 对错误 magic 不抛异常,只记 issue 并返回空
    // Model,这里先自查 MDLX 魔数,保证垃圾输入落到 ParseFailed。
    if (length < 4 || std::memcmp(data, "MDLX", 4) != 0) {
        error = WOError::ParseFailed;
        return out;
    }

    mdx::Model model;
    try {
        mdx::Parser parser;
        model = parser.parse(std::span<const u8>(data, length), mdx::MDLXFormat::MDX);
    } catch (const std::exception&) {
        error = WOError::ParseFailed;
        return out;
    }

    out.name = model.modelName;
    out.boundsMin = toWO(model.modelExtent.minimum);
    out.boundsMax = toWO(model.modelExtent.maximum);

    // ── 材质(只取 layer[0])──
    for (const auto& mat : model.materials) {
        WOMaterial wm;
        if (!mat.layers.empty()) {
            const auto& layer = mat.layers[0];
            if (layer.textureId < model.textures.size())
                wm.texturePath = model.textures[layer.textureId].fileName;
            switch (layer.filterMode) {
                case mdx::Layer::FilterMode::None:
                    wm.blendMode = WOBlendMode::Opaque; break;
                case mdx::Layer::FilterMode::Transparent:
                case mdx::Layer::FilterMode::Blend:
                    wm.blendMode = WOBlendMode::Blend; break;
                case mdx::Layer::FilterMode::Additive:
                case mdx::Layer::FilterMode::AddAlpha:
                    wm.blendMode = WOBlendMode::Additive; break;
                case mdx::Layer::FilterMode::Modulate:
                case mdx::Layer::FilterMode::Modulate2x:
                    wm.blendMode = WOBlendMode::Modulate; break;
            }
            const u32 sf = static_cast<u32>(layer.shadingFlags);
            wm.twoSided = (sf & 0x10) != 0;        // ShadingFlag::TwoSided
            wm.unlit = (sf & 0x101) != 0;          // Unshaded 0x1 | Unlit 0x100
        }
        out.materials.push_back(std::move(wm));
    }

    // ── 骨骼 ──
    std::unordered_map<u32, int32_t> nodeToBone;
    nodeToBone.reserve(model.bones.size());
    for (size_t i = 0; i < model.bones.size(); ++i) {
        const auto& b = model.bones[i];
        WOBone wb;
        wb.name = b.node.name;
        if (b.node.objectId < model.pivotPoints.size())
            wb.pivot = toWO(model.pivotPoints[b.node.objectId]);
        nodeToBone[b.node.objectId] = (int32_t)i;
        out.bones.push_back(std::move(wb));
    }
    for (size_t i = 0; i < model.bones.size(); ++i) {
        const u32 pid = model.bones[i].node.parentId;
        if (pid == mdx::Node::NO_PARENT) continue;
        auto it = nodeToBone.find(pid);
        if (it != nodeToBone.end()) {
            out.bones[i].parentIndex = it->second;
            // PIVT 为模型空间绝对坐标,转成父空间相对偏移(锚点公式用)。
            // 减数必须是父的原始绝对 pivot(model.pivotPoints)——out.bones[parent].pivot
            // 可能已被本循环就地改成相对值(父先于子处理时),深度 ≥3 的链会出错。
            // 越界时不做减法,与首个循环的 fallback(保持零值)语义一致。
            const u32 parentObjId = model.bones[it->second].node.objectId;
            if (parentObjId < model.pivotPoints.size()) {
                const Vector3f& parentPivot = model.pivotPoints[parentObjId];
                out.bones[i].pivot.x -= parentPivot.x;
                out.bones[i].pivot.y -= parentPivot.y;
                out.bones[i].pivot.z -= parentPivot.z;
            }
        }
        // 父不是骨骼(helper 等)v1 挂根
    }
    setIdentityInverseBinds(out);

    // ── 网格 ──
    for (const auto& g : model.geosets) {
        WOMesh mesh;
        const size_t vcount = g.vertexPositions.size();
        mesh.positions.reserve(vcount);
        for (const auto& p : g.vertexPositions) mesh.positions.push_back(toWO(p));
        mesh.normals.reserve(vcount);
        if (g.vertexNormals.size() == vcount) {
            for (const auto& n : g.vertexNormals) mesh.normals.push_back(toWO(n));
        } else {
            mesh.normals.assign(vcount, WOVec3{0, 0, 1});
        }
        if (!g.textureCoordinateSets.empty() &&
            g.textureCoordinateSets[0].size() == vcount) {
            mesh.uvs.reserve(vcount);
            for (const auto& uv : g.textureCoordinateSets[0]) mesh.uvs.push_back(toWO(uv));
        } else {
            mesh.uvs.assign(vcount, WOVec2{0, 0});
        }
        mesh.indices.reserve(g.faces.size());
        for (u16 idx : g.faces) mesh.indices.push_back((uint32_t)idx);
        mesh.materialIndex = (int32_t)g.materialId;

        mesh.boneIndices.resize(vcount * 4, 0);
        mesh.boneWeights.resize(vcount * 4, 0);
        if (g.skinData.size() == vcount * 8) {
            // Reforged SKIN:4 骨骼索引 + 4 权重(合计 255)
            for (size_t v = 0; v < vcount; ++v) {
                for (size_t j = 0; j < 4; ++j) {
                    mesh.boneIndices[v * 4 + j] = g.skinData[v * 8 + j];
                    mesh.boneWeights[v * 4 + j] = g.skinData[v * 8 + 4 + j];
                }
            }
        } else if (!g.vertexGroups.empty() && g.vertexGroups.size() == vcount &&
                   !g.matrixGroups.empty()) {
            // 经典 GNDX/MTGC/MATS:每顶点一个矩阵组,组内骨骼等权
            std::vector<std::pair<size_t, size_t>> ranges;
            size_t offset = 0;
            for (u32 count : g.matrixGroups) {
                ranges.push_back({offset, offset + count});
                offset += count;
            }
            for (size_t v = 0; v < vcount; ++v) {
                const u8 gi = g.vertexGroups[v];
                size_t n = 0;
                if (gi < ranges.size()) {
                    auto [begin, end] = ranges[gi];
                    for (size_t k = begin; k < end && k < g.matrixIndices.size() && n < 4; ++k) {
                        auto it = nodeToBone.find(g.matrixIndices[k]);
                        if (it == nodeToBone.end()) continue;  // 非骨骼节点跳过
                        mesh.boneIndices[v * 4 + n] = (uint8_t)it->second;
                        ++n;
                    }
                }
                if (n == 0) {  // 兜底:刚性绑 bone 0
                    n = 1;
                    mesh.boneIndices[v * 4] = 0;
                }
                const uint8_t w = (uint8_t)(255 / n);
                for (size_t j = 0; j < n; ++j) {
                    mesh.boneWeights[v * 4 + j] = (j == 0) ? (uint8_t)(255 - w * (n - 1)) : w;
                }
            }
        } else {
            // 无蒙皮信息:刚性绑 bone 0
            for (size_t v = 0; v < vcount; ++v) mesh.boneWeights[v * 4] = 255;
        }
        out.meshes.push_back(std::move(mesh));
    }

    // ── 动画(MDX 时间戳即毫秒;按序列区间过滤并 rebase)──
    for (const auto& seq : model.sequences) {
        WOAnimation anim;
        anim.name = seq.name;
        anim.durationMs = (seq.intervalEnd > seq.intervalStart)
                              ? seq.intervalEnd - seq.intervalStart : 0;
        anim.loops = (static_cast<u32>(seq.flags) & 0x1) == 0;  // Flag::NonLooping
        for (const auto& bone : model.bones) {
            anim.translations.push_back(
                convertVec3Track(bone.node.translationTracks, seq.intervalStart, seq.intervalEnd));
            anim.rotations.push_back(
                convertQuatTrack(bone.node.rotationTracks, seq.intervalStart, seq.intervalEnd));
            anim.scales.push_back(
                convertVec3Track(bone.node.scalingTracks, seq.intervalStart, seq.intervalEnd));
        }
        out.animations.push_back(std::move(anim));
    }

    return out;
}

// ── 测试夹具:1 三角网格 / 3 骨骼(深度 3 链)/ 1 个 1000ms "Stand" 动画 ──
std::vector<uint8_t> WOEncodeTestMDX() {
    mdx::Model model;
    model.version = 800;
    model.modelName = "TestModel";
    model.blendTime = 0;

    // 纹理 + 材质
    mdx::Texture tex;
    tex.fileName = "Textures/test.blp";
    model.textures.push_back(tex);

    mdx::Material mat;
    mdx::Layer layer;
    layer.filterMode = mdx::Layer::FilterMode::None;
    layer.textureId = 0;
    mat.layers.push_back(layer);
    model.materials.push_back(mat);

    // 骨骼 3 个(root → child → grandchild,深度 3 链验证 pivot 转换)
    mdx::Bone b0;
    b0.node.name = "root";
    b0.node.objectId = 0;
    b0.node.parentId = mdx::Node::NO_PARENT;
    mdx::Bone b1;
    b1.node.name = "child";
    b1.node.objectId = 1;
    b1.node.parentId = 0;
    // bone1 位移轨道:0ms 在原点,1000ms 移到 (0,1,0)
    b1.node.translationTracks.isUsed = true;
    b1.node.translationTracks.interpolationType = mdx::InterpolationType::Linear;
    b1.node.translationTracks.timestamps = {0, 1000};
    b1.node.translationTracks.keys_data = {Vector3f{0, 0, 0}, Vector3f{0, 1, 0}};
    b1.node.translationTracks.keyCount = 2;
    mdx::Bone b2;
    b2.node.name = "grandchild";
    b2.node.objectId = 2;
    b2.node.parentId = 1;
    model.bones = {b0, b1, b2};
    // PIVT 绝对坐标:同 x 的链,转换后应得 (10,0,0)/(0,0,5)/(0,0,4)
    model.pivotPoints = {Vector3f{10, 0, 0}, Vector3f{10, 0, 5}, Vector3f{10, 0, 9}};

    // 动画序列
    mdx::Sequence seq;
    seq.name = "Stand";
    seq.intervalStart = 0;
    seq.intervalEnd = 1000;
    seq.flags = mdx::Sequence::Flag::None;
    model.sequences.push_back(seq);

    // 1 个三角形网格(经典矩阵组蒙皮:v0,v1 → bone0;v2 → bone1)
    mdx::Geoset g;
    g.vertexPositions = {Vector3f{0, 0, 0}, Vector3f{1, 0, 0}, Vector3f{0, 1, 0}};
    g.vertexNormals = {Vector3f{0, 0, 1}, Vector3f{0, 0, 1}, Vector3f{0, 0, 1}};
    g.textureCoordinateSets = {{Vector2f{0, 0}, Vector2f{1, 0}, Vector2f{0, 1}}};
    g.faces = {0, 1, 2};
    g.materialId = 0;
    g.vertexGroups = {0, 0, 1};
    g.matrixGroups = {1, 1};
    g.matrixIndices = {0, 1};
    model.geosets.push_back(g);

    mdx::Writer writer;
    return writer.write(model, mdx::MDLXFormat::MDX);
}

} // namespace WhiteoutBridge
