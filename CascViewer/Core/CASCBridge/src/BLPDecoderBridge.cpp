#include "BLPDecoderBridge.h"
#include <cstring>

namespace CascBridge {

#pragma pack(push, 1)
struct BLP2Header {
    char magic[4];        // "BLP2"
    uint32_t type;        // 0=JPEG, 1=direct
    uint32_t compression; // 1=raw, 2=DXTC
    uint32_t alphaDepth;  // 0, 1, or 8
    uint32_t alphaType;   // 0-7
    uint32_t hasMips;     // 0 or 1
    uint32_t width;
    uint32_t height;
    uint32_t mipmapOffsets[16];
    uint32_t mipmapSizes[16];
};
#pragma pack(pop)

#pragma pack(push, 1)
struct BLP1Header {
    char magic[4];        // "BLP1"
    uint32_t compression; // 0=JPEG, 1=raw/paletted
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t alphaDepth;
    uint32_t mipmapOffsets[16];
    uint32_t mipmapSizes[16];
};
#pragma pack(pop)

BLPDecodeResult BLPDecoderBridge::decode(const uint8_t* data, size_t length, CascError& error) {
    error = CascError::None;

    if (length < 4) {
        error = CascError::DecodingError;
        return {};
    }

    // Check magic bytes
    bool isBLP2 = (std::strncmp(reinterpret_cast<const char*>(data), "BLP2", 4) == 0);
    bool isBLP1 = (std::strncmp(reinterpret_cast<const char*>(data), "BLP1", 4) == 0);

    if (!isBLP2 && !isBLP1) {
        error = CascError::DecodingError;
        return {};
    }

    BLPDecodeResult result;
    result.frameCount = 1;

    if (isBLP2) {
        if (length < sizeof(BLP2Header)) {
            error = CascError::DecodingError;
            return {};
        }

        BLP2Header header;
        std::memcpy(&header, data, sizeof(BLP2Header));

        result.format = BLPFormat::BLP2;
        result.width = header.width;
        result.height = header.height;
        result.hasAlpha = header.alphaDepth > 0;

        // Sanity check dimensions
        if (header.width > 16384 || header.height > 16384) {
            error = CascError::DecodingError;
            return {};
        }

        // Count mip levels with valid offsets
        result.mipLevels = 0;
        for (int i = 0; i < 16; ++i) {
            if (header.mipmapOffsets[i] > 0) {
                result.mipLevels++;
            } else {
                break;
            }
        }

        if (header.compression == 1) {
            // Raw/uncompressed
            result.compression = BLPCompression::Raw;

            uint32_t firstOffset = header.mipmapOffsets[0];
            uint32_t firstSize = header.mipmapSizes[0];
            size_t expectedSize = static_cast<size_t>(header.width) * header.height * 4;

            if (firstOffset == 0 || firstSize == 0) {
                error = CascError::DecodingError;
                return {};
            }

            if (static_cast<size_t>(firstOffset) + static_cast<size_t>(firstSize) > length) {
                error = CascError::DecodingError;
                return {};
            }

            BLPFrame frame;
            frame.width = header.width;
            frame.height = header.height;
            frame.rgbaData.resize(expectedSize);

            // Copy raw RGBA data
            const uint8_t* src = data + firstOffset;
            std::memcpy(frame.rgbaData.data(), src, std::min(static_cast<size_t>(firstSize), static_cast<size_t>(expectedSize)));

            result.frames.push_back(frame);

            // Populate mipMaps if present
            if (result.mipLevels > 1) {
                result.mipMaps.resize(result.mipLevels);
                for (uint32_t mip = 0; mip < result.mipLevels; ++mip) {
                    uint32_t offset = header.mipmapOffsets[mip];
                    uint32_t size = header.mipmapSizes[mip];
                    uint32_t mipWidth = std::max(1U, header.width >> mip);
                    uint32_t mipHeight = std::max(1U, header.height >> mip);
                    size_t mipExpectedSize = static_cast<size_t>(mipWidth) * mipHeight * 4;

                    if (offset == 0 || size == 0 || static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                        continue;
                    }

                    BLPFrame mipFrame;
                    mipFrame.width = mipWidth;
                    mipFrame.height = mipHeight;
                    mipFrame.rgbaData.resize(mipExpectedSize);
                    std::memcpy(mipFrame.rgbaData.data(), data + offset, std::min(static_cast<size_t>(size), static_cast<size_t>(mipExpectedSize)));
                    result.mipMaps[mip].push_back(mipFrame);
                }
            }
        } else if (header.compression == 2) {
            // DXTC - not yet supported
            error = CascError::DecodingError;
            return {};
        } else {
            result.compression = BLPCompression::Unknown;
            error = CascError::DecodingError;
            return {};
        }
    } else {
        // BLP1 - not yet supported
        error = CascError::DecodingError;
        return {};
    }

    return result;
}

} // namespace CascBridge
