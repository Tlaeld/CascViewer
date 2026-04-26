#pragma once
#include <string>
#include <vector>
#include <expected>
#include "CascTypes.h"

namespace CascBridge {

struct CDNEndpoint {
    std::string host;
    std::string path;
};

struct CDNBuildConfig {
    std::string buildName;
    std::string buildConfigHash;
    std::string cdnConfigHash;
    std::string productConfig;
    std::vector<CDNEndpoint> endpoints;
};

class CDNConfig {
public:
    std::expected<CDNBuildConfig, CascError> fetchConfig(const std::string& product, const std::string& region);
private:
    std::string downloadText(const std::string& url);
};

} // namespace CascBridge
