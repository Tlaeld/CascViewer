#include "CDNConfig.h"
#include <curl/curl.h>
#include <sstream>
#include <algorithm>
#include <cctype>

namespace CascBridge {

static size_t writeStringCallback(void* contents, size_t size, size_t nmemb, void* userp)
{
    size_t totalSize = size * nmemb;
    std::string* str = static_cast<std::string*>(userp);
    str->append(static_cast<char*>(contents), totalSize);
    return totalSize;
}

std::string CDNConfig::downloadText(const std::string& url)
{
    CURL* curl = curl_easy_init();
    if (!curl) {
        return {};
    }

    std::string response;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeStringCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        return {};
    }
    return response;
}

static std::vector<std::string> splitLine(const std::string& line, char delimiter)
{
    std::vector<std::string> parts;
    std::stringstream ss(line);
    std::string part;
    while (std::getline(ss, part, delimiter)) {
        parts.push_back(part);
    }
    return parts;
}

static std::string trim(const std::string& s)
{
    auto start = std::find_if_not(s.begin(), s.end(), [](unsigned char c) { return std::isspace(c); });
    auto end = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    if (start >= end) return {};
    return std::string(start, end);
}

std::expected<CDNBuildConfig, CascError> CDNConfig::fetchConfig(const std::string& product, const std::string& region)
{
    std::string versionsUrl = "http://us.patch.battle.net:1119/" + product + "/versions";
    std::string cdnsUrl = "http://us.patch.battle.net:1119/" + product + "/cdns";

    std::string versionsText = downloadText(versionsUrl);
    std::string cdnsText = downloadText(cdnsUrl);

    if (versionsText.empty() || cdnsText.empty()) {
        return std::unexpected(CascError::NetworkError);
    }

    CDNBuildConfig config;

    // Parse versions: first line = headers, second line = active build
    std::istringstream versionsStream(versionsText);
    std::string headerLine;
    std::string dataLine;
    if (!std::getline(versionsStream, headerLine)) {
        return std::unexpected(CascError::CDNConfigError);
    }
    // Skip any comment/blank lines to find data line
    while (std::getline(versionsStream, dataLine)) {
        if (!trim(dataLine).empty() && dataLine[0] != '#') {
            break;
        }
    }
    if (dataLine.empty()) {
        return std::unexpected(CascError::CDNConfigError);
    }

    std::vector<std::string> headers = splitLine(headerLine, '|');
    std::vector<std::string> values = splitLine(dataLine, '|');

    for (size_t i = 0; i < headers.size() && i < values.size(); ++i) {
        std::string key = trim(headers[i]);
        std::string val = trim(values[i]);
        if (key == "BuildConfig") {
            config.buildConfigHash = val;
        } else if (key == "CDNConfig") {
            config.cdnConfigHash = val;
        } else if (key == "ProductConfig") {
            config.productConfig = val;
        } else if (key == "BuildName" || key == "VersionsName") {
            config.buildName = val;
        }
    }

    // Parse cdns: find region entry
    std::istringstream cdnsStream(cdnsText);
    std::string cdnsHeaderLine;
    if (!std::getline(cdnsStream, cdnsHeaderLine)) {
        return std::unexpected(CascError::CDNConfigError);
    }

    std::vector<std::string> cdnsHeaders = splitLine(cdnsHeaderLine, '|');
    int nameIdx = -1;
    int pathIdx = -1;
    int hostsIdx = -1;
    for (size_t i = 0; i < cdnsHeaders.size(); ++i) {
        std::string key = trim(cdnsHeaders[i]);
        if (key == "Name") nameIdx = static_cast<int>(i);
        else if (key == "Path") pathIdx = static_cast<int>(i);
        else if (key == "Hosts") hostsIdx = static_cast<int>(i);
    }

    if (nameIdx < 0 || pathIdx < 0 || hostsIdx < 0) {
        return std::unexpected(CascError::CDNConfigError);
    }

    std::string cdnLine;
    while (std::getline(cdnsStream, cdnLine)) {
        std::string trimmed = trim(cdnLine);
        if (trimmed.empty() || trimmed[0] == '#') continue;

        std::vector<std::string> parts = splitLine(cdnLine, '|');
        if (static_cast<int>(parts.size()) <= nameIdx) continue;

        if (trim(parts[nameIdx]) == region) {
            std::string hosts = trim(parts[hostsIdx]);
            std::string path = trim(parts[pathIdx]);
            std::vector<std::string> hostList = splitLine(hosts, ' ');
            for (const auto& h : hostList) {
                std::string host = trim(h);
                if (!host.empty()) {
                    config.endpoints.push_back(CDNEndpoint{host, path});
                }
            }
            break;
        }
    }

    if (config.buildConfigHash.empty()) {
        return std::unexpected(CascError::CDNConfigError);
    }

    return config;
}

} // namespace CascBridge
