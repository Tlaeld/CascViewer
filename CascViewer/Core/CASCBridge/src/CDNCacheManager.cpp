#include "CDNCacheManager.h"
#include <curl/curl.h>
#include <sys/stat.h>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <cstdlib>

namespace CascBridge {

static size_t writeFileCallback(void* contents, size_t size, size_t nmemb, void* userp)
{
    size_t totalSize = size * nmemb;
    std::FILE* fp = static_cast<std::FILE*>(userp);
    size_t written = std::fwrite(contents, 1, totalSize, fp);
    return written;
}

static bool ensureDirectory(const std::string& path)
{
    if (mkdir(path.c_str(), S_IRWXU) == 0 || errno == EEXIST) {
        struct stat st;
        if (stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
            return true;
        }
    }
    return false;
}

static bool ensureDirectoryRecursive(const std::string& path)
{
    if (path.empty()) return true;
    struct stat st;
    if (stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
        return true;
    }

    size_t pos = path.find_last_of('/');
    if (pos != std::string::npos && pos > 0) {
        if (!ensureDirectoryRecursive(path.substr(0, pos))) {
            return false;
        }
    }
    return ensureDirectory(path);
}

static std::string getHomeDirectory()
{
    const char* home = std::getenv("HOME");
    if (home) {
        return std::string(home);
    }
    return {};
}

CDNCacheManager::CDNCacheManager(const std::string& product, const std::string& region)
{
    std::string home = getHomeDirectory();
    cacheRoot = home + "/Library/Caches/CascViewer/cdn/" + product + "_" + region;
    ensureDirectoryRecursive(cacheRoot);
}

std::string CDNCacheManager::chunkPath(const std::string& encodingKey) const
{
    if (encodingKey.size() < 2) {
        return cacheRoot + "/" + encodingKey;
    }
    return cacheRoot + "/" + encodingKey.substr(0, 2) + "/" + encodingKey;
}

bool CDNCacheManager::hasChunk(const std::string& encodingKey) const
{
    struct stat st;
    return stat(chunkPath(encodingKey).c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

std::expected<void, CascError> CDNCacheManager::downloadChunk(const std::string& url, const std::string& destPath)
{
    std::FILE* fp = std::fopen(destPath.c_str(), "wb");
    if (!fp) {
        return std::unexpected(CascError::NetworkError);
    }

    CURL* curl = curl_easy_init();
    if (!curl) {
        std::fclose(fp);
        return std::unexpected(CascError::NetworkError);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeFileCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, fp);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);

    CURLcode res = curl_easy_perform(curl);
    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
    curl_easy_cleanup(curl);
    std::fclose(fp);

    if (res != CURLE_OK || httpCode != 200) {
        std::remove(destPath.c_str());
        return std::unexpected(CascError::NetworkError);
    }

    return {};
}

std::expected<std::vector<uint8_t>, CascError> CDNCacheManager::getChunk(const std::string& encodingKey,
                                                                          const std::string& cdnUrl)
{
    std::string path = chunkPath(encodingKey);

    if (!hasChunk(encodingKey)) {
        std::string subDir = path.substr(0, path.find_last_of('/'));
        ensureDirectoryRecursive(subDir);

        auto result = downloadChunk(cdnUrl, path);
        if (!result.has_value()) {
            return std::unexpected(result.error());
        }
    }

    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        return std::unexpected(CascError::ReadError);
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<uint8_t> buffer;
    if (size > 0) {
        buffer.resize(static_cast<size_t>(size));
        if (!file.read(reinterpret_cast<char*>(buffer.data()), size)) {
            return std::unexpected(CascError::ReadError);
        }
    }

    return buffer;
}

void CDNCacheManager::clearCache()
{
    // Simple implementation: remove all files under cacheRoot
    // A full recursive removal would be more robust, but this is a skeleton
    std::string cmd = "rm -rf \"" + cacheRoot + "\"";
    std::system(cmd.c_str());
    ensureDirectoryRecursive(cacheRoot);
}

} // namespace CascBridge
