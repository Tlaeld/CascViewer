#include "BLPDecoderBridge.h"
#include <cstring>
#include <algorithm>
#include <thread>
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>

namespace CascBridge {

#pragma pack(push, 1)
struct BLP2Header {
    char magic[4];        // "BLP2"
    uint32_t type;        // 0=JPEG, 1=direct
    uint8_t compression;  // 1=raw, 2=DXTC
    uint8_t alphaDepth;   // 0, 1, or 8
    uint8_t alphaType;    // 0-7
    uint8_t hasMips;      // 0 or 1
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

#pragma pack(push, 1)
struct DDSHeader {
    char magic[4];        // "DDS "
    uint32_t dwSize;
    uint32_t dwFlags;
    uint32_t dwHeight;
    uint32_t dwWidth;
    uint32_t dwPitchOrLinearSize;
    uint32_t dwDepth;
    uint32_t dwMipMapCount;
    uint32_t dwReserved1[11];
    // Pixel format (32 bytes)
    uint32_t pfSize;
    uint32_t pfFlags;
    char pfFourCC[4];
    uint32_t pfRGBBitCount;
    uint32_t pfRBitMask;
    uint32_t pfGBitMask;
    uint32_t pfBBitMask;
    uint32_t pfABitMask;
    uint32_t dwCaps;
    uint32_t dwCaps2;
    uint32_t dwCaps3;
    uint32_t dwCaps4;
    uint32_t dwReserved2;
};
#pragma pack(pop)

static_assert(sizeof(DDSHeader) == 128, "DDS header size mismatch");

// ---------------------------------------------------------------------------
// DXT decompression helpers
// ---------------------------------------------------------------------------

static uint16_t readLE16(const uint8_t* p) {
    return p[0] | (p[1] << 8);
}

struct DXTColor {
    uint8_t r, g, b, a;
};

static void decodeRGB565(uint16_t c, uint8_t& r, uint8_t& g, uint8_t& b) {
    r = ((c >> 11) & 0x1F) << 3;
    g = ((c >> 5) & 0x3F) << 2;
    b = (c & 0x1F) << 3;
}

static void decompressDXT1Color(const uint8_t* src, DXTColor* dst, int stride, bool hasAlpha) {
    uint16_t c0 = readLE16(src);
    uint16_t c1 = readLE16(src + 2);
    uint32_t lookup = src[4] | (src[5] << 8) | (src[6] << 16) | (src[7] << 24);

    DXTColor colors[4];
    decodeRGB565(c0, colors[0].r, colors[0].g, colors[0].b);
    colors[0].a = 255;
    decodeRGB565(c1, colors[1].r, colors[1].g, colors[1].b);
    colors[1].a = 255;

    bool useAlpha = hasAlpha && (c0 <= c1);

    if (!useAlpha) {
        colors[2].r = static_cast<uint8_t>((2 * colors[0].r + colors[1].r) / 3);
        colors[2].g = static_cast<uint8_t>((2 * colors[0].g + colors[1].g) / 3);
        colors[2].b = static_cast<uint8_t>((2 * colors[0].b + colors[1].b) / 3);
        colors[2].a = 255;

        colors[3].r = static_cast<uint8_t>((colors[0].r + 2 * colors[1].r) / 3);
        colors[3].g = static_cast<uint8_t>((colors[0].g + 2 * colors[1].g) / 3);
        colors[3].b = static_cast<uint8_t>((colors[0].b + 2 * colors[1].b) / 3);
        colors[3].a = 255;
    } else {
        colors[2].r = static_cast<uint8_t>((colors[0].r + colors[1].r) / 2);
        colors[2].g = static_cast<uint8_t>((colors[0].g + colors[1].g) / 2);
        colors[2].b = static_cast<uint8_t>((colors[0].b + colors[1].b) / 2);
        colors[2].a = 255;

        colors[3].r = 0;
        colors[3].g = 0;
        colors[3].b = 0;
        colors[3].a = 0;
    }

    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            int idx = (lookup >> (2 * (y * 4 + x))) & 0x3;
            dst[y * stride + x] = colors[idx];
        }
    }
}

static void decompressDXT3Block(const uint8_t* src, DXTColor* dst, int stride) {
    uint64_t alphaBits = 0;
    for (int i = 0; i < 8; i++) {
        alphaBits |= (uint64_t)src[i] << (i * 8);
    }
    // Color portion (same as DXT1, always 4 colors)
    decompressDXT1Color(src + 8, dst, stride, false);
    // Apply explicit 4-bit alpha
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            int idx = y * 4 + x;
            uint8_t a = (alphaBits >> (idx * 4)) & 0xF;
            dst[y * stride + x].a = a | (a << 4);
        }
    }
}

static void decompressDXT5Block(const uint8_t* src, DXTColor* dst, int stride) {
    uint8_t a0 = src[0];
    uint8_t a1 = src[1];
    uint64_t alphaLookup = 0;
    for (int i = 0; i < 6; i++) {
        alphaLookup |= (uint64_t)src[2 + i] << (i * 8);
    }

    uint8_t alpha[8];
    alpha[0] = a0;
    alpha[1] = a1;
    if (a0 > a1) {
        alpha[2] = static_cast<uint8_t>((6 * a0 + 1 * a1) / 7);
        alpha[3] = static_cast<uint8_t>((5 * a0 + 2 * a1) / 7);
        alpha[4] = static_cast<uint8_t>((4 * a0 + 3 * a1) / 7);
        alpha[5] = static_cast<uint8_t>((3 * a0 + 4 * a1) / 7);
        alpha[6] = static_cast<uint8_t>((2 * a0 + 5 * a1) / 7);
        alpha[7] = static_cast<uint8_t>((1 * a0 + 6 * a1) / 7);
    } else {
        alpha[2] = static_cast<uint8_t>((4 * a0 + 1 * a1) / 5);
        alpha[3] = static_cast<uint8_t>((3 * a0 + 2 * a1) / 5);
        alpha[4] = static_cast<uint8_t>((2 * a0 + 3 * a1) / 5);
        alpha[5] = static_cast<uint8_t>((1 * a0 + 4 * a1) / 5);
        alpha[6] = 0;
        alpha[7] = 255;
    }

    decompressDXT1Color(src + 8, dst, stride, false);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            int idx = y * 4 + x;
            int aIdx = (alphaLookup >> (idx * 3)) & 0x7;
            dst[y * stride + x].a = alpha[aIdx];
        }
    }
}

static bool decompressDXT(uint32_t width, uint32_t height, const uint8_t* data, size_t dataLen,
                          ImageCompression compression, std::vector<uint8_t>& rgba) {
    if (width == 0 || height == 0) return false;

    size_t blockCountX = (width + 3) / 4;
    size_t blockCountY = (height + 3) / 4;
    size_t blockSize = (compression == ImageCompression::DXTC1) ? 8 : 16;
    size_t expectedDataSize = blockCountX * blockCountY * blockSize;
    if (dataLen < expectedDataSize) return false;

    rgba.resize(static_cast<size_t>(width) * height * 4);

    auto decompressRows = [&](size_t startRow, size_t endRow) {
        DXTColor block[4 * 4];
        for (size_t by = startRow; by < endRow; ++by) {
            for (size_t bx = 0; bx < blockCountX; ++bx) {
                const uint8_t* src = data + (by * blockCountX + bx) * blockSize;
                if (compression == ImageCompression::DXTC1) {
                    decompressDXT1Color(src, block, 4, false);
                } else if (compression == ImageCompression::DXTC3) {
                    decompressDXT3Block(src, block, 4);
                } else {
                    decompressDXT5Block(src, block, 4);
                }

                for (int y = 0; y < 4; y++) {
                    for (int x = 0; x < 4; x++) {
                        uint32_t px = static_cast<uint32_t>(bx * 4 + x);
                        uint32_t py = static_cast<uint32_t>(by * 4 + y);
                        if (px < width && py < height) {
                            size_t dstOff = (py * width + px) * 4;
                            DXTColor& c = block[y * 4 + x];
                            rgba[dstOff + 0] = c.r;
                            rgba[dstOff + 1] = c.g;
                            rgba[dstOff + 2] = c.b;
                            rgba[dstOff + 3] = c.a;
                        }
                    }
                }
            }
        }
    };

    // Small images: single-thread to avoid thread overhead
    const size_t minRowsPerThread = 8;
    size_t numThreads = std::thread::hardware_concurrency();
    if (numThreads == 0) numThreads = 4;
    if (blockCountY < minRowsPerThread * numThreads) {
        decompressRows(0, blockCountY);
        return true;
    }

    size_t rowsPerThread = (blockCountY + numThreads - 1) / numThreads;
    std::vector<std::thread> threads;
    threads.reserve(numThreads);

    for (size_t t = 0; t < numThreads; ++t) {
        size_t startRow = t * rowsPerThread;
        size_t endRow = std::min(startRow + rowsPerThread, blockCountY);
        if (startRow >= endRow) break;
        threads.emplace_back(decompressRows, startRow, endRow);
    }

    for (auto& t : threads) {
        t.join();
    }
    return true;
}

// ---------------------------------------------------------------------------
// DDS parsing
// ---------------------------------------------------------------------------

static bool fourccMatch(const char* a, const char* b) {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
}

static ImageDecodeResult decodeDDS(const uint8_t* data, size_t length, CascError& error) {
    error = CascError::None;
    ImageDecodeResult result;
    result.frameCount = 1;

    if (length < sizeof(DDSHeader)) {
        error = CascError::DecodingError;
        return result;
    }

    DDSHeader header;
    std::memcpy(&header, data, sizeof(DDSHeader));

    if (header.dwSize != 124) {
        error = CascError::DecodingError;
        return result;
    }

    uint32_t width = header.dwWidth;
    uint32_t height = header.dwHeight;

    if (width > 16384 || height > 16384 || width == 0 || height == 0) {
        error = CascError::DecodingError;
        return result;
    }

    result.format = ImageFormat::DDS;
    result.width = width;
    result.height = height;
    result.mipLevels = std::max(1U, header.dwMipMapCount);

    ImageCompression compression = ImageCompression::Unknown;
    bool hasAlpha = false;

    if (header.pfFlags & 0x4) { // DDPF_FOURCC
        if (fourccMatch(header.pfFourCC, "DXT1")) {
            compression = ImageCompression::DXTC1;
            hasAlpha = false;
        } else if (fourccMatch(header.pfFourCC, "DXT3")) {
            compression = ImageCompression::DXTC3;
            hasAlpha = true;
        } else if (fourccMatch(header.pfFourCC, "DXT5")) {
            compression = ImageCompression::DXTC5;
            hasAlpha = true;
        } else if (fourccMatch(header.pfFourCC, "DX10")) {
            // We don't parse DX10 DXGI_FORMAT here — would need mapping table
            error = CascError::DecodingError;
            return result;
        }
    }

    if (compression == ImageCompression::Unknown) {
        error = CascError::DecodingError;
        return result;
    }

    result.compression = compression;
    result.hasAlpha = hasAlpha;

    size_t dataOffset = sizeof(DDSHeader);
    size_t blockSize = (compression == ImageCompression::DXTC1) ? 8 : 16;
    size_t blockCountX = (width + 3) / 4;
    size_t blockCountY = (height + 3) / 4;
    size_t mainLevelSize = blockCountX * blockCountY * blockSize;

    if (dataOffset + mainLevelSize > length) {
        error = CascError::DecodingError;
        return result;
    }

    // Decode main image
    BLPFrame frame;
    frame.width = width;
    frame.height = height;
    if (!decompressDXT(width, height, data + dataOffset, mainLevelSize, compression, frame.rgbaData)) {
        error = CascError::DecodingError;
        return result;
    }
    result.frames.push_back(frame);

    // Decode mipmaps
    size_t mipOffset = dataOffset + mainLevelSize;
    result.mipMaps.resize(result.mipLevels);
    result.mipMaps[0].push_back(frame);

    for (uint32_t mip = 1; mip < result.mipLevels; mip++) {
        uint32_t mipW = std::max(1U, width >> mip);
        uint32_t mipH = std::max(1U, height >> mip);
        size_t mipBlockX = (mipW + 3) / 4;
        size_t mipBlockY = (mipH + 3) / 4;
        size_t mipSize = mipBlockX * mipBlockY * blockSize;

        if (mipOffset + mipSize > length) break;

        BLPFrame mipFrame;
        mipFrame.width = mipW;
        mipFrame.height = mipH;
        if (decompressDXT(mipW, mipH, data + mipOffset, mipSize, compression, mipFrame.rgbaData)) {
            result.mipMaps[mip].push_back(mipFrame);
        }
        mipOffset += mipSize;
    }

    return result;
}

// ---------------------------------------------------------------------------
// JPEG decoding via ImageIO
// ---------------------------------------------------------------------------

static bool decodeJPEGData(const uint8_t* jpegData, size_t jpegLen,
                           uint32_t& outW, uint32_t& outH,
                           std::vector<uint8_t>& rgba) {
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault, jpegData, jpegLen);
    if (!cfData) return false;

    CGImageSourceRef source = CGImageSourceCreateWithData(cfData, NULL);
    CFRelease(cfData);
    if (!source) return false;

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return false;

    outW = static_cast<uint32_t>(CGImageGetWidth(image));
    outH = static_cast<uint32_t>(CGImageGetHeight(image));

    size_t width = outW;
    size_t height = outH;
    rgba.resize(width * height * 4);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        rgba.data(), width, height, 8, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        CGImageRelease(image);
        return false;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);

    // Convert premultiplied alpha to straight alpha
    for (size_t i = 0; i < width * height; ++i) {
        uint8_t a = rgba[i * 4 + 3];
        if (a > 0 && a < 255) {
            rgba[i * 4 + 0] = static_cast<uint8_t>(std::min(255, static_cast<int>(rgba[i * 4 + 0] * 255 / a)));
            rgba[i * 4 + 1] = static_cast<uint8_t>(std::min(255, static_cast<int>(rgba[i * 4 + 1] * 255 / a)));
            rgba[i * 4 + 2] = static_cast<uint8_t>(std::min(255, static_cast<int>(rgba[i * 4 + 2] * 255 / a)));
        }
    }

    return true;
}

// ---------------------------------------------------------------------------
// BLP parsing
// ---------------------------------------------------------------------------

static ImageDecodeResult decodeBLP(const uint8_t* data, size_t length, CascError& error) {
    error = CascError::None;
    ImageDecodeResult result;
    result.frameCount = 1;

    bool isBLP2 = (std::strncmp(reinterpret_cast<const char*>(data), "BLP2", 4) == 0);
    bool isBLP1 = (std::strncmp(reinterpret_cast<const char*>(data), "BLP1", 4) == 0);

    if (!isBLP2 && !isBLP1) {
        error = CascError::DecodingError;
        return result;
    }

    if (isBLP2) {
        if (length < sizeof(BLP2Header)) {
            error = CascError::DecodingError;
            return result;
        }

        BLP2Header header;
        std::memcpy(&header, data, sizeof(BLP2Header));

        result.format = ImageFormat::BLP2;
        result.width = header.width;
        result.height = header.height;
        result.hasAlpha = header.alphaDepth > 0;

        if (header.width > 16384 || header.height > 16384) {
            error = CascError::DecodingError;
            return result;
        }

        result.mipLevels = 0;
        for (int i = 0; i < 16; ++i) {
            if (header.mipmapOffsets[i] > 0) {
                result.mipLevels++;
            } else {
                break;
            }
        }

        if (header.type == 0) {
            // BLP2 JPEG
            result.compression = ImageCompression::JPEG;

            uint32_t firstOffset = header.mipmapOffsets[0];
            uint32_t firstSize = header.mipmapSizes[0];
            if (firstOffset == 0 || firstSize == 0 ||
                static_cast<size_t>(firstOffset) + static_cast<size_t>(firstSize) > length) {
                error = CascError::DecodingError;
                return result;
            }

            // BLP2 JPEG mipmap data: first 4 bytes may be JPEG size prefix, rest is JPEG data.
            // Some files have raw JPEG starting at offset.
            auto resolveJPEG = [&](const uint8_t* ptr, uint32_t totalSize,
                                   const uint8_t*& outPtr, uint32_t& outSize) -> bool {
                if (totalSize > 4 && ptr[0] == 0xFF && ptr[1] == 0xD8) {
                    // Raw JPEG data
                    outPtr = ptr;
                    outSize = totalSize;
                    return true;
                }
                if (totalSize > 4) {
                    uint32_t declaredSize;
                    std::memcpy(&declaredSize, ptr, sizeof(uint32_t));
                    if (ptr[4] == 0xFF && ptr[5] == 0xD8) {
                        outPtr = ptr + 4;
                        outSize = (declaredSize > 0 && declaredSize <= totalSize - 4)
                                  ? declaredSize
                                  : (totalSize - 4);
                        return true;
                    }
                }
                return false;
            };

            const uint8_t* jpegPtr = nullptr;
            uint32_t jpegSize = 0;
            if (!resolveJPEG(data + firstOffset, firstSize, jpegPtr, jpegSize)) {
                error = CascError::DecodingError;
                return result;
            }

            BLPFrame frame;
            if (!decodeJPEGData(jpegPtr, jpegSize, frame.width, frame.height, frame.rgbaData)) {
                error = CascError::DecodingError;
                return result;
            }
            result.frames.push_back(frame);

            if (result.mipLevels > 1) {
                result.mipMaps.resize(result.mipLevels);
                result.mipMaps[0].push_back(frame);
                for (uint32_t mip = 1; mip < result.mipLevels; ++mip) {
                    uint32_t offset = header.mipmapOffsets[mip];
                    uint32_t size = header.mipmapSizes[mip];

                    if (offset == 0 || size == 0 ||
                        static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                        continue;
                    }

                    const uint8_t* mipJpegPtr = nullptr;
                    uint32_t mipJpegSize = 0;
                    if (!resolveJPEG(data + offset, size, mipJpegPtr, mipJpegSize)) {
                        continue;
                    }

                    BLPFrame mipFrame;
                    if (decodeJPEGData(mipJpegPtr, mipJpegSize, mipFrame.width, mipFrame.height, mipFrame.rgbaData)) {
                        result.mipMaps[mip].push_back(mipFrame);
                    }
                }
            }
        } else if (header.type == 1) {
            if (header.compression == 1) {
                // BLP2 Raw
                result.compression = ImageCompression::Raw;

                uint32_t firstOffset = header.mipmapOffsets[0];
                uint32_t firstSize = header.mipmapSizes[0];
                size_t expectedSize = static_cast<size_t>(header.width) * header.height * 4;

                if (firstOffset == 0 || firstSize == 0 ||
                    static_cast<size_t>(firstOffset) + static_cast<size_t>(firstSize) > length) {
                    error = CascError::DecodingError;
                    return result;
                }

                BLPFrame frame;
                frame.width = header.width;
                frame.height = header.height;
                frame.rgbaData.resize(expectedSize);
                std::memcpy(frame.rgbaData.data(), data + firstOffset,
                            std::min(static_cast<size_t>(firstSize), expectedSize));
                result.frames.push_back(frame);

                if (result.mipLevels > 1) {
                    result.mipMaps.resize(result.mipLevels);
                    result.mipMaps[0].push_back(frame);
                    for (uint32_t mip = 1; mip < result.mipLevels; ++mip) {
                        uint32_t offset = header.mipmapOffsets[mip];
                        uint32_t size = header.mipmapSizes[mip];
                        uint32_t mipW = std::max(1U, header.width >> mip);
                        uint32_t mipH = std::max(1U, header.height >> mip);
                        size_t mipExpected = static_cast<size_t>(mipW) * mipH * 4;

                        if (offset == 0 || size == 0 ||
                            static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                            continue;
                        }

                        BLPFrame mipFrame;
                        mipFrame.width = mipW;
                        mipFrame.height = mipH;
                        mipFrame.rgbaData.resize(mipExpected);
                        std::memcpy(mipFrame.rgbaData.data(), data + offset,
                                    std::min(static_cast<size_t>(size), mipExpected));
                        result.mipMaps[mip].push_back(mipFrame);
                    }
                }
            } else if (header.compression == 2) {
                // BLP2 with DXTC
                ImageCompression comp = ImageCompression::Unknown;
                if (header.alphaDepth == 0) {
                    comp = ImageCompression::DXTC1;
                } else if (header.alphaDepth == 1) {
                    comp = ImageCompression::DXTC3;
                } else {
                    comp = ImageCompression::DXTC5;
                }
                result.compression = comp;

                uint32_t firstOffset = header.mipmapOffsets[0];
                uint32_t firstSize = header.mipmapSizes[0];
                if (firstOffset == 0 || firstSize == 0 ||
                    static_cast<size_t>(firstOffset) + static_cast<size_t>(firstSize) > length) {
                    error = CascError::DecodingError;
                    return result;
                }

                BLPFrame frame;
                frame.width = header.width;
                frame.height = header.height;
                if (!decompressDXT(header.width, header.height, data + firstOffset, firstSize, comp, frame.rgbaData)) {
                    error = CascError::DecodingError;
                    return result;
                }
                result.frames.push_back(frame);
                result.hasAlpha = (header.alphaDepth > 0);

                if (result.mipLevels > 1) {
                    result.mipMaps.resize(result.mipLevels);
                    result.mipMaps[0].push_back(frame);
                    for (uint32_t mip = 1; mip < result.mipLevels; ++mip) {
                        uint32_t offset = header.mipmapOffsets[mip];
                        uint32_t size = header.mipmapSizes[mip];
                        uint32_t mipW = std::max(1U, header.width >> mip);
                        uint32_t mipH = std::max(1U, header.height >> mip);
                        size_t mipExpected = static_cast<size_t>(mipW) * mipH * 4;

                        if (offset == 0 || size == 0 ||
                            static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                            continue;
                        }

                        BLPFrame mipFrame;
                        mipFrame.width = mipW;
                        mipFrame.height = mipH;
                        mipFrame.rgbaData.resize(mipExpected);
                        if (!decompressDXT(mipW, mipH, data + offset, size, comp, mipFrame.rgbaData)) {
                            continue;
                        }
                        result.mipMaps[mip].push_back(mipFrame);
                    }
                }
            } else {
                result.compression = ImageCompression::Unknown;
                error = CascError::DecodingError;
                return result;
            }
        } else {
            result.compression = ImageCompression::Unknown;
            error = CascError::DecodingError;
            return result;
        }
    } else {
        // BLP1
        result.format = ImageFormat::BLP1;

        if (length < sizeof(BLP1Header)) {
            error = CascError::DecodingError;
            return result;
        }

        BLP1Header header;
        std::memcpy(&header, data, sizeof(BLP1Header));

        result.width = header.width;
        result.height = header.height;
        result.hasAlpha = header.alphaDepth > 0;

        if (header.width > 16384 || header.height > 16384 || header.width == 0 || header.height == 0) {
            error = CascError::DecodingError;
            return result;
        }

        result.mipLevels = 0;
        for (int i = 0; i < 16; ++i) {
            if (header.mipmapOffsets[i] > 0) {
                result.mipLevels++;
            } else {
                break;
            }
        }

        if (header.compression == 0) {
            // BLP1 JPEG
            result.compression = ImageCompression::JPEG;

            uint32_t firstOffset = header.mipmapOffsets[0];
            uint32_t firstSize = header.mipmapSizes[0];
            if (firstOffset == 0 || firstSize == 0 ||
                static_cast<size_t>(firstOffset) + static_cast<size_t>(firstSize) > length) {
                error = CascError::DecodingError;
                return result;
            }

            BLPFrame frame;
            if (!decodeJPEGData(data + firstOffset, firstSize, frame.width, frame.height, frame.rgbaData)) {
                error = CascError::DecodingError;
                return result;
            }
            result.frames.push_back(frame);

            if (result.mipLevels > 1) {
                result.mipMaps.resize(result.mipLevels);
                result.mipMaps[0].push_back(frame);
                for (uint32_t mip = 1; mip < result.mipLevels; ++mip) {
                    uint32_t offset = header.mipmapOffsets[mip];
                    uint32_t size = header.mipmapSizes[mip];

                    if (offset == 0 || size == 0 ||
                        static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                        continue;
                    }

                    BLPFrame mipFrame;
                    if (decodeJPEGData(data + offset, size, mipFrame.width, mipFrame.height, mipFrame.rgbaData)) {
                        result.mipMaps[mip].push_back(mipFrame);
                    }
                }
            }
        } else if (header.compression == 1) {
            // Raw/paletted BLP1
            result.compression = ImageCompression::Raw;

            size_t paletteOffset = sizeof(BLP1Header);
            if (paletteOffset + 1024 > length) {
                error = CascError::DecodingError;
                return result;
            }

            struct PaletteColor { uint8_t b, g, r, a; };
            const PaletteColor* palette = reinterpret_cast<const PaletteColor*>(data + paletteOffset);

            auto decodeBLP1Mip = [&](uint32_t w, uint32_t h, uint32_t offset, uint32_t size, BLPFrame& outFrame) -> bool {
                size_t pixelCount = static_cast<size_t>(w) * h;
                size_t indexDataSize = pixelCount;

                size_t requiredSize = indexDataSize;
                if (header.alphaDepth == 8) {
                    requiredSize += pixelCount;
                } else if (header.alphaDepth == 1) {
                    requiredSize += (pixelCount + 7) / 8;
                }

                if (size < requiredSize ||
                    static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                    return false;
                }

                outFrame.width = w;
                outFrame.height = h;
                outFrame.rgbaData.resize(pixelCount * 4);

                const uint8_t* indices = data + offset;
                const uint8_t* alphaData = indices + indexDataSize;
                size_t alphaDataSize = size - indexDataSize;

                for (size_t i = 0; i < pixelCount; ++i) {
                    uint8_t idx = indices[i];
                    const PaletteColor& c = palette[idx];
                    outFrame.rgbaData[i * 4 + 0] = c.r;
                    outFrame.rgbaData[i * 4 + 1] = c.g;
                    outFrame.rgbaData[i * 4 + 2] = c.b;

                    if (header.alphaDepth == 0) {
                        outFrame.rgbaData[i * 4 + 3] = 255;
                    } else if (header.alphaDepth == 8) {
                        outFrame.rgbaData[i * 4 + 3] = (i < alphaDataSize) ? alphaData[i] : 255;
                    } else if (header.alphaDepth == 1) {
                        size_t byteIdx = i / 8;
                        size_t bitIdx = i % 8;
                        outFrame.rgbaData[i * 4 + 3] = (byteIdx < alphaDataSize && ((alphaData[byteIdx] >> bitIdx) & 1)) ? 255 : 0;
                    } else {
                        outFrame.rgbaData[i * 4 + 3] = 255;
                    }
                }
                return true;
            };

            BLPFrame frame;
            if (!decodeBLP1Mip(header.width, header.height, header.mipmapOffsets[0], header.mipmapSizes[0], frame)) {
                error = CascError::DecodingError;
                return result;
            }
            result.frames.push_back(frame);

            if (result.mipLevels > 1) {
                result.mipMaps.resize(result.mipLevels);
                result.mipMaps[0].push_back(frame);
                for (uint32_t mip = 1; mip < result.mipLevels; ++mip) {
                    uint32_t offset = header.mipmapOffsets[mip];
                    uint32_t size = header.mipmapSizes[mip];
                    uint32_t mipW = std::max(1U, header.width >> mip);
                    uint32_t mipH = std::max(1U, header.height >> mip);

                    if (offset == 0 || size == 0 ||
                        static_cast<size_t>(offset) + static_cast<size_t>(size) > length) {
                        continue;
                    }

                    BLPFrame mipFrame;
                    if (decodeBLP1Mip(mipW, mipH, offset, size, mipFrame)) {
                        result.mipMaps[mip].push_back(mipFrame);
                    }
                }
            }
        } else {
            result.compression = ImageCompression::Unknown;
            error = CascError::DecodingError;
            return result;
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

ImageDecodeResult ImageDecoderBridge::decode(const uint8_t* data, size_t length, CascError& error) {
    error = CascError::None;

    if (length < 4) {
        error = CascError::DecodingError;
        return {};
    }

    if (std::strncmp(reinterpret_cast<const char*>(data), "DDS ", 4) == 0) {
        return decodeDDS(data, length, error);
    }

    if (std::strncmp(reinterpret_cast<const char*>(data), "BLP2", 4) == 0 ||
        std::strncmp(reinterpret_cast<const char*>(data), "BLP1", 4) == 0) {
        return decodeBLP(data, length, error);
    }

    error = CascError::DecodingError;
    return {};
}

} // namespace CascBridge
