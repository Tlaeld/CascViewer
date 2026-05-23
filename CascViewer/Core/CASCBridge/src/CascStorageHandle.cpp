#include "CascStorageHandle.h"
#include "LocalCascStorage.h"
#include "CDNConfig.h"
#include <cstdio>
#include <memory>
#include <mutex>
#include <shared_mutex>

namespace CascBridge {

struct CascStorageHandle::Impl {
    std::unique_ptr<ICascStorage> storage;
    mutable std::shared_mutex mutex;
};

CascStorageHandle::CascStorageHandle() : impl(std::make_shared<Impl>()) {}
CascStorageHandle::~CascStorageHandle() = default;

CascStorageHandle CascStorageHandle::createLocal() {
    CascStorageHandle handle;
    handle.impl->storage = std::make_unique<LocalCascStorage>();
    return handle;
}

std::vector<std::string> CascStorageHandle::fetchProductRegions(const std::string& product) {
    CDNConfig config;
    return config.fetchProductRegions(product);
}

void CascStorageHandle::setFetchCancellationFlag(bool cancelled) {
    CDNConfig::setGlobalCancelFlag(cancelled);
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

void CascStorageHandle::setListFilePath(const std::string& path) {
    std::lock_guard<std::shared_mutex> lock(impl->mutex);
    if (impl->storage) {
        impl->storage->setListFilePath(path);
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
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in open(): %s\n", e.what());
        return CascError::Unknown;
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in open()\n");
        return CascError::Unknown;
    }
}

void CascStorageHandle::close() {
    try {
        std::lock_guard<std::shared_mutex> lock(impl->mutex);
        if (impl->storage) {
            impl->storage->close();
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in close(): %s\n", e.what());
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in close()\n");
    }
}

bool CascStorageHandle::isOpen() const {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage && impl->storage->isOpen();
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in isOpen(): %s\n", e.what());
        return false;
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in isOpen()\n");
        return false;
    }
}

std::vector<CascFileEntry> CascStorageHandle::listDirectory(const std::string& path, CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->listDirectory(path, error) : std::vector<CascFileEntry>{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in listDirectory(): %s\n", e.what());
        error = CascError::Unknown;
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in listDirectory()\n");
        error = CascError::Unknown;
        return {};
    }
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->extractFile(cascPath, destPath, ProgressCallback{}) : CascError::Unknown;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in extractFile(): %s\n", e.what());
        return CascError::Unknown;
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in extractFile()\n");
        return CascError::Unknown;
    }
}

CascError CascStorageHandle::extractFile(const std::string& cascPath,
                                         const std::string& destPath,
                                         void (*progressCallback)(void*, int64_t, int64_t),
                                         void* progressContext) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        if (!impl->storage) {
            return CascError::Unknown;
        }
        ProgressCallback progress;
        if (progressCallback) {
            progress = [progressCallback, progressContext](int64_t current, int64_t total) {
                progressCallback(progressContext, current, total);
            };
        }
        return impl->storage->extractFile(cascPath, destPath, progress);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in extractFile(): %s\n", e.what());
        return CascError::Unknown;
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in extractFile()\n");
        return CascError::Unknown;
    }
}

void CascStorageHandle::requestCancelExtraction() {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        if (impl->storage) {
            impl->storage->requestCancelExtraction();
        }
    } catch (...) {
    }
}

std::vector<uint8_t> CascStorageHandle::readFile(const std::string& cascPath, CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->readFile(cascPath, error) : std::vector<uint8_t>{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in readFile(): %s\n", e.what());
        error = CascError::Unknown;
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in readFile()\n");
        error = CascError::Unknown;
        return {};
    }
}

std::vector<uint8_t> CascStorageHandle::readFilePartial(const std::string& cascPath, uint64_t offset, uint64_t length, CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->readFilePartial(cascPath, offset, length, error) : std::vector<uint8_t>{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in readFilePartial(): %s\n", e.what());
        error = CascError::Unknown;
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in readFilePartial()\n");
        error = CascError::Unknown;
        return {};
    }
}

CascStorageInfo CascStorageHandle::getStorageInfo(CascError& error) {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->getStorageInfo(error) : CascStorageInfo{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in getStorageInfo(): %s\n", e.what());
        error = CascError::Unknown;
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in getStorageInfo()\n");
        error = CascError::Unknown;
        return {};
    }
}

std::vector<std::pair<std::string, uint32_t>> CascStorageHandle::getTags() {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->getTags() : std::vector<std::pair<std::string, uint32_t>>{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in getTags(): %s\n", e.what());
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in getTags()\n");
        return {};
    }
}

std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>> CascStorageHandle::parseInstallManifest() {
    try {
        std::shared_lock<std::shared_mutex> lock(impl->mutex);
        return impl->storage ? impl->storage->parseInstallManifest() : std::pair<std::vector<InstallManifestTag>, std::vector<InstallManifestEntry>>{};
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[CascStorageHandle] Exception in parseInstallManifest(): %s\n", e.what());
        return {};
    } catch (...) {
        std::fprintf(stderr, "[CascStorageHandle] Unknown exception in parseInstallManifest()\n");
        return {};
    }
}

} // namespace CascBridge
