# Contributing to NekoPilot for Mac

感谢你参与 NekoPilot for Mac。请先阅读本文件和 [开发指南](docs/DEVELOPMENT.md)，再提交 Issue 或 Pull Request。

## 贡献范围

优先接受：

- 稳定性和可靠性改进。
- 订阅、节点选择、连接状态和路由流程的 Bug 修复。
- 可复现、可测试的性能和用户体验改进。
- 不改变 sing-box 内核的集成改进。

新功能建议先通过 Issue 讨论，确认产品方向后再开始实现。涉及代理行为、系统代理、权限、网络路由或数据迁移的改动，应同时说明影响范围和回滚方式。

## 开发约定

- 保持用户选择优先；不要在后台自动替用户切换节点。
- 本地单节点与远程订阅属于不同生命周期，不要把本地链接当成可更新订阅。
- UI 状态应反映真实执行阶段，而不是只显示按钮动画。
- 纯函数、解析器、状态机和配置合并逻辑应优先补充单元测试。
- 不要提交订阅 URL、私钥、API Token、个人日志或真实用户配置。

## 提交前检查

```bash
git diff --check
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
NEKOPILOT_VERIFY_REPRODUCIBLE=1 native/scripts/build-sing-box-macos-arm64.sh
native/scripts/package-macos.sh
```

涉及 SwiftUI/AppKit、macOS 系统代理、sing-box 生命周期或打包资源时，还应在 Apple Silicon Mac 上运行一次实际 `.app`，并记录测试环境、版本和复现步骤。只通过编译、检查或签名验证不能替代真实网络与系统行为验收。旧 Tauri 代码仅用于回滚和对照，不接受新的正式功能实现。

## Pull Request 要求

请在 PR 描述中包含：

1. 变更目的和用户可见影响。
2. 影响的平台、配置迁移和权限边界。
3. 测试命令及结果。
4. 如有 UI 变化，附上截图或录屏。
5. 如有已知限制，明确写出，不要用“后续处理”代替限制说明。

## 许可证

提交代码即表示你同意该贡献按仓库现有许可证和 NOTICE 条款发布。请不要提交无法确认授权来源的第三方代码、图标或配置。
