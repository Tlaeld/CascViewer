#pragma once
#include "CascStorage.h"
#include "CDNConfig.h"
#include "CDNCacheManager.h"
#include <memory>

namespace CascBridge {

class OnlineCascStorage : public ICascStorage {
    std::unique_ptr<CDNConfig> cdnConfig;
    std::unique_ptr<CDNCacheManager> cacheManager;
    CDNBuildConfig currentBuild;
    bool opened = false;
public:
    ~OnlineCascStorage() override;
    std::expected<void, CascError> open(const std::string& productConfig) override;
    void close() override;
    bool isOpen() const override { return opened; }
    std::expected<std::vector<CascFileEntry>, CascError> listDirectory(const std::string& path) override;
    std::expected<void, CascError> extractFile(const std::string& cascPath,
                                               const std::string& destPath,
                                               const ProgressCallback& progress) override;
    std::expected<std::vector<uint8_t>, CascError> readFile(const std::string& cascPath) override;
    std::expected<CascStorageInfo, CascError> getStorageInfo() override;
};

} // namespace CascBridge
