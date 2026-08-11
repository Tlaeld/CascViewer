#pragma once
// 内部工具头(不加入 modulemap,不对 Swift 暴露)。

#include <string>

namespace WhiteoutBridge {

/// WhiteoutLib 解析出的部分字符串(如 M3 CHAR ref)可能携带结尾/嵌入 NUL,
/// 按 C 字符串语义截断到第一个 NUL,避免污染 Swift 侧的路径比较与字典查找。
inline std::string sanitized(std::string s) {
    const auto pos = s.find('\0');
    if (pos != std::string::npos) s.resize(pos);
    return s;
}

} // namespace WhiteoutBridge
