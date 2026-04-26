#include "OnlineCascStorage.h"
#include <fstream>
#include <sstream>

namespace CascBridge {

OnlineCascStorage::~OnlineCascStorage()
{
    close();
}

std::expected<void, CascError> OnlineCascStorage::open(const std::string& productConfig)
{
    close();

    // Expected format: "product:region"
    size_t colonPos = productConfig.find(':');
    if (colonPos == std::string::npos) {
        return std::unexpected(CascError::CDNConfigError);
    }

    std::string product = productConfig.substr(0, colonPos);
    std::string region = productConfig.substr(colonPos + 1);

    if (product.empty() || region.empty()) {
        return std::unexpected(CascError::CDNConfigError);
    }

    cdnConfig = std::make_unique<CDNConfig>();
    auto configResult = cdnConfig->fetchConfig(product, region);
    if (!configResult.has_value()) {
        return std::unexpected(configResult.error());
    }

    currentBuild = std::move(configResult.value());
    cacheManager = std::make_unique<CDNCacheManager>(product, region);
    opened = true;
    return {};
}

void OnlineCascStorage::close()
{
    opened = false;
    cacheManager.reset();
    cdnConfig.reset();
}

std::expected<std::vector<CascFileEntry>, CascError> OnlineCascStorage::listDirectory(const std::string& /*path*/)
{
    return std::unexpected(CascError::NotImplemented);
}

std::expected<std::vector<uint8_t>, CascError> OnlineCascStorage::readFile(const std::string& /*cascPath*/)
{
    return std::unexpected(CascError::NotImplemented);
}

std::expected<void, CascError> OnlineCascStorage::extractFile(const std::string& cascPath,
                                                               const std::string& destPath,
                                                               const ProgressCallback& progress)
{
    auto data = readFile(cascPath);
    if (!data.has_value()) {
        return std::unexpected(data.error());
    }

    std::ofstream out(destPath, std::ios::binary);
    if (!out.is_open()) {
        return std::unexpected(CascError::InvalidPath);
    }

    const auto& buffer = data.value();
    out.write(reinterpret_cast<const char*>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
    if (!out.good()) {
        return std::unexpected(CascError::ReadError);
    }

    if (progress) {
        progress(static_cast<int64_t>(buffer.size()), static_cast<int64_t>(buffer.size()));
    }

    return {};
}

std::expected<CascStorageInfo, CascError> OnlineCascStorage::getStorageInfo()
{
    if (!opened) {
        return std::unexpected(CascError::StorageNotFound);
    }

    CascStorageInfo info;
    info.productName = currentBuild.buildName;
    info.buildVersion = currentBuild.buildConfigHash;
    info.totalFiles = 0;
    info.totalSize = 0;
    return info;
}

} // namespace CascBridge
