// WhiteoutLib 链接冒烟测试:创建 Texture 并用 BLP writer 编码后再解析。
#include <whiteout/textures/texture.h>
#include <whiteout/textures/blp/blp.h>
#include <cstdio>
#include <cstring>
#include <span>

using namespace whiteout;
using namespace whiteout::textures;

int main() {
    auto tex = Texture::create2D(PixelFormat::RGBA8, 4, 4, 1);
    std::memset(tex.dataPtr(), 0xAB, 4 * 4 * 4);

    blp::Writer writer;
    auto bytes = writer.write(tex);
    if (bytes.empty()) { std::puts("FAIL: encode"); return 1; }

    blp::Parser parser;
    auto parsed = parser.parse(std::span<const u8>(bytes.data(), bytes.size()));
    if (!parsed || parsed->width() != 4 || parsed->height() != 4) {
        std::puts("FAIL: parse");
        return 1;
    }
    std::puts("SMOKE OK");
    return 0;
}
