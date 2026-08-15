#include "WOTextureDecoder.h"

#include <cstring>

#include <whiteout/textures/texture.h>
#include <whiteout/textures/blp/blp.h>
#include <whiteout/textures/dds/dds.h>

using namespace whiteout;
using namespace whiteout::textures;

namespace WhiteoutBridge {

static uint32_t readLE32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void writeLE32(uint8_t* p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

// ── 24-bit 非压缩 DDS 支持 ──
// WhiteoutLib 的 dds::Parser 只接受 4 字节/像素的 legacy 格式,24-bit DDS
// 会被拒绝。这里在桥内把 24-bit 像素扩展成 32-bit(每像素追加 alpha=255),
// 并把头部改成对应的 32-bit 描述,再交给 parser。R/G/B 掩码保持原样,
// parser 依据掩码自行处理通道顺序(常见的 BGR 文件会走 Bgra 交换路径)。

static constexpr uint32_t kDDPFAlphaPixels = 0x1;
static constexpr uint32_t kDDPFFourCC = 0x4;
static constexpr uint32_t kDDPFRGB = 0x40;
static constexpr size_t kDDSHeaderSize = 128; // 4 magic + 124 header

// DDS_PIXELFORMAT 字段在整个文件中的偏移(小端 u32):
// pf.dwFlags@80, pf.dwFourCC@84, pf.dwRGBBitCount@88,
// dwRBitMask@92, dwGBitMask@96, dwBBitMask@100, dwABitMask@104
static bool isDDS24Bit(const uint8_t* data, size_t length) {
    if (length < kDDSHeaderSize) return false;
    const uint32_t pfFlags = readLE32(data + 80);
    const uint32_t bitCount = readLE32(data + 88);
    return bitCount == 24 && (pfFlags & kDDPFRGB) && !(pfFlags & kDDPFFourCC);
}

static std::vector<uint8_t> expandDDS24To32(const uint8_t* data, size_t length) {
    const size_t srcBytes = length - kDDSHeaderSize;
    std::vector<uint8_t> out(kDDSHeaderSize + (srcBytes / 3) * 4);
    std::memcpy(out.data(), data, kDDSHeaderSize);
    writeLE32(out.data() + 88, 32);                                // dwRGBBitCount
    writeLE32(out.data() + 104, 0xFF000000u);                      // dwABitMask
    writeLE32(out.data() + 80, readLE32(data + 80) | kDDPFAlphaPixels); // dwFlags
    // 像素区按紧凑布局处理:每 3 字节 (b,g,r) 扩为 4 字节 (b,g,r,255)。
    // 近似说明:若文件的逐 mip 行带 4 字节对齐 pitch 填充(24-bit DDS 实践中
    // 很少见),这里的紧凑假设会产生错位的像素,而不是解码失败。
    const uint8_t* src = data + kDDSHeaderSize;
    uint8_t* dst = out.data() + kDDSHeaderSize;
    for (size_t i = 0; i + 2 < srcBytes; i += 3) {
        *dst++ = src[i];
        *dst++ = src[i + 1];
        *dst++ = src[i + 2];
        *dst++ = 255;
    }
    return out;
}

static WOImageCompression compressionFor(PixelFormat fmt) {
    switch (fmt) {
        case PixelFormat::BC1:   return WOImageCompression::DXTC1;
        case PixelFormat::BC2:   return WOImageCompression::DXTC3;
        case PixelFormat::BC3:   return WOImageCompression::DXTC5;
        case PixelFormat::RGBA8: return WOImageCompression::Raw;
        default:                 return WOImageCompression::Unknown;
    }
}

static bool alphaPresent(const Texture& tex) {
    if (tex.format() != PixelFormat::RGBA8) return true;  // BC2/BC3 等按有 alpha 处理
    auto span = tex.mipData(0);
    for (size_t i = 3; i < span.size(); i += 4) {
        if (span[i] != 255) return true;
    }
    return false;
}

WOImageDecodeResult WOTextureDecoder::decode(const uint8_t* data, size_t length,
                                             WOError& error) {
    WOImageDecodeResult result;
    error = WOError::None;
    if (!data || length < 4) { error = WOError::EmptyData; return result; }

    const uint32_t magic = readLE32(data);
    std::optional<Texture> parsed;
    WOImageFormat format = WOImageFormat::Unknown;

    if (magic == 0x31504C42 /* BLP1 */ || magic == 0x32504C42 /* BLP2 */ ||
        magic == 0x30504C42 /* BLP0 */) {
        blp::Parser parser;
        parsed = parser.parse(std::span<const u8>(data, length));
        format = (magic == 0x32504C42) ? WOImageFormat::BLP2 : WOImageFormat::BLP1;
    } else if (magic == 0x20534444 /* "DDS " */) {
        dds::Parser parser;
        if (isDDS24Bit(data, length)) {
            std::vector<uint8_t> expanded = expandDDS24To32(data, length);
            parsed = parser.parse(std::span<const u8>(expanded.data(), expanded.size()));
        } else {
            parsed = parser.parse(std::span<const u8>(data, length));
        }
        format = WOImageFormat::DDS;
    } else {
        error = WOError::UnsupportedFormat;
        return result;
    }

    if (!parsed || parsed->width() == 0 || parsed->height() == 0) {
        error = WOError::ParseFailed;
        return result;
    }

    const PixelFormat srcFormat = parsed->format();
    Texture rgba = (srcFormat == PixelFormat::RGBA8)
                       ? std::move(*parsed)
                       : parsed->copyAsFormat(PixelFormat::RGBA8);
    if (rgba.width() == 0 || rgba.format() != PixelFormat::RGBA8) {
        error = WOError::ParseFailed;
        return result;
    }

    result.format = format;
    result.compression = compressionFor(srcFormat);
    result.width = rgba.width();
    result.height = rgba.height();
    result.mipLevels = rgba.mipCount();
    result.frameCount = 1;
    result.hasAlpha = alphaPresent(rgba);

    for (u32 level = 0; level < rgba.mipCount(); ++level) {
        const MipLevel& mip = rgba.mipLevel(level);
        auto span = rgba.mipData(level);
        WOImageFrame frame;
        frame.width = mip.width;
        frame.height = mip.height;
        frame.rgbaData.assign(span.begin(), span.end());
        if (level == 0) result.frames.push_back(frame);
        result.mipMaps.push_back({std::move(frame)});
    }
    return result;
}

std::vector<uint8_t> WOEncodeTestImage(uint32_t width, uint32_t height, uint32_t kind) {
    auto tex = Texture::create2D(PixelFormat::RGBA8, width, height, 1);
    u8* p = tex.dataPtr();
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            size_t i = ((size_t)y * width + x) * 4;
            bool on = ((x / 4) + (y / 4)) % 2 == 0;
            p[i + 0] = on ? 255 : 32;
            p[i + 1] = (uint8_t)(width > 1 ? x * 255 / (width - 1) : 0);
            p[i + 2] = (uint8_t)(height > 1 ? y * 255 / (height - 1) : 0);
            p[i + 3] = 255;
        }
    }
    switch (kind) {
        case 0: {
            blp::Writer writer;
            blp::SaveOptions opts;
            opts.version = blp::BlpVersion::BLP1;
            return writer.write(tex, opts);
        }
        case 1: {
            blp::Writer writer;
            blp::SaveOptions opts;
            opts.version = blp::BlpVersion::BLP2;
            opts.encoding = blp::BlpEncoding::BGRA;
            return writer.write(tex, opts);
        }
        case 2: {
            dds::Writer writer;
            return writer.write(tex);
        }
        default:
            return {};
    }
}

} // namespace WhiteoutBridge
