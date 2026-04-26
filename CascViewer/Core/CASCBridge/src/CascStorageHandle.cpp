#include "CascStorageHandle.h"
#include "LocalCascStorage.h"
#include "OnlineCascStorage.h"
#include <memory>
#include <mutex>

namespace CascBridge {

struct CascStorageHandle::Impl {
    std::unique_ptr<ICascStorage> storage;
    mutable std::mutex mutex;
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
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->open(pathOrConfig) : CascError::Unknown;
}

void CascStorageHandle::close() {
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->close();
    }
}

bool CascStorageHandle::isOpen() const {
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage && impl->storage->isOpen();
}

std::vector<CascFileEntry> CascStorageHandle::listDirectory(const std::string& path, CascError& error) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->listDirectory(path, error) : std::vector<CascFileEntry>{};
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->extractFile(cascPath, destPath, ProgressCallback{}) : CascError::Unknown;
}

std::vector<uint8_t> CascStorageHandle::readFile(const std::string& cascPath, CascError& error) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->readFile(cascPath, error) : std::vector<uint8_t>{};
}

CascStorageInfo CascStorageHandle::getStorageInfo(CascError& error) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->getStorageInfo(error) : CascStorageInfo{};
}

} // namespace CascBridge
