# CascViewer for macOS — Design Document

**Date:** 2026-04-26  
**Status:** Approved  
**Scope:** First version must support both local and online CASC storage browsing, file search, extraction, and BLP image viewing (advanced). Read-only, no modification support.

---

## 1. Overview

CascViewer for macOS is a native GUI application for browsing Blizzard CASC (Content Addressable Storage Container) file systems. It supports all Blizzard games that use CASC, providing local and online CDN storage browsing, file search, extraction, and advanced BLP image viewing.

**Key Principles:**
- Read-only. No modification of CASC storage is supported or planned.
- Unified abstraction: local and online storage are treated identically by the UI layer.
- Native macOS experience: classic CascView layout with modern macOS interactions.

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────┐
│  SwiftUI Views (Classic Layout + macOS) │
├─────────────────────────────────────────┤
│  ViewModels (ObservableObject)          │
├─────────────────────────────────────────┤
│  Core Services (Swift)                  │
│  - CASCStorageService                   │
│  - CASCSearchService                    │
│  - CASCExtractService                   │
│  - CDNConfigService                     │
│  - BLPDecoderCoordinator                │
├─────────────────────────────────────────┤
│  C++ Bridge Layer                       │
│  - CascStorage (unified interface)      │
│  - LocalCascStorage (CascLib)           │
│  - OnlineCascStorage (CDN client)       │
│  - BLPDecoder                           │
├─────────────────────────────────────────┤
│  Third-Party Libraries                  │
│  - CascLib (C++)                        │
│  - BLP decoding library (C/C++)         │
│  - CDN download / cache manager         │
└─────────────────────────────────────────┘
```

### 2.2 Module Structure

```
CascViewer/
├── App/
│   ├── CascViewerApp.swift
│   └── AppState.swift
├── Core/
│   ├── CASCBridge/
│   │   ├── include/
│   │   │   ├── CascStorage.h
│   │   │   ├── LocalCascStorage.h
│   │   │   ├── OnlineCascStorage.h
│   │   │   └── BLPDecoderBridge.h
│   │   └── src/
│   │       ├── CascStorage.cpp
│   │       ├── LocalCascStorage.cpp
│   │       ├── OnlineCascStorage.cpp
│   │       ├── CDNConfig.cpp
│   │       ├── CDNCacheManager.cpp
│   │       └── BLPDecoder.cpp
│   ├── Services/
│   │   ├── CASCStorageService.swift
│   │   ├── CASCSearchService.swift
│   │   ├── CASCExtractService.swift
│   │   ├── CDNConfigService.swift
│   │   └── BLPDecoderCoordinator.swift
│   └── Models/
│       ├── CASCFileEntry.swift
│       ├── CASCStorageInfo.swift
│       ├── CASCError.swift
│       └── BLPImageInfo.swift
├── UI/
│   ├── MainWindow/
│   │   ├── MainWindowView.swift
│   │   ├── ToolbarView.swift
│   │   └── StatusBarView.swift
│   ├── FileBrowser/
│   │   ├── FileTreeView.swift
│   │   ├── FileListView.swift
│   │   └── FilePreviewPanel.swift
│   ├── Search/
│   │   └── SearchPanelView.swift
│   ├── BLPViewer/
│   │   ├── BLPViewerWindow.swift
│   │   ├── BLPViewerView.swift
│   │   ├── BLPAnimationControls.swift
│   │   └── BLPMipMapSelector.swift
│   └── Common/
│       └── ProgressOverlay.swift
└── Resources/
```

### 2.3 Key Design Decisions

1. **C++ Bridge uses C++17**: Exposes clean C++ class interfaces consumed directly by Swift via Swift 5.9+ C++ interoperability. No C wrappers or Objective-C bridging required.
2. **Unified Storage Interface**: `ICascStorage` abstract base class with `LocalCascStorage` and `OnlineCascStorage` implementations. The Swift layer interacts only with the abstraction.
3. **CDN Local Cache**: Online mode caches downloaded chunks in `~/Library/Caches/CascViewer/cdn/`, organized by `(product, region)`, supporting resumable downloads.
4. **Threading**: All CascLib operations run on a dedicated `DispatchQueue` (`cascQueue`) to avoid blocking the main thread.
5. **Error Handling**: C++ layer uses `std::expected<T, CascError>`; Swift side maps to `Result<T, CASCError>`.

---

## 3. C++ Bridge Layer

### 3.1 Unified Storage Interface

```cpp
class ICascStorage {
public:
    virtual ~ICascStorage() = default;
    virtual bool open(const std::string& pathOrConfig) = 0;
    virtual void close() = 0;
    virtual std::vector<CascFileEntry> listDirectory(const std::string& path) = 0;
    virtual bool extractFile(const std::string& cascPath, const std::string& destPath) = 0;
    virtual std::vector<uint8_t> readFile(const std::string& cascPath) = 0;
    virtual CascStorageInfo getStorageInfo() = 0;
};

class LocalCascStorage : public ICascStorage {
    HANDLE hStorage = nullptr;
public:
    bool open(const std::string& localPath) override;
    // ... CascLib-based implementation
};

class OnlineCascStorage : public ICascStorage {
    std::unique_ptr<CDNConfig> cdnConfig;
    std::unique_ptr<CDNCacheManager> cacheManager;
public:
    bool open(const std::string& productCode) override;
    // ... CDN-based implementation
};
```

### 3.2 CDN Online Mode Workflow

1. **Configuration Acquisition**: User inputs game product code (e.g., `wow`) and region (e.g., `us`).
2. **CDNConfigService** downloads and parses Blizzard CDN build configuration (`versions`, `cdns`, `build-config`).
3. **OnlineCascStorage** uses the CDN root URL from configuration to establish a virtual CASC filesystem view.
4. **On-Demand Download**: When browsing or searching, only required index and data chunks are downloaded.
5. **Local Cache**: Chunks are cached on disk by `(buildId, encodingKey)`, prioritized on subsequent access.

### 3.3 Data Transfer

- **File Read**: C++ `std::vector<uint8_t>` bridges directly to Swift `Data` with minimal copying.
- **Callbacks**: Long-running operations (extraction, CDN download) report progress via C++ lambda callbacks bridged to Swift closures.

---

## 4. UI Layout

### 4.1 Main Window

Classic three-pane layout with modern macOS styling:

```
┌─────────────────────────────────────────────────────────────┐
│  [Toolbar]  Open Storage ▼  |  Search...  |  Refresh | ⚙️  │
├──────────┬─────────────────────────────┬────────────────────┤
│          │                             │                    │
│  Tree    │       File List             │   Inspector/       │
│ (Sidebar)│   (Sortable Table)          │   Preview Panel    │
│          │                             │                    │
│ 📁 Data  │  Name        │ Size │ Type  │  Name: xxx.blp    │
│   📁 ... │  ─────────────────────────  │  Size: 2.4 MB     │
│   📁 ... │  tex1.blp    │ 1.2M │ BLP   │  Format: BLP2     │
│          │  tex2.blp    │ 800K │ BLP   │  MIPs: 11         │
│          │  model.mdx   │ 3.1M │ MDX   │  [Open Preview]   │
│          │  ...         │      │       │                    │
├──────────┴─────────────────────────────┴────────────────────┤
│  Ready | Files: 1,234 | Selected: 3 | Storage: WoW 10.2.5  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Interaction Details

| Element | Behavior |
|---------|----------|
| **Directory Tree** | `List` + `OutlineGroup` with expand/collapse animations; selection highlight uses system accent color. |
| **File List** | `Table` (macOS 13+) or `NSTableView` wrapper; supports column sorting, multi-selection, right-click context menu. |
| **Search Field** | Integrated in Toolbar via `NSSearchField`; supports real-time filtering and global deep search on Enter. |
| **Preview Panel** | Collapsible inspector (toggle via toolbar button or swipe gesture); shows BLP thumbnail when selected. |
| **Drag & Drop** | Drag files from list to Finder to auto-extract; native macOS drag preview. |
| **QuickLook** | System QuickLook integration (Space key); custom BLP preview extension provided. |

### 4.3 Window Behavior

- Default size: 1200×800, minimum: 900×600.
- Sidebar width resizable and persisted in user preferences.
- Preview panel can be fully collapsed to maximize file list area.

---

## 5. BLP Viewer

### 5.1 Viewer Window

BLP viewer opens as a dedicated modal window on double-click or "Open" action.

```
┌──────────────────────────────────────────┐
│  ← Back  |  texture.blp  |  [Anim] [MIP] │
├──────────────────────────────────────────┤
│                                          │
│           ┌─────────────┐                │
│           │             │                │
│           │  BLP Image  │                │
│           │  (centered) │                │
│           │             │                │
│           └─────────────┘                │
│                                          │
│  ← → Pan  |  Scroll Zoom  |  Double Reset│
├──────────────────────────────────────────┤
│  Format: BLP2 | Size: 512×512 | Frames: 8│
└──────────────────────────────────────────┘
```

### 5.2 Feature Specifications

| Feature | Specification |
|---------|---------------|
| **Basic Viewing** | Render decoded texture via Metal/CoreImage; smooth zoom 10%–1000%. |
| **MIP Map Switching** | Toolbar dropdown selects MIP level (0 = full size); displays available levels only; instant switch. |
| **Animated Textures** | Playback controls: play/pause, frame rate adjustment, step forward/backward, loop toggle. |
| **Transparency** | Checkerboard background for alpha-channel BLPs (standard image viewer convention). |
| **Export** | Export to PNG (preserve alpha) or JPEG. |

### 5.3 Technical Implementation

- **Decode Pipeline**: `BLP file → C++ BLPDecoder → raw pixel data (RGBA) → Swift Data → CIImage → Metal texture`.
- **Animation Frame Buffer**: Preload all frames into memory (BLP animations typically have few frames); drive with `Timer`/`CADisplayLink`.
- **Zoom Interaction**: `NSMagnificationGestureRecognizer` + scroll wheel; Metal rendering ensures fluid performance.

---

## 6. Search & Extraction

### 6.1 Search

| Mode | Description |
|------|-------------|
| **Quick Filter** | Toolbar search field filters current directory in real time (filename match only). |
| **Global Deep Search** | Menu Edit → Find in Storage (⌘⇧F); recursively searches entire CASC storage. |
| **Wildcard Support** | Supports `*` and `?` (e.g., `*.blp`, `interface/*`). |
| **Regex Mode** | Optional regex mode in advanced search panel. |
| **Type Filter** | Search panel sidebar can filter by extension (.blp, .mdx, .mp3, etc.). |

**Implementation:**
- Local: iterate CascLib file list, build in-memory index, then search.
- Online: leverage already-downloaded root index (contains full file list) without downloading actual data.

### 6.2 Extraction

| Interaction | Behavior |
|-------------|----------|
| **Menu Extract** | Select files → File → Extract → choose destination folder. |
| **Context Menu** | Right-click → "Extract...". |
| **Drag to Finder** | Drag selected files to Finder window/desktop; auto-extract to drop location. |
| **Batch Extract** | Multi-select and extract; preserves directory structure automatically. |

**Extraction Options Dialog:**
- Destination path (default: `~/Desktop/casc-extract`)
- Keep directory structure (checked by default)
- Overwrite existing files
- Open destination after extraction

**Technical Details:**
- Background thread execution with progress bar (cancelable).
- Online storage: automatically triggers required CDN chunk downloads.
- Large files: stream to disk to avoid memory spikes.

---

## 7. Error Handling

### 7.1 Error Scenarios

| Scenario | Handling |
|----------|----------|
| Invalid/corrupted CASC storage | Alert: "Unable to open storage. The path may be incorrect or files are corrupted." Expandable detail shows CascLib error code. |
| Online CDN connection failure | Auto-retry 3 times → network error alert with "Retry" and "Switch to Offline Mode" options. |
| CDN chunk download failure | Mark chunk as failed; skip or alert during browse/extract; right-click "Re-download" available. |
| BLP decode failure | Placeholder image + error text in viewer; raw data export still available. |
| Extraction permission denied | Standard macOS permission dialog guiding user to an allowed location. |
| Storage locked by another process | Detect file lock; prompt user to close other programs and retry. |

### 7.2 Error Architecture

- Define `CASCError` Swift enum covering all error cases.
- C++ layer normalizes all errors to `std::expected<T, CascError>`.
- Swift UI layer consumes `Result<T, CASCError>` and presents user-friendly messages.

---

## 8. Testing Strategy

| Test Type | Coverage |
|-----------|----------|
| **C++ Bridge Unit Tests** | XCTest for Swift ↔ C++ data conversion, error propagation, memory safety. |
| **Service Layer Unit Tests** | Mock `ICascStorage`; test search algorithms, extraction logic, path handling without real game files. |
| **UI Tests** | XCUITest for main window layout, search interactions, extraction flows, BLP viewer controls. |
| **Integration Tests** | Minimal test CASC storage committed to repo; validate end-to-end open/browse/extract. |
| **Online CDN Tests** | Marked `flaky`; optional in CI. Primary online testing via local Mock CDN server. |

---

## 9. Read-Only Safety Guarantees

- C++ bridge **exposes only read APIs**; no write/modify functions are wrapped.
- All CascLib invocations use `CASC_OPEN_READ_ONLY` flag explicitly.
- UI contains no edit/delete/rename entry points.
- Code review checklist includes read-only verification for any new C++ bridge additions.

---

## 10. Target Platform

- **macOS 13+** (Ventura or later)
- **Xcode 15+** (required for Swift C++ interoperability)
- **Swift 5.9+**
- **Architecture**: Universal (Intel + Apple Silicon)

---

## 11. Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| CascLib | Latest upstream | CASC storage reading (local) |
| BLP Decoder Lib | C/C++ library (to be selected during implementation) | BLP texture decoding |
| Swift C++ Interop | Swift 5.9+ | Direct C++ bridging |

---

## 12. Open Points (None)

All design decisions have been resolved and approved by the product owner.

---

*Document written after collaborative brainstorming session. Approved for implementation planning.*
