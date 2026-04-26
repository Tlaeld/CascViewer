#pragma once
#include "CascTypes.h"
#include <string>
#include <vector>
#include <cstdint>
#include <memory>

namespace CascBridge {

class CascStorageHandle {
    struct Impl;
    std::shared_ptr<Impl> impl;
public:
    CascStorageHandle();

    static CascStorageHandle createLocal();
    static CascStorageHandle createOnline();

    CascError open(const std::string& pathOrConfig);
    void close();
    bool isOpen() const;
    std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error);
    CascError extractFile(const std::string& cascPath,
                          const std::string& destPath);
    std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error);
    CascStorageInfo getStorageInfo(CascError& error);
};

} // namespace CascBridge
