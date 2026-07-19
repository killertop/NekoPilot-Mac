# NekoPilot for Mac

<p align="center">
  <img src="./src/assets/nekopilot-logo.png" alt="NekoPilot" width="128">
</p>

NekoPilot for Mac 是一款以 macOS 为主要目标的桌面代理客户端，基于 Tauri、React、TypeScript、Rust 和 sing-box 构建。产品重点是清晰、可控的日常代理流程：导入订阅或单节点链接，选择节点，连接到指定节点，并查看实际连接结果。

> 当前仓库仍在持续开发。当前本地 Release 包适合开发和 QA；正式分发包必须通过带签名的发布流水线生成，详见 [docs/RELEASE.md](docs/RELEASE.md)。

## 当前范围

- 订阅导入、更新、删除和订阅元信息展示。
- 支持 `vless://`、`trojan://`、`vmess://`、`ss://`、`anytls://` 单节点链接。
- 明确的分组和节点选择；不会自动替用户切换节点。
- 基于内置 sing-box 进程的系统代理模式。
- Rule 和 Global 路由模式。
- 持久化显示 connecting、connected、testing、failed 及失败原因等连接状态。
- macOS 深链 Scheme：`nekopilot://`。

当前产品验收目标是 macOS。Windows 和 Linux 配置仍保留在 Tauri 基线中，但不是本仓库当前的主要验收平台。

## 技术栈

- Tauri 2
- React 19、TypeScript
- Rust 2021
- Deno 2
- Vite、Vitest
- sing-box

## 环境要求

- macOS 10.15 或更高版本。
- Deno 2.x。
- Rust stable 工具链和 Cargo。
- Xcode Command Line Tools。

安装前端依赖并准备本地 hooks：

```bash
deno install
deno task prepare
```

## 开发运行

启动 Tauri 开发应用：

```bash
deno task tauri dev
```

开发命令会启动 Vite 前端和 Rust 后端，并启用开发诊断能力。它用于日常开发，不等同于最终分发包验收。

## 测试与构建

运行前端单元测试：

```bash
deno task test
```

运行 Rust 库测试：

```bash
cargo test --manifest-path src-tauri/Cargo.toml --lib
```

运行生产前端构建：

```bash
deno task build
```

构建本地 Release 应用和 macOS 包：

```bash
deno task tauri build
```

本地产物位于 `src-tauri/target/release/bundle/` 下。本地构建可能是 adhoc 签名；正式签名和公证流程见 [docs/RELEASE.md](docs/RELEASE.md)。

## 目录结构

```text
src/                 React 界面、状态、配置和前端测试
src-tauri/src/       Rust commands、数据库、引擎和生命周期代码
src-tauri/            Tauri 配置、图标、资源和 Cargo workspace
scripts/              构建、二进制下载和模板同步脚本
docs/                 开发、发布、审计和实现说明
```

## 文档

- [English README](README.md)
- [开发指南](docs/DEVELOPMENT.md)
- [发布指南](docs/RELEASE.md)
- [安全说明](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

源码发布默认经由 VPS 裸仓库，再由 VPS 推送到项目自己的 GitHub 仓库，转推钩子是 [scripts/post-receive-github-sync.sh](scripts/post-receive-github-sync.sh)。

## 许可证与来源声明

本仓库由 [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac) 维护。仓库保留 Apache-2.0 `LICENSE` 和 `NOTICE` 文件，以满足源代码归属与许可证要求。NekoPilot for Mac 使用独立的产品名称、图标、Bundle ID 和用户界面品牌。具体适用范围请查看 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
