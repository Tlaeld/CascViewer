#pragma once
#include "CascTypes.h"
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace CascBridge {

using ProgressCallback = std::function<void(int64_t current, int64_t total)>;
using COpenProgressCallback = void(*)(void* context, const char* message, int current, int total);

class ICascStorage {
public:
    virtual ~ICascStorage() = default;

    virtual void setCdnDownloadEnabled(bool enabled) {}
    virtual void setCachePath(const std::string& path) {}
    virtual void setListFilePath(const std::string& path) {}
    virtual void setOpenProgressCallback(COpenProgressCallback callback, void* context) {}
    virtual void requestCancelExtraction() {}
    virtual CascError open(const std::string& pathOrConfig) = 0;
    virtual void close() = 0;
    virtual bool isOpen() const = 0;

    virtual std::vector<CascFileEntry> listDirectory(const std::string& path, CascError& error) = 0;

    virtual CascError extractFile(const std::string& cascPath,
                                  const std::string& destPath,
                                  const ProgressCallback& progress) = 0;

    virtual std::vector<uint8_t> readFile(const std::string& cascPath, CascError& error) = 0;
    virtual std::vector<uint8_t> readFilePartial(const std::string& cascPath, uint64_t offset, uint64_t length, CascError& error) = 0;

    virtual CascStorageInfo getStorageInfo(CascError& error) = 0;

    virtual std::vector<std::pair<std::string, uint32_t>> getTags() = 0;

    virtual std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> parseInstallManifest() = 0;
};

} // namespace CascBridge
