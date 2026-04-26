#pragma once
#include "CascStorage.h"
#include "CascLib.h"

namespace CascBridge {

class LocalCascStorage : public ICascStorage {
    HANDLE hStorage = nullptr;
public:
    ~LocalCascStorage() override;
    std::expected<void, CascError> open(const std::string& localPath) override;
    void close() override;
    bool isOpen() const override { return hStorage != nullptr; }
    std::expected<std::vector<CascFileEntry>, CascError> listDirectory(const std::string& path) override;
    std::expected<void, CascError> extractFile(const std::string& cascPath,
                                               const std::string& destPath,
                                               const ProgressCallback& progress) override;
    std::expected<std::vector<uint8_t>, CascError> readFile(const std::string& cascPath) override;
    std::expected<CascStorageInfo, CascError> getStorageInfo() override;
};

} // namespace CascBridge
