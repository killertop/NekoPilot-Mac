# NekoPilot for Mac / NekoPilot Mac 原生代理客户端

<p align="center">
  <a href="https://nekopilot-official.sturdy-joy-3290.chatgpt.site">
    <img src="./native/Resources/NekoPilotLogo.png" alt="NekoPilot" width="128">
  </a>
</p>

<p align="center">
  <a href="https://nekopilot-official.sturdy-joy-3290.chatgpt.site"><strong>官方网站 / Official Website</strong></a>
  ·
  <a href="https://github.com/killertop/NekoPilot-Mac/releases"><strong>下载 / Download</strong></a>
</p>

NekoPilot 是面向 Apple 芯片 Mac 的原生代理客户端；应用壳使用 SwiftUI + AppKit，未经修改的上游 Go 原版 sing-box 是唯一代理核心。<br>
NekoPilot is a native proxy client for Apple Silicon Macs. Its application shell uses SwiftUI + AppKit, and the unmodified upstream Go sing-box executable is its only proxy engine.

Swift 负责菜单栏、窗口生命周期、睡眠/唤醒、系统代理、持久化和原生交互；Go sing-box 负责协议、路由、DNS 与测速。项目不会在 Swift 中重新实现代理协议。<br>
Swift owns the menu bar, window lifecycle, sleep/wake handling, system proxy, persistence, and native interaction. Go sing-box owns protocols, routing, DNS, and URL Test. NekoPilot does not reimplement proxy protocols in Swift.

## 发布范围 / Release scope

- 仅支持 Apple Silicon（`arm64`）/ Apple Silicon (`arm64`) only.
- 需要 macOS 13 或更高版本 / Requires macOS 13 or newer.
- 通过 GitHub Releases 分发 ad-hoc 签名包；此分发路径不要求 Apple Developer ID 或公证 / GitHub Releases distribute ad-hoc signed packages; this path does not require Apple Developer ID or notarization.
- 不构建或发布 Windows、Linux、Intel macOS 软件包 / No Windows, Linux, or Intel macOS packages are built or published.

仓库不再包含 Rust、Tauri、React 或跨平台应用实现；Git 历史仍可用于追溯旧版本。<br>
The repository no longer contains Rust, Tauri, React, or cross-platform application code; Git history remains available for older-version research.

## 功能 / Features

- 导入并更新机场订阅 / Import and update subscriptions.
- 导入 `vless://`、`trojan://`、`vmess://`、`ss://` 与 `anytls://` 单节点链接 / Import standalone `vless://`, `trojan://`, `vmess://`, `ss://`, and `anytls://` links.
- 在一个按延迟排序的列表中展示全部节点 / Present every imported node in one delay-sorted list.
- 在连接前或连接中手动测速，并保留历史延迟结果 / Run manual URL Test while disconnected or connected, with persisted historical delay results.
- 通过系统代理模式连接到所选节点 / Connect to the selected node through System Proxy mode.
- 支持自定义直连/代理规则，以及内置的中国网络和局域网直连规则 / Support custom direct/proxy rules plus bundled China and LAN direct rules.
- 单一原生菜单栏图标，区分运行与停止状态 / A single native menu-bar item with distinct running and stopped states.

## 技术架构 / Technology

- Swift 6、SwiftUI 与 AppKit：原生应用壳 / Swift 6, SwiftUI, and AppKit: native application shell.
- 上游 Go 原版 sing-box：协议、路由、DNS 与测速；Swift 通过官方 1.14 gRPC API 直接通信 / Original upstream Go sing-box: protocols, routing, DNS, and URL Test; Swift communicates directly through its official 1.14 gRPC API.
- SQLite：本地数据 / SQLite: local data.
- Shell 与 GitHub Actions：可复现的 Apple Silicon 打包 / Shell and GitHub Actions: reproducible Apple Silicon packaging.

## 开发 / Development

环境要求：Apple 芯片 Mac、macOS 13+、Xcode 26.2、Go 1.26.5 与 GitHub CLI。<br>
Requirements: an Apple Silicon Mac, macOS 13+, Xcode 26.2, Go 1.26.5, and GitHub CLI.

```bash
native/scripts/build-sing-box-macos-arm64.sh
NEKOPILOT_SING_BOX="$PWD/native/.build/sidecar/sing-box" \
  swift run --package-path native NekoPilot
```

运行原生检查 / Run native checks:

```bash
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
```

构建并验证实际 `.app`、DMG、压缩包、签名、架构、资源和最低系统版本 / Build and verify the actual application, DMG, archive, signature, architecture, resources, and minimum macOS version:

```bash
native/scripts/package-macos.sh
```

产物位于 `native/dist/`。打包脚本会复制固定的菜单栏模板图标、离线规则基线和从固定上游源码构建的 sing-box，然后执行 ad-hoc 签名。<br>
Artifacts are written to `native/dist/`. The package script copies the pinned menu-bar template, offline rule baseline, and source-built sing-box into the app before ad-hoc signing it.

## 目录 / Project layout

```text
native/Sources/NekoPilot/       SwiftUI/AppKit 应用壳 / application shell
native/Sources/NekoPilotCore/   生命周期、持久化、配置编译和核心进程管理 / lifecycle, persistence, compiler, engine supervision
native/Resources/               macOS 应用与菜单栏资源 / macOS app and menu-bar artwork
native/scripts/                 固定 sing-box 构建与 macOS 打包校验 / pinned sing-box build and package verification
.github/workflows/              Apple Silicon 测试与发布 / Apple Silicon tests and release
docs/                           开发与发布文档 / development and release guides
```

更多信息 / More information: [官方网站 / Official Website](https://nekopilot-official.sturdy-joy-3290.chatgpt.site)、[架构说明 / Architecture](docs/ARCHITECTURE.md)、[中文说明 / Chinese README](README_CN.md)、[开发指南 / Development Guide](docs/DEVELOPMENT.md)、[发布指南 / Release Guide](docs/RELEASE.md)。

源码通过发布指南说明的 VPS 裸仓库同步；维护仓库为 [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac)。许可证见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。<br>
Source publication is routed through the VPS bare repository described in the release guide. The maintained repository is [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac). See [LICENSE](LICENSE) and [NOTICE](NOTICE).
