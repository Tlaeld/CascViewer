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
    std::vector<uint8_t> readFilePartial(const std::string& cascPath, uint64_t offset, uint64_t length, CascError& error) override;
    CascStorageInfo getStorageInfo(CascError& error) override;
    std::vector<std::pair<std::string, uint32_t>> getTags() override;

    std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> parseInstallManifest() override;
};

} // namespace CascBridge
