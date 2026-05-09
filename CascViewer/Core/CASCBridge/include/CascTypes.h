#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace CascBridge {

enum class FileType : uint8_t {
    File,
    Directory
};

enum class CascNameType : uint8_t {
    Full,       // Fully qualified file name from ROOT index
    DataId,     // Name created from file data id
    CKey,       // Name created as string representation of CKey
    EKey        // Name created as string representation of EKey
};

struct CascFileEntry {
    std::string name;
    std::string fullPath;
    FileType type;
    uint64_t size;
    std::string encodingKey;  // empty for directories
    bool isLocal = true;
    CascNameType nameType = CascNameType::Full;
};

struct CascStorageInfo {
    std::string productName;
    std::string buildVersion;
    uint64_t totalFiles;
    uint64_t totalSize;
};

enum class CascError : uint8_t {
    None,
    InvalidPath,
    StorageNotFound,
    StorageCorrupted,
    FileNotFound,
    ReadError,
    NetworkError,
    CDNConfigError,
    DecodingError,
    NotImplemented,
    Unknown
};

} // namespace CascBridge
