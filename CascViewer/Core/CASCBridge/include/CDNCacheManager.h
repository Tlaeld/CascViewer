#pragma once
#include <string>
#include <vector>
#include <expected>
#include "CascTypes.h"

namespace CascBridge {

class CDNCacheManager {
    std::string cacheRoot;
public:
    explicit CDNCacheManager(const std::string& product, const std::string& region);
    std::expected<std::vector<uint8_t>, CascError> getChunk(const std::string& encodingKey,
                                                             const std::string& cdnUrl);
    bool hasChunk(const std::string& encodingKey) const;
    void clearCache();
private:
    std::string chunkPath(const std::string& encodingKey) const;
    std::expected<void, CascError> downloadChunk(const std::string& url, const std::string& destPath);
};

} // namespace CascBridge
