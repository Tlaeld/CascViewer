#pragma once
#include "CascTypes.h"
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace CascBridge {

using ProgressCallback = std::function<void(int64_t current, int64_t total)>;

class ICascStorage {
public:
    virtual ~ICascStorage() = default;

    virtual CascError open(const std::string& pathOrConfig) = 0;
    virtual void close() = 0;
    virtual bool isOpen() const = 0;

    virtual std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error) = 0;

    virtual CascError extractFile(const std::string& cascPath,
                                  const std::string& destPath,
                                  const ProgressCallback& progress) = 0;

    virtual std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error) = 0;

    virtual CascStorageInfo getStorageInfo(CascError& error) = 0;
};

} // namespace CascBridge
