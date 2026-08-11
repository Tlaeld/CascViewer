#pragma once
#include "WOTypes.h"
#include <cstddef>

namespace WhiteoutBridge {

enum class WOImageFormat : uint8_t { Unknown, BLP1, BLP2, DDS };

enum class WOImageCompression : uint8_t { Raw, DXTC1, DXTC3, DXTC5, JPEG, Unknown };

struct WOImageFrame {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgbaData;  // RGBA8888
};

struct WOImageDecodeResult {
    WOImageFormat format = WOImageFormat::Unknown;
    WOImageCompression compression = WOImageCompression::Unknown;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t mipLevels = 0;
    uint32_t frameCount = 1;
    bool hasAlpha = false;
    std::vector<WOImageFrame> frames;               // 1 帧(mip 0)
    std::vector<std::vector<WOImageFrame>> mipMaps; // mipMaps[level][frame]
};

class WOTextureDecoder {
public:
    WOImageDecodeResult decode(const uint8_t* data, size_t length, WOError& error);
};

// ── 测试支持(writer round-trip 夹具,无版权素材)──
// kind: 0 = BLP1, 1 = BLP2, 2 = DDS。返回编码后的文件字节(失败返回空)。
std::vector<uint8_t> WOEncodeTestImage(uint32_t width, uint32_t height, uint32_t kind);

} // namespace WhiteoutBridge
