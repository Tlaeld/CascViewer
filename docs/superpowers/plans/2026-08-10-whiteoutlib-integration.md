# WhiteoutLib 接入实施计划(纹理解码替换 + 3D 模型预览)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除手写 BLP/DDS 解码器(`BLPDecoderBridge`,约 1055 行)改用 WhiteoutLib textures 模块,并基于 WhiteoutLib models 模块(MDX/M3/M2)新增带骨骼动画的 SceneKit 3D 模型预览。

**Architecture:** WhiteoutLib 作为 git 子模块用 CMake 构建 universal 静态库;新建薄 C++ 桥 `WhiteoutBridge`(只出 POD 值类型)接入现有 `CascBridge` clang module;Swift 服务层复用现有 CascLib 存储读文件,SceneKit 负责渲染(`SCNSkinner` GPU 蒙皮),动画轨道在 CPU 用 simd 求值。

**Tech Stack:** C++20(CMake 构建 WhiteoutLib)/ C++23(Xcode 工程已设),Swift(objcxx interop),SceneKit,simd,XCTest,WhiteoutLib @ `da67a85`。

**Spec:** `docs/superpowers/specs/2026-08-10-whiteoutlib-integration-design.md`

## Global Constraints

- **CascLib 及其桥接全部保留不动**;WhiteoutLib 以 `-DWHITEOUT_ENABLE_CASC=OFF -DWHITEOUT_ENABLE_MPQ=OFF` 构建,只使用 textures + models。
- **零版权素材**:所有测试数据用 WhiteoutLib writer 现场生成,禁止把游戏资源放进仓库。
- 现有 74 个 XCTest 保持通过(允许的改动:Task 3 中 BridgeTests 里直接测旧解码器的用例迁移到新桥)。
- 构建/测试命令(在仓库根目录):
  - 构建:`xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build`
  - 测试:`xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test`
- WhiteoutLib pin 到 commit `da67a852966268eb59502649ce1296f7b9268d94`。
- 已验证:该 commit 在本机 macOS arm64 以 Release 构建通过(`libwhiteout_lib.a`)。
- Swift 与 C++ 边界类型只允许:`std::string`、`std::vector<POD>`、POD struct、C 回调函数指针。禁止 `std::optional`/`std::span`/`std::array`/`std::function` 出现在桥公共头文件(Swift interop 限制)。
- 本地化 key 同时加入 `CascViewer/Resources/en.lproj/Localizable.strings` 和 `CascViewer/Resources/zh-Hans.lproj/Localizable.strings`。
- git 提交信息格式沿用项目现有风格(如 `feat: ...` / `fix: ...`,见 `git log --oneline`)。

## 已知简化(实施时不得"顺手"加深,留给后续迭代)

- M2 解析器在 WhiteoutLib 中是实验性:parent-skeleton(SKPD)链不解析;部分模型解析失败走错误路径。
- M2 global-sequence(0xFFFF 之外的 globalSequenceId)轨道 v1 跳过。
- MDX inverse-bind 一律用 pivot 链计算(绑定姿态无旋转),不用 BPOS。
- M3 轨道插值 v1 只映射 Constant/Linear(Hermite/Bezier 按 Linear 处理);M3 时间戳按 30fps 折算毫秒(`kM3FramesPerSecond = 30.0`,视觉验证后可调)。
- M3 STC→sequence 配对:数量相等时按下标一一对应,否则全部用 STC[0]。
- 动画混合(blending/crossfade)不做,一次只播一个序列。
- 材质只取第一层(MDX layer[0] / M3 diffuseLayer / M2 textureCombo 第一层)。

---

### Task 1: Vendor WhiteoutLib 子模块 + 构建脚本 + 冒烟测试

**Files:**
- Create: `WhiteoutLib/`(git 子模块)
- Create: `tools/build_whiteout.sh`
- Create: `tools/test_whiteout_smoke.cpp`
- Modify: `.gitignore`(忽略 `WhiteoutLib/build-*/`)

**Interfaces:**
- Consumes: 无
- Produces: `WhiteoutLib/build-universal/libwhiteout_lib.a`(universal 静态库),头文件目录 `WhiteoutLib/include/`。后续所有任务依赖。

- [ ] **Step 1: 添加子模块并 pin commit**

```bash
cd /path/to/Casc_viewer
git submodule add https://github.com/FernandoS27/WhiteoutLib WhiteoutLib
git -C WhiteoutLib checkout da67a852966268eb59502649ce1296f7b9268d94
```

- [ ] **Step 2: 写构建脚本**

`tools/build_whiteout.sh`:

```bash
#!/bin/bash
# 构建 WhiteoutLib universal(arm64 + x86_64)静态库。
# 只启用核心库(textures + models),不启用 CASC/MPQ(项目用 CascLib)。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=WhiteoutLib
COMMON_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DWHITEOUT_ENABLE_CASC=OFF
  -DWHITEOUT_ENABLE_MPQ=OFF
  -DWHITEOUT_BUILD_TESTS=OFF
  -DWHITEOUT_BUILD_EXAMPLES=OFF
  -DWHITEOUT_WARNINGS_AS_ERRORS=OFF
  -DWHITEOUT_INSTALL=OFF
)

for ARCH in arm64 x86_64; do
  cmake -S "$SRC" -B "$SRC/build-$ARCH" "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  cmake --build "$SRC/build-$ARCH" --target whiteout_lib -j 12
done

mkdir -p "$SRC/build-universal"
lipo -create \
  "$SRC/build-arm64/libwhiteout_lib.a" \
  "$SRC/build-x86_64/libwhiteout_lib.a" \
  -output "$SRC/build-universal/libwhiteout_lib.a"

echo "OK: $SRC/build-universal/libwhiteout_lib.a"
lipo -info "$SRC/build-universal/libwhiteout_lib.a"
```

`chmod +x tools/build_whiteout.sh`

注意:静态库产物在 `build-<arch>/` 根目录名为 `libwhiteout_lib.a`(已在 arm64 验证);若实际路径不同,用 `find WhiteoutLib/build-arm64 -name 'libwhiteout_lib.a'` 定位后修正脚本。

- [ ] **Step 3: .gitignore 追加**

```
# WhiteoutLib 构建产物
WhiteoutLib/build-*/
```

- [ ] **Step 4: 运行构建脚本**

Run: `tools/build_whiteout.sh`
Expected: 末尾输出 `OK: WhiteoutLib/build-universal/libwhiteout_lib.a`,lipo 显示 `arm64 x86_64`。

- [ ] **Step 5: 冒烟测试(直接 clang++ 链接静态库,不经 Xcode)**

`tools/test_whiteout_smoke.cpp`:

```cpp
// WhiteoutLib 链接冒烟测试:创建 Texture 并用 BLP writer 编码后再解析。
#include <whiteout/textures/texture.h>
#include <whiteout/textures/blp/blp.h>
#include <cstdio>
#include <cstring>

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
```

编译运行:

```bash
clang++ -std=c++20 -I WhiteoutLib/include tools/test_whiteout_smoke.cpp \
  WhiteoutLib/build-universal/libwhiteout_lib.a -o /tmp/test_whiteout_smoke \
  -framework CoreFoundation && /tmp/test_whiteout_smoke
```

Expected: `SMOKE OK`。若链接报缺失符号(如 compression 相关),在链接行追加 `-lz` 再试;WhiteoutLib 宣称零外部 codec 依赖,正常不需要。

- [ ] **Step 6: Commit**

```bash
git add .gitmodules .gitignore tools/build_whiteout.sh tools/test_whiteout_smoke.cpp WhiteoutLib
git commit -m "feat: vendor WhiteoutLib submodule with universal build script"
```

---

### Task 2: WOTextureDecoder C++ 桥 + Xcode 接线 + round-trip 测试

**Files:**
- Create: `CascViewer/Core/WhiteoutBridge/include/WOTypes.h`
- Create: `CascViewer/Core/WhiteoutBridge/include/WOTextureDecoder.h`
- Create: `CascViewer/Core/WhiteoutBridge/src/WOTextureDecoder.cpp`
- Modify: `CascViewer/Core/CASCBridge/include/module.modulemap`
- Modify: `CascViewer/Core/CASCBridge/include/CascBridgeUmbrella.h`
- Modify: `CascViewer.xcodeproj/project.pbxproj`
- Test: `CascViewerTests/WhiteoutBridgeTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `libwhiteout_lib.a` 与 `WhiteoutLib/include`。
- Produces(后续任务依赖的确切签名,namespace `WhiteoutBridge`,经 `import CascBridge` 可见):
  - `enum class WOError : uint8_t { None, EmptyData, UnsupportedFormat, ParseFailed }`
  - `WOTextureDecoder::decode(const uint8_t* data, size_t length, WOError& error) -> WOImageDecodeResult`
  - `WOEncodeTestImage(uint32_t width, uint32_t height, uint32_t kind) -> std::vector<uint8_t>`(kind: 0=BLP1, 1=BLP2, 2=DDS)
  - `WOImageDecodeResult { format, compression, width, height, mipLevels, frameCount, hasAlpha, frames, mipMaps }`(形状与旧 `CascBridge::ImageDecodeResult` 相同)

- [ ] **Step 1: 写失败测试**

`CascViewerTests/WhiteoutBridgeTests.swift`:

```swift
import XCTest
import CascBridge
@testable import CascViewer

final class WhiteoutBridgeTests: XCTestCase {

    private func decode(_ bytes: std.vector<UInt8>) -> WhiteoutBridge.WOImageDecodeResult {
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        return data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return decoder.decode(ptr, data.count, &error)
        }
    }

    func testBLP2RoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 1)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(bytes)
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP2)
        XCTAssertEqual(result.width, 16)
        XCTAssertEqual(result.height, 16)
        XCTAssertEqual(result.frames.size(), 1)
        XCTAssertEqual(result.frames[0].rgbaData.size(), 16 * 16 * 4)
        XCTAssertGreaterThanOrEqual(result.mipLevels, 1)
    }

    func testBLP1RoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 0)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(bytes)
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP1)
        XCTAssertEqual(result.width, 16)
    }

    func testDDSRoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestImage(16, 16, 2)
        XCTAssertGreaterThan(bytes.size(), 0)
        let result = decode(bytes)
        XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.DDS)
        XCTAssertEqual(result.width, 16)
    }

    func testGarbageFails() {
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]
        var error = WhiteoutBridge.WOError.None
        var decoder = WhiteoutBridge.WOTextureDecoder()
        garbage.withUnsafeBufferPointer { buf in
            _ = decoder.decode(buf.baseAddress!, buf.count, &error)
        }
        XCTAssertNotEqual(error, WhiteoutBridge.WOError.None)
    }
}
```

注意:该文件此时编译不过(桥类型不存在)——这正是失败状态。同时把测试文件加入 Xcode 测试 target(见 Step 4 的 pbxproj 说明,新增文件的 fileRef/buildFile 参照 `BridgeTests.swift` 在 `CascViewerTests` target 里的现有条目模仿添加)。

- [ ] **Step 2: 运行测试确认编译失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeTests 2>&1 | tail -20`
Expected: 编译错误 `cannot find 'WOTextureDecoder' in scope`(测试不存在时先报 no such test,属正常,以编译错误为准)。

- [ ] **Step 3: 实现桥**

`CascViewer/Core/WhiteoutBridge/include/WOTypes.h`:

```cpp
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace WhiteoutBridge {

enum class WOError : uint8_t {
    None,
    EmptyData,
    UnsupportedFormat,
    ParseFailed
};

} // namespace WhiteoutBridge
```

`CascViewer/Core/WhiteoutBridge/include/WOTextureDecoder.h`:

```cpp
#pragma once
#include "WOTypes.h"

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
```

`CascViewer/Core/WhiteoutBridge/src/WOTextureDecoder.cpp`:

```cpp
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
```

- [ ] **Step 4: Xcode 接线(modulemap / umbrella / pbxproj)**

`CascViewer/Core/CASCBridge/include/module.modulemap` 在 `BLPDecoderBridge.h` 行后加一行(Task 3 才删旧行):

```
    header "WOTypes.h"
    header "WOTextureDecoder.h"
```

`CascViewer/Core/CASCBridge/include/CascBridgeUmbrella.h` 末尾加:

```cpp
#include "WOTypes.h"
#include "WOTextureDecoder.h"
```

`project.pbxproj` 修改(全部模仿现有 `BLPDecoderBridge.cpp/h` 条目,文本编辑;每个新文件需要 3 个条目:PBXBuildFile、PBXFileReference、加入对应 build phase / group):

1. 把 `WOTypes.h`、`WOTextureDecoder.h` 加入 PBXFileReference(挂在 `Core/CASCBridge/include` 所在 group 或新建 WhiteoutBridge group)与 `WOTextureDecoder.cpp` 的 PBXBuildFile 加入 app target(`CascViewer`)的 Sources build phase。旧文件 `BLPDecoderBridge.cpp` 的 PBXBuildFile UUID 行是模板,复制改 UUID(24 位十六进制,保证唯一)改路径。
2. `HEADER_SEARCH_PATHS`(Debug 与 Release 两处)追加 `$(SRCROOT)/CascViewer/Core/WhiteoutBridge/include` 和 `$(SRCROOT)/WhiteoutLib/include`。
3. `LIBRARY_SEARCH_PATHS`(Debug 与 Release)追加 `$(SRCROOT)/WhiteoutLib/build-universal`。
4. `OTHER_LDFLAGS`(Debug 与 Release)追加 `-lwhiteout_lib`。
5. 测试文件 `WhiteoutBridgeTests.swift` 加入 `CascViewerTests` target 的 Sources phase(模仿 `BridgeTests.swift` 条目)。

注意:WhiteoutLib 头文件需要 C++20;工程已是 `CLANG_CXX_LANGUAGE_STANDARD = c++23`,满足。

- [ ] **Step 5: 运行新测试**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeTests 2>&1 | tail -20`
Expected: 4 个用例 PASS。

- [ ] **Step 6: Commit**

```bash
git add CascViewer/Core/WhiteoutBridge CascViewer/Core/CASCBridge/include/module.modulemap \
  CascViewer/Core/CASCBridge/include/CascBridgeUmbrella.h CascViewer.xcodeproj/project.pbxproj \
  CascViewerTests/WhiteoutBridgeTests.swift
git commit -m "feat: add WhiteoutBridge texture decoder backed by WhiteoutLib"
```

---

### Task 3: BLPDecoderCoordinator 切换到新桥 + 删除 BLPDecoderBridge

**Files:**
- Modify: `CascViewer/Core/Services/BLPDecoderCoordinator.swift`
- Modify: `CascViewerTests/BridgeTests.swift`
- Delete: `CascViewer/Core/CASCBridge/src/BLPDecoderBridge.cpp`
- Delete: `CascViewer/Core/CASCBridge/include/BLPDecoderBridge.h`
- Modify: `CascViewer/Core/CASCBridge/include/module.modulemap`(删 `header "BLPDecoderBridge.h"`)
- Modify: `CascViewer/Core/CASCBridge/include/CascBridgeUmbrella.h`(删 `#include "BLPDecoderBridge.h"`)
- Modify: `CascViewer.xcodeproj/project.pbxproj`(删 BLPDecoderBridge 条目)

**Interfaces:**
- Consumes: Task 2 的 `WhiteoutBridge.WOTextureDecoder` / `WOImageDecodeResult` / `WOEncodeTestImage`。
- Produces: `BLPDecoderCoordinator.decode(data:) async throws -> ImageDecodeResult`(签名不变);`ImageDecodeResult` Swift struct 不变。

- [ ] **Step 1: 迁移 BridgeTests 中直接测旧解码器的用例(先改测试,确认失败)**

`CascViewerTests/BridgeTests.swift` 中所有 `CascBridge.ImageDecoderBridge()` 出现处(第 63、89、181、279 行附近,共 4 处)统一改为 `WhiteoutBridge.WOTextureDecoder()`;`CascBridge.CascError.None` 相应改为 `WhiteoutBridge.WOError.None`。

其中 `testBLP2RawDecodeInMemory`(约 41-80 行)手工拼 BLP2 字节,WhiteoutLib parser 未必接受该手工布局——重写为 writer round-trip:

```swift
func testBLP2RawDecodeInMemory() {
    let bytes = WhiteoutBridge.WOEncodeTestImage(4, 4, 1)
    XCTAssertGreaterThan(bytes.size(), 0)
    var data = Data(bytes)
    var error = WhiteoutBridge.WOError.None
    var decoder = WhiteoutBridge.WOTextureDecoder()
    let result = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOImageDecodeResult in
        let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
        return decoder.decode(ptr, data.count, &error)
    }
    XCTAssertEqual(error, WhiteoutBridge.WOError.None)
    XCTAssertEqual(result.format, WhiteoutBridge.WOImageFormat.BLP2)
    XCTAssertEqual(result.width, 4)
    XCTAssertEqual(result.height, 4)
    XCTAssertEqual(result.frames.size(), 1)
    XCTAssertEqual(result.frames[0].rgbaData.size(), 4 * 4 * 4)
}
```

其余 3 处(181、279 行附近)若同样是手工构造 BLP/DDS 字节,同样改用 `WOEncodeTestImage` 生成并保留断言语义(尺寸/格式/错误码);若是"非法输入报错"用例,仅换类型即可。`BLPDecoderCoordinator` 相关用例(PNG 经 ImageIO fallback,约 109-114 行)保持不变。

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/BridgeTests 2>&1 | tail -20`
Expected: 编译错误(此时 `BLPDecoderCoordinator.swift` 还引用着将被删的类型不报错,但断言可能 FAIL——旧解码器还在时 `WOTextureDecoder` 用例应已可通过;关键是下一步切换后保持绿)。

- [ ] **Step 2: 切换 BLPDecoderCoordinator**

`BLPDecoderCoordinator.swift` 改动(其余行不动):

```swift
// 第 13 行
private var decoder = WhiteoutBridge.WOTextureDecoder()

// decode(data:) 内
var error = WhiteoutBridge.WOError.None
let cppResult: WhiteoutBridge.WOImageDecodeResult? = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOImageDecodeResult? in
    guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        return nil
    }
    return decoder.decode(ptr, data.count, &error)
}
```

`ImageDecodeResult.init(cppResult:)` 签名改为 `init(cppResult: WhiteoutBridge.WOImageDecodeResult)`,内部 `switch cppResult.format` 的 case `.BLP2` / `.DDS` 不变(枚举名相同,命名空间不同)。

- [ ] **Step 3: 删除旧解码器**

```bash
git rm CascViewer/Core/CASCBridge/src/BLPDecoderBridge.cpp CascViewer/Core/CASCBridge/include/BLPDecoderBridge.h
```

`module.modulemap` 删除 `    header "BLPDecoderBridge.h"` 行;`CascBridgeUmbrella.h` 删除 `#include "BLPDecoderBridge.h"` 行。

`project.pbxproj`:删除 `BLPDecoderBridge.cpp` 的 PBXBuildFile 条目、Sources phase 引用,以及 `BLPDecoderBridge.h` 的 PBXFileReference 条目(Task 2 添加新文件时复制的模板行就是要删的这些)。

- [ ] **Step 4: 全量测试**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | tail -30`
Expected: 全部测试 PASS(含既有 74 个减去迁移的、加上新增的)。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: replace hand-written BLP/DDS decoder with WhiteoutLib-backed bridge"
```

---

### Task 4: WOModel 值类型 + MDX 解析桥 + round-trip 测试

**Files:**
- Create: `CascViewer/Core/WhiteoutBridge/include/WOModel.h`
- Create: `CascViewer/Core/WhiteoutBridge/include/WOModelLoader.h`
- Create: `CascViewer/Core/WhiteoutBridge/src/WOModelLoader.cpp`
- Create: `CascViewer/Core/WhiteoutBridge/src/WOModelLoaderMDX.cpp`
- Modify: `CascViewer/Core/CASCBridge/include/module.modulemap`(加两个 header)
- Modify: `CascViewer/Core/CASCBridge/include/CascBridgeUmbrella.h`(加两个 include)
- Modify: `CascViewer.xcodeproj/project.pbxproj`(加 2 个 .cpp + 2 个 .h)
- Test: `CascViewerTests/WhiteoutBridgeModelTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `WOTypes.h`(WOError)。
- Produces(Task 5/6 依赖):
  - `WOModelLoader::parseMDX(const uint8_t*, size_t, WOError&) -> WOModel`
  - `WOModelLoader::parseM3(const uint8_t*, size_t, WOError&) -> WOModel`(Task 5 实现,本任务先声明并返回 ParseFailed)
  - `WOModelLoader::parseM2(const uint8_t*, size_t, void* ctx, WOM2ReadFileCallback, WOError&) -> WOModel`(同 Task 5)
  - `typedef bool (*WOM2ReadFileCallback)(void* ctx, uint32_t fileDataId, std::vector<uint8_t>& out)`
  - `WOEncodeTestMDX() -> std::vector<uint8_t>`
  - 值类型:`WOModel / WOMesh / WOMaterial / WOBone / WOAnimation / WOVec3Track / WOQuatTrack / WOVec2 / WOVec3 / WOVec4`(字段见下)

- [ ] **Step 1: 写失败测试**

`CascViewerTests/WhiteoutBridgeModelTests.swift`:

```swift
import XCTest
import CascBridge
@testable import CascViewer

final class WhiteoutBridgeModelTests: XCTestCase {

    private func parseMDX(_ bytes: std.vector<UInt8>) -> WhiteoutBridge.WOModel {
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        return data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return loader.parseMDX(ptr, data.count, &error)
        }
    }

    func testMDXRoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestMDX()
        XCTAssertGreaterThan(bytes.size(), 0)
        let model = parseMDX(bytes)

        XCTAssertEqual(model.format, WhiteoutBridge.WOModelFormat.MDX)
        XCTAssertEqual(model.meshes.size(), 1)
        XCTAssertEqual(model.meshes[0].positions.size(), 3)      // 三角形
        XCTAssertEqual(model.meshes[0].indices.size(), 3)
        XCTAssertEqual(model.meshes[0].boneIndices.size(), 3)    // 4 个/顶点,扁平
        XCTAssertEqual(model.materials.size(), 1)
        XCTAssertEqual(model.bones.size(), 2)
        XCTAssertEqual(model.bones[1].parentIndex, 0)
        XCTAssertEqual(model.animations.size(), 1)
        XCTAssertEqual(String(model.animations[0].name), "Stand")
        XCTAssertEqual(model.animations[0].durationMs, 1000)
        // bone1 的位移轨道:2 个关键帧
        let track = model.animations[0].translations[1]
        XCTAssertEqual(track.times.size(), 2)
        XCTAssertEqual(track.keys.size(), 2)
        XCTAssertEqual(track.times[0], 0)
        XCTAssertEqual(track.times[1], 1000)
        // bone0 无轨道
        XCTAssertEqual(model.animations[0].translations[0].times.size(), 0)
    }

    func testMDXGarbageFails() {
        let garbage: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        garbage.withUnsafeBufferPointer { buf in
            _ = loader.parseMDX(buf.baseAddress!, buf.count, &error)
        }
        XCTAssertEqual(error, WhiteoutBridge.WOError.ParseFailed)
    }
}
```

把该文件加入测试 target(模仿 `BridgeTests.swift` 条目)。

- [ ] **Step 2: 运行确认编译失败**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeModelTests 2>&1 | tail -10`
Expected: `cannot find 'WOModelLoader' in scope` 编译错误。

- [ ] **Step 3: 实现 WOModel.h / WOModelLoader.h**

`CascViewer/Core/WhiteoutBridge/include/WOModel.h`:

```cpp
#pragma once
#include "WOTypes.h"

namespace WhiteoutBridge {

enum class WOModelFormat : uint8_t { MDX, M3, M2 };

enum class WOBlendMode : uint8_t { Opaque, AlphaTest, Blend, Additive, Modulate };

enum class WOInterpolation : uint8_t { Constant, Linear, Hermite, Bezier };

struct WOVec2 { float x = 0, y = 0; };
struct WOVec3 { float x = 0, y = 0, z = 0; };
struct WOVec4 { float x = 0, y = 0, z = 0, w = 1; };

struct WOVec3Track {
    WOInterpolation interp = WOInterpolation::Constant;
    std::vector<uint32_t> times;        // 毫秒
    std::vector<WOVec3> keys;
    std::vector<WOVec3> inTangents;     // 仅 Hermite/Bezier
    std::vector<WOVec3> outTangents;
};

struct WOQuatTrack {
    WOInterpolation interp = WOInterpolation::Constant;
    std::vector<uint32_t> times;        // 毫秒
    std::vector<WOVec4> keys;           // XYZW
    std::vector<WOVec4> inTangents;
    std::vector<WOVec4> outTangents;
};

struct WOBone {
    std::string name;
    int32_t parentIndex = -1;
    WOVec3 pivot;
    std::vector<float> inverseBind;     // 16 个,row-major;空 = 单位阵
    WOVec3 restTranslation;
    WOVec4 restRotation;                // 默认 identity(0,0,0,1)
    WOVec3 restScale = {1, 1, 1};
};

struct WOMesh {
    std::vector<WOVec3> positions;
    std::vector<WOVec3> normals;
    std::vector<WOVec2> uvs;
    std::vector<uint32_t> indices;
    std::vector<uint8_t> boneIndices;   // 扁平,4 个/顶点
    std::vector<uint8_t> boneWeights;   // 扁平,4 个/顶点,每顶点合计 255
    int32_t materialIndex = -1;
};

struct WOMaterial {
    std::string texturePath;            // MDX/M3;M2 常为 ""
    uint32_t textureFileDataId = 0;     // M2 TXID;0 = 无
    WOBlendMode blendMode = WOBlendMode::Opaque;
    bool twoSided = false;
    bool unlit = false;
};

struct WOAnimation {
    std::string name;
    uint32_t durationMs = 0;
    bool loops = true;
    // 与 WOModel::bones 平行;空 times = 该骨骼无轨道
    std::vector<WOVec3Track> translations;
    std::vector<WOQuatTrack> rotations;
    std::vector<WOVec3Track> scales;
};

struct WOModel {
    std::string name;
    WOModelFormat format = WOModelFormat::MDX;
    std::vector<WOMesh> meshes;
    std::vector<WOMaterial> materials;
    std::vector<WOBone> bones;
    std::vector<WOAnimation> animations;
    WOVec3 boundsMin, boundsMax;
};

} // namespace WhiteoutBridge
```

`CascViewer/Core/WhiteoutBridge/include/WOModelLoader.h`:

```cpp
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
```

`CascViewer/Core/WhiteoutBridge/src/WOModelLoader.cpp`(M3/M2 占位,Task 5 替换):

```cpp
#include "WOModelLoader.h"

namespace WhiteoutBridge {

WOModel WOModelLoader::parseM3(const uint8_t*, size_t, WOError& error) {
    error = WOError::UnsupportedFormat;
    return WOModel{};
}

WOModel WOModelLoader::parseM2(const uint8_t*, size_t, void*,
                               WOM2ReadFileCallback, WOError& error) {
    error = WOError::UnsupportedFormat;
    return WOModel{};
}

} // namespace WhiteoutBridge
```

- [ ] **Step 4: 实现 WOModelLoaderMDX.cpp**

`CascViewer/Core/WhiteoutBridge/src/WOModelLoaderMDX.cpp`:

```cpp
#include "WOModelLoader.h"

#include <whiteout/models/mdx/mdx.h>

#include <unordered_map>

using namespace whiteout;

namespace WhiteoutBridge {

namespace {

WOVec2 toWO(const Vector2f& v) { return {v.x, v.y}; }
WOVec3 toWO(const Vector3f& v) { return {v.x, v.y, v.z}; }
WOVec4 toWO(const Quaternion& q) { return {q.x, q.y, q.z, q.w}; }

// MDX Track 的 keys()/tangentKeys() 非 const,先复制再访问。
WOVec3Track convertVec3Track(const mdx::Track<Vector3f>& src, u32 start, u32 end) {
    WOVec3Track out;
    if (!src.isUsed || src.keyCount == 0) return out;
    mdx::Track<Vector3f> tr = src;

    switch (tr.interpolationType) {
        case mdx::InterpolationType::None:   out.interp = WOInterpolation::Constant; break;
        case mdx::InterpolationType::Linear: out.interp = WOInterpolation::Linear; break;
        case mdx::InterpolationType::Hermite: out.interp = WOInterpolation::Hermite; break;
        case mdx::InterpolationType::Bezier: out.interp = WOInterpolation::Bezier; break;
    }
    const bool smooth = (out.interp == WOInterpolation::Hermite ||
                         out.interp == WOInterpolation::Bezier);
    const bool isGlobal = (tr.globalSequenceId != mdx::Track<Vector3f>::kNoGlobalSequence);

    for (size_t k = 0; k < tr.keyCount; ++k) {
        u32 t = tr.timestamps[k];
        if (!isGlobal) {
            if (t < start || t >= end) continue;
            t -= start;
        }
        out.times.push_back(t);
        if (smooth) {
            const auto& tk = tr.tangentKeys()[k];
            out.keys.push_back(toWO(tk.value));
            out.inTangents.push_back(toWO(tk.inTan));
            out.outTangents.push_back(toWO(tk.outTan));
        } else {
            out.keys.push_back(toWO(tr.keys()[k]));
        }
    }
    return out;
}

WOQuatTrack convertQuatTrack(const mdx::Track<Quaternion>& src, u32 start, u32 end) {
    WOQuatTrack out;
    if (!src.isUsed || src.keyCount == 0) return out;
    mdx::Track<Quaternion> tr = src;

    switch (tr.interpolationType) {
        case mdx::InterpolationType::None:   out.interp = WOInterpolation::Constant; break;
        case mdx::InterpolationType::Linear: out.interp = WOInterpolation::Linear; break;
        case mdx::InterpolationType::Hermite: out.interp = WOInterpolation::Hermite; break;
        case mdx::InterpolationType::Bezier: out.interp = WOInterpolation::Bezier; break;
    }
    const bool smooth = (out.interp == WOInterpolation::Hermite ||
                         out.interp == WOInterpolation::Bezier);
    const bool isGlobal = (tr.globalSequenceId != mdx::Track<Quaternion>::kNoGlobalSequence);

    for (size_t k = 0; k < tr.keyCount; ++k) {
        u32 t = tr.timestamps[k];
        if (!isGlobal) {
            if (t < start || t >= end) continue;
            t -= start;
        }
        out.times.push_back(t);
        if (smooth) {
            const auto& tk = tr.tangentKeys()[k];
            out.keys.push_back(toWO(tk.value));
            out.inTangents.push_back(toWO(tk.inTan));
            out.outTangents.push_back(toWO(tk.outTan));
        } else {
            out.keys.push_back(toWO(tr.keys()[k]));
        }
    }
    return out;
}

// 绑定姿态语义:MDX 顶点存的就是绑定位置,骨骼绑定变换 = 恒等。
// 动画时用锚点公式 local = T(pivot + t) R S T(-pivot),绑定(t=0,R=I,S=I)即恒等。
// 因此 inverseBind 一律为单位阵(无需 BPOS)。
void setIdentityInverseBinds(WOModel& out) {
    for (auto& bone : out.bones) {
        bone.inverseBind.assign(16, 0.0f);
        bone.inverseBind[0] = bone.inverseBind[5] = 1.0f;
        bone.inverseBind[10] = bone.inverseBind[15] = 1.0f;
    }
}

} // namespace

WOModel WOModelLoader::parseMDX(const uint8_t* data, size_t length, WOError& error) {
    error = WOError::None;
    WOModel out;
    out.format = WOModelFormat::MDX;
    if (!data || length == 0) { error = WOError::EmptyData; return out; }

    mdx::Model model;
    try {
        mdx::Parser parser;
        model = parser.parse(std::span<const u8>(data, length), mdx::MDLXFormat::MDX);
    } catch (const std::exception&) {
        error = WOError::ParseFailed;
        return out;
    }

    out.name = model.modelName;
    out.boundsMin = toWO(model.modelExtent.minimum);
    out.boundsMax = toWO(model.modelExtent.maximum);

    // ── 材质(只取 layer[0])──
    for (const auto& mat : model.materials) {
        WOMaterial wm;
        if (!mat.layers.empty()) {
            const auto& layer = mat.layers[0];
            if (layer.textureId < model.textures.size())
                wm.texturePath = model.textures[layer.textureId].fileName;
            switch (layer.filterMode) {
                case mdx::Layer::FilterMode::None:
                    wm.blendMode = WOBlendMode::Opaque; break;
                case mdx::Layer::FilterMode::Transparent:
                case mdx::Layer::FilterMode::Blend:
                    wm.blendMode = WOBlendMode::Blend; break;
                case mdx::Layer::FilterMode::Additive:
                case mdx::Layer::FilterMode::AddAlpha:
                    wm.blendMode = WOBlendMode::Additive; break;
                case mdx::Layer::FilterMode::Modulate:
                case mdx::Layer::FilterMode::Modulate2x:
                    wm.blendMode = WOBlendMode::Modulate; break;
            }
            const u32 sf = static_cast<u32>(layer.shadingFlags);
            wm.twoSided = (sf & 0x10) != 0;        // ShadingFlag::TwoSided
            wm.unlit = (sf & 0x101) != 0;          // Unshaded 0x1 | Unlit 0x100
        }
        out.materials.push_back(std::move(wm));
    }

    // ── 骨骼 ──
    std::unordered_map<u32, int32_t> nodeToBone;
    nodeToBone.reserve(model.bones.size());
    for (size_t i = 0; i < model.bones.size(); ++i) {
        const auto& b = model.bones[i];
        WOBone wb;
        wb.name = b.node.name;
        if (b.node.objectId < model.pivotPoints.size())
            wb.pivot = toWO(model.pivotPoints[b.node.objectId]);
        nodeToBone[b.node.objectId] = (int32_t)i;
        out.bones.push_back(std::move(wb));
    }
    for (size_t i = 0; i < model.bones.size(); ++i) {
        const u32 pid = model.bones[i].node.parentId;
        if (pid == mdx::Node::NO_PARENT) continue;
        auto it = nodeToBone.find(pid);
        if (it != nodeToBone.end()) {
            out.bones[i].parentIndex = it->second;
            // PIVT 为模型空间绝对坐标,转成父空间相对偏移(锚点公式用)
            out.bones[i].pivot.x -= out.bones[it->second].pivot.x;
            out.bones[i].pivot.y -= out.bones[it->second].pivot.y;
            out.bones[i].pivot.z -= out.bones[it->second].pivot.z;
        }
        // 父不是骨骼(helper 等)v1 挂根
    }
    setIdentityInverseBinds(out);

    // ── 网格 ──
    for (const auto& g : model.geosets) {
        WOMesh mesh;
        const size_t vcount = g.vertexPositions.size();
        mesh.positions.reserve(vcount);
        for (const auto& p : g.vertexPositions) mesh.positions.push_back(toWO(p));
        mesh.normals.reserve(vcount);
        if (g.vertexNormals.size() == vcount) {
            for (const auto& n : g.vertexNormals) mesh.normals.push_back(toWO(n));
        } else {
            mesh.normals.assign(vcount, WOVec3{0, 0, 1});
        }
        if (!g.textureCoordinateSets.empty() &&
            g.textureCoordinateSets[0].size() == vcount) {
            mesh.uvs.reserve(vcount);
            for (const auto& uv : g.textureCoordinateSets[0]) mesh.uvs.push_back(toWO(uv));
        } else {
            mesh.uvs.assign(vcount, WOVec2{0, 0});
        }
        mesh.indices.reserve(g.faces.size());
        for (u16 idx : g.faces) mesh.indices.push_back((uint32_t)idx);
        mesh.materialIndex = (int32_t)g.materialId;

        mesh.boneIndices.resize(vcount * 4, 0);
        mesh.boneWeights.resize(vcount * 4, 0);
        if (g.skinData.size() == vcount * 8) {
            // Reforged SKIN:4 骨骼索引 + 4 权重(合计 255)
            for (size_t v = 0; v < vcount; ++v) {
                for (size_t j = 0; j < 4; ++j) {
                    mesh.boneIndices[v * 4 + j] = g.skinData[v * 8 + j];
                    mesh.boneWeights[v * 4 + j] = g.skinData[v * 8 + 4 + j];
                }
            }
        } else if (!g.vertexGroups.empty() && g.vertexGroups.size() == vcount &&
                   !g.matrixGroups.empty()) {
            // 经典 GNDX/MTGC/MATS:每顶点一个矩阵组,组内骨骼等权
            std::vector<std::pair<size_t, size_t>> ranges;
            size_t offset = 0;
            for (u32 count : g.matrixGroups) {
                ranges.push_back({offset, offset + count});
                offset += count;
            }
            for (size_t v = 0; v < vcount; ++v) {
                const u8 gi = g.vertexGroups[v];
                size_t n = 0;
                if (gi < ranges.size()) {
                    auto [begin, end] = ranges[gi];
                    for (size_t k = begin; k < end && k < g.matrixIndices.size() && n < 4; ++k) {
                        auto it = nodeToBone.find(g.matrixIndices[k]);
                        if (it == nodeToBone.end()) continue;  // 非骨骼节点跳过
                        mesh.boneIndices[v * 4 + n] = (uint8_t)it->second;
                        ++n;
                    }
                }
                if (n == 0) {  // 兜底:刚性绑 bone 0
                    n = 1;
                    mesh.boneIndices[v * 4] = 0;
                }
                const uint8_t w = (uint8_t)(255 / n);
                uint8_t sum = 0;
                for (size_t j = 0; j < n; ++j) {
                    mesh.boneWeights[v * 4 + j] = (j == 0) ? (uint8_t)(255 - w * (n - 1)) : w;
                    sum += mesh.boneWeights[v * 4 + j];
                }
            }
        } else {
            // 无蒙皮信息:刚性绑 bone 0
            for (size_t v = 0; v < vcount; ++v) mesh.boneWeights[v * 4] = 255;
        }
        out.meshes.push_back(std::move(mesh));
    }

    // ── 动画(MDX 时间戳即毫秒;按序列区间过滤并 rebase)──
    for (const auto& seq : model.sequences) {
        WOAnimation anim;
        anim.name = seq.name;
        anim.durationMs = (seq.intervalEnd > seq.intervalStart)
                              ? seq.intervalEnd - seq.intervalStart : 0;
        anim.loops = (static_cast<u32>(seq.flags) & 0x1) == 0;  // Flag::NonLooping
        for (const auto& bone : model.bones) {
            anim.translations.push_back(
                convertVec3Track(bone.node.translationTracks, seq.intervalStart, seq.intervalEnd));
            anim.rotations.push_back(
                convertQuatTrack(bone.node.rotationTracks, seq.intervalStart, seq.intervalEnd));
            anim.scales.push_back(
                convertVec3Track(bone.node.scalingTracks, seq.intervalStart, seq.intervalEnd));
        }
        out.animations.push_back(std::move(anim));
    }

    return out;
}

// ── 测试夹具:1 三角网格 / 2 骨骼 / 1 个 1000ms "Stand" 动画 ──
std::vector<uint8_t> WOEncodeTestMDX() {
    mdx::Model model;
    model.version = 800;
    model.modelName = "TestModel";
    model.blendTime = 0;

    // 纹理 + 材质
    mdx::Texture tex;
    tex.fileName = "Textures/test.blp";
    model.textures.push_back(tex);

    mdx::Material mat;
    mdx::Layer layer;
    layer.filterMode = mdx::Layer::FilterMode::None;
    layer.textureId = 0;
    mat.layers.push_back(layer);
    model.materials.push_back(mat);

    // 骨骼 2 个(bone1 是 bone0 的子)
    mdx::Bone b0;
    b0.node.name = "root";
    b0.node.objectId = 0;
    b0.node.parentId = mdx::Node::NO_PARENT;
    mdx::Bone b1;
    b1.node.name = "child";
    b1.node.objectId = 1;
    b1.node.parentId = 0;
    // bone1 位移轨道:0ms 在原点,1000ms 移到 (0,1,0)
    b1.node.translationTracks.isUsed = true;
    b1.node.translationTracks.interpolationType = mdx::InterpolationType::Linear;
    b1.node.translationTracks.timestamps = {0, 1000};
    b1.node.translationTracks.keys_data = {Vector3f{0, 0, 0}, Vector3f{0, 1, 0}};
    b1.node.translationTracks.keyCount = 2;
    model.bones = {b0, b1};
    model.pivotPoints = {Vector3f{0, 0, 0}, Vector3f{0, 0, 1}};

    // 动画序列
    mdx::Sequence seq;
    seq.name = "Stand";
    seq.intervalStart = 0;
    seq.intervalEnd = 1000;
    seq.flags = mdx::Sequence::Flag::None;
    model.sequences.push_back(seq);

    // 1 个三角形网格(经典矩阵组蒙皮:v0,v1 → bone0;v2 → bone1)
    mdx::Geoset g;
    g.vertexPositions = {Vector3f{0, 0, 0}, Vector3f{1, 0, 0}, Vector3f{0, 1, 0}};
    g.vertexNormals = {Vector3f{0, 0, 1}, Vector3f{0, 0, 1}, Vector3f{0, 0, 1}};
    g.textureCoordinateSets = {{Vector2f{0, 0}, Vector2f{1, 0}, Vector2f{0, 1}}};
    g.faces = {0, 1, 2};
    g.materialId = 0;
    g.vertexGroups = {0, 0, 1};
    g.matrixGroups = {1, 1};
    g.matrixIndices = {0, 1};
    model.geosets.push_back(g);

    mdx::Writer writer;
    return writer.write(model, mdx::MDLXFormat::MDX);
}

} // namespace WhiteoutBridge
```

注意(实现者自查):MDX 锚点公式 `local = T(pivot + t) R S T(-pivot)` 下,绑定姿态(t=0、R=I、S=I)对每根骨骼都是恒等变换,故 `inverseBind` 一律单位阵;`pivot` 已从 PIVT 的模型空间绝对坐标转成父空间相对偏移。若真实模型显示错位,第一排查点是 PIVT 语义(绝对/相对),第二排查点是 SKIN 块"索引在前、权重在后"的字节序。

modulemap 追加:

```
    header "WOModel.h"
    header "WOModelLoader.h"
```

umbrella 追加:

```cpp
#include "WOModel.h"
#include "WOModelLoader.h"
```

pbxproj:把 `WOModelLoader.cpp`、`WOModelLoaderMDX.cpp` 加入 app target Sources(模仿 `WOTextureDecoder.cpp` 条目),2 个头文件加入 group。

- [ ] **Step 5: 运行测试**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeModelTests 2>&1 | tail -20`
Expected: 2 个用例 PASS。若 MDX writer 拒绝空 vector 之外的字段(如 `textureCoordinateSets` 嵌套写法),按编译错误修正夹具构造(mdx::Geoset 的字段均为 public)。

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add MDX model parsing to WhiteoutBridge"
```

---

### Task 5: M3 + M2 解析桥 + round-trip 测试

**Files:**
- Create: `CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM3.cpp`
- Create: `CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM2.cpp`
- Modify: `CascViewer/Core/WhiteoutBridge/src/WOModelLoader.cpp`(删除 M3/M2 占位实现)
- Modify: `CascViewer.xcodeproj/project.pbxproj`(加 2 个 .cpp)
- Test: `CascViewerTests/WhiteoutBridgeModelTests.swift`(追加 M3/M2 用例)

**Interfaces:**
- Consumes: Task 4 的 `WOModelLoader` 声明、`WOModel` 类型、`WOM2ReadFileCallback`。
- Produces: `parseM3` / `parseM2` 真实实现;`WOEncodeTestM3()` / `WOEncodeTestM2()` 测试夹具。

- [ ] **Step 1: 追加失败测试**

`WhiteoutBridgeModelTests.swift` 追加:

```swift
    private func parseM3(_ bytes: std.vector<UInt8>) -> WhiteoutBridge.WOModel {
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        return data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return loader.parseM3(ptr, data.count, &error)
        }
    }

    func testM3RoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestM3()
        XCTAssertGreaterThan(bytes.size(), 0)
        let model = parseM3(bytes)
        XCTAssertEqual(model.format, WhiteoutBridge.WOModelFormat.M3)
        XCTAssertEqual(model.meshes.size(), 1)
        XCTAssertGreaterThan(model.meshes[0].positions.size(), 0)
        XCTAssertEqual(model.bones.size(), 1)
        XCTAssertEqual(model.materials.size(), 1)
        XCTAssertEqual(model.animations.size(), 1)
        // 夹具的骨骼带 2 帧位移动画
        XCTAssertEqual(model.animations[0].translations[0].times.size(), 2)
    }

    func testM2SmokeRoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestM2()
        XCTAssertGreaterThan(bytes.size(), 0)
        var data = Data(bytes)
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        let model = data.withUnsafeBytes { rawBuffer -> WhiteoutBridge.WOModel in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return loader.parseM2(ptr, data.count, nil, nil, &error)
        }
        XCTAssertEqual(error, WhiteoutBridge.WOError.None)
        XCTAssertEqual(model.format, WhiteoutBridge.WOModelFormat.M2)
    }
```

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeModelTests 2>&1 | tail -10`
Expected: `WOEncodeTestM3`/`WOEncodeTestM2` 链接错误(undefined symbol,声明已有实现缺失)。

- [ ] **Step 2: 实现 WOModelLoaderM3.cpp**

`CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM3.cpp`:

```cpp
#include "WOModelLoader.h"

#include <whiteout/models/m3/m3.h>
#include <whiteout/models/m3/parser.h>

#include <cstring>

using namespace whiteout;

namespace WhiteoutBridge {

namespace {

constexpr float kM3FramesPerSecond = 30.0f;  // M3 时间戳为帧,按 30fps 折算毫秒

WOVec2 toWO(const Vector2f& v) { return {v.x, v.y}; }
WOVec3 toWO(const Vector3f& v) { return {v.x, v.y, v.z}; }
WOVec4 toWO(const Quaternion& q) { return {q.x, q.y, q.z, q.w}; }

uint32_t frameToMs(i32 frame) {
    return frame > 0 ? (uint32_t)((float)frame * 1000.0f / kM3FramesPerSecond) : 0;
}

// 在指定 STC 中解析 AnimRef → AnimBlock(slot/index 解码)。
// 返回 false 表示该 STC 不含此 animId。
bool resolveAnimId(const m3::SubTrackContainer& stc, u32 animId,
                   u32& outSlot, u32& outIndex) {
    for (size_t k = 0; k < stc.animIds.size() && k < stc.animRefs.size(); ++k) {
        if (stc.animIds[k] == animId) {
            const u32 ref = stc.animRefs[k];
            outSlot = ref >> 16;
            outIndex = ref & 0xFFFF;
            return true;
        }
    }
    return false;
}

WOVec3Track convertSD3V(const m3::AnimBlock<Vector3f>& block, u16 interpType) {
    WOVec3Track out;
    out.interp = (interpType == 0) ? WOInterpolation::Constant
                                   : WOInterpolation::Linear;  // v1:Hermite/Bezier 按 Linear
    for (size_t k = 0; k < block.keys.size() && k < block.timestamps.size(); ++k) {
        out.times.push_back(frameToMs(block.timestamps[k]));
        out.keys.push_back(toWO(block.keys[k]));
    }
    return out;
}

WOQuatTrack convertSD4Q(const m3::AnimBlock<Quaternion>& block, u16 interpType) {
    WOQuatTrack out;
    out.interp = (interpType == 0) ? WOInterpolation::Constant
                                   : WOInterpolation::Linear;
    for (size_t k = 0; k < block.keys.size() && k < block.timestamps.size(); ++k) {
        out.times.push_back(frameToMs(block.timestamps[k]));
        out.keys.push_back(toWO(block.keys[k]));
    }
    return out;
}

// 骨骼单个属性(位置/旋转/缩放)在 STC 中解析为轨道。
template <typename TrackT>
TrackT resolveBoneTrack(const m3::SubTrackContainer* stc, u32 animId, u16 interpType,
                        u32 wantSlot) {
    TrackT out;
    if (!stc || animId == 0) return out;
    u32 slot = 0, index = 0;
    if (!resolveAnimId(*stc, animId, slot, index) || slot != wantSlot) return out;
    if constexpr (std::is_same_v<TrackT, WOVec3Track>) {
        if (index < stc->sd3v.size()) return convertSD3V(stc->sd3v[index], interpType);
    } else {
        if (index < stc->sd4q.size()) return convertSD4Q(stc->sd4q[index], interpType);
    }
    return out;
}

} // namespace

WOModel WOModelLoader::parseM3(const uint8_t* data, size_t length, WOError& error) {
    error = WOError::None;
    WOModel out;
    out.format = WOModelFormat::M3;
    if (!data || length == 0) { error = WOError::EmptyData; return out; }

    m3::Model model;
    try {
        m3::Parser parser;
        model = parser.parse(std::span<const u8>(data, length));
    } catch (const std::exception&) {
        error = WOError::ParseFailed;
        return out;
    }

    out.name = model.name;
    out.boundsMin = toWO(model.bounds.min);
    out.boundsMax = toWO(model.bounds.max);

    // ── 材质:batch → materialMaps → standardMaterials,只取 diffuseLayer ──
    // WOMaterial 下标与 materialMaps 下标对齐(非 Standard 的 map 也占位,保证索引一致)
    for (const auto& mm : model.materialMaps) {
        WOMaterial wm;
        if (mm.materialType == m3::MaterialType::Standard &&
            mm.materialIndex < model.standardMaterials.size()) {
            const auto& sm = model.standardMaterials[mm.materialIndex];
            if (sm.diffuseLayer) wm.texturePath = sm.diffuseLayer->texturePath;
            switch (sm.blendMode) {
                case m3::BlendMode::Opaque:     wm.blendMode = WOBlendMode::Opaque; break;
                case m3::BlendMode::AlphaBlend: wm.blendMode = WOBlendMode::Blend; break;
                case m3::BlendMode::Add:
                case m3::BlendMode::AlphaAdd:   wm.blendMode = WOBlendMode::Additive; break;
                case m3::BlendMode::Mod:
                case m3::BlendMode::Mod2x:      wm.blendMode = WOBlendMode::Modulate; break;
            }
            const u32 mf = static_cast<u32>(sm.flags);
            wm.twoSided = (mf & 0x8) != 0;   // MaterialFlag::TwoSided
            wm.unlit = (mf & 0x10) != 0;     // MaterialFlag::Unshaded
        }
        out.materials.push_back(std::move(wm));
    }

    // ── 骨骼 ──
    for (const auto& b : model.bones) {
        WOBone wb;
        wb.name = b.name;
        wb.parentIndex = (b.parentIndex == 0xFFFF) ? -1 : (int32_t)b.parentIndex;
        wb.restTranslation = toWO(b.position.initValue);
        wb.restRotation = toWO(b.rotation.initValue);
        wb.restScale = toWO(b.scale.initValue);
        out.bones.push_back(std::move(wb));
    }
    // inverse bind:IREF 与骨骼按下标对齐
    for (size_t i = 0; i < out.bones.size() && i < model.initialReference.size(); ++i) {
        const Matrix44f& m = model.initialReference[i].matrix;
        auto& ib = out.bones[i].inverseBind;
        ib.assign(16, 0.0f);
        for (int r = 0; r < 4; ++r)
            for (int c = 0; c < 4; ++c)
                ib[r * 4 + c] = m.data[r][c];
    }

    // ── 网格:顶点缓冲按 Region 拆分,骨骼索引经 boneLookup 重映射 ──
    auto positions = model.vertices.getPositions();
    auto normals = model.vertices.getNormals();
    auto uvs = model.vertices.getUVs(0);
    auto boneIdx = model.vertices.getBoneIndices();   // region-local
    auto boneWts = model.vertices.getBoneWeights();   // 合计 255

    if (!model.divisions.empty()) {
        const auto& div = model.divisions[0];
        for (size_t ri = 0; ri < div.regions.size(); ++ri) {
            const auto& region = div.regions[ri];
            WOMesh mesh;
            const size_t v0 = region.firstVertex;
            const size_t vc = region.vertexCount;
            if (v0 + vc > positions.size()) continue;
            mesh.positions.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.positions.push_back(toWO(positions[k]));
            mesh.normals.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.normals.push_back(k < normals.size() ? toWO(normals[k]) : WOVec3{0, 0, 1});
            mesh.uvs.reserve(vc);
            for (size_t k = v0; k < v0 + vc; ++k)
                mesh.uvs.push_back(k < uvs.size() ? toWO(uvs[k]) : WOVec2{0, 0});

            const size_t i0 = region.firstIndex;
            const size_t ic = region.indexCount;
            for (size_t k = i0; k < i0 + ic && k < div.faces.size(); ++k)
                mesh.indices.push_back((uint32_t)div.faces[k] - (uint32_t)v0);

            // 材质:找引用该 region 的 batch
            for (const auto& batch : div.batches) {
                if (batch.regionIndex == ri) {
                    mesh.materialIndex = (int32_t)batch.materialIndex;  // 与 materialMaps 对齐
                    break;
                }
            }

            mesh.boneIndices.resize(vc * 4, 0);
            mesh.boneWeights.resize(vc * 4, 0);
            for (size_t k = 0; k < vc; ++k) {
                const size_t gv = v0 + k;
                if (gv >= boneIdx.size()) break;
                for (size_t j = 0; j < 4; ++j) {
                    const size_t lu = (size_t)region.firstBoneLookup + boneIdx[gv][j];
                    const u8 real = (lu < model.boneLookup.size())
                                        ? (u8)model.boneLookup[lu] : 0;
                    mesh.boneIndices[k * 4 + j] = real;
                    mesh.boneWeights[k * 4 + j] = (gv < boneWts.size()) ? boneWts[gv][j] : (j == 0 ? 255 : 0);
                }
            }
            out.meshes.push_back(std::move(mesh));
        }
    }

    // ── 动画:STC 与 sequence 配对(数量相等按下标,否则用 STC[0])──
    const bool pairByIndex = (model.subTrackCollections.size() == model.sequences.size());
    for (size_t si = 0; si < model.sequences.size(); ++si) {
        const auto& seq = model.sequences[si];
        const m3::SubTrackContainer* stc = nullptr;
        if (!model.subTrackCollections.empty())
            stc = &model.subTrackCollections[pairByIndex ? si : 0];

        WOAnimation anim;
        anim.name = seq.name;
        anim.durationMs = frameToMs((i32)(seq.endFrame > seq.startFrame
                                              ? seq.endFrame - seq.startFrame : 0));
        anim.loops = true;  // v1:M3 一律循环
        for (const auto& bone : model.bones) {
            anim.translations.push_back(resolveBoneTrack<WOVec3Track>(
                stc, bone.position.animId, bone.position.interpType, 2 /* sd3v */));
            anim.rotations.push_back(resolveBoneTrack<WOQuatTrack>(
                stc, bone.rotation.animId, bone.rotation.interpType, 3 /* sd4q */));
            anim.scales.push_back(resolveBoneTrack<WOVec3Track>(
                stc, bone.scale.animId, bone.scale.interpType, 2 /* sd3v */));
        }
        out.animations.push_back(std::move(anim));
    }

    return out;
}

// ── 测试夹具:1 三角网格 / 1 骨骼 / 1 个位移动画 ──
std::vector<uint8_t> WOEncodeTestM3() {
    m3::Model model;
    model.setVersion(30);
    model.name = "TestM3";

    // 骨骼:带 animId=7 的位移动画引用
    m3::Bone bone;
    bone.setVersion(30);
    bone.name = "root";
    bone.parentIndex = 0xFFFF;
    bone.position.initValue = Vector3f{0, 0, 0};
    bone.rotation.initValue = Quaternion::identity();
    bone.scale.initValue = Vector3f{1, 1, 1};
    bone.position.animId = 7;
    bone.position.interpType = 1;  // linear
    model.bones = {bone};
    model.skinBoneCount = 1;

    // IREF(单位阵)
    m3::InitialReference iref;
    iref.setVersion(30);
    for (int r = 0; r < 4; ++r) iref.matrix.data[r][r] = 1.0f;
    model.initialReference = {iref};

    // 顶点缓冲:3 顶点,UV1 布局,stride = 12+4+4+4+4+4 = 32
    m3::VertexBuffer vb;
    vb.flags = m3::VertexFormatFlag::UV1;
    const size_t stride = 32, vcount = 3;
    vb.data.resize(stride * vcount, 0);
    const float pos[3][3] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}};
    for (size_t v = 0; v < vcount; ++v) {
        u8* base = vb.data.data() + v * stride;
        std::memcpy(base, pos[v], 12);            // position
        base[12] = 255;                           // weight0 = 255,其余 0
        base[16] = 127;                           // normal z (i8 归一)
        // boneIndices(20-23)全 0;uv(24-27)全 0;tangent(28-31)全 0
    }
    model.vertices = vb;
    model.vertices.initialize();

    // 网格划分:1 region + 1 batch
    m3::MeshDivision div;
    div.setVersion(30);
    div.faces = {0, 1, 2};
    m3::Region region;
    region.setVersion(30);
    region.firstVertex = 0;
    region.vertexCount = 3;
    region.firstIndex = 0;
    region.indexCount = 3;
    region.firstBoneLookup = 0;
    region.boneLookupCount = 1;
    div.regions = {region};
    m3::Batch batch;
    batch.setVersion(30);
    batch.regionIndex = 0;
    batch.materialIndex = 0;
    div.batches = {batch};
    model.divisions = {div};
    model.boneLookup = {0};

    // 材质
    m3::MaterialMap mm;
    mm.setVersion(30);
    mm.materialType = m3::MaterialType::Standard;
    mm.materialIndex = 0;
    model.materialMaps = {mm};
    m3::StandardMaterial sm;
    sm.setVersion(30);
    sm.name = "TestMat";
    sm.blendMode = m3::BlendMode::Opaque;
    m3::TextureLayer tl;
    tl.setVersion(30);
    tl.texturePath = "Assets/Textures/test.dds";
    sm.diffuseLayer = tl;
    model.standardMaterials = {sm};

    // 动画:1 sequence + 1 STC(animId=7 → sd3v[0],2 帧)
    m3::Sequence seq;
    seq.setVersion(30);
    seq.name = "Stand";
    seq.startFrame = 0;
    seq.endFrame = 30;
    model.sequences = {seq};

    m3::SubTrackContainer stc;
    stc.setVersion(30);
    stc.animIds = {7};
    stc.animRefs = {(2u << 16) | 0u};  // slot 2 (sd3v),index 0
    m3::AnimBlock<Vector3f> block;
    block.timestamps = {0, 30};
    block.keys = {Vector3f{0, 0, 0}, Vector3f{0, 1, 0}};
    stc.sd3v = {block};
    model.subTrackCollections = {stc};

    m3::Writer writer;
    return writer.write(model);
}

} // namespace WhiteoutBridge
```

实现注意:`Region`/`Batch` 的字段名以 `include/whiteout/models/m3/structures/mesh.h` 为准;若 `VertexFormatFlag` 不支持 `|` 赋值,用 `vb.flags = m3::VertexFormatFlag::UV1;` 直接赋。若 writer 对 `VertexBuffer.flags` 的类型是 `u32`,写 `vb.flags = (u32)m3::VertexFormatFlag::UV1;`。编译报错时以头文件实际类型微调,不得改变测试断言语义。

- [ ] **Step 3: 实现 WOModelLoaderM2.cpp**

`CascViewer/Core/WhiteoutBridge/src/WOModelLoaderM2.cpp`:

```cpp
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
                        mesh.materialIndex = mesh.materialIndex;  // 材质索引不变
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
    m2::Model model;
    model.modelName = "TestM2";
    m2::Writer writer;
    auto result = writer.write(model);
    return result.m2Data;
}

} // namespace WhiteoutBridge
```

`WOModelLoader.cpp` 中删除两个占位函数(现在由 M3/M2 文件提供实现),保留空文件或直接 `git rm` 该文件并从 pbxproj 移除(二选一,避免重复定义链接错误)。

pbxproj:加入 `WOModelLoaderM3.cpp`、`WOModelLoaderM2.cpp`;若删 `WOModelLoader.cpp` 则同步移除其条目。

- [ ] **Step 4: 运行测试**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/WhiteoutBridgeModelTests 2>&1 | tail -20`
Expected: 4 个用例全 PASS。M3 夹具若 round-trip 失败(writer 对缺省字段敏感),按 `hasIssues()`/`getIssues()` 输出修正夹具,不得删断言。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add M3 and M2 model parsing to WhiteoutBridge"
```

---

### Task 6: ModelLoaderService + ModelScene(Swift 模型加载服务)

**Files:**
- Create: `CascViewer/Core/Models/ModelScene.swift`
- Create: `CascViewer/Core/Services/ModelLoaderService.swift`
- Test: `CascViewerTests/ModelLoaderServiceTests.swift`

**Interfaces:**
- Consumes: `WhiteoutBridge.WOModelLoader`(Task 4/5)、`BLPDecoderCoordinator.decode(data:)`(Task 3 后不变)、`CascBridge.CascStorageHandle.readFile(_:_:)`(现有)。
- Produces(Task 7/9 依赖):
  - `ModelScene`(Swift 值类型,字段见下)
  - `ModelLoaderService.load(path:format:) async throws -> ModelScene`
  - `ModelLoaderService.FileProvider` 协议 + `CascModelFileProvider`(生产)+ 测试用 mock

- [ ] **Step 1: 写失败测试**

`CascViewerTests/ModelLoaderServiceTests.swift`:

```swift
import XCTest
import CascBridge
@testable import CascViewer

final class ModelLoaderServiceTests: XCTestCase {

    /// 内存文件提供者:MDX 模型 + 一张 BLP 纹理
    private func makeProvider() -> MockModelFileProvider {
        let provider = MockModelFileProvider()
        provider.files["models/test.mdx"] = Data(WhiteoutBridge.WOEncodeTestMDX())
        provider.files["Textures/test.blp"] = Data(WhiteoutBridge.WOEncodeTestImage(8, 8, 1))
        return provider
    }

    func testLoadMDXScene() async throws {
        let service = ModelLoaderService(provider: makeProvider())
        let scene = try await service.load(path: "models/test.mdx", format: .mdx)

        XCTAssertEqual(scene.format, .mdx)
        XCTAssertEqual(scene.meshes.count, 1)
        XCTAssertEqual(scene.meshes[0].positions.count, 3)
        XCTAssertEqual(scene.bones.count, 2)
        XCTAssertEqual(scene.animations.count, 1)
        XCTAssertEqual(scene.animations[0].name, "Stand")
        XCTAssertEqual(scene.animations[0].durationMs, 1000)
        // 材质纹理已解析并解码
        XCTAssertEqual(scene.materials.count, 1)
        XCTAssertNotNil(scene.materials[0].diffuseTexture)
        XCTAssertEqual(scene.materials[0].diffuseTexture?.width, 8)
    }

    func testMissingModelThrows() async {
        let service = ModelLoaderService(provider: MockModelFileProvider())
        do {
            _ = try await service.load(path: "nope.mdx", format: .mdx)
            XCTFail("应当抛错")
        } catch {
            // 预期
        }
    }

    func testMissingTextureKeepsMaterial() async throws {
        let provider = MockModelFileProvider()
        provider.files["models/test.mdx"] = Data(WhiteoutBridge.WOEncodeTestMDX())
        // 不放纹理文件
        let service = ModelLoaderService(provider: provider)
        let scene = try await service.load(path: "models/test.mdx", format: .mdx)
        XCTAssertNil(scene.materials[0].diffuseTexture)  // 纹理缺失但材质还在
    }
}
```

`MockModelFileProvider` 定义在 `ModelLoaderService.swift` 的 `#if DEBUG` 段(仿 `MockFileReader` 模式):

```swift
#if DEBUG
final class MockModelFileProvider: ModelLoaderService.FileProvider, @unchecked Sendable {
    var files: [String: Data] = [:]
    func readFile(path: String) -> Data? { files[path] }
    func readFileByDataId(_ id: UInt32) -> Data? { files[String(format: "FILE%08X.dat", id)] }
}
#endif
```

Run: `xcodebuild ... test -only-testing:CascViewerTests/ModelLoaderServiceTests 2>&1 | tail -10`
Expected: 编译错误(类型不存在)。记得把测试文件加入测试 target。

- [ ] **Step 2: 实现 ModelScene.swift**

`CascViewer/Core/Models/ModelScene.swift`:

```swift
import Foundation
import simd

/// 渲染无关的模型场景描述(WOModel 的 Swift 值类型镜像)。
struct ModelScene: Sendable {
    var name: String
    var format: Format
    var meshes: [Mesh]
    var materials: [Material]
    var bones: [Bone]
    var animations: [Animation]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    enum Format: Sendable { case mdx, m3, m2 }

    struct Mesh: Sendable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]
        var boneIndices: [SIMD4<UInt8>]  // 每顶点 4 个
        var boneWeights: [SIMD4<UInt8>]  // 每顶点合计 255
        var materialIndex: Int           // -1 = 无
    }

    struct Material: Sendable {
        var texturePath: String
        var textureFileDataId: UInt32    // M2 TXID;0 = 无
        var blendMode: BlendMode
        var twoSided: Bool
        var unlit: Bool
        var diffuseTexture: ImageDecodeResult.ImageFrame?  // 加载阶段填充,nil = 缺失
    }

    enum BlendMode: Sendable { case opaque, alphaTest, blend, additive, modulate }

    struct Bone: Sendable {
        var name: String
        var parentIndex: Int             // -1 = root
        var pivot: SIMD3<Float>          // 父空间(MDX/M2 的锚点公式用)
        var inverseBind: simd_float4x4
        var restTranslation: SIMD3<Float>
        var restRotation: simd_quatf
        var restScale: SIMD3<Float>
    }

    enum Interpolation: Sendable { case constant, linear, hermite, bezier }

    struct Vec3Track: Sendable {
        var interp: Interpolation
        var times: [Float]               // 毫秒
        var keys: [SIMD3<Float>]
        var inTangents: [SIMD3<Float>]
        var outTangents: [SIMD3<Float>]
    }

    struct QuatTrack: Sendable {
        var interp: Interpolation
        var times: [Float]
        var keys: [simd_quatf]
        var inTangents: [simd_quatf]
        var outTangents: [simd_quatf]
    }

    struct Animation: Sendable {
        var name: String
        var durationMs: Float
        var loops: Bool
        var translations: [Vec3Track]    // 与 bones 平行
        var rotations: [QuatTrack]
        var scales: [Vec3Track]
    }
}
```

- [ ] **Step 3: 实现 ModelLoaderService.swift**

`CascViewer/Core/Services/ModelLoaderService.swift`:

```swift
import Foundation
import simd
import CascBridge

/// 把 WOModel(C++) 转成 ModelScene(Swift)并解析纹理。
actor ModelLoaderService {

    /// 文件读取抽象(生产用 CascModelFileProvider,测试用 Mock)。
    protocol FileProvider: Sendable {
        func readFile(path: String) -> Data?
        func readFileByDataId(_ id: UInt32) -> Data?
    }

    enum LoadError: Error {
        case fileNotFound(String)
        case parseFailed(String)
    }

    private let provider: any FileProvider
    private static let cache = NSCache<NSString, ModelSceneBox>()

    init(provider: any FileProvider) {
        self.provider = provider
    }

    func load(path: String, format: ModelScene.Format) async throws -> ModelScene {
        let cacheKey = path as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            return cached.scene
        }
        guard let data = provider.readFile(path: path), !data.isEmpty else {
            throw LoadError.fileNotFound(path)
        }

        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        let cppModel: WhiteoutBridge.WOModel

        switch format {
        case .mdx:
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseMDX(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                                data.count, &error)
            }
        case .m3:
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseM3(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                               data.count, &error)
            }
        case .m2:
            let box = M2ReadBox(provider: provider)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<M2ReadBox>.fromOpaque(ctx).release() }
            let callback: WhiteoutBridge.WOM2ReadFileCallback = { ctx, fileDataId, outSize in
                guard let ctx = ctx, let outSize = outSize else { return nil }
                let box = Unmanaged<M2ReadBox>.fromOpaque(ctx).takeUnretainedValue()
                guard let bytes = box.provider.readFileByDataId(fileDataId),
                      !bytes.isEmpty else { return nil }
                box.retained[fileDataId] = bytes   // 保活,parse 返回前指针有效
                outSize.pointee = bytes.count
                return bytes.withUnsafeBytes {
                    $0.bindMemory(to: UInt8.self).baseAddress
                }
            }
            cppModel = data.withUnsafeBytes { rawBuffer in
                loader.parseM2(rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                               data.count, ctx, callback, &error)
            }
        }

        guard error == .None else {
            throw LoadError.parseFailed(path)
        }

        var scene = ModelSceneConverter.convert(cppModel, format: format)
        await resolveTextures(&scene)
        Self.cache.setObject(ModelSceneBox(scene: scene), forKey: cacheKey)
        return scene
    }

    /// 逐材质解析纹理引用并从存储读取解码;失败保留 nil(占位材质)。
    private func resolveTextures(_ scene: inout ModelScene) async {
        let coordinator = BLPDecoderCoordinator()
        for i in scene.materials.indices {
            let mat = scene.materials[i]
            let data: Data?
            if !mat.texturePath.isEmpty {
                data = provider.readFile(path: mat.texturePath)
            } else if mat.textureFileDataId != 0 {
                data = provider.readFileByDataId(mat.textureFileDataId)
            } else {
                data = nil
            }
            guard let textureData = data,
                  let decoded = try? await coordinator.decode(data: textureData),
                  let mip0 = decoded.frames.first else { continue }
            scene.materials[i].diffuseTexture = mip0
        }
    }
}

/// NSCache 需要 class 包装
final class ModelSceneBox: NSObject {
    let scene: ModelScene
    init(scene: ModelScene) { self.scene = scene }
}

/// M2 回调的保活盒
private final class M2ReadBox: @unchecked Sendable {
    let provider: any ModelLoaderService.FileProvider
    var retained: [UInt32: Data] = [:]
    init(provider: any ModelLoaderService.FileProvider) { self.provider = provider }
}

/// 生产环境 FileProvider:同步读 C++ 存储句柄(句柄内部有锁,线程安全)。
final class CascModelFileProvider: ModelLoaderService.FileProvider, @unchecked Sendable {
    private var handle: CascBridge.CascStorageHandle
    init(handle: CascBridge.CascStorageHandle) { self.handle = handle }

    func readFile(path: String) -> Data? {
        var error = CascBridge.CascError.None
        let buffer = handle.readFile(std.string(path), &error)
        guard error == .None else { return nil }
        return Data(buffer)
    }

    func readFileByDataId(_ id: UInt32) -> Data? {
        readFile(path: String(format: "FILE%08X.dat", id))
    }
}
```

`ModelSceneConverter`(放同文件或新建 `Core/Services/ModelSceneConverter.swift`,枚举/容器转换,纯函数便于测试):

```swift
import Foundation
import simd
import CascBridge

/// WOModel(C++) → ModelScene(Swift) 转换。
enum ModelSceneConverter {

    static func convert(_ cpp: WhiteoutBridge.WOModel, format: ModelScene.Format) -> ModelScene {
        var scene = ModelScene(
            name: String(cpp.name),
            format: format,
            meshes: [],
            materials: [],
            bones: [],
            animations: [],
            boundsMin: SIMD3(cpp.boundsMin.x, cpp.boundsMin.y, cpp.boundsMin.z),
            boundsMax: SIMD3(cpp.boundsMax.x, cpp.boundsMax.y, cpp.boundsMax.z)
        )

        scene.materials = (0..<cpp.materials.size()).map { i in
            let m = cpp.materials[i]
            return ModelScene.Material(
                texturePath: String(m.texturePath),
                textureFileDataId: m.textureFileDataId,
                blendMode: convertBlend(m.blendMode),
                twoSided: m.twoSided,
                unlit: m.unlit,
                diffuseTexture: nil
            )
        }

        scene.bones = (0..<cpp.bones.size()).map { i in
            let b = cpp.bones[i]
            return ModelScene.Bone(
                name: String(b.name),
                parentIndex: Int(b.parentIndex),
                pivot: SIMD3(b.pivot.x, b.pivot.y, b.pivot.z),
                inverseBind: convertMat4(b.inverseBind),
                restTranslation: SIMD3(b.restTranslation.x, b.restTranslation.y, b.restTranslation.z),
                restRotation: simd_quatf(ix: b.restRotation.x, iy: b.restRotation.y,
                                         iz: b.restRotation.z, r: b.restRotation.w),
                restScale: SIMD3(b.restScale.x, b.restScale.y, b.restScale.z)
            )
        }

        scene.meshes = (0..<cpp.meshes.size()).map { i in
            let m = cpp.meshes[i]
            let vcount = m.positions.size()
            var mesh = ModelScene.Mesh(
                positions: (0..<vcount).map { SIMD3(m.positions[$0].x, m.positions[$0].y, m.positions[$0].z) },
                normals: (0..<m.normals.size()).map { SIMD3(m.normals[$0].x, m.normals[$0].y, m.normals[$0].z) },
                uvs: (0..<m.uvs.size()).map { SIMD2(m.uvs[$0].x, m.uvs[$0].y) },
                indices: (0..<m.indices.size()).map { m.indices[$0] },
                boneIndices: [],
                boneWeights: [],
                materialIndex: Int(m.materialIndex)
            )
            let quadCount = m.boneIndices.size() / 4
            mesh.boneIndices = (0..<quadCount).map {
                SIMD4(m.boneIndices[$0 * 4], m.boneIndices[$0 * 4 + 1],
                      m.boneIndices[$0 * 4 + 2], m.boneIndices[$0 * 4 + 3])
            }
            mesh.boneWeights = (0..<(m.boneWeights.size() / 4)).map {
                SIMD4(m.boneWeights[$0 * 4], m.boneWeights[$0 * 4 + 1],
                      m.boneWeights[$0 * 4 + 2], m.boneWeights[$0 * 4 + 3])
            }
            return mesh
        }

        scene.animations = (0..<cpp.animations.size()).map { i in
            let a = cpp.animations[i]
            return ModelScene.Animation(
                name: String(a.name),
                durationMs: Float(a.durationMs),
                loops: a.loops,
                translations: (0..<a.translations.size()).map { convertVec3Track(a.translations[$0]) },
                rotations: (0..<a.rotations.size()).map { convertQuatTrack(a.rotations[$0]) },
                scales: (0..<a.scales.size()).map { convertVec3Track(a.scales[$0]) }
            )
        }

        return scene
    }

    private static func convertBlend(_ b: WhiteoutBridge.WOBlendMode) -> ModelScene.BlendMode {
        switch b {
        case .Opaque: return .opaque
        case .AlphaTest: return .alphaTest
        case .Blend: return .blend
        case .Additive: return .additive
        default: return .modulate
        }
    }

    private static func convertMat4(_ v: std.vector<Float>) -> simd_float4x4 {
        // 16 个 row-major;空 = 单位阵
        guard v.size() == 16 else { return matrix_identity_float4x4 }
        var m = matrix_identity_float4x4
        // simd_float4x4 为列主序存储,按转置填充
        for r in 0..<4 {
            for c in 0..<4 {
                m[c, r] = v[r * 4 + c]
            }
        }
        return m
    }

    private static func convertVec3Track(_ t: WhiteoutBridge.WOVec3Track) -> ModelScene.Vec3Track {
        ModelScene.Vec3Track(
            interp: convertInterp(t.interp),
            times: (0..<t.times.size()).map { Float(t.times[$0]) },
            keys: (0..<t.keys.size()).map { SIMD3(t.keys[$0].x, t.keys[$0].y, t.keys[$0].z) },
            inTangents: (0..<t.inTangents.size()).map { SIMD3(t.inTangents[$0].x, t.inTangents[$0].y, t.inTangents[$0].z) },
            outTangents: (0..<t.outTangents.size()).map { SIMD3(t.outTangents[$0].x, t.outTangents[$0].y, t.outTangents[$0].z) }
        )
    }

    private static func convertQuatTrack(_ t: WhiteoutBridge.WOQuatTrack) -> ModelScene.QuatTrack {
        ModelScene.QuatTrack(
            interp: convertInterp(t.interp),
            times: (0..<t.times.size()).map { Float(t.times[$0]) },
            keys: (0..<t.keys.size()).map {
                simd_quatf(ix: t.keys[$0].x, iy: t.keys[$0].y, iz: t.keys[$0].z, r: t.keys[$0].w)
            },
            inTangents: (0..<t.inTangents.size()).map {
                simd_quatf(ix: t.inTangents[$0].x, iy: t.inTangents[$0].y, iz: t.inTangents[$0].z, r: t.inTangents[$0].w)
            },
            outTangents: (0..<t.outTangents.size()).map {
                simd_quatf(ix: t.outTangents[$0].x, iy: t.outTangents[$0].y, iz: t.outTangents[$0].z, r: t.outTangents[$0].w)
            }
        )
    }

    private static func convertInterp(_ i: WhiteoutBridge.WOInterpolation) -> ModelScene.Interpolation {
        switch i {
        case .Constant: return .constant
        case .Linear: return .linear
        case .Hermite: return .hermite
        default: return .bezier
        }
    }
}
```

- [ ] **Step 4: 运行测试**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test -only-testing:CascViewerTests/ModelLoaderServiceTests 2>&1 | tail -20`
Expected: 3 个用例 PASS。注意 `ModelSceneConverter` 不嵌在 actor 里(纯函数),测试可直接调用。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add ModelLoaderService converting WhiteoutBridge models to ModelScene"
```

---

### Task 7: ModelSceneBuilder(SceneKit 场景图)

**Files:**
- Create: `CascViewer/Core/Services/ModelSceneBuilder.swift`
- Test: `CascViewerTests/ModelSceneBuilderTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `ModelScene`。
- Produces(Task 9 依赖):`ModelSceneBuilder.build(_ scene: ModelScene) -> BuiltModelScene`;`BuiltModelScene { rootNode: SCNNode, boneNodes: [SCNNode] }`(boneNodes 与 `ModelScene.bones` 平行)。

- [ ] **Step 1: 写失败测试**

`CascViewerTests/ModelSceneBuilderTests.swift`:

```swift
import XCTest
import SceneKit
@testable import CascViewer

final class ModelSceneBuilderTests: XCTestCase {

    private func makeScene() -> ModelScene {
        // 与 WOEncodeTestMDX 夹具同构:1 三角形 / 2 骨骼 / 1 材质
        let mesh = ModelScene.Mesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
            indices: [0, 1, 2],
            boneIndices: [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0)],
            boneWeights: [SIMD4(255, 0, 0, 0), SIMD4(255, 0, 0, 0), SIMD4(255, 0, 0, 0)],
            materialIndex: 0
        )
        let material = ModelScene.Material(
            texturePath: "", textureFileDataId: 0, blendMode: .opaque,
            twoSided: false, unlit: false, diffuseTexture: nil
        )
        let bone0 = ModelScene.Bone(
            name: "root", parentIndex: -1, pivot: .zero,
            inverseBind: matrix_identity_float4x4,
            restTranslation: .zero, restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            restScale: SIMD3(1, 1, 1)
        )
        let bone1 = ModelScene.Bone(
            name: "child", parentIndex: 0, pivot: SIMD3(0, 0, 1),
            inverseBind: matrix_identity_float4x4,
            restTranslation: .zero, restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            restScale: SIMD3(1, 1, 1)
        )
        return ModelScene(
            name: "t", format: .mdx, meshes: [mesh], materials: [material],
            bones: [bone0, bone1], animations: [],
            boundsMin: .zero, boundsMax: SIMD3(1, 1, 1)
        )
    }

    func testBuildStructure() {
        let built = ModelSceneBuilder.build(makeScene())
        XCTAssertEqual(built.boneNodes.count, 2)
        // 父子关系:child 挂在 root 下,root 挂在场景根下
        XCTAssertEqual(built.rootNode.childNodes.count, 1)
        XCTAssertEqual(built.rootNode.childNodes[0].childNodes.first?.name, "child")
        // 网格节点带几何与蒙皮器
        let geometryNodes = built.rootNode.childNodes.filter { $0.geometry != nil }
        // 网格直接挂场景根(不是骨骼下)
        XCTAssertEqual(geometryNodes.count, 1)
        let skinner = geometryNodes[0].skinner
        XCTAssertNotNil(skinner)
        XCTAssertEqual(skinner?.bones.count, 2)
        XCTAssertEqual(skinner?.boneInverseBindTransforms?.count, 2)
    }

    func testMaterialMapping() {
        let built = ModelSceneBuilder.build(makeScene())
        let geometryNode = built.rootNode.childNodes.first { $0.geometry != nil }!
        let material = geometryNode.geometry!.firstMaterial!
        XCTAssertFalse(material.isDoubleSided)
        XCTAssertEqual(material.lightingModel, .blinn)   // 非 unlit
    }
}
```

- [ ] **Step 2: 运行确认编译失败**

Expected: `cannot find 'ModelSceneBuilder' in scope`。

- [ ] **Step 3: 实现 ModelSceneBuilder.swift**

`CascViewer/Core/Services/ModelSceneBuilder.swift`:

```swift
import Foundation
import SceneKit
import simd

struct BuiltModelScene {
    let rootNode: SCNNode
    let boneNodes: [SCNNode]  // 与 ModelScene.bones 平行
}

enum ModelSceneBuilder {

    static func build(_ scene: ModelScene) -> BuiltModelScene {
        let root = SCNNode()

        // ── 骨骼节点树(rest 变换;MDX/M2 的锚点公式在 AnimationPlayer 中处理,
        //    这里 rest 局部变换统一为 T(restTranslation) R(restRotation) S(restScale),
        //    MDX/M2 的 rest* 全为默认值,等价单位阵——绑定姿态即恒等)──
        var boneNodes = scene.bones.map { bone -> SCNNode in
            let node = SCNNode()
            node.name = bone.name
            node.simdTransform = translationMatrix(bone.restTranslation)
                * simd_float4x4(bone.restRotation)
                * scaleMatrix(bone.restScale)
            return node
        }
        for (i, bone) in scene.bones.enumerated() where bone.parentIndex >= 0
            && bone.parentIndex < boneNodes.count {
            boneNodes[bone.parentIndex].addChildNode(boneNodes[i])
        }
        for (i, bone) in scene.bones.enumerated() where bone.parentIndex < 0 {
            root.addChildNode(boneNodes[i])
        }

        // ── 网格 ──
        for mesh in scene.meshes {
            let geometry = buildGeometry(mesh)
            let node = SCNNode(geometry: geometry)
            node.geometry?.firstMaterial = buildMaterial(
                mesh.materialIndex >= 0 && mesh.materialIndex < scene.materials.count
                    ? scene.materials[mesh.materialIndex] : nil
            )
            if !scene.bones.isEmpty && !mesh.boneIndices.isEmpty {
                node.skinner = buildSkinner(mesh: mesh, bones: scene.bones,
                                            boneNodes: boneNodes,
                                            baseGeometry: geometry)
                node.skinner?.skeleton = root
            }
            root.addChildNode(node)
        }

        // 基础光照,避免全黑
        let light = SCNLight()
        light.type = .omni
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(5, 10, 5)
        root.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        return BuiltModelScene(rootNode: root, boneNodes: boneNodes)
    }

    private static func buildGeometry(_ mesh: ModelScene.Mesh) -> SCNGeometry {
        let vertexData = Data(bytes: mesh.positions, count: mesh.positions.count * 12)
        let positionSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex,
            vectorCount: mesh.positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12
        )
        let normalData = Data(bytes: mesh.normals, count: mesh.normals.count * 12)
        let normalSource = SCNGeometrySource(
            data: normalData, semantic: .normal,
            vectorCount: mesh.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 12
        )
        let uvData = Data(bytes: mesh.uvs, count: mesh.uvs.count * 8)
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: mesh.uvs.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 8
        )
        let indexData = mesh.indices.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4
        )
        return SCNGeometry(sources: [positionSource, normalSource, uvSource],
                           elements: [element])
    }

    private static func buildSkinner(mesh: ModelScene.Mesh, bones: [ModelScene.Bone],
                                     boneNodes: [SCNNode],
                                     baseGeometry: SCNGeometry) -> SCNSkinner {
        // SceneKit 骨骼权重格式:每顶点 4 个 UInt16 索引 + 4 个 Float 权重
        var weightIndices: [UInt16] = []
        var weightValues: [Float] = []
        weightIndices.reserveCapacity(mesh.boneIndices.count * 4)
        weightValues.reserveCapacity(mesh.boneWeights.count * 4)
        for v in 0..<mesh.boneIndices.count {
            for j in 0..<4 {
                weightIndices.append(UInt16(mesh.boneIndices[v][j]))
                weightValues.append(Float(mesh.boneWeights[v][j]) / 255.0)
            }
        }
        let weightIndicesData = weightIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let weightValuesData = weightValues.withUnsafeBufferPointer { Data(buffer: $0) }
        let boneIndicesSource = SCNGeometrySource(
            data: weightIndicesData, semantic: .boneIndices,
            vectorCount: mesh.boneIndices.count,
            usesFloatComponents: false, componentsPerVector: 4,
            bytesPerComponent: 2, dataOffset: 0, dataStride: 8
        )
        let boneWeightsSource = SCNGeometrySource(
            data: weightValuesData, semantic: .boneWeights,
            vectorCount: mesh.boneWeights.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16
        )
        return SCNSkinner(
            baseGeometry: baseGeometry,
            bones: boneNodes,
            boneInverseBindTransforms: bones.map { $0.inverseBind },
            boneWeights: boneWeightsSource,
            boneIndices: boneIndicesSource
        )
    }

    private static func buildMaterial(_ mat: ModelScene.Material?) -> SCNMaterial {
        let material = SCNMaterial()
        guard let mat = mat else {
            material.diffuse.contents = NSColor.systemGray  // 占位
            return material
        }
        if let tex = mat.diffuseTexture, let image = tex.cgImage {
            material.diffuse.contents = image
        } else {
            material.diffuse.contents = NSColor.systemGray
        }
        material.isDoubleSided = mat.twoSided
        material.lightingModel = mat.unlit ? .constant : .blinn
        switch mat.blendMode {
        case .opaque:
            material.blendMode = .replace
        case .alphaTest:
            material.blendMode = .replace
            material.transparencyMode = .aOne   // alpha 裁剪近似
        case .blend:
            material.blendMode = .alpha
        case .additive:
            material.blendMode = .add
        case .modulate:
            material.blendMode = .multiply
        }
        return material
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[3, 0] = t.x; m[3, 1] = t.y; m[3, 2] = t.z
        return m
    }

    private static func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[0, 0] = s.x; m[1, 1] = s.y; m[2, 2] = s.z
        return m
    }
}
```

实现注意:`buildSkinner` 返回后,在网格循环里追加一行 `node.skinner?.skeleton = root`(SCNSkinner 的 skeleton 必须指向骨骼树根);`SCNSkinner(baseGeometry: nil ...)` 若初始化器不允许 nil,把 `node.geometry` 传入 `baseGeometry`。

- [ ] **Step 4: 运行测试**

Run: `xcodebuild ... test -only-testing:CascViewerTests/ModelSceneBuilderTests 2>&1 | tail -20`
Expected: 2 个用例 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add SceneKit ModelSceneBuilder with skinned geometry"
```

---

### Task 8: ModelAnimationPlayer(骨骼动画求值)

**Files:**
- Create: `CascViewer/Core/Services/ModelAnimationPlayer.swift`
- Test: `CascViewerTests/ModelAnimationPlayerTests.swift`

**Interfaces:**
- Consumes: `ModelScene`(Task 6)、`BuiltModelScene`(Task 7)。
- Produces(Task 9 依赖):
  - `class ModelAnimationPlayer`(init(scene:built:);`var animationNames: [String]`;`func selectAnimation(index: Int)`;`func update(timeMs: Float)` 对骨骼节点赋变换;静态求值函数 `evaluate(track:timeMs:default:) -> SIMD3<Float>` / `evaluate(track:timeMs:default:) -> simd_quatf` 供测试)

- [ ] **Step 1: 写失败测试(求值数学)**

`CascViewerTests/ModelAnimationPlayerTests.swift`:

```swift
import XCTest
import simd
@testable import CascViewer

final class ModelAnimationPlayerTests: XCTestCase {

    private func vec3Track(_ interp: ModelScene.Interpolation,
                           times: [Float], keys: [SIMD3<Float>]) -> ModelScene.Vec3Track {
        ModelScene.Vec3Track(interp: interp, times: times, keys: keys,
                             inTangents: [], outTangents: [])
    }

    func testConstantTrack() {
        let t = vec3Track(.constant, times: [0, 1000], keys: [SIMD3(1, 2, 3), SIMD3(4, 5, 6)])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 500, default: .zero), SIMD3(1, 2, 3))
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 1500, default: .zero), SIMD3(4, 5, 6))
    }

    func testLinearTrack() {
        let t = vec3Track(.linear, times: [0, 1000], keys: [SIMD3(0, 0, 0), SIMD3(0, 10, 0)])
        let v = ModelAnimationPlayer.evaluate(track: t, timeMs: 500, default: .zero)
        XCTAssertEqual(v.y, 5, accuracy: 0.001)
    }

    func testLinearClampAndLoop() {
        // 播放器外层处理 loop;evaluate 本身按 clamp
        let t = vec3Track(.linear, times: [0, 1000], keys: [SIMD3(0, 0, 0), SIMD3(10, 0, 0)])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 2000, default: .zero).x, 10)
    }

    func testEmptyTrackUsesDefault() {
        let t = vec3Track(.linear, times: [], keys: [])
        XCTAssertEqual(ModelAnimationPlayer.evaluate(track: t, timeMs: 100, default: SIMD3(7, 8, 9)),
                       SIMD3(7, 8, 9))
    }

    func testQuatSlerp() {
        let q0 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let q1 = simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        let track = ModelScene.QuatTrack(interp: .linear, times: [0, 1000],
                                         keys: [q0, q1], inTangents: [], outTangents: [])
        let q = ModelAnimationPlayer.evaluate(track: track, timeMs: 500, default: q0)
        // 半程应绕 z 转 90°
        let rotated = q.act(SIMD3(1, 0, 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 0.01)
        XCTAssertEqual(rotated.y, 1, accuracy: 0.01)
    }

    func testPlayerAppliesToBoneNodes() {
        // 1 骨骼,位移轨道 0→(0,1,0)
        let track = ModelScene.Vec3Track(interp: .linear, times: [0, 1000],
                                         keys: [.zero, SIMD3(0, 1, 0)],
                                         inTangents: [], outTangents: [])
        let bone = ModelScene.Bone(name: "b", parentIndex: -1, pivot: .zero,
                                   inverseBind: matrix_identity_float4x4,
                                   restTranslation: .zero,
                                   restRotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                   restScale: SIMD3(1, 1, 1))
        let anim = ModelScene.Animation(name: "a", durationMs: 1000, loops: true,
                                        translations: [track],
                                        rotations: [ModelScene.QuatTrack(interp: .constant, times: [], keys: [], inTangents: [], outTangents: [])],
                                        scales: [ModelScene.Vec3Track(interp: .constant, times: [], keys: [], inTangents: [], outTangents: [])])
        let scene = ModelScene(name: "s", format: .mdx, meshes: [], materials: [],
                               bones: [bone], animations: [anim],
                               boundsMin: .zero, boundsMax: .zero)
        let built = ModelSceneBuilder.build(scene)
        let player = ModelAnimationPlayer(scene: scene, built: built)
        player.selectAnimation(index: 0)
        player.update(timeMs: 1000)
        // MDX 公式:local = T(pivot + t) R S T(-pivot);pivot=0 → 平移 (0,1,0)
        XCTAssertEqual(built.boneNodes[0].simdPosition.y, 1, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: 运行确认编译失败**

Expected: `cannot find 'ModelAnimationPlayer' in scope`。

- [ ] **Step 3: 实现 ModelAnimationPlayer.swift**

`CascViewer/Core/Services/ModelAnimationPlayer.swift`:

```swift
import Foundation
import SceneKit
import simd

/// CPU 求值骨骼动画轨道并赋给 SceneKit 骨骼节点。
/// 矩阵公式:
///  - M3:        local = T(t) R(r) S(s)
///  - MDX / M2:  local = T(pivot + t) R(r) S(s) T(-pivot)
final class ModelAnimationPlayer {
    private let scene: ModelScene
    private let built: BuiltModelScene
    private var animationIndex: Int = -1

    var animationNames: [String] { scene.animations.map(\.name) }

    init(scene: ModelScene, built: BuiltModelScene) {
        self.scene = scene
        self.built = built
    }

    func selectAnimation(index: Int) {
        animationIndex = (index >= 0 && index < scene.animations.count) ? index : -1
    }

    /// timeMs 为动画内时间(未取模);loops 由本函数按序列配置处理。
    func update(timeMs: Float) {
        guard animationIndex >= 0 else { return }
        let anim = scene.animations[animationIndex]
        let t: Float
        if anim.loops && anim.durationMs > 0 {
            t = timeMs.truncatingRemainder(dividingBy: anim.durationMs)
        } else {
            t = min(timeMs, anim.durationMs)
        }
        for (i, bone) in scene.bones.enumerated() {
            // M3 轨道值是完整局部位移(default 取 rest);
            // MDX/M2 锚点公式中位移是相对 pivot 的增量(default 取 0)。
            let translationDefault = (scene.format == .m3) ? bone.restTranslation : SIMD3<Float>.zero
            let translation = Self.evaluate(track: anim.translations[i], timeMs: t,
                                            default: translationDefault)
            let rotation = Self.evaluate(track: anim.rotations[i], timeMs: t,
                                         default: bone.restRotation)
            let scale = Self.evaluate(track: anim.scales[i], timeMs: t,
                                      default: bone.restScale)
            built.boneNodes[i].simdTransform =
                localMatrix(bone: bone, t: translation, r: rotation, s: scale)
        }
    }

    private func localMatrix(bone: ModelScene.Bone, t: SIMD3<Float>,
                             r: simd_quatf, s: SIMD3<Float>) -> simd_float4x4 {
        switch scene.format {
        case .m3:
            // M3:t 即完整局部 TRS(空轨道时 evaluate 已返回 restTranslation)
            return translationMatrix(t)
                * simd_float4x4(r)
                * scaleMatrix(s)
        case .mdx, .m2:
            return translationMatrix(bone.pivot + t)
                * simd_float4x4(r)
                * scaleMatrix(s)
                * translationMatrix(-bone.pivot)
        }
    }

    // ── 静态求值(供测试)──

    static func evaluate(track: ModelScene.Vec3Track, timeMs: Float,
                         default defaultValue: SIMD3<Float>) -> SIMD3<Float> {
        guard !track.times.isEmpty, track.keys.count == track.times.count else {
            return defaultValue
        }
        let (i, alpha) = segment(times: track.times, timeMs: timeMs)
        let a = track.keys[i]
        guard alpha > 0, i + 1 < track.keys.count else { return a }
        let b = track.keys[i + 1]
        switch track.interp {
        case .constant:
            return a
        case .linear:
            return simd_mix(a, b, SIMD3(repeating: alpha))
        case .hermite, .bezier:
            // 三次 Hermite:切线缺失时退化为线性
            guard track.outTangents.count > i, track.inTangents.count > i + 1 else {
                return simd_mix(a, b, SIMD3(repeating: alpha))
            }
            let dt = track.times[i + 1] - track.times[i]
            return cubicHermite(a, track.outTangents[i] * dt,
                                track.inTangents[i + 1] * dt, b, alpha)
        }
    }

    static func evaluate(track: ModelScene.QuatTrack, timeMs: Float,
                         default defaultValue: simd_quatf) -> simd_quatf {
        guard !track.times.isEmpty, track.keys.count == track.times.count else {
            return defaultValue
        }
        let (i, alpha) = segment(times: track.times, timeMs: timeMs)
        let a = track.keys[i]
        guard alpha > 0, i + 1 < track.keys.count else { return a }
        let b = track.keys[i + 1]
        switch track.interp {
        case .constant:
            return a
        case .linear:
            return simd_slerp(a, b, alpha)
        case .hermite, .bezier:
            // squad(q1, outTan, inTan, q2, t) 的常用近似:slerp(slerp(q1,q2,t), slerp(out,in,t), 2t(1-t))
            guard track.outTangents.count > i, track.inTangents.count > i + 1 else {
                return simd_slerp(a, b, alpha)
            }
            let s1 = simd_slerp(a, b, alpha)
            let s2 = simd_slerp(track.outTangents[i], track.inTangents[i + 1], alpha)
            return simd_slerp(s1, s2, 2 * alpha * (1 - alpha))
        }
    }

    /// 找到 timeMs 所在关键帧段(返回左端下标与 [0,1] 插值系数;越界 clamp)。
    private static func segment(times: [Float], timeMs: Float) -> (Int, Float) {
        if timeMs <= times[0] { return (0, 0) }
        for i in 0..<(times.count - 1) {
            if timeMs >= times[i] && timeMs < times[i + 1] {
                let span = times[i + 1] - times[i]
                return (i, span > 0 ? (timeMs - times[i]) / span : 0)
            }
        }
        return (times.count - 1, 0)
    }

    private static func cubicHermite(_ p0: SIMD3<Float>, _ m0: SIMD3<Float>,
                                     _ m1: SIMD3<Float>, _ p1: SIMD3<Float>,
                                     _ t: Float) -> SIMD3<Float> {
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
             + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
    }

    private func translationMatrix(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[3, 0] = v.x; m[3, 1] = v.y; m[3, 2] = v.z
        return m
    }

    private func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[0, 0] = s.x; m[1, 1] = s.y; m[2, 2] = s.z
        return m
    }
}
```
- [ ] **Step 4: 运行测试**

Run: `xcodebuild ... test -only-testing:CascViewerTests/ModelAnimationPlayerTests 2>&1 | tail -20`
Expected: 6 个用例 PASS。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add skeletal ModelAnimationPlayer with simd track evaluation"
```

---

### Task 9: ModelViewer UI + 入口接线

**Files:**
- Create: `CascViewer/UI/ModelViewer/ModelViewerView.swift`(SCNView representable)
- Create: `CascViewer/UI/ModelViewer/ModelViewerWindow.swift`(SwiftUI view + viewModel + window controller)
- Modify: `CascViewer/UI/FileBrowser/FilePreviewPanel.swift`(模型分支按钮)
- Modify: `CascViewer/UI/FileBrowser/FileListView.swift:170`(双击路径)
- Modify: `CascViewer/App/AppSettings.swift`(`useBuiltInModelViewer`)
- Modify: `CascViewer/UI/MainWindow/ToolbarView.swift:197`(设置开关)
- Modify: `CascViewer/Resources/en.lproj/Localizable.strings`、`CascViewer/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `CascViewer.xcodeproj/project.pbxproj`(2 个新 Swift 文件)

**Interfaces:**
- Consumes: `ModelLoaderService`/`CascModelFileProvider`(Task 6)、`ModelSceneBuilder`(Task 7)、`ModelAnimationPlayer`(Task 8)、`openImageViewerWindow` 的窗口模式(BLPViewerWindow.swift:249-301)。
- Produces: `openModelViewerWindow(fileName:scene:)`;预览面板与双击的模型入口。

- [ ] **Step 1: 本地化 key**

`en.lproj/Localizable.strings` 追加(参照现有 `"open_image_viewer"` 等行格式):

```
"open_model_viewer" = "Open in Model Viewer";
"animation_label" = "Animation";
"no_animations" = "No animations";
"model_load_failed" = "Failed to load model: %@";
"use_builtin_model_viewer" = "Use built-in model viewer";
```

`zh-Hans.lproj/Localizable.strings` 追加:

```
"open_model_viewer" = "在模型查看器中打开";
"animation_label" = "动画";
"no_animations" = "无动画";
"model_load_failed" = "模型加载失败:%@";
"use_builtin_model_viewer" = "使用内置模型查看器";
```

- [ ] **Step 2: ModelViewerView.swift(SCNView 包装)**

`CascViewer/UI/ModelViewer/ModelViewerView.swift`:

```swift
import SwiftUI
import SceneKit

/// SCNView 的 SwiftUI 包装;场景由 viewModel 构建好后整体替换。
struct ModelViewerView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraInteraction = true
        view.autoenablesDefaultLighting = false  // 光照由 builder 提供
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
    }
}
```

- [ ] **Step 3: ModelViewerWindow.swift(view + viewModel + window controller)**

`CascViewer/UI/ModelViewer/ModelViewerWindow.swift`:

```swift
import SwiftUI
import SceneKit
import CoreVideo

struct ModelViewerWindow: View {
    let fileName: String
    let modelScene: ModelScene
    let built: BuiltModelScene
    @StateObject private var viewModel = ModelViewerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileName).font(.headline)
                Spacer()
                if !viewModel.player.animationNames.isEmpty {
                    Picker(L("animation_label"), selection: $viewModel.selectedAnimation) {
                        ForEach(Array(viewModel.player.animationNames.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .frame(maxWidth: 220)
                    Button(viewModel.isPlaying ? "⏸" : "▶") {
                        viewModel.togglePlayback()
                    }
                } else {
                    Text(L("no_animations")).foregroundColor(.secondary)
                }
            }
            .padding()

            Divider()

            ModelViewerView(scene: viewModel.scnScene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text("\(modelScene.meshes.count) meshes · \(modelScene.bones.count) bones · \(modelScene.animations.count) anims")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            viewModel.setup(scene: modelScene, built: built)
        }
        .onDisappear {
            viewModel.stopAnimation()
        }
    }
}

private let modelDisplayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context -> CVReturn in
    guard let context = context else { return kCVReturnError }
    let viewModel = Unmanaged<ModelViewerViewModel>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        viewModel.tick()
    }
    return kCVReturnSuccess
}

@MainActor
final class ModelViewerViewModel: ObservableObject {
    @Published var scnScene = SCNScene()
    @Published var isPlaying = false
    @Published var selectedAnimation = 0 {
        didSet { player.selectAnimation(index: selectedAnimation); currentTimeMs = 0 }
    }

    private(set) var player = ModelAnimationPlayer(scene: ModelScene(
        name: "", format: .mdx, meshes: [], materials: [], bones: [], animations: [],
        boundsMin: .zero, boundsMax: .zero),
        built: BuiltModelScene(rootNode: SCNNode(), boneNodes: []))

    private var displayLink: CVDisplayLink?
    private var displayLinkContext: UnsafeMutableRawPointer?
    private var startTime: CFTimeInterval = 0
    private var currentTimeMs: Float = 0

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        if let context = displayLinkContext {
            Unmanaged<ModelViewerViewModel>.fromOpaque(context).release()
        }
    }

    func setup(scene: ModelScene, built: BuiltModelScene) {
        player = ModelAnimationPlayer(scene: scene, built: built)
        scnScene.rootNode.addChildNode(built.rootNode)
        frameCamera(to: scene)
        if !scene.animations.isEmpty {
            player.selectAnimation(index: 0)
            togglePlayback()
        }
    }

    /// 相机取景:按包围盒对角线把默认相机拉远。
    private func frameCamera(to scene: ModelScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let size = scene.boundsMax - scene.boundsMin
        let center = (scene.boundsMax + scene.boundsMin) / 2
        let radius = max(simd_length(size) / 2, 0.001)
        cameraNode.position = SCNVector3(center.x, center.y, center.z + radius * 3)
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scnScene.pointOfView = cameraNode
        scnScene.rootNode.addChildNode(cameraNode)
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { startAnimation() } else { stopAnimation() }
    }

    func tick() {
        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        currentTimeMs = Float((now - startTime) * 1000)
        player.update(timeMs: currentTimeMs)
    }

    private func startAnimation() {
        stopAnimation()
        startTime = 0
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let displayLink = link else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        displayLinkContext = context
        CVDisplayLinkSetOutputCallback(displayLink, modelDisplayLinkCallback, context)
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    func stopAnimation() {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        if let context = displayLinkContext {
            Unmanaged<ModelViewerViewModel>.fromOpaque(context).release()
            displayLinkContext = nil
        }
        displayLink = nil
    }
}

// MARK: - Window opener(镜像 ImageViewerWindowController 模式)

@MainActor
final class ModelViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [ModelViewerWindowController] = []
    private static let lock = NSLock()

    init(fileName: String, modelScene: ModelScene, built: BuiltModelScene) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileName
        window.setContentSize(NSSize(width: 900, height: 640))
        window.setFrameAutosaveName("CascViewerModelWindow")
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: ModelViewerWindow(fileName: fileName, modelScene: modelScene, built: built))
        Self.lock.lock()
        Self.controllers.append(self)
        Self.lock.unlock()
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.lock.lock()
            Self.controllers.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }
}

@MainActor
func openModelViewerWindow(fileName: String, modelScene: ModelScene, built: BuiltModelScene) {
    _ = ModelViewerWindowController(fileName: fileName, modelScene: modelScene, built: built)
}
```

- [ ] **Step 4: AppSettings + ToolbarView**

`AppSettings.swift`(仿 `useBuiltInImageViewer`,第 35、59、83 行三处模式):

```swift
    @Published var useBuiltInModelViewer: Bool {
        didSet { defaults.set(useBuiltInModelViewer, forKey: "useBuiltInModelViewer") }
    }
```

init 中:`self.useBuiltInModelViewer = defaults.object(forKey: "useBuiltInModelViewer") as? Bool ?? true`;reset 中:`useBuiltInModelViewer = true`。

`ToolbarView.swift` 在 `useBuiltInImageViewer` 的 Toggle 后加:

```swift
Toggle(L("use_builtin_model_viewer"), isOn: $settings.useBuiltInModelViewer)
```

- [ ] **Step 5: FilePreviewPanel 模型分支**

`isImageFile` 下加:

```swift
    private func isModelFile(_ name: String) -> Bool {
        let ext = name.lowercased()
        let modelExts = [".mdx", ".m3", ".m3a", ".m2"]
        return modelExts.contains { ext.hasSuffix($0) }
    }

    @MainActor
    private func openModelFile(entry: CASCFileEntry) async {
        guard let storageService = appState.currentStorage else { return }

        if AppSettings.shared.useBuiltInModelViewer {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let format: ModelScene.Format = (ext == "m2") ? .m2 : (ext == "mdx" ? .mdx : .m3)
            let provider = CascModelFileProvider(handle: storageService.handle)
            let service = ModelLoaderService(provider: provider)
            do {
                let scene = try await service.load(path: entry.normalizedPath, format: format)
                let built = ModelSceneBuilder.build(scene)
                openModelViewerWindow(fileName: entry.name, modelScene: scene, built: built)
            } catch {
                appState.errorMessage = L("model_load_failed", error.localizedDescription)
            }
            return
        }

        // 设置关闭时回退到系统打开(复用 openImageFile 的提取路径)
        await openImageFile(entry: entry)
    }
```

在第 59 行 `if isImageFile(entry.name) { ... }` 块后追加同款按钮块(`isOpeningImage` 状态变量可复用,或新增 `isOpeningModel`,二选一保持简单):

```swift
                    if isModelFile(entry.name) {
                        Button(action: {
                            isOpeningImage = true
                            openFileTask = Task {
                                await openModelFile(entry: entry)
                                isOpeningImage = false
                            }
                        }) {
                            if isOpeningImage {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Text(L("open_model_viewer"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                        .disabled(isOpeningImage)
                    }
```

注意:`CASCStorageService.handle` 的访问级别要与 `CASCExtractService(storage:)` 一致(FilePreviewPanel 已在用 `storageService.handle`,直接可用);`ModelSceneBuilder.build` 非 MainActor 标注,在主线程调用即可(几何构建快),若卡顿再移后台。

- [ ] **Step 6: FileListView 双击路径**

`FileListView.swift` 第 170 行的 `isImage` 判断扩展为(提取到临时目录后):

```swift
            let lowerName = safeName.lowercased()
            let isImage = lowerName.hasSuffix(".blp") || lowerName.hasSuffix(".dds")
            let isModel = lowerName.hasSuffix(".mdx") || lowerName.hasSuffix(".m3")
                || lowerName.hasSuffix(".m3a") || lowerName.hasSuffix(".m2")
            if isImage, let data = try? Data(contentsOf: destURL) {
                openImageViewerWindow(fileName: safeName, imageData: data)
            } else if isModel, AppSettings.shared.useBuiltInModelViewer,
                      let storage = appState.currentStorage {
                // 模型伴随文件(.skin/.anim/纹理)仍需从存储读,故走 provider 而非本地文件
                let ext = (safeName as NSString).pathExtension.lowercased()
                let format: ModelScene.Format = (ext == "m2") ? .m2 : (ext == "mdx" ? .mdx : .m3)
                Task { @MainActor in
                    let provider = CascModelFileProvider(handle: storage.handle)
                    let service = ModelLoaderService(provider: provider)
                    if let scene = try? await service.load(path: entry.normalizedPath, format: format) {
                        let built = ModelSceneBuilder.build(scene)
                        openModelViewerWindow(fileName: safeName, modelScene: scene, built: built)
                    } else {
                        NSWorkspace.shared.open(destURL)
                    }
                }
            } else {
                NSWorkspace.shared.open(destURL)
            }
```

注意:该函数上下文里 `entry` 变量名以其所在函数为准(双击处理函数的 entry 参数);若没有 `entry.normalizedPath` 可用,用 `entry.name`。

- [ ] **Step 7: pbxproj 加入新文件并构建**

`ModelViewerView.swift`、`ModelViewerWindow.swift` 加入 app target(模仿 `BLPViewerWindow.swift` 条目,挂在 UI group 下新建 ModelViewer group)。

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED。

- [ ] **Step 8: 全量测试 + 人工冒烟**

Run: `xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | tail -10`
Expected: 全部 PASS。

人工冒烟(开发机有真实 CASC 存储时):打开一个 WC3/HotS/WoW 存储 → 双击 `.mdx`/`.m3`/`.m2` 文件 → 模型窗口显示并可播动画;M2 解析失败时显示 `model_load_failed` 错误条而非崩溃。

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: add 3D model viewer with skeletal animation playback"
```

---

### Task 10: README 架构更新 + 全量验证

**Files:**
- Modify: `README.md`(Architecture 节,约 159 行起)
- Modify: `README.zh.md`(对应节)

**Interfaces:**
- Consumes: 全部前序任务。
- Produces: 无(文档 + 验证)。

- [ ] **Step 1: 更新架构图与说明**

`README.md` 的 4 层架构图(SwiftUI → Swift Services → C++ Bridge → CascLib + CDN Cache Manager)更新为:

```
┌─────────────────────────────────────────────────┐
│                   SwiftUI Views                  │
├─────────────────────────────────────────────────┤
│  Swift Services (Storage, Search, Extract,       │
│  ModelLoader, ModelSceneBuilder, AnimationPlayer)│
├──────────────────────┬──────────────────────────┤
│  C++ Bridge (CascLib)│  WhiteoutBridge          │
├──────────────────────┼──────────────────────────┤
│  CascLib + CDN Cache │  WhiteoutLib (textures + │
│                      │  models, static lib)     │
└──────────────────────┴──────────────────────────┘
```

说明文字更新:BLP/DDS 解码与 MDX/M3/M2 模型解析由 [WhiteoutLib](https://github.com/FernandoS27/WhiteoutLib)(子模块,CMake 构建,`tools/build_whiteout.sh`)提供;CASC 存储访问仍由 CascLib 提供。3D 模型查看器支持骨骼动画播放(SceneKit + SCNSkinner)。

`README.zh.md` 做对应中文更新。

构建前置说明(两个 README 的 Build/构建节)加一行:首次构建前需运行 `git submodule update --init --recursive && tools/build_whiteout.sh`。

- [ ] **Step 2: 全量验证**

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug build 2>&1 | tail -5
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -configuration Debug test 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED + 全部测试 PASS。

- [ ] **Step 3: 删除调研残留**

```bash
rm -rf /tmp/whiteoutlib-check /tmp/test_whiteout_smoke
```

- [ ] **Step 4: Commit**

```bash
git add README.md README.zh.md
git commit -m "docs: update architecture for WhiteoutLib integration and 3D model viewer"
```
