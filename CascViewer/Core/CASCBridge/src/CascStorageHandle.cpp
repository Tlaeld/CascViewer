#include "CascStorageHandle.h"
#include "LocalCascStorage.h"
#include "OnlineCascStorage.h"
#include <memory>
#include <mutex>
#include <shared_mutex>

namespace CascBridge {

struct CascStorageHandle::Impl {
    std::unique_ptr<ICascStorage> storage;
    mutable std::shared_mutex mutex;
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

void CascStorageHandle::setCdnDownloadEnabled(bool enabled) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->setCdnDownloadEnabled(enabled);
    }
}

void CascStorageHandle::setOpenProgressCallback(COpenProgressCallback callback, void* context) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->setOpenProgressCallback(callback, context);
    }
}

CascError CascStorageHandle::open(const std::string& pathOrConfig) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->open(pathOrConfig) : CascError::Unknown;
}

void CascStorageHandle::close() {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->close();
    }
}

bool CascStorageHandle::isOpen() const {
    std::shared_lock<std::shared_mutex> lock(impl->mutex);
    return impl->storage && impl->storage->isOpen();
}

std::vector<CascFileEntry> CascStorageHandle::listDirectory(const std::string& path, CascError& error) {
    std::shared_lock<std::shared_mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->listDirectory(path, error) : std::vector<CascFileEntry>{};
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath) {
    std::shared_lock<std::shared_mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->extractFile(cascPath, destPath, ProgressCallback{}) : CascError::Unknown;
}

std::vector<uint8_t> CascStorageHandle::readFile(const std::string& cascPath, CascError& error) {
    std::shared_lock<std::shared_mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->readFile(cascPath, error) : std::vector<uint8_t>{};
}

CascStorageInfo CascStorageHandle::getStorageInfo(CascError& error) {
    std::shared_lock<std::shared_mutex> lock(impl->mutex);
    return impl->storage ? impl->storage->getStorageInfo(error) : CascStorageInfo{};
}

} // namespace CascBridge
