#pragma once
#include "CascTypes.h"
#include <vector>
#include <cstdint>

namespace CascBridge {

enum class ImageFormat : uint8_t {
    Unknown,
    BLP1,
    BLP2,
    DDS
};

enum class ImageCompression : uint8_t {
    Raw,
    DXTC1,
    DXTC3,
    DXTC5,
    JPEG,
    Unknown
};

struct BLPFrame {
    uint32_t width;
    uint32_t height;
    std::vector<uint8_t> rgbaData;  // Always RGBA8888
};

struct ImageDecodeResult {
    ImageFormat format;
    ImageCompression compression;
    uint32_t width;
    uint32_t height;
    uint32_t mipLevels;
    uint32_t frameCount;
    bool hasAlpha;
    std::vector<BLPFrame> frames;  // For animation: multiple frames. For static: 1 frame
    std::vector<std::vector<BLPFrame>> mipMaps;  // mipMaps[level][frame]
};

class ImageDecoderBridge {
public:
    ImageDecodeResult decode(const uint8_t* data, size_t length, CascError& error);
};

} // namespace CascBridge
