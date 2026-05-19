#pragma once
#include <string>
#include <vector>
#include <functional>
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
    static void setGlobalCancelFlag(bool value);
    CDNBuildConfig fetchConfig(const std::string& product, const std::string& region, CascError& error);
    std::vector<std::string> fetchProductRegions(const std::string& product);
    std::vector<std::string> fetchProductRegions(const std::string& product, const std::function<bool()>& isCancelled);
private:
    std::string downloadText(const std::string& url);
    std::string downloadText(const std::string& url, const std::function<bool()>& isCancelled);
};

} // namespace CascBridge
