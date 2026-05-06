#include "LocalCascStorage.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <limits>

namespace CascBridge {

static CascError mapCascError(DWORD error)
{
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
        return CascError::FileNotFound;
    }
    if (error == ERROR_ACCESS_DENIED) {
        return CascError::InvalidPath;
    }
    if (error == ERROR_FILE_CORRUPT) {
        return CascError::StorageCorrupted;
    }
    if (error == ERROR_NOT_ENOUGH_MEMORY) {
        return CascError::ReadError;
    }
    if (error == ERROR_NETWORK_NOT_AVAILABLE) {
        return CascError::NetworkError;
    }
    return CascError::Unknown;
}

static std::string ekeyToHex(const BYTE* ekey)
{
    static const char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(MD5_HASH_SIZE * 2);
    for (int i = 0; i < MD5_HASH_SIZE; ++i) {
        result.push_back(hex[ekey[i] >> 4]);
        result.push_back(hex[ekey[i] & 0x0F]);
    }
    return result;
}

static bool cascProgressCallback(void* userParam, CASC_PROGRESS_MSG progressMsg, LPCSTR szObject, DWORD current, DWORD total)
{
    auto* storage = static_cast<LocalCascStorage*>(userParam);
    const char* msg = "";
    switch(progressMsg) {
        case CascProgressLoadingFile: msg = "Loading file"; break;
        case CascProgressLoadingManifest: msg = "Loading manifest"; break;
        case CascProgressDownloadingFile: msg = "Downloading file"; break;
        case CascProgressLoadingIndexes: msg = "Loading indexes"; break;
        case CascProgressDownloadingArchiveIndexes: msg = "Downloading archive indexes"; break;
    }
    if(szObject && szObject[0]) {
        fprintf(stderr, "[CASC-PROGRESS] %s: %s (%u/%u)\n", msg, szObject, current, total);
    } else if(total) {
        fprintf(stderr, "[CASC-PROGRESS] %s (%u/%u)\n", msg, current, total);
    } else {
        fprintf(stderr, "[CASC-PROGRESS] %s\n", msg);
    }
    if (storage) {
        storage->invokeProgressCallback(msg, static_cast<int>(current), static_cast<int>(total));
    }
    return false; // don't cancel
}

LocalCascStorage::~LocalCascStorage()
{
    close();
}

void LocalCascStorage::close()
{
    if (hStorage != nullptr) {
        CascCloseStorage(hStorage);
        hStorage = nullptr;
    }
}

void LocalCascStorage::setCdnDownloadEnabled(bool enabled)
{
    cdnDownloadEnabled = enabled;
}

void LocalCascStorage::setOpenProgressCallback(COpenProgressCallback callback, void* context)
{
    progressCallback = callback;
    progressContext = context;
}

void LocalCascStorage::invokeProgressCallback(const char* message, int current, int total)
{
    if (progressCallback) {
        progressCallback(progressContext, message, current, total);
    }
}

CascError LocalCascStorage::open(const std::string& localPath)
{
    if (hStorage != nullptr) {
        close();
    }

    CASC_OPEN_STORAGE_ARGS args = {};
    args.Size = sizeof(CASC_OPEN_STORAGE_ARGS);
    args.dwLocaleMask = CASC_LOCALE_ALL;
    args.PfnProgressCallback = cascProgressCallback;
    args.PtrProgressParam = this;
    args.dwFlags = cdnDownloadEnabled ? CASC_FEATURE_ALLOW_DOWNLOAD : 0;

    if (!CascOpenStorageEx(localPath.c_str(), &args, false, &hStorage)) {
        DWORD error = GetCascError();
        fprintf(stderr, "[CASC-CPP] open() failed: %s, error=%u\n", localPath.c_str(), error);
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
            return CascError::StorageNotFound;
        }
        return mapCascError(error);
    }

    return CascError::None;
}

std::vector<CascFileEntry> LocalCascStorage::listDirectory(const std::string& path, CascError& error)
{
    error = CascError::None;

    if (hStorage == nullptr) {
        error = CascError::StorageNotFound;
        return {};
    }

    struct FindCloser {
        HANDLE h;
        ~FindCloser() { if (h != INVALID_HANDLE_VALUE && h != nullptr) CascFindClose(h); }
    };

    // Build masks with both path separators — CascLib may use \ internally even on macOS
    std::vector<std::string> masks;
    if (path.empty()) {
        masks.push_back("*");
    } else {
        masks.push_back(path + "/*");
        masks.push_back(path + "\\*");
    }

    std::vector<CascFileEntry> entries;
    entries.reserve(8192);

    for (const auto& mask : masks) {
        CASC_FIND_DATA findData = {};
        HANDLE hFind = CascFindFirstFile(hStorage, mask.c_str(), &findData, nullptr);
        if (hFind == INVALID_HANDLE_VALUE || hFind == nullptr) {
            continue;
        }

        FindCloser closer{hFind};

        do {
            if (findData.szFileName[0] == '\0') {
                continue;
            }
            CascFileEntry entry;
            entry.fullPath = findData.szFileName;
            entry.name = findData.szPlainName ? findData.szPlainName : entry.fullPath;
            entry.type = FileType::File;
            entry.size = findData.FileSize;
            entry.encodingKey = ekeyToHex(findData.EKey);
            entry.isLocal = findData.bFileAvailable != 0;
            entries.push_back(std::move(entry));
        } while (CascFindNextFile(hFind, &findData));

        if (!entries.empty()) {
            break;
        }
    }

    return entries;
}

std::vector<uint8_t> LocalCascStorage::readFile(const std::string& cascPath, CascError& error)
{
    error = CascError::None;

    if (hStorage == nullptr) {
        error = CascError::StorageNotFound;
        return {};
    }

    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, cascPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
        error = mapCascError(GetCascError());
        return {};
    }

    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        error = mapCascError(GetCascError());
        return {};
    }

    if (fileSize64 > static_cast<ULONGLONG>(std::numeric_limits<size_t>::max())) {
        CascCloseFile(hFile);
        error = CascError::ReadError;
        return {};
    }

    size_t fileSize = static_cast<size_t>(fileSize64);
    std::vector<uint8_t> buffer;
    try {
        buffer.resize(fileSize);
    } catch (const std::bad_alloc&) {
        CascCloseFile(hFile);
        error = CascError::ReadError;
        return {};
    }

    constexpr size_t CHUNK_SIZE = static_cast<size_t>(std::numeric_limits<DWORD>::max());
    size_t offset = 0;
    while (offset < fileSize) {
        DWORD toRead = static_cast<DWORD>(std::min(CHUNK_SIZE, fileSize - offset));
        DWORD bytesRead = 0;
        if (!CascReadFile(hFile, buffer.data() + offset, toRead, &bytesRead)) {
            CascCloseFile(hFile);
            error = mapCascError(GetCascError());
            return {};
        }
        offset += bytesRead;
    }

    CascCloseFile(hFile);
    return buffer;
}

CascError LocalCascStorage::extractFile(const std::string& cascPath,
                                        const std::string& destPath,
                                        const ProgressCallback& progress)
{
    if (hStorage == nullptr) {
        return CascError::StorageNotFound;
    }

    constexpr size_t BUFFER_SIZE = 1024 * 1024;  // 1 MB chunks
    std::vector<uint8_t> chunk;
    try {
        chunk.resize(BUFFER_SIZE);
    } catch (const std::bad_alloc&) {
        return CascError::ReadError;
    }

    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, cascPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
        return mapCascError(GetCascError());
    }

    // Create parent directories if needed
    {
        size_t lastSep = destPath.find_last_of("/\\");
        if (lastSep != std::string::npos) {
            std::string dir = destPath.substr(0, lastSep);
            static thread_local std::string lastCreatedDir;
            if (dir != lastCreatedDir) {
                std::filesystem::create_directories(dir);
                lastCreatedDir = dir;
            }
        }
    }

    FILE* fp = std::fopen(destPath.c_str(), "wb");
    if (fp == nullptr) {
        CascCloseFile(hFile);
        return CascError::InvalidPath;
    }

    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        std::fclose(fp);
        return mapCascError(GetCascError());
    }
    uint64_t totalRead = 0;

    while (totalRead < fileSize64) {
        DWORD toRead = static_cast<DWORD>(std::min(BUFFER_SIZE, static_cast<size_t>(fileSize64 - totalRead)));
        DWORD bytesRead = 0;
        if (!CascReadFile(hFile, chunk.data(), toRead, &bytesRead)) {
            CascCloseFile(hFile);
            std::fclose(fp);
            return mapCascError(GetCascError());
        }
        if (std::fwrite(chunk.data(), 1, bytesRead, fp) != bytesRead) {
            CascCloseFile(hFile);
            std::fclose(fp);
            return CascError::ReadError;
        }
        totalRead += bytesRead;
        if (progress) {
            progress(static_cast<int64_t>(totalRead), static_cast<int64_t>(fileSize64));
        }
    }

    CascCloseFile(hFile);
    if (std::fclose(fp) != 0) {
        return CascError::ReadError;
    }
    return CascError::None;
}

CascStorageInfo LocalCascStorage::getStorageInfo(CascError& error)
{
    error = CascError::None;

    if (hStorage == nullptr) {
        error = CascError::StorageNotFound;
        return {};
    }

    DWORD fileCount = 0;
    if (!CascGetStorageInfo(hStorage, CascStorageLocalFileCount, &fileCount, sizeof(fileCount), nullptr)) {
        error = CascError::Unknown;
        return {};
    }

    CascStorageInfo info;
    info.productName = "unknown";
    info.buildVersion = "unknown";
    info.totalFiles = fileCount;
    info.totalSize = 0;
    return info;
}

} // namespace CascBridge
