# CascViewer for macOS

一款用于浏览暴雪 CASC（内容寻址存储容器）文件系统的原生 macOS 应用程序。

[English](README.md) | 简体中文

## 功能特性

- **浏览本地 CASC 存储** — 从已安装的暴雪游戏中浏览本地文件
- **浏览在线 CDN 存储** — 无需本地安装即可连接在线 CDN
- **文件搜索** — 支持通配符和正则表达式搜索
- **文件提取** — 支持保留目录结构批量导出
- **高级 BLP 图片查看器** — 支持 MIP 贴图切换和动画播放

## 系统要求

- macOS 13.0+ (Ventura 或更高版本)
- Xcode 15+
- Swift 5.9+

## 构建

```bash
git clone --recursive <仓库地址>
cd CascViewer
open CascViewer.xcodeproj
```

或通过命令行构建：
```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -destination 'platform=macOS'
```

## 使用指南

1. 点击 **"打开存储"** 浏览本地 CASC 文件夹或连接在线 CDN
2. 使用左侧的**目录树**和中间的**文件列表**浏览文件
3. 使用工具栏搜索框或打开搜索面板进行**文件搜索**
4. **双击 BLP 文件**打开图片查看器
5. **拖拽文件到 Finder** 或使用**提取**功能导出文件

## 架构

```
SwiftUI 视图层 ← Swift 服务层 ← C++ 桥接层 ← CascLib
                                      ↓
                                CDN 缓存管理器
                                      ↓
                                BLP 解码器
```

- **C++ 桥接层**：通过统一的 `ICascStorage` 接口封装 CascLib，同时支持本地和在线存储
- **Swift 服务层**：`CASCStorageService`、`CASCSearchService`、`CASCExtractService`、`BLPDecoderCoordinator`
- **SwiftUI 前端**：经典三栏布局，现代 macOS 风格

## 已知限制

- **在线 CDN 浏览**：CDN 配置下载和缓存管理已实现，但完整的在线存储浏览需要额外的 CASC 根文件解析功能。计划在后续更新中实现。
- **BLP DXTC 纹理**：支持 BLP2 原始/未压缩纹理。DXTC 压缩纹理需要额外的解码库。

## 注意事项

- **只读工具**：本工具不会以任何方式修改 CASC 存储
- **在线 CDN**：按需下载和缓存游戏数据分块
- **BLP 查看器**：支持 BLP2 未压缩纹理；DXTC 压缩纹理需要额外的解码器库

## 许可证

这是一个只读浏览工具，不会修改暴雪游戏文件。
