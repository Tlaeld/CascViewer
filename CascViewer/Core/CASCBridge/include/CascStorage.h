#pragma once
#include "CascTypes.h"
#include <cstdint>
#include <expected>
#include <functional>
#include <string>
#include <vector>

namespace CascBridge {

using ProgressCallback = std::function<void(int64_t current, int64_t total)>;

class ICascStorage {
public:
    virtual ~ICascStorage() = default;

    virtual std::expected<void, CascError> open(const std::string& pathOrConfig) = 0;
    virtual void close() = 0;
    virtual bool isOpen() const = 0;

    virtual std::expected<std::vector<CascFileEntry>, CascError>
        listDirectory(const std::string& path) = 0;

    virtual std::expected<void, CascError>
        extractFile(const std::string& cascPath,
                    const std::string& destPath,
                    const ProgressCallback& progress) = 0;

    virtual std::expected<std::vector<uint8_t>, CascError>
        readFile(const std::string& cascPath) = 0;

    virtual std::expected<CascStorageInfo, CascError> getStorageInfo() = 0;
};

} // namespace CascBridge
