# CascViewer for macOS

A native macOS application for browsing Blizzard CASC (Content Addressable Storage Container) file systems.

English | [简体中文](README.zh.md)

## Features

- **Browse local CASC storage** from installed Blizzard games
- **Browse online CDN storage** without local installation
- **File search** with wildcard and regex support
- **Extract files** with directory structure preservation
- **Advanced image viewer** for BLP (War3/WoW) and DDS (SC2) textures with MIP map switching and animation playback

## Requirements

- macOS 13.0+ (Ventura or later)
- Xcode 15+
- Swift 5.9+

## Building

```bash
git clone --recursive <repo-url>
cd CascViewer
open CascViewer.xcodeproj
```

Or build from command line:
```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -destination 'platform=macOS'
```

## Usage

1. Click **"Open Storage"** to browse a local CASC folder or connect to online CDN
2. Navigate files using the **directory tree** (left) and **file list** (center)
3. **Search** files using the toolbar search or open the Search panel
4. **Double-click BLP files** to open the image viewer
5. **Drag files to Finder** or use **Extract** to export files

## Architecture

```
SwiftUI Views ← Swift Services ← C++ Bridge ← CascLib
                                    ↓
                              CDN Cache Manager
                                    ↓
                              BLP Decoder
```

- **C++ Bridge Layer**: Wraps CascLib with a unified `ICascStorage` interface for local and online storage
- **Swift Service Layer**: `CASCStorageService`, `CASCSearchService`, `CASCExtractService`, `BLPDecoderCoordinator`
- **SwiftUI Frontend**: Classic three-pane layout with modern macOS styling

## Known Limitations

- **Online CDN browsing**: The CDN configuration download and cache management are implemented, but full online storage browsing requires additional CASC root file parsing. This is planned for a future update.
- **Image formats**: BLP2 raw and DDS DXT1/3/5 textures are supported. BLP1 and BLP2 JPEG-compressed textures are not yet supported.

## Important Notes

- **Read-only**: This tool does not modify CASC storage in any way
- **Online CDN**: Downloads and caches game data chunks on-demand
- **Image Viewer**: Supports BLP2 raw and DDS DXT1/3/5 textures. BLP1 and BLP2 JPEG-compressed textures are not yet supported.

## License

This is a read-only browsing tool. It does not modify Blizzard game files.
