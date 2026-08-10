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
