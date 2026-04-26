#include "CascStorageHandle.h"
#include "LocalCascStorage.h"
#include "OnlineCascStorage.h"
#include <memory>

namespace CascBridge {

struct CascStorageHandle::Impl {
    std::unique_ptr<ICascStorage> storage;
};

CascStorageHandle::CascStorageHandle() : impl(std::make_shared<Impl>()) {}

CascStorageHandle CascStorageHandle::createLocal() {
    CascStorageHandle handle;
    handle.impl->storage = std::make_unique<LocalCascStorage>();
    return handle;
}

CascStorageHandle CascStorageHandle::createOnline() {
    CascStorageHandle handle;
    handle.impl->storage = std::make_unique<OnlineCascStorage>();
    return handle;
}

CascError CascStorageHandle::open(const std::string& pathOrConfig) {
    return impl->storage ? impl->storage->open(pathOrConfig) : CascError::Unknown;
}

void CascStorageHandle::close() {
    if (impl->storage) {
        impl->storage->close();
    }
}

bool CascStorageHandle::isOpen() const {
    return impl->storage && impl->storage->isOpen();
}

std::vector<CascFileEntry> CascStorageHandle::listDirectory(const std::string& path, CascError& error) {
    return impl->storage ? impl->storage->listDirectory(path, error) : std::vector<CascFileEntry>{};
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath) {
    return impl->storage ? impl->storage->extractFile(cascPath, destPath, ProgressCallback{}) : CascError::Unknown;
}

std::vector<uint8_t> CascStorageHandle::readFile(const std::string& cascPath, CascError& error) {
    return impl->storage ? impl->storage->readFile(cascPath, error) : std::vector<uint8_t>{};
}

CascStorageInfo CascStorageHandle::getStorageInfo(CascError& error) {
    return impl->storage ? impl->storage->getStorageInfo(error) : CascStorageInfo{};
}

} // namespace CascBridge
