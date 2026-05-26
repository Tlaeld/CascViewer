#include "LocalCascStorage.h"
#include "CascCommon.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <limits>
#include <pthread.h>
#include <thread>
#include <unordered_set>

namespace CascBridge {

/// RAII guard for CascLib file handles (exception-safe).
struct CascFileGuard {
    HANDLE hFile = nullptr;
    explicit CascFileGuard(HANDLE h = nullptr) : hFile(h) {}
    ~CascFileGuard() { if (hFile) CascCloseFile(hFile); }
    CascFileGuard(const CascFileGuard&) = delete;
    CascFileGuard& operator=(const CascFileGuard&) = delete;
    CascFileGuard(CascFileGuard&& other) noexcept : hFile(other.hFile) { other.hFile = nullptr; }
    CascFileGuard& operator=(CascFileGuard&& other) noexcept {
        if (this != &other) {
            if (hFile) CascCloseFile(hFile);
            hFile = other.hFile;
            other.hFile = nullptr;
        }
        return *this;
    }
    HANDLE release() { HANDLE h = hFile; hFile = nullptr; return h; }
};

// Windows error codes that may be returned by CascLib
#ifndef ERROR_CRC
#define ERROR_CRC 23
#endif
#ifndef ERROR_INVALID_DATA
#define ERROR_INVALID_DATA 13
#endif
#ifndef ERROR_OUTOFMEMORY
#define ERROR_OUTOFMEMORY 14
#endif
#ifndef ERROR_NO_NETWORK
#define ERROR_NO_NETWORK 1222
#endif
#ifndef ERROR_INTERNET_CANNOT_CONNECT
#define ERROR_INTERNET_CANNOT_CONNECT 12029
#endif
#ifndef ERROR_NO_DATA
#define ERROR_NO_DATA 232
#endif
#ifndef ERROR_DISK_FULL
#define ERROR_DISK_FULL 112
#endif
#ifndef ERROR_WRITE_FAULT
#define ERROR_WRITE_FAULT 29
#endif

static CascError mapCascError(DWORD error)
{
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
        return CascError::FileNotFound;
    }
    if (error == ERROR_ACCESS_DENIED) {
        return CascError::InvalidPath;
    }
    if (error == ERROR_FILE_CORRUPT || error == ERROR_CRC || error == ERROR_INVALID_DATA) {
        return CascError::StorageCorrupted;
    }
    if (error == ERROR_NOT_ENOUGH_MEMORY || error == ERROR_OUTOFMEMORY) {
        return CascError::ReadError;
    }
    if (error == ERROR_NETWORK_NOT_AVAILABLE || error == ERROR_NO_NETWORK || error == ERROR_INTERNET_CANNOT_CONNECT) {
        return CascError::NetworkError;
    }
    if (error == ERROR_NO_DATA || error == ERROR_HANDLE_EOF) {
        return CascError::FileNotFound;
    }
    if (error == ERROR_NOT_SUPPORTED || error == ERROR_BAD_FORMAT) {
        return CascError::ReadError;
    }
    if (error == ERROR_DISK_FULL || error == ERROR_WRITE_FAULT) {
        return CascError::InvalidPath;
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
    // Clean up processed listfile temp file
    if (!processedListFilePath.empty()) {
        std::error_code ec;
        std::filesystem::remove(processedListFilePath, ec);
        processedListFilePath.clear();
    }
}

void LocalCascStorage::setCdnDownloadEnabled(bool enabled)
{
    cdnDownloadEnabled = enabled;
}

void LocalCascStorage::setCachePath(const std::string& path)
{
    cachePath = path;
}

void LocalCascStorage::setListFilePath(const std::string& path)
{
    // Clean up old processed listfile temp file
    if (!processedListFilePath.empty()) {
        std::error_code ec;
        std::filesystem::remove(processedListFilePath, ec);
        processedListFilePath.clear();
    }
    listFilePath = path;
}

void LocalCascStorage::setOpenProgressCallback(COpenProgressCallback callback, void* context)
{
    std::lock_guard<std::mutex> lock(progressMutex);
    progressCallback = callback;
    progressContext = context;
}

void LocalCascStorage::invokeProgressCallback(const char* message, int current, int total)
{
    COpenProgressCallback cb = nullptr;
    void* ctx = nullptr;
    {
        std::lock_guard<std::mutex> lock(progressMutex);
        cb = progressCallback;
        ctx = progressContext;
    }
    if (cb) {
        cb(ctx, message, current, total);
    }
}

void LocalCascStorage::requestCancelExtraction() {
    cancelGeneration.fetch_add(1, std::memory_order_release);
}

CascError LocalCascStorage::open(const std::string& localPath)
{
    if (hStorage != nullptr) {
        close();
    }

    bool isOnlineParam = false;
    size_t firstStar = localPath.find('*');
    if (firstStar != std::string::npos && firstStar > 0) {
        size_t secondStar = localPath.find('*', firstStar + 1);
        // Online config format: cachePath*product*region (region optional)
        isOnlineParam = (secondStar != std::string::npos) ? (secondStar > firstStar + 1) : true;
    }

    CASC_OPEN_STORAGE_ARGS args = {};
    args.Size = sizeof(CASC_OPEN_STORAGE_ARGS);
    args.dwLocaleMask = CASC_LOCALE_ALL;
    args.PfnProgressCallback = cascProgressCallback;
    args.PtrProgressParam = this;

    bool opened = false;

    if (isOnlineParam) {
        // Parse "cachePath*product*region" and pass fields directly via args
        // to avoid ParseOpenParams bugs with multi-part online storage strings.
        size_t firstSep = localPath.find('*');
        size_t secondSep = localPath.find('*', firstSep + 1);
        
        std::string cachePathStr = localPath.substr(0, firstSep);
        std::string productStr = (secondSep != std::string::npos) 
            ? localPath.substr(firstSep + 1, secondSep - firstSep - 1) 
            : localPath.substr(firstSep + 1);
        std::string regionStr = (secondSep != std::string::npos) 
            ? localPath.substr(secondSep + 1) 
            : "";

        args.dwFlags = cdnDownloadEnabled ? (CASC_FEATURE_ALLOW_DOWNLOAD | CASC_FEATURE_ONLINE) : 0;
        args.szLocalPath = cachePathStr.c_str();
        args.szCodeName = productStr.c_str();
        if (!regionStr.empty()) {
            args.szRegion = regionStr.c_str();
        }
        
        opened = CascOpenStorageEx(NULL, &args, true, &hStorage);
    } else {
        args.dwFlags = cdnDownloadEnabled ? (CASC_FEATURE_ALLOW_DOWNLOAD | CASC_FEATURE_ONLINE) : 0;
        opened = CascOpenStorageEx(localPath.c_str(), &args, false, &hStorage);
    }

    if (!opened) {
        DWORD error = GetCascError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
            return CascError::StorageNotFound;
        }
        return mapCascError(error);
    }

    // Enable CDN download for local storages by patching dwFeatures.
    // CascLib only sets CASC_FEATURE_ONLINE for online storages (CascVersions),
    // but local storages (.build.info) also have CDN config and need this flag
    // for FetchCascFile / bAllowDownloading to work.
    if (cdnDownloadEnabled && hStorage != nullptr) {
        TCascStorage* hs = static_cast<TCascStorage*>(hStorage);
        if (hs->ClassName == CASC_MAGIC_STORAGE) {
            hs->dwFeatures |= CASC_FEATURE_ONLINE;
        }
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
    {
        DWORD fileCount = 0;
        if (CascGetStorageInfo(hStorage, CascStorageLocalFileCount, &fileCount, sizeof(fileCount), nullptr) && fileCount > 0) {
            entries.reserve(static_cast<size_t>(fileCount));
        } else {
            entries.reserve(8192);
        }
    }

    
    for (const auto& mask : masks) {
        CASC_FIND_DATA findData = {};
        HANDLE hFind = CascFindFirstFile(hStorage, mask.c_str(), &findData, listFilePath.empty() ? nullptr : listFilePath.c_str());
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
            entry.nameType = static_cast<CascNameType>(findData.NameType);
            entry.tagBitMask = findData.TagBitMask;
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

    std::string openPath = cascPath;
    std::replace(openPath.begin(), openPath.end(), '/', '\\');
    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, openPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
        error = mapCascError(GetCascError());
        return {};
    }

    ULONGLONG fileSize64 = 0;
    bool hasKnownSize = CascGetFileSize64(hFile, &fileSize64);

    if (hasKnownSize) {
        if (fileSize64 > static_cast<ULONGLONG>(std::numeric_limits<size_t>::max())) {
            CascCloseFile(hFile);
            error = CascError::ReadError;
            return {};
        }

        // Cap file size to prevent unbounded memory allocation
        constexpr size_t MAX_READ_SIZE = 512 * 1024 * 1024; // 512 MB
        if (fileSize64 > MAX_READ_SIZE) {
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
    } else {
        // Fallback: stream read without known size (some files report size failure but data is readable)
        constexpr size_t BUFFER_SIZE = 1024 * 1024; // 1 MB chunks
        std::vector<uint8_t> chunk(BUFFER_SIZE);
        std::vector<uint8_t> buffer;
        buffer.reserve(BUFFER_SIZE);
        uint64_t totalRead = 0;

        constexpr uint64_t MAX_STREAM_SIZE = 512ULL * 1024 * 1024; // 512 MB
        while (true) {
            if (totalRead >= MAX_STREAM_SIZE) {
                CascCloseFile(hFile);
                error = CascError::ReadError;
                return {};
            }
            DWORD bytesRead = 0;
            if (!CascReadFile(hFile, chunk.data(), static_cast<DWORD>(BUFFER_SIZE), &bytesRead)) {
                DWORD err = GetCascError();
                if (err == ERROR_HANDLE_EOF) {
                    break;
                }
                CascCloseFile(hFile);
                error = mapCascError(err);
                return {};
            }
            if (bytesRead == 0) {
                if (totalRead == 0) {
                    CascCloseFile(hFile);
                    error = CascError::FileNotFound;
                    return {};
                }
                break;
            }
            try {
                buffer.insert(buffer.end(), chunk.begin(), chunk.begin() + bytesRead);
                totalRead += bytesRead;
            } catch (const std::bad_alloc&) {
                CascCloseFile(hFile);
                error = CascError::ReadError;
                return {};
            }
        }

        CascCloseFile(hFile);
        return buffer;
    }
}

std::vector<uint8_t> LocalCascStorage::readFilePartial(const std::string& cascPath, uint64_t offset, uint64_t length, CascError& error)
{
    error = CascError::None;

    if (hStorage == nullptr) {
        error = CascError::StorageNotFound;
        return {};
    }

    std::string openPath = cascPath;
    std::replace(openPath.begin(), openPath.end(), '/', '\\');
    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, openPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
        error = mapCascError(GetCascError());
        return {};
    }

    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        error = mapCascError(GetCascError());
        return {};
    }

    if (offset >= fileSize64) {
        CascCloseFile(hFile);
        return {};
    }

    ULONGLONG toRead = std::min(length, fileSize64 - offset);
    if (toRead > static_cast<ULONGLONG>(std::numeric_limits<size_t>::max())) {
        CascCloseFile(hFile);
        error = CascError::ReadError;
        return {};
    }

    // Cap to 10MB for partial reads
    constexpr size_t MAX_PARTIAL_READ = 10 * 1024 * 1024;
    size_t readSize = static_cast<size_t>(std::min<ULONGLONG>(toRead, MAX_PARTIAL_READ));

    if (!CascSetFilePointer64(hFile, static_cast<LONGLONG>(offset), nullptr, FILE_BEGIN)) {
        CascCloseFile(hFile);
        error = mapCascError(GetCascError());
        return {};
    }

    std::vector<uint8_t> buffer;
    try {
        buffer.resize(readSize);
    } catch (const std::bad_alloc&) {
        CascCloseFile(hFile);
        error = CascError::ReadError;
        return {};
    }

    DWORD totalRead = 0;
    while (totalRead < readSize) {
        DWORD bytesRead = 0;
        DWORD chunkSize = static_cast<DWORD>(std::min<size_t>(readSize - totalRead, std::numeric_limits<DWORD>::max()));
        if (!CascReadFile(hFile, buffer.data() + totalRead, chunkSize, &bytesRead)) {
            CascCloseFile(hFile);
            error = mapCascError(GetCascError());
            return {};
        }
        if (bytesRead == 0) {
            break;
        }
        totalRead += bytesRead;
    }

    buffer.resize(totalRead);
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

    auto resultPromise = std::make_shared<std::promise<CascError>>();
    std::future<CascError> resultFuture = resultPromise->get_future();
    const uint64_t startCancelGen = cancelGeneration.load(std::memory_order_acquire);
    HANDLE storageHandle = hStorage;

    std::thread worker([this, storageHandle, cascPath, destPath, progress, startCancelGen, resultPromise]() {
        // recv() is a POSIX cancellation point; deferred mode means we only
        // cancel at I/O boundaries, never mid-computation.
        pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, nullptr);
        pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED, nullptr);

        constexpr size_t BUFFER_SIZE = 64 * 1024;  // 64 KB chunks
        constexpr uint64_t MAX_EXTRACT_SIZE = 512ULL * 1024 * 1024;
        // Heap buffer (unique_ptr): small leak on pthread_cancel, but avoids stack overflow.
        auto chunk = std::make_unique<uint8_t[]>(BUFFER_SIZE);

        std::string openPath = cascPath;
        std::replace(openPath.begin(), openPath.end(), '/', '\\');

        HANDLE hFile = nullptr;
        if (!CascOpenFile(storageHandle, openPath.c_str(), CASC_LOCALE_ALL, CASC_OPEN_BY_NAME, &hFile)) {
            resultPromise->set_value(mapCascError(GetCascError()));
            return;
        }

        {
            size_t lastSep = destPath.find_last_of("/\\");
            if (lastSep != std::string::npos) {
                std::error_code ec;
                std::filesystem::create_directories(destPath.substr(0, lastSep), ec);
            }
        }

        FILE* fp = std::fopen(destPath.c_str(), "wb");
        if (fp == nullptr) {
            CascCloseFile(hFile);
            resultPromise->set_value(CascError::InvalidPath);
            return;
        }

        ULONGLONG fileSize64 = 0;
        bool hasKnownSize = CascGetFileSize64(hFile, &fileSize64);
        uint64_t totalRead = 0;
        CascError result = CascError::None;

        if (hasKnownSize && fileSize64 > 0) {
            if (fileSize64 > MAX_EXTRACT_SIZE) {
                result = CascError::ReadError;
            } else {
                while (totalRead < fileSize64) {
                    if (cancelGeneration.load(std::memory_order_acquire) != startCancelGen) {
                        result = CascError::Cancelled;
                        break;
                    }
                    DWORD toRead = static_cast<DWORD>(std::min(BUFFER_SIZE, static_cast<size_t>(fileSize64 - totalRead)));
                    DWORD bytesRead = 0;
                    if (!CascReadFile(hFile, chunk.get(), toRead, &bytesRead)) {
                        result = mapCascError(GetCascError());
                        break;
                    }
                    if (std::fwrite(chunk.get(), 1, bytesRead, fp) != bytesRead) {
                        result = CascError::ReadError;
                        break;
                    }
                    totalRead += bytesRead;
                    if (progress) {
                        progress(static_cast<int64_t>(totalRead), static_cast<int64_t>(fileSize64));
                    }
                }
            }
        } else {
            while (true) {
                if (totalRead >= MAX_EXTRACT_SIZE) {
                    result = CascError::ReadError;
                    break;
                }
                if (cancelGeneration.load(std::memory_order_acquire) != startCancelGen) {
                    result = CascError::Cancelled;
                    break;
                }
                DWORD bytesRead = 0;
                if (!CascReadFile(hFile, chunk.get(), static_cast<DWORD>(BUFFER_SIZE), &bytesRead)) {
                    DWORD err = GetCascError();
                    if (err == ERROR_HANDLE_EOF) {
                        break;
                    }
                    result = mapCascError(err);
                    break;
                }
                if (bytesRead == 0) {
                    if (totalRead == 0) {
                        result = CascError::FileNotFound;
                    }
                    break;
                }
                if (std::fwrite(chunk.get(), 1, bytesRead, fp) != bytesRead) {
                    result = CascError::ReadError;
                    break;
                }
                totalRead += bytesRead;
            }
        }

        CascCloseFile(hFile);
        std::fclose(fp);
        if (result != CascError::None && result != CascError::Cancelled) {
            std::remove(destPath.c_str());
        }
        resultPromise->set_value(result);
    });

    // Poll every 100ms: did the worker finish, or was cancellation requested?
    while (true) {
        if (resultFuture.wait_for(std::chrono::milliseconds(100)) == std::future_status::ready) {
            worker.join();
            return resultFuture.get();
        }
        if (cancelGeneration.load(std::memory_order_acquire) != startCancelGen) {
            pthread_cancel(worker.native_handle());
            worker.detach();
            std::remove(destPath.c_str());
            return CascError::Cancelled;
        }
    }
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

std::vector<std::pair<std::string, uint32_t>> LocalCascStorage::getTags()
{
    if (hStorage == nullptr) {
        return {};
    }

    size_t cbTags = 0;
    CascGetStorageInfo(hStorage, CascStorageTags, nullptr, 0, &cbTags);
    if (cbTags == 0) {
        return {};
    }

    // Allocate with max alignment to avoid UB from reinterpret_cast on under-aligned storage
    std::vector<std::max_align_t> alignedBuffer((cbTags + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t));
    auto* bufferData = reinterpret_cast<uint8_t*>(alignedBuffer.data());
    if (!CascGetStorageInfo(hStorage, CascStorageTags, bufferData, cbTags, &cbTags)) {
        return {};
    }

    auto* pTags = reinterpret_cast<PCASC_STORAGE_TAGS>(bufferData);
    std::vector<std::pair<std::string, uint32_t>> result;
    result.reserve(pTags->TagCount);
    for (size_t i = 0; i < pTags->TagCount; ++i) {
        const auto& tag = pTags->Tags[i];
        result.emplace_back(std::string(tag.szTagName, tag.TagNameLength), tag.TagValue);
    }
    return result;
}

std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> LocalCascStorage::parseInstallManifest()
{
    if (hStorage == nullptr) {
        return {};
    }

    TCascStorage* hs = TCascStorage::IsValid(hStorage);
    if (hs == nullptr) {
        return {};
    }
    if ((hs->InstallCKey.Flags & CASC_CE_HAS_CKEY) == 0) {
        return {};
    }

    // Open the install file by its CKey
    HANDLE hFile = nullptr;
    if (!CascOpenFile(hStorage, reinterpret_cast<const char*>(hs->InstallCKey.CKey), CASC_LOCALE_ALL, CASC_OPEN_BY_CKEY, &hFile)) {
        return {};
    }

    // Read the entire file
    ULONGLONG fileSize64 = 0;
    if (!CascGetFileSize64(hFile, &fileSize64)) {
        CascCloseFile(hFile);
        return {};
    }
    if (fileSize64 == 0 || fileSize64 > 256 * 1024 * 1024) {
        CascCloseFile(hFile);
        return {};
    }

    size_t fileSize = static_cast<size_t>(fileSize64);
    std::vector<uint8_t> data;
    try {
        data.resize(fileSize);
    } catch (const std::bad_alloc&) {
        CascCloseFile(hFile);
        return {};
    }
    DWORD bytesRead = 0;
    if (!CascReadFile(hFile, data.data(), static_cast<DWORD>(fileSize), &bytesRead) || bytesRead != fileSize) {
        CascCloseFile(hFile);
        return {};
    }
    CascCloseFile(hFile);

    const uint8_t* ptr = data.data();
    const uint8_t* end = data.data() + fileSize;

    // Parse header
    if (fileSize < 10) {
        return {};
    }
    uint16_t magic = ptr[0] | (ptr[1] << 8);
    if (magic != 0x4E49) {
        return {}; // 'IN'
    }
    uint8_t version = ptr[2];
    if (version != 1) {
        return {};
    }
    // uint8_t ekeyLength = ptr[3]; // expected 0x10
    uint16_t tagCount = (ptr[4] << 8) | ptr[5];
    uint32_t entryCount = ((uint32_t)ptr[6] << 24) | ((uint32_t)ptr[7] << 16) | ((uint32_t)ptr[8] << 8) | ptr[9];

    // Cap entryCount to prevent OOM from malformed manifests claiming huge counts
    const uint32_t maxEntries = static_cast<uint32_t>(fileSize / 32);
    if (entryCount > maxEntries) {
        entryCount = maxEntries;
    }

    ptr += 10;

    std::vector<InstallManifestTag> tags;
    tags.reserve(tagCount);

    uint64_t bitmapLength64 = (static_cast<uint64_t>(entryCount) / 8) + ((entryCount & 0x07) ? 1 : 0);
    size_t bitmapLength = static_cast<size_t>(bitmapLength64);

    // Parse tags
    for (uint16_t i = 0; i < tagCount && ptr < end; ++i) {
        const char* tagName = reinterpret_cast<const char*>(ptr);
        size_t maxNameLen = static_cast<size_t>(end - ptr);
        size_t nameLen = strnlen(tagName, maxNameLen);
        if (nameLen >= maxNameLen) break;
        ptr += nameLen + 1;
        if (ptr + sizeof(uint16_t) > end) break;
        uint16_t tagValue = (ptr[0] << 8) | ptr[1];
        ptr += sizeof(uint16_t); // skip USHORT (bitmap size or flags)
        if (ptr + bitmapLength > end) break;
        tags.push_back({std::string(tagName, nameLen), tagValue});
        ptr += bitmapLength;
    }

    std::vector<InstallManifestEntry> entries;
    entries.reserve(entryCount);

    // Parse file entries
    for (uint32_t i = 0; i < entryCount && ptr < end; ++i) {
        const char* fileName = reinterpret_cast<const char*>(ptr);
        size_t maxNameLen = static_cast<size_t>(end - ptr);
        size_t nameLen = strnlen(fileName, maxNameLen);
        if (nameLen >= maxNameLen) break;
        ptr += nameLen + 1;
        if (ptr + 16 + 4 > end) break;

        std::string ckeyStr;
        ckeyStr.reserve(32);
        static const char hex[] = "0123456789abcdef";
        for (int j = 0; j < 16; ++j) {
            ckeyStr.push_back(hex[ptr[j] >> 4]);
            ckeyStr.push_back(hex[ptr[j] & 0x0F]);
        }

        ptr += 16;
        uint32_t fileSize = ((uint32_t)ptr[0] << 24) | ((uint32_t)ptr[1] << 16) | ((uint32_t)ptr[2] << 8) | ptr[3];
        ptr += 4;

        // Compute tag bits for this entry from each tag's bitmap
        std::vector<uint8_t> tagBits;
        tagBits.reserve(tagCount);
        const uint8_t* tagPtr = data.data() + 10; // start of tags section
        for (uint16_t t = 0; t < tagCount && tagPtr < end; ++t) {
            const char* tName = reinterpret_cast<const char*>(tagPtr);
            size_t tLen = strnlen(tName, static_cast<size_t>(end - tagPtr));
            tagPtr += tLen + 1 + sizeof(uint16_t); // name + USHORT
            if (tagPtr + bitmapLength > end) break;
            uint8_t hasTag = 0;
            size_t byteIndex = i / 8;
            size_t bitIndex = i % 8;
            if (byteIndex < bitmapLength) {
                hasTag = (tagPtr[byteIndex] & (1 << bitIndex)) != 0 ? 1 : 0;
            }
            tagBits.push_back(hasTag);
            tagPtr += bitmapLength;
        }

        entries.push_back({std::string(fileName, nameLen), ckeyStr, fileSize, std::move(tagBits)});
    }

    // Deduplicate by file name (install manifest may contain duplicate entries for different tag combinations)
    std::vector<InstallManifestEntry> uniqueEntries;
    uniqueEntries.reserve(entries.size());
    std::unordered_set<std::string> seen;
    for (auto& entry : entries) {
        if (seen.insert(entry.fileName).second) {
            uniqueEntries.push_back(std::move(entry));
        }
    }

    return {tags, uniqueEntries};
}

} // namespace CascBridge
