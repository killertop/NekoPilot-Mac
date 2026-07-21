# NekoPilot for Mac

<p align="center">
  <img src="./native/Resources/NekoPilotLogo.png" alt="NekoPilot" width="128">
</p>

NekoPilot 是面向 Apple 芯片 Mac 的原生代理客户端。应用壳使用 SwiftUI + AppKit，未经修改的上游 Go 原版 sing-box 是唯一代理核心。

Swift 负责菜单栏、窗口生命周期、睡眠/唤醒、系统代理、持久化和原生交互；Go sing-box 只负责协议、路由、DNS 和 URL Test。项目不会在 Swift 中重新实现代理协议。

## 发布范围

- 只支持 Apple Silicon（`arm64`）。
- 最低 macOS 13。
- 只通过 GitHub Release 分发 ad-hoc 签名包；这条发布路径不要求 Apple Developer ID 和公证。
- 不构建、不发布 Windows、Linux 或 Intel macOS 软件包。

仓库不再保留 Rust、Tauri、React 或跨平台应用实现；Git 历史仍可用于追溯旧版本。

## 产品范围

- 导入、更新机场订阅。
- 导入 `vless://`、`trojan://`、`vmess://`、`ss://` 和 `anytls://` 单节点。
- 所有节点统一显示在一个按延迟排序的列表中。
- 未连接和已连接状态都能手动执行 URL Test，并保留历史延迟结果。
- 通过系统代理模式连接到用户选择的节点。
- 自定义直连/代理规则，以及内置的中国网络和局域网直连规则。
- 单一原生菜单栏图标，并区分运行和停止状态。

## 技术架构

- Swift 6、SwiftUI、AppKit：原生应用。
- Go 原版 sing-box：协议、路由、DNS、URL Test。
- SQLite：本地数据。
- Shell 与 GitHub Actions：可复现的 Apple Silicon 构建和打包。

## 开发

环境要求：Apple 芯片 Mac、macOS 13+、Xcode 26.2、Go 1.26.5、GitHub CLI。

```bash
native/scripts/build-sing-box-macos-arm64.sh
NEKOPILOT_SING_BOX="$PWD/native/.build/sidecar/sing-box" \
  swift run --package-path native NekoPilot
```

运行原生检查：

```bash
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
```

构建并验证真实 `.app`、DMG、压缩包、签名、架构、资源和最低系统版本：

```bash
native/scripts/package-macos.sh
```

产物位于 `native/dist/`。打包脚本会复制固定的菜单栏模板图标、离线规则基线和从固定上游源码构建的 sing-box，然后执行 ad-hoc 签名。

## 目录

```text
native/Sources/NekoPilot/       SwiftUI/AppKit 应用壳
native/Sources/NekoPilotCore/   生命周期、持久化、配置编译和核心进程管理
native/Resources/               macOS 应用与菜单栏原始资源
native/scripts/                 sing-box 固定源码构建和 macOS 打包验证
.github/workflows/              原生 Apple Silicon 测试与发布
docs/                           开发与发布文档
```

更多信息见 [架构说明](docs/ARCHITECTURE.md)、[英文说明](README.md)、[开发指南](docs/DEVELOPMENT.md) 和 [发布指南](docs/RELEASE.md)。源码通过发布文档说明的 VPS 裸仓库同步到 [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac)。许可证见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
