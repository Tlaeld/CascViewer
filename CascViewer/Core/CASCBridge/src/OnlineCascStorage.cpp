#include "OnlineCascStorage.h"
#include <fstream>
#include <sstream>

namespace CascBridge {

OnlineCascStorage::~OnlineCascStorage()
{
    close();
}

CascError OnlineCascStorage::open(const std::string& productConfig)
{
    close();

    // Expected format: "product:region"
    size_t colonPos = productConfig.find(':');
    if (colonPos == std::string::npos) {
        return CascError::CDNConfigError;
    }

    std::string product = productConfig.substr(0, colonPos);
    std::string region = productConfig.substr(colonPos + 1);

    if (product.empty() || region.empty()) {
        return CascError::CDNConfigError;
    }

    cdnConfig = std::make_unique<CDNConfig>();
    CascError error = CascError::None;
    currentBuild = cdnConfig->fetchConfig(product, region, error);
    if (error != CascError::None) {
        return error;
    }

    cacheManager = std::make_unique<CDNCacheManager>(product, region);
    opened = true;
    return CascError::None;
}

void OnlineCascStorage::close()
{
    opened = false;
    cacheManager.reset();
    cdnConfig.reset();
}

std::vector<CascFileEntry> OnlineCascStorage::listDirectory(const std::string& /*path*/, CascError& error)
{
    error = CascError::NotImplemented;
    return {};
}

std::vector<uint8_t> OnlineCascStorage::readFile(const std::string& /*cascPath*/, CascError& error)
{
    error = CascError::NotImplemented;
    return {};
}

std::vector<uint8_t> OnlineCascStorage::readFilePartial(const std::string& /*cascPath*/, uint64_t /*offset*/, uint64_t /*length*/, CascError& error)
{
    error = CascError::NotImplemented;
    return {};
}

CascError OnlineCascStorage::extractFile(const std::string& cascPath,
                                         const std::string& destPath,
                                         const ProgressCallback& progress)
{
    CascError error = CascError::None;
    auto buffer = readFile(cascPath, error);
    if (error != CascError::None) {
        return error;
    }

    std::ofstream out(destPath, std::ios::binary);
    if (!out.is_open()) {
        return CascError::InvalidPath;
    }

    out.write(reinterpret_cast<const char*>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
    if (!out.good()) {
        return CascError::ReadError;
    }

    if (progress) {
        progress(static_cast<int64_t>(buffer.size()), static_cast<int64_t>(buffer.size()));
    }

    return CascError::None;
}

CascStorageInfo OnlineCascStorage::getStorageInfo(CascError& error)
{
    error = CascError::None;

    if (!opened) {
        error = CascError::StorageNotFound;
        return {};
    }

    CascStorageInfo info;
    info.productName = currentBuild.buildName;
    info.buildVersion = currentBuild.buildConfigHash;
    info.totalFiles = 0;
    info.totalSize = 0;
    return info;
}

std::vector<std::pair<std::string, uint32_t>> OnlineCascStorage::getTags()
{
    return {};
}

std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> OnlineCascStorage::parseInstallManifest()
{
    return {};
}

} // namespace CascBridge
