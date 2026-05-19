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
    uint64_t tagBitMask = 0;
};

struct CascStorageInfo {
    std::string productName;
    std::string buildVersion;
    uint64_t totalFiles;
    uint64_t totalSize;
};

struct InstallManifestTag {
    std::string name;
    uint32_t value;
};

struct InstallManifestEntry {
    std::string fileName;
    std::string ckey;
    uint32_t flags;
    std::vector<uint8_t> tagBits;
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
    Cancelled,
    Unknown
};

} // namespace CascBridge
