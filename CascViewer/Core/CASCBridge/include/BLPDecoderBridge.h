#pragma once
#include "CascTypes.h"
#include <vector>
#include <cstdint>

namespace CascBridge {

enum class BLPFormat : uint8_t {
    BLP0,  // Unknown/invalid
    BLP1,
    BLP2
};

enum class BLPCompression : uint8_t {
    Raw,
    DXTC1,
    DXTC3,
    DXTC5,
    Unknown
};

struct BLPFrame {
    uint32_t width;
    uint32_t height;
    std::vector<uint8_t> rgbaData;  // Always RGBA8888
};

struct BLPDecodeResult {
    BLPFormat format;
    BLPCompression compression;
    uint32_t width;
    uint32_t height;
    uint32_t mipLevels;
    uint32_t frameCount;
    bool hasAlpha;
    std::vector<BLPFrame> frames;  // For animation: multiple frames. For static: 1 frame
    std::vector<std::vector<BLPFrame>> mipMaps;  // mipMaps[level][frame]
};

class BLPDecoderBridge {
public:
    BLPDecodeResult decode(const uint8_t* data, size_t length, CascError& error);
};

} // namespace CascBridge
