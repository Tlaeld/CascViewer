# CascViewer Code Quality Review Report

**Date:** 2026-05-23  
**Scope:** All project code except `CascLib/` submodule  
**Reviewers:** Kimi Code CLI (automated) + subagent analysis  
**Test Status:** 74/74 pass (0 failures)

---

## Executive Summary

The codebase is well-structured with clear separation between C++ bridge, Swift services, and SwiftUI UI layers. Exception safety, RAII, and bounds checking are generally solid. However, several **Critical** and **Important** issues remain across memory safety, thread safety, Swift/C++ interop, and test coverage.

| Severity | Count | Summary |
|----------|-------|---------|
| Critical | 3 | Buffer over-read, runtime crash, test pollution |
| Important | 26 | Thread safety, resource leaks, interop bugs, coverage gaps |
| Minor | 22 | Performance nits, UB, weak assertions, naming |

---

## Critical Issues (Fix Immediately)

### 1. Off-by-one buffer over-read in BLP2 JPEG resolution
- **File:** `CascViewer/Core/CASCBridge/src/BLPDecoderBridge.cpp:491`
- **Description:** The `resolveJPEG` lambda checks `if (totalSize > 4)` before accessing `ptr[4]` and `ptr[5]`. When `totalSize == 5`, the condition passes but `ptr[5]` reads a 6th byte out of bounds.
- **Fix:** Change to `if (totalSize >= 6)` before accessing `ptr[5]`.

### 2. SearchTagSystem crashes on tag values ≥ 64
- **File:** `CascViewer/Core/Services/CASCSearchService.swift:148`
- **Description:** `(1 as UInt64) << UInt64(tag.value)` performs an unchecked left-shift. Shifting by ≥ 64 bits is a runtime trap in Swift. `CascTag.value` is `UInt32`, so malformed/large tag values will crash the app.
- **Fix:** Clamp before shifting: `guard tag.value < 64 else { continue }`.

### 3. AppSettings singleton pollutes real UserDefaults.standard
- **File:** `CascViewer/App/AppSettings.swift:9`
- **Description:** `AppSettings` hardcodes `UserDefaults.standard`. Tests mutate `AppSettings.shared` (e.g., `resetToDefaults()`, changing `languageCode`), which writes to the developer's actual macOS preferences, breaking test isolation.
- **Fix:** Allow dependency injection of a `UserDefaults` instance (e.g., `init(defaults: UserDefaults = .standard)`), or make `AppSettingsTests` operate on a non-shared instance.

---

## Important Issues

### C++ Bridge — Thread Safety & Memory

### 4. Concurrent access to CascLib storage handle via `shared_lock`
- **File:** `CascViewer/Core/CASCBridge/src/CascStorageHandle.cpp:116–153`
- **Description:** `extractFile`, `readFile`, `readFilePartial`, `listDirectory` use `std::shared_lock`, allowing multiple threads to enter `LocalCascStorage` simultaneously and call `CascOpenFile`/`CascReadFile`/`CascFindFirstFile` on the same `hStorage`. CascLib does **not** guarantee thread-safety for concurrent access to the same storage handle.
- **Fix:** Change storage-mutating operations to `std::lock_guard<std::shared_mutex>` (exclusive lock), or document that the caller must serialize all storage operations. The Swift side's `readSerialQueue` mitigates this for search reads only.

### 5. Unbounded memory growth in `readFile` streaming fallback
- **File:** `CascViewer/Core/CASCBridge/src/LocalCascStorage.cpp:349–382`
- **Description:** When `CascGetFileSize64` returns `false`, the streaming fallback repeatedly `buffer.insert`s 1 MB chunks with no maximum size cap.
- **Fix:** Add a `MAX_READ_SIZE` cap (e.g., 512 MB) to the fallback path.

### 6. `CascStorageHandle` destruction while operations are in-flight
- **File:** `CascViewer/Core/CASCBridge/src/CascStorageHandle.cpp` / `.h`
- **Description:** `CascStorageHandle` holds `std::shared_ptr<Impl>`, which owns the `std::shared_mutex`. If the last Swift reference is dropped while another thread holds a `shared_lock` on `impl->mutex`, `Impl` is destroyed, destroying the mutex while locked — undefined behavior.
- **Fix:** Add an explicit shutdown protocol or a separate shared-state object whose lifetime is managed independently.

### 7. Shared cancellation flag races across concurrent extractions
- **File:** `CascViewer/Core/CASCBridge/src/LocalCascStorage.cpp:469`
- **Description:** `extractFile` resets `extractionCancelled` to `false` at the start of every extraction. If two extractions were ever concurrent, the second would overwrite the first's cancellation state.
- **Fix:** Scope cancellation per-extraction (e.g., pass a cancellation token into the read loop).

### 8. Swift-side double-release of progress context
- **File:** `CascViewer/Core/Services/CASCStorageService.swift:107–111`
- **Description:** `deinit` calls `release()` on `progressContext`, but `openWithConfig` / `openLocal` also call `release()` after `setOpenProgressCallback(nil, nil)`. If `deinit` runs while an `open` operation is in progress, both paths can release the same pointer.
- **Fix:** Remove the release from `deinit`; rely solely on the balanced `passRetained`/`release` in `openWithConfig` / `openLocal`.

### C++ Bridge — Safety & Correctness

### 9. Integer overflow in CURL write callback
- **File:** `CascViewer/Core/CASCBridge/src/CDNCacheManager.cpp:28`
- **Description:** `size_t totalSize = size * nmemb;` can overflow. Unsigned overflow is UB in C++.
- **Fix:** Check `if (size != 0 && nmemb > SIZE_MAX / size) return 0;`.

### 10. Read errors masked as EOF in streaming fallback
- **File:** `CascViewer/Core/CASCBridge/src/LocalCascStorage.cpp:361`
- **Description:** `if (err == ERROR_HANDLE_EOF || totalRead > 0) break;` treats any read error as EOF if at least one byte was already read, masking corruption/network errors.
- **Fix:** Only treat `ERROR_HANDLE_EOF` as EOF; propagate other errors.

### 11. `fetchConfig` ignores global cancellation
- **File:** `CascViewer/Core/CASCBridge/src/CDNConfig.cpp:131–132`
- **Description:** `fetchConfig` calls `downloadText` without a cancellation function and never checks `g_cancelGeneration`. Unlike `fetchProductRegions`, it cannot be cancelled mid-flight.
- **Fix:** Pass an `isCancelled` lambda and verify the generation before returning.

### 12. Silent exception swallowing in `requestCancelExtraction`
- **File:** `CascViewer/Core/CASCBridge/src/CascStorageHandle.cpp:155–163`
- **Description:** The catch-all block silently swallows every exception.
- **Fix:** Log to stderr like the other methods.

### 13. Unbounded JPEG decode buffer allocation
- **File:** `CascViewer/Core/CASCBridge/src/BLPDecoderBridge.cpp:389`
- **Description:** `decodeJPEGData` resizes `rgba` to `width * height * 4` without an upper bound. Malicious JPEG dimensions could cause OOM.
- **Fix:** Cap decoded dimensions (e.g., 16384×16384).

### Swift Models & Services

### 14. `CDNProduct` synthesized `Equatable` is broken
- **File:** `CascViewer/Core/Models/CDNProduct.swift:3`
- **Description:** `let id = UUID()` is part of synthesized `Equatable`. Two instances with identical `name`/`code` will never be equal. `builtInList` creates new instances on every access (though it is `static let`, the instances inside are fresh).
- **Fix:** Implement custom `==` that compares `name` and `code` only, or make `id` computed from a stable property.

### 15. `CASCFileEntry` custom `Hashable` ignores other properties
- **File:** `CascViewer/Core/Models/CASCFileEntry.swift:89–95`
- **Description:** Two entries with the same `fullPath` but different `size`, `isLocal`, or `tagBitMask` will hash and compare as equal. This is intentional for SwiftUI identity but is a footgun for `Set` or dictionary use.
- **Fix:** Document the identity semantics in a code comment.

### 16. `LocalizationManager.shared` is unisolated global mutable state
- **File:** `CascViewer/Core/Services/LocalizationManager.swift:4`
- **Description:** `languageCode` is mutable from any thread. Tests that touch `AppSettings.shared` or call `L()` can leave it in an unexpected state.
- **Fix:** Reset `LocalizationManager.shared.languageCode` in a global `setUp`/`tearDown`, or protect it with an actor.

### 17. `CASCStorageService.readFileData` blocks MainActor
- **File:** `CascViewer/Core/Services/CASCStorageService.swift:714–719`
- **Description:** `readFileData(forPath:)` calls `handle.readFile(...)` directly on the main thread. This is a synchronous, potentially long-running I/O operation.
- **Fix:** Dispatch through the serial `queue` or mark the method `async`.

### 18. `InstallManifestExtractService` frequent MainActor switching
- **File:** `CascViewer/UI/InstallManifest/InstallManifestExportSheet.swift:33–36`
- **Description:** The extraction loop calls `await MainActor.run` on every iteration to update progress. This thrashes the main thread.
- **Fix:** Throttle UI updates (e.g., only update every 5% or every 100 ms).

### 19. Temporary file leak in `FilePreviewPanel.openImageFile`
- **File:** `CascViewer/UI/FileBrowser/FilePreviewPanel.swift:89–122`
- **Description:** If extraction succeeds and the file is opened, the temporary directory in `~/tmp/CascViewer/Open/<UUID>/` is never deleted.
- **Fix:** Schedule cleanup after a delay, or use `NSTemporaryDirectory` with automatic cleanup.

### 20. `NSLog` and `print()` used for production logging
- **Files:** `CascViewer/UI/InstallManifest/InstallManifestExportSheet.swift`, `CascViewer/Core/Services/CDNProductService.swift`, `CascViewer/Core/Services/CASCStorageService.swift`, `CascViewer/UI/FileBrowser/FileTreeView.swift`
- **Description:** `NSLog` and `print()` are used throughout. These are debug leftovers that should be replaced with `os.log` or removed.
- **Fix:** Replace `NSLog` with `Logger`; remove or `#if DEBUG` guard `print()` statements.

### Tests — Coverage & Reliability

### 21. `AppSettingsTests` has ineffective `UserDefaults` isolation
- **File:** `CascViewerTests/AppSettingsTests.swift:7–8, 14`
- **Description:** Creates `UserDefaults(suiteName:)` but never injects it. The `defaults` variable is dead code.
- **Fix:** Inject the suite-backed `UserDefaults` into `AppSettings`, or remove the unused variable.

### 22. `BridgeTests` omits two `CASCError` cases
- **File:** `CascViewerTests/BridgeTests.swift:59`
- **Description:** `.fileNotAvailable` and `.cancelled` are missing from the description-coverage array.
- **Fix:** Add the missing cases.

### 23. `ServiceTests` makes a brittle exact-error assertion
- **File:** `CascViewerTests/ServiceTests.swift:12`
- **Description:** `await service.openLocal(path: "/nonexistent")` asserts `.storageNotFound`, but the underlying C++ bridge may return `.invalidPath` depending on the OS.
- **Fix:** Assert `XCTAssertNotNil(service.error)` instead.

### 24. Pure helper tests unnecessarily depend on the real C++ bridge
- **Files:** `CascViewerTests/SearchParserTests.swift:159, 181, 191, 202, 211`; `CascViewerTests/ServiceTests.swift:27, 38`
- **Description:** Tests for pure methods (`filterByTypes`, `getCandidates`, `isSafeRegexPattern`) instantiate `CASCSearchService` with a real `CascStorageHandle.createLocal()` even though the handle is never used.
- **Fix:** Extract these helpers into free functions or add a test-only `CASCSearchService()` init that doesn't require a handle.

### 25. `CASCStorageService.buildChildrenMap` parallel path is completely untested
- **File:** `CascViewer/Core/Services/CASCStorageService.swift:511–648`
- **Description:** Parallel chunking (triggered when `entries.count > 4096`) has zero test coverage.
- **Fix:** Add a test with ~5,000 entries and assert output matches the serial path.

### 26. `CASCSearchService` content/hex/tag search is untested
- **File:** `CascViewer/Core/Services/CASCSearchService.swift:271–453`
- **Description:** Only `searchFilename` is covered. `searchContent`, `searchHex`, and `searchTag` have no tests.
- **Fix:** Add unit tests for each mode, including cancellation and empty queries.

### 27. `CASCSearchService.rangeOfCaseInsensitive` ASCII fallback path is untested
- **File:** `CascViewer/Core/Services/CASCSearchService.swift:356–371`
- **Description:** The non-UTF-8 byte-scan branch is never exercised.
- **Fix:** Add a test with invalid UTF-8 data and a case-insensitive ASCII needle.

### 28. `CASCExtractService` extraction logic is completely untested
- **File:** `CascViewer/Core/Services/CASCExtractService.swift:57–174`
- **Description:** No tests cover `extract`, `cancel`, path sanitization, `preserveStructure`, `overwriteExisting`, or progress reporting.
- **Fix:** Add tests for cancellation, empty entry arrays, and path sanitization edge cases (`..`, `.`).

### 29. `CASCStorageService.entry(forPath:)` and `entriesUnder(path:)` are untested
- **File:** `CascViewer/Core/Services/CASCStorageService.swift:689–712`
- **Description:** These public helpers have no coverage, including virtual-directory paths (`CONTENT_KEY`, `ENCODED_KEY`, `UNKNOWN`).
- **Fix:** Add unit tests.

### 30. `AppSettings.clearCache()` is untested
- **File:** `CascViewer/App/AppSettings.swift:89–103`
- **Fix:** Add a test that creates dummy files in the cache path, calls `clearCache()`, and asserts removal.

---

## Minor Issues

### C++ Bridge

| # | File | Line | Issue | Fix |
|---|------|------|-------|-----|
| 31 | `LocalCascStorage.cpp` | 700 | `bitmapLength` could wrap if `entryCount == UINT32_MAX` | Use `uint64_t` for intermediate calculation |
| 32 | `LocalCascStorage.cpp` | 703–757 | Pointer arithmetic past buffer end after `strnlen` | Check `ptr >= end` before addition |
| 33 | `LocalCascStorage.cpp` | 769 | Suppressed NRVO due to explicit `std::move` in return | Return locals directly: `return {tags, uniqueEntries};` |
| 34 | `LocalCascStorage.cpp` | 626 | Alignment UB in `reinterpret_cast<PCASC_STORAGE_TAGS>` | Use `alignas` storage or copy into aligned struct |

### Swift

| # | File | Issue | Fix |
|---|------|-------|-----|
| 35 | `CascViewer/Core/Services/CASCStorageService.swift:98` | `directoryPaths` is set but never read | Remove dead code |
| 36 | `CascViewerTests/SearchPreviewTests.swift:15, 27` | Weak `contains` assertions | Assert exact prefix strings |
| 37 | `CascViewerTests/SearchParserTests.swift:148` | Weak mixed-case assertion | Assert `lowerBound` and `upperBound` |
| 38 | `CascViewerTests/ServiceTests.swift:25–32` | `testCASCSearchService` is trivial (empty array → empty results) | Remove or replace with meaningful test |
| 39 | `CascViewerTests/BridgeTests.swift:12–92` | Contains non-bridge model tests | Move to `CascViewerTests.swift` or `ModelTests.swift` |
| 40 | `CascViewerTests/SearchParserTests.swift` | Name is too narrow (tests regex, tags, hex search, etc.) | Rename to `SearchServiceTests.swift` |
| 41 | `CascViewerTests/AppSettingsTests.swift:40` | Hardcodes language count (`== 2`) | Assert `count >= 2` and check required languages |
| 42 | `CascViewerTests/CascViewerTests.swift` | Generic grab-bag of unrelated tests | Split into focused files |
| 43 | `CascViewerTests/SearchPreviewTests.swift:24` | Passes grapheme count instead of byte count for `queryLength` | Pass `Data(searchText.utf8).count` |
| 44 | `CascViewer/Core/Services/CASCStorageService.swift:673` | Missing test for `((a+)?)+` regex pattern | Add to `testUnsafeRegexPatterns` |
| 45 | `CascViewerTests/IntegrationTests.swift:9–28` | `testEndToEndSearchFlow` doesn't exercise `AppState` | Rename or assert `appState.searchResults` |
| 46 | `CascViewerTests/ChildrenMapTests.swift` | Doesn't test `UNKNOWN` virtual folder | Add test with `FILE00166360.dat`-style names |
| 47 | `CascViewerTests/CascViewerTests.swift` / `SearchParserTests.swift` | `HexPatternParser` missing edge-case tests | Add tests for `?48`, `48?`, odd-length strings |

---

## Positive Findings

- **RAII:** `FindCloser`, `std::unique_ptr`, and CoreFoundation `CFRelease`/`CG*Release` pairs are used correctly throughout the C++ bridge.
- **Null checks:** `impl->storage` is consistently checked before dereferencing in `CascStorageHandle`.
- **Bounds checking:** Most file parsers (BLP, DDS) validate header sizes and offsets against `length`.
- **Exception safety:** `CascStorageHandle` wraps every public method in `try-catch` to prevent C++ exceptions from crossing into Swift.
- **File size caps:** `readFile` and `readFilePartial` enforce reasonable maximum read sizes (512 MB / 10 MB).
- **Cancellation:** Extraction and search operations have explicit cancellation paths.
- **Serial queues:** The Swift side uses dedicated serial queues for storage and search reads to mitigate CascLib thread-safety concerns.
