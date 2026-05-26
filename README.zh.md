<h1 align="center">CascViewer</h1>

<p align="center">
  <strong>一款用于浏览暴雪 CASC（内容寻址存储容器）文件系统的原生 macOS 应用程序。</strong>
</p>

<p align="center">
  <a href="#系统要求">
    <img src="https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple" alt="macOS 13.0+">
  </a>
  <a href="#构建">
    <img src="https://img.shields.io/badge/Xcode-15%2B-blue?logo=xcode" alt="Xcode 15+">
  </a>
  <a href="#构建">
    <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift" alt="Swift 5.9+">
  </a>
  <a href="#许可证">
    <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT">
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文
</p>

---

## 💡 项目背景

CascViewer 诞生于一个简单的需求：**macOS 平台上长期缺少一款可视化的 CASC 浏览工具**。Windows 用户多年来一直可以使用 [CascView](https://www.zezula.net/en/casc/main.html)，而 macOS 用户想要查看暴雪游戏资源时，只能依赖命令行工具或通过虚拟机运行 Windows 软件。

本项目旨在填补这一空白，为 macOS 带来原生的、现代化的 CASC 浏览体验。功能设计与工作流程大量参考了 Windows 经典工具 **CascView**（作者：Ladislav Zezula），并以 SwiftUI 和原生 macOS 设计模式重新实现。

## ✨ 功能特性

### 存储浏览
- **本地存储** — 浏览已安装暴雪游戏（魔兽世界、星际争霸 II 等）的 CASC 归档文件
- **在线 CDN 存储** — 无需本地游戏安装即可直连暴雪 CDN，支持自动缓存管理
- **列表文件支持** — 加载自定义列表文件以解析混淆文件名（`FILE########.dat` → 人类可读名称）
- **目录树** — 层级文件夹导航，为未分类文件提供虚拟文件夹

### 高级搜索
- **多模式搜索** — 按文件名、路径或编码密钥搜索
- **范围选择** — 搜索整个存储或限定当前目录
- **正则表达式** — 启用正则表达式进行复杂模式匹配
- **文件类型过滤** — 按文件扩展名或自定义类型模式过滤
- **标签过滤** — 按安装清单标签过滤（适用于支持的游戏）
- **可排序结果** — 按名称、大小或路径升序/降序排序

### 文件操作
- **提取文件** — 导出单个或多个文件，可选保留目录结构
- **进度追踪** — 实时显示提取进度并支持取消
- **复制路径** — 复制完整文件路径到剪贴板

### 图像查看
- **BLP 纹理** — 查看 BLP1/2 纹理，支持 MIP 贴图级别切换
- **DDS 纹理** — 查看 DDS 纹理，支持 DXT1/3/5 解压缩
- **内置查看器** — 可选使用内置查看器或外部应用程序打开

### 安装清单
- **清单浏览器** — 解析并查看安装清单文件，支持标签过滤
- **基于标签的过滤** — 按安装标签（语言、平台等）过滤文件

### 界面与本地化
- **原生 macOS 设计** — 经典三栏布局，现代 SwiftUI 风格
- **深色模式** — 自动跟随系统偏好切换浅色/深色主题
- **多语言** — 支持英文和简体中文
- **可调整面板** — 可调节侧边栏和文件列表/预览分割区

## 🛠 系统要求

- **macOS** 13.0+ (Ventura 或更高版本)
- **Xcode** 15+
- **Swift** 5.9+
- **Git**（需要子模块支持）

## 🚀 构建

### 克隆仓库

```bash
git clone --recursive https://github.com/yourusername/CascViewer.git
cd CascViewer
```

> **注意：** `--recursive` 参数用于获取 [CascLib](https://github.com/ladislav-zezula/CascLib) 子模块。

### 使用 Xcode 构建

```bash
open CascViewer.xcodeproj
```

然后在 Xcode 中选择 **Product → Build** (⌘B)。

### 命令行构建

```bash
xcodebuild -project CascViewer.xcodeproj -scheme CascViewer -destination 'platform=macOS'
```

## 💡 关于代码签名的说明

本软件**未使用 Apple 开发者证书签名**。下载预构建版本后，macOS 可能会提示「无法打开」或「来自身份不明的开发者」。

请在终端执行以下命令移除隔离属性后即可正常使用：

```bash
sudo xattr -r -d com.apple.quarantine /Applications/CascViewer.app
```

## 📖 使用指南

### 打开存储

1. 点击工具栏中的 **"打开存储"**
2. 选择以下方式之一：
   - **本地文件夹** — 选择本地 CASC 目录（例如 `World of Warcraft\_retail_`）
   - **在线 CDN** — 选择游戏产品和区域，通过 CDN 浏览

### 浏览文件

- 使用左侧的**目录树**进行导航
- 在**文件列表**（中间）中查看文件，包含名称、路径、大小、类型和本地可用性等列
- 在**信息面板**（底部）中预览文件详情
- 双击文件夹进入目录

### 搜索

1. 在工具栏搜索框中输入关键词进行快速文件名搜索
2. 或点击 **"高级搜索"** 打开搜索面板：
   - 正则表达式、区分大小写、包含路径选项
   - 文件类型和标签过滤
   - 范围选择（整个存储或当前目录）

### 提取文件

1. 在文件列表中选择一个或多个文件
2. 右键点击并选择 **"提取"**
3. 选择目标文件夹和选项（保留结构、覆盖已有文件）

### 查看图像

- 双击 `.blp` 或 `.dds` 文件打开图像查看器
- 使用 MIP 贴图选择器查看不同纹理分辨率

### 键盘快捷键

| 快捷键 | 操作 |
|--------|------|
| `⌘O` | 打开存储 |
| `⌘R` | 刷新当前存储 |
| `⌘⇧F` | 高级搜索 |
| `⌘⌥I` | 打开安装清单 |
| `⌘[` | 返回上一级 |

## 🏗 架构

```
┌─────────────────────────────────────────────┐
│           SwiftUI 前端层                    │
│  (文件浏览器、搜索、BLP查看器、设置)         │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           Swift 服务层                      │
│  CASCStorageService   CASCSearchService     │
│  CASCExtractService   BLPDecoderCoordinator │
│  CDNProductService                          │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           C++ 桥接层                        │
│  ICascStorage (本地 / 在线)                 │
│  BLPDecoderBridge                           │
└────────────────────┬────────────────────────┘
                     │
┌────────────────────▼────────────────────────┐
│           第三方库                          │
│  CascLib (MIT)     CDN 缓存管理器           │
└─────────────────────────────────────────────┘
```

### 核心组件

- **C++ 桥接层** — 封装 [CascLib](https://github.com/ladislav-zezula/CascLib)，通过统一的 `ICascStorage` 接口同时支持本地和在线存储
- **Swift 服务层** — 存储、搜索、提取和图像解码的业务逻辑
- **SwiftUI 前端** — 原生 macOS 三栏布局 UI，支持 SwiftUI 与 AppKit 互操作以实现高级表格视图

## 🤝 贡献指南

欢迎贡献！请随时提交 Issue 或 Pull Request。

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/新功能`)
3. 提交更改 (`git commit -m 'feat: 添加新功能'`)
4. 推送到分支 (`git push origin feature/新功能`)
5. 创建 Pull Request

## 📄 许可证

本项目基于 **MIT 许可证** 发布。

本项目使用了 Ladislav Zezula 的 [CascLib](https://github.com/ladislav-zezula/CascLib)，同样基于 MIT 许可证。

## 🙏 致谢

- **[CascLib](https://github.com/ladislav-zezula/CascLib)** by Ladislav Zezula — 为本应用提供支持的 CASC 归档库
- **[CascView](https://www.zezula.net/en/casc/main.html)** by Ladislav Zezula — 原始的 Windows CASC 浏览器，本项目的功能设计与工作流程深受其启发
- **暴雪娱乐** — CASC 文件系统规范

## ⚠️ 免责声明

这是一款**只读浏览工具**，不会以任何方式修改暴雪游戏文件。通过本工具访问的所有游戏资源版权归各自版权所有者所有。

## 🤖 关于本项目的代码

本项目采用 **vibe coding（氛围编程 / AI 辅助开发）** 方式构建，使用 [Kimi](https://kimi.moonshot.cn/) 作为 AI 编程助手。尽管我们已尽力确保代码质量，但您仍可能遇到 AI 生成代码中常见的 bug 或粗糙之处。我们恳请您的理解与包容，并热忱欢迎提交 Issue 和贡献代码，共同帮助本项目不断完善。
