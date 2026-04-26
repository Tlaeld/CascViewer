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
    CascError open(const std::string& productConfig) override;
    void close() override;
    bool isOpen() const override { return opened; }
    std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error) override;
    CascError extractFile(const std::string& cascPath,
                          const std::string& destPath,
                          const ProgressCallback& progress) override;
    std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error) override;
    CascStorageInfo getStorageInfo(CascError& error) override;
};

} // namespace CascBridge
