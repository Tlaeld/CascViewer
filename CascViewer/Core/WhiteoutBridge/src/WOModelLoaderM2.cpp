#include "WOModelLoader.h"

#include <whiteout/models/m2/m2.h>
#include <whiteout/models/m2/parser.h>
#include <whiteout/interfaces.h>

using namespace whiteout;

namespace WhiteoutBridge {

namespace {

// 把 Swift 侧 C 回调适配成 WhiteoutLib 的 CascFileSystem(按 FileDataId 读伴随文件)。
class WOM2CallbackFS final : public interfaces::CascFileSystem {
public:
    WOM2CallbackFS(void* ctx, WOM2ReadFileCallback cb) : ctx_(ctx), cb_(cb) {}

    std::vector<u8> readFile(u32 fileId) const override {
        if (!cb_) return {};
        size_t size = 0;
        const uint8_t* p = cb_(ctx_, fileId, &size);
        if (!p || size == 0) return {};
        return std::vector<u8>(p, p + size);
    }
    std::optional<u32> reserveFileId(const std::string&) override { return std::nullopt; }
    bool writeFile(u32, const std::vector<u8>&) override { return false; }
    bool fileExists(u32 fileId) const override {
        if (!cb_) return false;
        size_t size = 0;
        return cb_(ctx_, fileId, &size) != nullptr && size > 0;
    }

private:
    void* ctx_;
    WOM2ReadFileCallback cb_;
};

WOVec2 toWO(const Vector2f& v) { return {v.x, v.y}; }
WOVec3 toWO(const Vector3f& v) { return {v.x, v.y, v.z}; }
WOVec4 toWO(const Quaternion& q) { return {q.x, q.y, q.z, q.w}; }

WOInterpolation mapM2Interp(m2::InterpolationType t) {
    switch (t) {  // 注意 M2 顺序:2=Bezier,3=Hermite(与 MDX 相反)
        case m2::InterpolationType::None:    return WOInterpolation::Constant;
        case m2::InterpolationType::Linear:  return WOInterpolation::Linear;
        case m2::InterpolationType::Bezier:  return WOInterpolation::Bezier;
        case m2::InterpolationType::Hermite: return WOInterpolation::Hermite;
    }
    return WOInterpolation::Constant;
}

WOVec3Track convertM2Vec3Track(const m2::AnimationTrack<Vector3f>& tr, size_t seqIdx) {
    WOVec3Track out;
    out.interp = mapM2Interp(tr.interpolationType);
    if (tr.globalSequenceId != 0xFFFF) return out;  // v1:跳过 global loop
    if (seqIdx >= tr.values.size() || seqIdx >= tr.timestamps.size()) return out;
    const auto& times = tr.timestamps[seqIdx];
    const auto& vals = tr.values[seqIdx];
    for (size_t k = 0; k < vals.size() && k < times.size(); ++k) {
        out.times.push_back(times[k]);  // M2 时间戳为毫秒
        out.keys.push_back(toWO(vals[k]));
    }
    return out;
}

WOQuatTrack convertM2QuatTrack(const m2::AnimationTrack<m2::CompatQuaternion>& tr,
                               size_t seqIdx) {
    WOQuatTrack out;
    out.interp = mapM2Interp(tr.interpolationType);
    if (tr.globalSequenceId != 0xFFFF) return out;
    if (seqIdx >= tr.values.size() || seqIdx >= tr.timestamps.size()) return out;
    const auto& times = tr.timestamps[seqIdx];
    const auto& vals = tr.values[seqIdx];
    for (size_t k = 0; k < vals.size() && k < times.size(); ++k) {
        out.times.push_back(times[k]);
        out.keys.push_back(toWO(static_cast<Quaternion>(vals[k])));
    }
    return out;
}

} // namespace

WOModel WOModelLoader::parseM2(const uint8_t* data, size_t length,
                               void* callbackCtx, WOM2ReadFileCallback callback,
                               WOError& error) {
    error = WOError::None;
    WOModel out;
    out.format = WOModelFormat::M2;
    if (!data || length == 0) { error = WOError::EmptyData; return out; }

    WOM2CallbackFS fs(callbackCtx, callback);
    m2::Model model;
    try {
        m2::Parser parser;
        model = parser.parse(fs, std::span<const u8>(data, length));
    } catch (const std::exception&) {
        error = WOError::ParseFailed;
        return out;
    }

    out.name = model.modelName;
    out.boundsMin = toWO(model.bounding.minimum);
    out.boundsMax = toWO(model.bounding.maximum);

    // ── 骨骼(M2 pivot 存的就是父空间偏移;绑定姿态 = 恒等,inverseBind 一律单位阵)──
    for (const auto& b : model.bones) {
        WOBone wb;
        wb.name = "bone_" + std::to_string(out.bones.size());  // M2 只有 CRC,无名
        wb.parentIndex = (int32_t)b.parentBoneId;              // -1 = root
        wb.pivot = toWO(b.pivot);
        wb.inverseBind.assign(16, 0.0f);
        wb.inverseBind[0] = wb.inverseBind[5] = 1.0f;
        wb.inverseBind[10] = wb.inverseBind[15] = 1.0f;
        out.bones.push_back(std::move(wb));
    }

    // ── 材质(WOMaterial 下标与 model.materials 对齐)──
    for (const auto& m : model.materials) {
        WOMaterial wm;
        switch (m.blendingMode) {
            case 0: wm.blendMode = WOBlendMode::Opaque; break;
            case 1: wm.blendMode = WOBlendMode::AlphaTest; break;
            case 2: wm.blendMode = WOBlendMode::Blend; break;
            case 3: wm.blendMode = WOBlendMode::Additive; break;
            default: wm.blendMode = WOBlendMode::Blend; break;
        }
        wm.twoSided = (m.flags & 0x04) != 0;
        wm.unlit = (m.flags & 0x01) != 0;
        out.materials.push_back(std::move(wm));
    }

    // ── 网格:skinProfiles[0],按 SkinSection 拆分 ──
    if (!model.skinProfiles.empty()) {
        const auto& skin = model.skinProfiles[0];
        for (size_t si = 0; si < skin.submeshes.size(); ++si) {
            const auto& sec = skin.submeshes[si];
            WOMesh mesh;
            const size_t v0 = sec.vertexStart;
            const size_t vc = sec.vertexCount;
            if (v0 + vc > skin.vertices.size() || skin.vertices.empty()) continue;

            // skin 顶点表是全局顶点下标的重映射
            for (size_t k = v0; k < v0 + vc; ++k) {
                const u16 gv = skin.vertices[k];
                if (gv >= model.vertices.size()) continue;
                const auto& sv = model.vertices[gv];
                mesh.positions.push_back(toWO(sv.position));
                mesh.normals.push_back(toWO(sv.normal));
                mesh.uvs.push_back(toWO(sv.texCoords[0]));
                // 骨骼索引经 boneCombos 重映射
                for (size_t j = 0; j < 4; ++j) {
                    u8 bi = sv.boneIndices[j];
                    const size_t combo = (size_t)sec.boneComboIndex + bi;
                    if (!model.boneCombos.empty() && combo < model.boneCombos.size())
                        bi = (u8)model.boneCombos[combo];
                    mesh.boneIndices.push_back(bi);
                    mesh.boneWeights.push_back(sv.boneWeights[j]);
                }
            }
            const size_t i0 = sec.indexStart;
            const size_t ic = sec.indexCount;
            for (size_t k = i0; k < i0 + ic && k < skin.indices.size(); ++k)
                mesh.indices.push_back((uint32_t)skin.indices[k] - (uint32_t)v0);

            // 材质:batch.skinSectionIndex → materials;纹理:textureCombos → textures/TXID
            for (const auto& batch : skin.batches) {
                if (batch.skinSectionIndex != si) continue;
                mesh.materialIndex = (int32_t)batch.materialIndex;
                const size_t tc = (size_t)batch.textureComboIndex;
                if (tc < model.textureCombos.size()) {
                    const u16 texIdx = model.textureCombos[tc];
                    if (texIdx < model.textures.size()) {
                        const auto& tex = model.textures[texIdx];
                        // 纹理引用写到 WOMaterial(按下标对齐的占位:存在 materialIndex 上)
                        if (mesh.materialIndex >= 0 &&
                            (size_t)mesh.materialIndex < out.materials.size()) {
                            auto& wm = out.materials[mesh.materialIndex];
                            if (!tex.filename.empty()) wm.texturePath = tex.filename;
                            if (texIdx < model.texture_ids.size())
                                wm.textureFileDataId = model.texture_ids[texIdx];
                        }
                    }
                }
                break;
            }
            out.meshes.push_back(std::move(mesh));
        }
    }

    // ── 动画:values/timestamps 按 sequence 下标取 ──
    for (size_t si = 0; si < model.sequences.size(); ++si) {
        const auto& seq = model.sequences[si];
        WOAnimation anim;
        anim.name = "anim_" + std::to_string(seq.id);
        anim.durationMs = seq.duration;
        anim.loops = (static_cast<u32>(seq.flags) & 0x20) != 0;  // SequenceFlag::Looping
        for (const auto& bone : model.bones) {
            anim.translations.push_back(convertM2Vec3Track(bone.translation, si));
            anim.rotations.push_back(convertM2QuatTrack(bone.rotation, si));
            anim.scales.push_back(convertM2Vec3Track(bone.scale, si));
        }
        out.animations.push_back(std::move(anim));
    }

    return out;
}

// ── 测试夹具:最小空模型(冒烟,验证 parse 不抛异常)──
std::vector<uint8_t> WOEncodeTestM2() {
    m2::Model model{};
    model.modelName = "TestM2";
    m2::Writer writer;
    auto result = writer.write(model);
    return result.m2Data;
}

} // namespace WhiteoutBridge
