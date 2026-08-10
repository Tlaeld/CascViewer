#include "WOTextureDecoder.h"

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
        parsed = parser.parse(std::span<const u8>(data, length));
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
