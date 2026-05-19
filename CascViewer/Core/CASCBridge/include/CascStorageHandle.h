#pragma once
#include "CascStorage.h"
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
    static std::vector<std::string> fetchProductRegions(const std::string& product);
    static void setFetchCancellationFlag(bool cancelled);

    void setCdnDownloadEnabled(bool enabled);
    void setCachePath(const std::string& path);
    void setListFilePath(const std::string& path);
    void setOpenProgressCallback(COpenProgressCallback callback, void* context);
    void requestCancelExtraction();
    CascError open(const std::string& pathOrConfig);
    void close();
    bool isOpen() const;
    std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error);
    CascError extractFile(const std::string& cascPath,
                          const std::string& destPath);
    CascError extractFile(const std::string& cascPath,
                          const std::string& destPath,
                          void (*progressCallback)(void*, int64_t, int64_t),
                          void* progressContext);
    std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error);
    std::vector<uint8_t> readFilePartial(const std::string& cascPath, uint64_t offset, uint64_t length, CascError& error);
    CascStorageInfo getStorageInfo(CascError& error);
    std::vector<std::pair<std::string, uint32_t>> getTags();
    std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> parseInstallManifest();
};

} // namespace CascBridge
