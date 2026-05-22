#include "CDNConfig.h"
#include <curl/curl.h>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <atomic>

namespace CascBridge {

static std::atomic<uint64_t> g_cancelGeneration{0};

void CDNConfig::setGlobalCancelFlag(bool value) {
    if (value) {
        g_cancelGeneration.fetch_add(1, std::memory_order_relaxed);
    }
}

static struct CurlGlobalInit {
    CurlGlobalInit() {
        curl_global_init(CURL_GLOBAL_DEFAULT);
    }
    ~CurlGlobalInit() {
        curl_global_cleanup();
    }
} curlGlobalInit;

namespace {

bool isValidProductOrRegion(const std::string& s) {
    return std::all_of(s.begin(), s.end(), [](unsigned char c) {
        return std::isalnum(c) || c == '-' || c == '_';
    });
}

size_t writeStringCallback(void* contents, size_t size, size_t nmemb, void* userp)
{
    size_t totalSize = size * nmemb;
    std::string* str = static_cast<std::string*>(userp);
    str->append(static_cast<char*>(contents), totalSize);
    return totalSize;
}

std::vector<std::string> splitLine(const std::string& line, char delimiter)
{
    std::vector<std::string> parts;
    std::stringstream ss(line);
    std::string part;
    while (std::getline(ss, part, delimiter)) {
        parts.push_back(part);
    }
    return parts;
}

std::string trim(const std::string& s)
{
    auto start = std::find_if_not(s.begin(), s.end(), [](unsigned char c) { return std::isspace(c); });
    auto end = std::find_if_not(s.rbegin(), s.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    if (start >= end) return {};
    return std::string(start, end);
}

std::string extractKeyName(const std::string& s)
{
    std::string trimmed = trim(s);
    size_t bangPos = trimmed.find('!');
    if (bangPos != std::string::npos) {
        return trimmed.substr(0, bangPos);
    }
    return trimmed;
}

} // namespace

std::string CDNConfig::downloadText(const std::string& url)
{
    return downloadText(url, {});
}

std::string CDNConfig::downloadText(const std::string& url, const std::function<bool()>& isCancelled)
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
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

    uint64_t sessionGeneration = g_cancelGeneration.load(std::memory_order_relaxed);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION,
        [](void* clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) -> int {
            const std::function<bool()>* fn = static_cast<const std::function<bool()>*>(clientp);
            if (fn && (*fn)()) return 1; // abort transfer
            return 0;
        });
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, isCancelled ? &isCancelled : nullptr);

    CURLcode res = curl_easy_perform(curl);
    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
    curl_easy_cleanup(curl);

    if (g_cancelGeneration.load(std::memory_order_relaxed) != sessionGeneration) {
        return {};
    }
    if (res != CURLE_OK || httpCode != 200) {
        return {};
    }
    return response;
}

CDNBuildConfig CDNConfig::fetchConfig(const std::string& product, const std::string& region, CascError& error)
{
    error = CascError::None;

    if (!isValidProductOrRegion(product) || !isValidProductOrRegion(region)) {
        error = CascError::CDNConfigError;
        return {};
    }

    std::string versionsUrl = "http://us.patch.battle.net:1119/" + product + "/versions";
    std::string cdnsUrl = "http://us.patch.battle.net:1119/" + product + "/cdns";

    std::string versionsText = downloadText(versionsUrl);
    std::string cdnsText = downloadText(cdnsUrl);

    if (versionsText.empty() || cdnsText.empty()) {
        error = CascError::NetworkError;
        return {};
    }

    CDNBuildConfig config;

    // Parse versions: first line = headers, second line = active build
    std::istringstream versionsStream(versionsText);
    std::string headerLine;
    std::string dataLine;
    if (!std::getline(versionsStream, headerLine)) {
        error = CascError::CDNConfigError;
        return {};
    }
    // Skip any comment/blank lines to find data line
    while (std::getline(versionsStream, dataLine)) {
        if (!trim(dataLine).empty() && dataLine[0] != '#') {
            break;
        }
    }
    if (dataLine.empty()) {
        error = CascError::CDNConfigError;
        return {};
    }

    std::vector<std::string> headers = splitLine(headerLine, '|');
    std::vector<std::string> values = splitLine(dataLine, '|');

    for (size_t i = 0; i < headers.size() && i < values.size(); ++i) {
        std::string key = extractKeyName(headers[i]);
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
        error = CascError::CDNConfigError;
        return {};
    }

    std::vector<std::string> cdnsHeaders = splitLine(cdnsHeaderLine, '|');
    int nameIdx = -1;
    int pathIdx = -1;
    int hostsIdx = -1;
    for (size_t i = 0; i < cdnsHeaders.size(); ++i) {
        std::string key = extractKeyName(cdnsHeaders[i]);
        if (key == "Name") nameIdx = static_cast<int>(i);
        else if (key == "Path") pathIdx = static_cast<int>(i);
        else if (key == "Hosts") hostsIdx = static_cast<int>(i);
    }

    if (nameIdx < 0 || pathIdx < 0 || hostsIdx < 0) {
        error = CascError::CDNConfigError;
        return {};
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
        error = CascError::CDNConfigError;
        return {};
    }

    return config;
}

std::vector<std::string> CDNConfig::fetchProductRegions(const std::string& product)
{
    return fetchProductRegions(product, {});
}

std::vector<std::string> CDNConfig::fetchProductRegions(const std::string& product, const std::function<bool()>& isCancelled)
{
    if (!isValidProductOrRegion(product)) {
        return {};
    }

    uint64_t sessionGeneration = g_cancelGeneration.load(std::memory_order_relaxed);
    std::string cdnsUrl = "http://us.patch.battle.net:1119/" + product + "/cdns";
    std::string cdnsText = downloadText(cdnsUrl, isCancelled);
    if (g_cancelGeneration.load(std::memory_order_relaxed) != sessionGeneration) {
        return {};
    }
    if (cdnsText.empty()) {
        return {};
    }

    std::vector<std::string> regions;
    std::istringstream stream(cdnsText);
    std::string headerLine;
    if (!std::getline(stream, headerLine)) {
        return {};
    }

    std::vector<std::string> headers = splitLine(headerLine, '|');
    int nameIdx = -1;
    for (size_t i = 0; i < headers.size(); ++i) {
        if (extractKeyName(headers[i]) == "Name") {
            nameIdx = static_cast<int>(i);
            break;
        }
    }
    if (nameIdx < 0) {
        return {};
    }

    std::string line;
    while (std::getline(stream, line)) {
        std::string trimmed = trim(line);
        if (trimmed.empty() || trimmed[0] == '#') continue;

        std::vector<std::string> parts = splitLine(line, '|');
        if (static_cast<int>(parts.size()) > nameIdx) {
            std::string region = trim(parts[nameIdx]);
            if (!region.empty()) {
                regions.push_back(region);
            }
        }
    }

    return regions;
}

} // namespace CascBridge
