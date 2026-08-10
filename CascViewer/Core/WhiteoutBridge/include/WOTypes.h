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
