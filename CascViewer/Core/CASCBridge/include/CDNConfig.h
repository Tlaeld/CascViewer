#pragma once
#include <string>
#include <vector>
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
    CDNBuildConfig fetchConfig(const std::string& product, const std::string& region, CascError& error);
private:
    std::string downloadText(const std::string& url);
};

} // namespace CascBridge
