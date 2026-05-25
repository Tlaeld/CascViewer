#include "CDNCacheManager.h"
#include <curl/curl.h>
#include <sys/stat.h>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <cerrno>
#include <algorithm>
#include <filesystem>

namespace CascBridge {

static bool isValidHex(const std::string& s) {
    return std::all_of(s.begin(), s.end(), [](unsigned char c) {
        return std::isxdigit(c);
    });
}

static bool isValidProductOrRegion(const std::string& s) {
    return std::all_of(s.begin(), s.end(), [](unsigned char c) {
        return std::isalnum(c) || c == '-' || c == '_';
    });
}

static size_t writeFileCallback(void* contents, size_t size, size_t nmemb, void* userp)
{
    if (size != 0 && nmemb > SIZE_MAX / size) {
        return 0;
    }
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
    if (!home || std::strlen(home) == 0) {
        home = "/tmp";
    }
    return std::string(home);
}

CDNCacheManager::CDNCacheManager(const std::string& product, const std::string& region)
{
    if (!isValidProductOrRegion(product) || !isValidProductOrRegion(region)) {
        cacheRoot = "/tmp/invalid_casc_cache";
        ensureDirectoryRecursive(cacheRoot);
        return;
    }
    std::string home = getHomeDirectory();
    cacheRoot = home + "/Library/Caches/CascViewer/cdn/" + product + "_" + region;
    ensureDirectoryRecursive(cacheRoot);
}

std::string CDNCacheManager::chunkPath(const std::string& encodingKey) const
{
    if (encodingKey.empty() || !isValidHex(encodingKey)) {
        return cacheRoot + "/invalid";
    }
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

CascError CDNCacheManager::downloadChunk(const std::string& url, const std::string& destPath)
{
    std::FILE* fp = std::fopen(destPath.c_str(), "wb");
    if (!fp) {
        return CascError::ReadError;
    }

    CURL* curl = curl_easy_init();
    if (!curl) {
        std::fclose(fp);
        return CascError::NetworkError;
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
    if (std::fclose(fp) != 0) {
        std::remove(destPath.c_str());
        return CascError::ReadError;
    }

    if (res != CURLE_OK || httpCode != 200) {
        std::remove(destPath.c_str());
        return CascError::NetworkError;
    }

    return CascError::None;
}

std::vector<uint8_t> CDNCacheManager::getChunk(const std::string& encodingKey,
                                               const std::string& cdnUrl,
                                               CascError& error)
{
    try {
    error = CascError::None;
    std::string path = chunkPath(encodingKey);

    if (!hasChunk(encodingKey)) {
        std::string subDir = path.substr(0, path.find_last_of('/'));
        if (!ensureDirectoryRecursive(subDir)) {
            error = CascError::ReadError;
            return {};
        }

        error = downloadChunk(cdnUrl, path);
        if (error != CascError::None) {
            return {};
        }
    }

    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        error = CascError::ReadError;
        return {};
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    // Cap chunk size to prevent unbounded memory allocation
    constexpr std::streamsize MAX_CHUNK_SIZE = 256 * 1024 * 1024; // 256 MB
    if (size < 0 || size > MAX_CHUNK_SIZE) {
        error = CascError::ReadError;
        return {};
    }

    std::vector<uint8_t> buffer;
    if (size > 0) {
        buffer.resize(static_cast<size_t>(size));
        if (!file.read(reinterpret_cast<char*>(buffer.data()), size)) {
            error = CascError::ReadError;
            return {};
        }
    }

    return buffer;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CDNCacheManager] Exception in getChunk(): %s\n", e.what());
        error = CascError::ReadError;
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CDNCacheManager] Unknown exception in getChunk()\n");
        error = CascError::ReadError;
        return {};
    }
}

void CDNCacheManager::clearCache()
{
    // Safety check: never delete if cacheRoot is empty or doesn't contain CascViewer
    if (cacheRoot.empty() || cacheRoot.find("CascViewer") == std::string::npos) {
        return;
    }
    std::error_code ec;
    std::filesystem::remove_all(cacheRoot, ec);
}

} // namespace CascBridge
