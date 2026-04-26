#include "LocalCascStorage.h"
#include <cstdio>
#include <cstring>

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

std::expected<void, CascError> LocalCascStorage::open(const std::string& localPath)
{
    if (hStorage != nullptr) {
        close();
    }

    if (!CascOpenStorage(localPath.c_str(), CASC_LOCALE_ALL, &hStorage)) {
        return std::unexpected(mapCascError(GetCascError()));
    }

    return {};
}

std::expected<std::vector<CascFileEntry>, CascError> LocalCascStorage::listDirectory(const std::string& path)
{
    if (hStorage == nullptr) {
        return std::unexpected(CascError::StorageNotFound);
    }

    std::string mask = path.empty() ? "*" : path + "\\*";
    CASC_FIND_DATA findData = {};
    HANDLE hFind = CascFindFirstFile(hStorage, mask.c_str(), &findData, nullptr);
    if (hFind == INVALID_HANDLE_VALUE) {
        DWORD error = GetCascError();
        if (error == ERROR_NO_MORE_FILES || error == ERROR_FILE_NOT_FOUND) {
            return std::vector<CascFileEntry>{};
        }
        return std::unexpected(mapCascError(error));
    }

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

    CascFindClose(hFind);
    return entries;
}

std::expected<std::vector<uint8_t>, CascError> LocalCascStorage::readFile(const std::string& cascPath)
{
    if (hStorage == nullptr) {
        return std::unexpected(CascError::StorageNotFound);
    }

    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, cascPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
        return std::unexpected(mapCascError(GetCascError()));
    }

    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        return std::unexpected(CascError::ReadError);
    }

    if (fileSize64 > static_cast<ULONGLONG>(std::numeric_limits<size_t>::max())) {
        CascCloseFile(hFile);
        return std::unexpected(CascError::ReadError);
    }

    size_t fileSize = static_cast<size_t>(fileSize64);
    std::vector<uint8_t> buffer(fileSize);

    if (fileSize > 0) {
        DWORD bytesRead = 0;
        if (!CascReadFile(hFile, buffer.data(), static_cast<DWORD>(fileSize), &bytesRead)) {
            CascCloseFile(hFile);
            return std::unexpected(CascError::ReadError);
        }
        buffer.resize(bytesRead);
    }

    CascCloseFile(hFile);
    return buffer;
}

std::expected<void, CascError> LocalCascStorage::extractFile(const std::string& cascPath,
                                                               const std::string& destPath,
                                                               const ProgressCallback& progress)
{
    auto data = readFile(cascPath);
    if (!data) {
        return std::unexpected(data.error());
    }

    FILE* fp = std::fopen(destPath.c_str(), "wb");
    if (fp == nullptr) {
        return std::unexpected(CascError::InvalidPath);
    }

    if (!data->empty()) {
        size_t written = std::fwrite(data->data(), 1, data->size(), fp);
        if (written != data->size()) {
            std::fclose(fp);
            return std::unexpected(CascError::ReadError);
        }
    }

    std::fclose(fp);

    if (progress) {
        progress(static_cast<int64_t>(data->size()), static_cast<int64_t>(data->size()));
    }

    return {};
}

std::expected<CascStorageInfo, CascError> LocalCascStorage::getStorageInfo()
{
    if (hStorage == nullptr) {
        return std::unexpected(CascError::StorageNotFound);
    }

    DWORD fileCount = 0;
    if (!CascGetStorageInfo(hStorage, CascStorageLocalFileCount, &fileCount, sizeof(fileCount), nullptr)) {
        return std::unexpected(CascError::Unknown);
    }

    CascStorageInfo info;
    info.productName = "unknown";
    info.buildVersion = "unknown";
    info.totalFiles = fileCount;
    info.totalSize = 0;
    return info;
}

} // namespace CascBridge
