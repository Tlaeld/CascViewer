<h1 align="center">CascViewer</h1>

<p align="center">
  <strong>A native macOS application for browsing Blizzard CASC (Content Addressable Storage Container) file systems.</strong>
</p>

<p align="center">
  <a href="#requirements">
    <img src="https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple" alt="macOS 13.0+">
  </a>
  <a href="#building">
    <img src="https://img.shields.io/badge/Xcode-15%2B-blue?logo=xcode" alt="Xcode 15+">
  </a>
  <a href="#building">
    <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift" alt="Swift 5.9+">
  </a>
  <a href="#license">
    <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT">
  </a>
</p>

<p align="center">
  English | <a href="README.zh.md">简体中文</a>
</p>

---

## 💡 Background

CascViewer was born out of a simple need: **there was no visual CASC browsing tool available for macOS**. While Windows users have had [CascView](https://www.zezula.net/en/casc/main.html) for years, macOS users who wanted to peek into Blizzard game assets were left with command-line tools or running Windows software through virtualization.

This project aims to fill that gap by bringing a native, modern macOS experience to CASC browsing. Feature design and workflow are heavily inspired by the Windows classic **CascView** by Ladislav Zezula, reimagined with SwiftUI and native macOS patterns.

## ✨ Features

### Storage Browsing
- **Local Storage** — Browse CASC archives from installed Blizzard games (WoW, SC2, etc.)
- **Online CDN Storage** — Connect directly to Blizzard CDN without local game installation, with automatic cache management
- **Listfile Support** — Load custom listfiles to resolve obfuscated filenames (`FILE########.dat` → human-readable names)
- **Directory Tree** — Hierarchical folder navigation with virtual folders for uncategorized files

### Advanced Search
- **Multi-mode Search** — Search by filename, path, or encoding key
- **Scope Selection** — Search entire storage or limit to current directory
- **Regex Support** — Enable regular expressions for complex patterns
- **File Type Filtering** — Filter by file extension or custom type patterns
- **Tag Filtering** — Filter by install manifest tags (for supported games)
- **Sortable Results** — Sort by name, size, or path with ascending/descending order

### File Operations
- **Extract Files** — Export single or multiple files with optional directory structure preservation
- **Progress Tracking** — Real-time extraction progress with cancel support
- **Path Copying** — Copy full file paths to clipboard

### Image Viewing
- **BLP Textures** — View BLP1/2 textures with MIP map level switching
- **DDS Textures** — View DDS textures with DXT1/3/5 decompression
- **Built-in Viewer** — Optional built-in viewer or external application opening

### Install Manifest
- **Manifest Browser** — Parse and view install manifest files with tag filtering
- **Tag-based Filtering** — Filter files by install tags (locale, platform, etc.)

### UI & Localization
- **Native macOS Design** — Classic three-pane layout with modern SwiftUI styling
- **Dark Mode Support** — Automatic light/dark theme following system preferences
- **Multi-language** — English and Simplified Chinese (简体中文) support
- **Resizable Panes** — Adjustable sidebar and file list/preview divider

## 🛠 Requirements

- **macOS** 13.0+ (Ventura or later)
- **Xcode** 15+
- **Swift** 5.9+
- **Git** (with submodule support)

## 🚀 Building

### Clone the repository

```bash
git clone --recursive https://github.com/yourusername/CascViewer.git
cd CascViewer
```

> **Note:** The `--recursive` flag is required to fetch the [CascLib](https://github.com/ladislav-zezula/CascLib) submodule.

### Build with Xcode

```bash
open CascViewer.xcodeproj
```

Then select **Product → Build** (⌘B) in Xcode.

### Build from command line

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -destination 'platform=macOS'
```

## 📖 Usage

### Opening a Storage

1. Click **"Open Storage"** (打开存储) in the toolbar
2. Choose one of:
   - **Local Folder** — Select a local CASC directory (e.g., `World of Warcraft\_retail_`)
   - **Online CDN** — Select a game product and region to browse via CDN

### Browsing Files

- Navigate using the **directory tree** on the left
- View files in the **file list** (center) with columns for name, path, size, type, and local availability
- Preview file details in the **info panel** (bottom)
- Double-click folders to navigate into them

### Searching

1. Type in the toolbar search box for quick filename search
2. Or click **"Advanced Search"** (高级搜索) to open the search panel with:
   - Regex, case sensitivity, and path inclusion options
   - File type and tag filters
   - Scope selection (entire storage or current directory)

### Extracting Files

1. Select one or more files in the file list
2. Right-click and choose **"Extract"** (提取)
3. Choose destination folder and options (preserve structure, overwrite)

### Viewing Images

- Double-click `.blp` or `.dds` files to open the image viewer
- Use MIP map selector to view different texture resolutions

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open Storage |
| `⌘R` | Refresh Current Storage |
| `⌘⇧F` | Advanced Search |
| `⌘⌥I` | Open Install Manifest |
| `⌘[` | Navigate Back |

## 🏗 Architecture

```
┌─────────────────────────────────────────────┐
│           SwiftUI Frontend Layer            │
│  (FileBrowser, Search, BLPViewer, Settings) │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           Swift Service Layer               │
│  CASCStorageService   CASCSearchService     │
│  CASCExtractService   BLPDecoderCoordinator │
│  CDNProductService                        │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           C++ Bridge Layer                  │
│  ICascStorage (Local / Online)              │
│  BLPDecoderBridge                           │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           Third-Party Libraries             │
│  CascLib (MIT)     CDN Cache Manager        │
└─────────────────────────────────────────────┘
```

### Key Components

- **C++ Bridge Layer** — Wraps [CascLib](https://github.com/ladislav-zezula/CascLib) with a unified `ICascStorage` interface supporting both local and online storage
- **Swift Service Layer** — Business logic for storage, search, extraction, and image decoding
- **SwiftUI Frontend** — Native macOS UI with three-pane layout, supporting both SwiftUI and AppKit interop for advanced table views

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is released under the **MIT License**.

The project uses [CascLib](https://github.com/ladislav-zezula/CascLib) by Ladislav Zezula, which is also licensed under the MIT License.

## 🙏 Acknowledgments

- **[CascLib](https://github.com/ladislav-zezula/CascLib)** by Ladislav Zezula — The CASC archive library that powers this application
- **[CascView](https://www.zezula.net/en/casc/main.html)** by Ladislav Zezula — The original Windows CASC browser that inspired this project's feature set and workflow
- **Blizzard Entertainment** — For the CASC file system specification

## ⚠️ Disclaimer

This is a **read-only browsing tool**. It does not modify Blizzard game files in any way. All game assets accessed through this tool remain the property of their respective copyright holders.

## 🤖 About the Code

This project was built with **vibe coding** — AI-assisted development using [Kimi](https://kimi.moonshot.cn/). While every effort has been made to ensure quality, you may encounter bugs or rough edges typical of AI-generated code. We appreciate your understanding and patience, and warmly welcome bug reports and contributions to help improve the project.
