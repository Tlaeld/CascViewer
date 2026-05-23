#pragma once
#include "CascStorage.h"
#include "CascLib.h"
#include <atomic>
#include <mutex>

namespace CascBridge {

class LocalCascStorage : public ICascStorage {
    HANDLE hStorage = nullptr;
    bool cdnDownloadEnabled = true;
    std::string cachePath;
    std::string listFilePath;
    std::string processedListFilePath;
    COpenProgressCallback progressCallback = nullptr;
    void* progressContext = nullptr;
    mutable std::mutex progressMutex;
    std::atomic<uint64_t> cancelGeneration{0};
public:
    ~LocalCascStorage() override;
    void setCdnDownloadEnabled(bool enabled) override;
    void setCachePath(const std::string& path) override;
    void setListFilePath(const std::string& path) override;
    void setOpenProgressCallback(COpenProgressCallback callback, void* context) override;
    void invokeProgressCallback(const char* message, int current, int total);
    void requestCancelExtraction() override;
    CascError open(const std::string& localPath) override;
    void close() override;
    bool isOpen() const override { return hStorage != nullptr; }
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
