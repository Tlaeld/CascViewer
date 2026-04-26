#include "LocalCascStorage.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
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
    std::string result;
    result.reserve(MD5_HASH_SIZE * 2);
    char buf[3];
    for (int i = 0; i < MD5_HASH_SIZE; ++i) {
        std::snprintf(buf, sizeof(buf), "%02x", ekey[i]);
        result.append(buf);
    }
    return result;
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

CascError LocalCascStorage::open(const std::string& localPath)
{
    if (hStorage != nullptr) {
        close();
    }

    if (!CascOpenStorage(localPath.c_str(), CASC_LOCALE_ALL, &hStorage)) {
        DWORD error = GetCascError();
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
        ~FindCloser() { if (h != INVALID_HANDLE_VALUE) CascFindClose(h); }
    };

    std::string mask = path.empty() ? "*" : path + "\\*";
    CASC_FIND_DATA findData = {};
    HANDLE hFind = CascFindFirstFile(hStorage, mask.c_str(), &findData, nullptr);
    if (hFind == INVALID_HANDLE_VALUE) {
        DWORD cascError = GetCascError();
        if (cascError == ERROR_NO_MORE_FILES || cascError == ERROR_FILE_NOT_FOUND) {
            return {};
        }
        error = mapCascError(cascError);
        return {};
    }

    FindCloser closer{hFind};

    std::vector<CascFileEntry> entries;
    do {
        CascFileEntry entry;
        entry.name = findData.szPlainName ? findData.szPlainName : findData.szFileName;
        entry.fullPath = findData.szFileName;
        entry.type = FileType::File;
        entry.size = findData.FileSize;
        entry.encodingKey = ekeyToHex(findData.EKey);
        entries.push_back(std::move(entry));
    } while (CascFindNextFile(hFind, &findData));

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
        error = CascError::ReadError;
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
            error = CascError::ReadError;
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

    FILE* fp = std::fopen(destPath.c_str(), "wb");
    if (fp == nullptr) {
        CascCloseFile(hFile);
        return CascError::InvalidPath;
    }

    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        std::fclose(fp);
        return CascError::ReadError;
    }
    uint64_t totalRead = 0;

    while (totalRead < fileSize64) {
        DWORD toRead = static_cast<DWORD>(std::min(BUFFER_SIZE, static_cast<size_t>(fileSize64 - totalRead)));
        DWORD bytesRead = 0;
        if (!CascReadFile(hFile, chunk.data(), toRead, &bytesRead)) {
            CascCloseFile(hFile);
            std::fclose(fp);
            return CascError::ReadError;
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
