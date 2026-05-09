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

void CascStorageHandle::setCachePath(const std::string& path) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->setCachePath(path);
    }
}

void CascStorageHandle::setOpenProgressCallback(COpenProgressCallback callback, void* context) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->setOpenProgressCallback(callback, context);
    }
}

CascError CascStorageHandle::open(const std::string& pathOrConfig) {
    try {
        std::lock_guard<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->open(pathOrConfig) : CascError::Unknown;
    } catch (...) {
        return CascError::Unknown;
    }
}

void CascStorageHandle::close() {
    try {
        std::lock_guard<std::shared_mutex> lock(impl->mutex);
        if (impl->storage) {
            impl->storage->close();
        }
    } catch (...) {
        // swallow
    }
}

bool CascStorageHandle::isOpen() const {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage && impl->storage->isOpen();
    } catch (...) {
        return false;
    }
}

std::vector<CascFileEntry> CascStorageHandle::listDirectory(const std::string& path, CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->listDirectory(path, error) : std::vector<CascFileEntry>{};
    } catch (...) {
        error = CascError::Unknown;
        return {};
    }
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->extractFile(cascPath, destPath, ProgressCallback{}) : CascError::Unknown;
    } catch (...) {
        return CascError::Unknown;
    }
}

std::vector<uint8_t> CascStorageHandle::readFile(const std::string& cascPath, CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->readFile(cascPath, error) : std::vector<uint8_t>{};
    } catch (...) {
        error = CascError::Unknown;
        return {};
    }
}

CascStorageInfo CascStorageHandle::getStorageInfo(CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->getStorageInfo(error) : CascStorageInfo{};
    } catch (...) {
        error = CascError::Unknown;
        return {};
    }
}

} // namespace CascBridge
