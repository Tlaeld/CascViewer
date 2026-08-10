#pragma once
#include "WOModel.h"
#include "WOTypes.h"

namespace WhiteoutBridge {

// M2 伴随文件(.skin/.anim/.skel)读取回调:
// 返回字节指针并写 outSize 为成功(指针须在 parse 返回前保持有效);NULL = 读取失败。
// 签名只用 C 兼容类型,便于 Swift @convention(c) 闭包实现。
typedef const uint8_t* (*WOM2ReadFileCallback)(void* ctx, uint32_t fileDataId,
                                               size_t* outSize);

class WOModelLoader {
public:
    WOModel parseMDX(const uint8_t* data, size_t length, WOError& error);
    WOModel parseM3(const uint8_t* data, size_t length, WOError& error);
    WOModel parseM2(const uint8_t* data, size_t length,
                    void* callbackCtx, WOM2ReadFileCallback callback,
                    WOError& error);
};

// ── 测试支持(writer round-trip 夹具,无版权素材)──
std::vector<uint8_t> WOEncodeTestMDX();  // 1 三角网格 / 2 骨骼 / 1 动画(Stand,1000ms)
std::vector<uint8_t> WOEncodeTestM3();   // Task 5 实现
std::vector<uint8_t> WOEncodeTestM2();   // Task 5 实现

} // namespace WhiteoutBridge
