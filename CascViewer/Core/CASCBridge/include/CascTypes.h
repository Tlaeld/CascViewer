#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace CascBridge {

enum class FileType {
    File,
    Directory
};

struct CascFileEntry {
    std::string name;
    std::string fullPath;
    FileType type;
    uint64_t size;
    std::string encodingKey;  // empty for directories
};

struct CascStorageInfo {
    std::string productName;
    std::string buildVersion;
    uint64_t totalFiles;
    uint64_t totalSize;
};

enum class CascError {
    None,
    InvalidPath,
    StorageNotFound,
    StorageCorrupted,
    FileNotFound,
    ReadError,
    NetworkError,
    CDNConfigError,
    DecodingError,
    Unknown
};

} // namespace CascBridge
