#pragma once
#include "CascStorage.h"
#include "CascLib.h"

namespace CascBridge {

class LocalCascStorage : public ICascStorage {
    HANDLE hStorage = nullptr;
    bool cdnDownloadEnabled = true;
    COpenProgressCallback progressCallback = nullptr;
    void* progressContext = nullptr;
public:
    ~LocalCascStorage() override;
    void setCdnDownloadEnabled(bool enabled) override;
    void setOpenProgressCallback(COpenProgressCallback callback, void* context) override;
    void invokeProgressCallback(const char* message, int current, int total);
    CascError open(const std::string& localPath) override;
    void close() override;
    bool isOpen() const override { return hStorage != nullptr; }
    std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error) override;
    CascError extractFile(const std::string& cascPath,
                          const std::string& destPath,
                          const ProgressCallback& progress) override;
    std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error) override;
    CascStorageInfo getStorageInfo(CascError& error) override;
};

} // namespace CascBridge
