# Changelog

本文件记录 NekoPilot for Mac 的用户可见变化。开发中的变更先记录在当前版本的 Unreleased 区域，发布时再整理为正式版本。 / This file records user-visible NekoPilot for Mac changes. Work in progress stays under Unreleased until it is prepared as a formal version.

## Unreleased

## 1.4.0 - 2026-07-22

### 界面 / Interface

- 全部页面和长内容弹窗统一使用 macOS 原生小号覆盖式滚动条：滚动时自然出现、空闲时淡出，不再保留粗重轨道或挤占内容宽度，同时保留系统滚动惯性、对比度和辅助功能。 / All pages and long-content sheets now use the native macOS small overlay scroller, which appears while scrolling, fades when idle, and no longer reserves a heavy gutter, while retaining system momentum, contrast, and accessibility behavior.

## 1.3.9 - 2026-07-22

### 菜单栏 / Menu Bar

- 依据未连接状态的新截图独立校正盾牌主体：其光学中心再下移 `1pt`，消除状态点曾掩盖的上偏；状态标记保持原位，避免连接状态整体偏低。 / Independently corrected the shield from a new disconnected-state screenshot: its optical center moves down another 1pt to remove the upward bias previously masked by the status badge, while the badge stays in place to avoid pulling connected states too low.

## 1.3.8 - 2026-07-22

### 菜单栏 / Menu Bar

- 按实际菜单栏截图校正图标光学重心：保持 `18×18pt` 画布、`16pt` 主体和状态标记尺寸不变，将完整图形下移 `0.5pt`，使其与系统及其他应用图标的视觉基线一致。 / Corrected the menu-bar icon's optical alignment from an actual screenshot: the 18×18pt canvas, 16pt mark, and status badge sizes remain unchanged while the complete composition moves down 0.5pt to align visually with system and other app icons.

## 1.3.7 - 2026-07-22

### 菜单栏 / Menu Bar

- 菜单栏图标改为居中的 `18×18pt` 原生自适应模板，主体收至 `16pt`；移除导致深色菜单栏主体变黑的彩色状态点，改用随系统前景色变化的实心点、空心点和叉号表达运行、处理中与失败状态。 / Rebuilt the menu-bar icon as a centered 18×18pt adaptive template with a 16pt brand mark. Replaced the colored badge that rendered the mark black on dark menu bars with system-tinted filled, ring, and cross badges for running, busy, and failed states.

## 1.3.6 - 2026-07-22

### 自动选择 / Automatic Selection

- “自动选择节点”开启时不再因手动点选而锁定本次连接；手动选择可以立即生效，但周期评估和并发请求始终由稳定的自动策略优先。关闭开关后，进行中的自动请求会被撤销，手动选择立即恢复最高优先级。 / Manual taps no longer lock an active connection while Automatic Node Selection is enabled: they can apply immediately, but the stable periodic policy and concurrent automatic requests remain authoritative. Disabling the switch revokes in-flight automatic work and restores manual priority immediately.

## 1.3.5 - 2026-07-22

### 菜单栏 / Menu Bar

- 修复 AppKit 自动重新启用“复制代理环境变量”的问题；仅在代理已连接时可点击，未连接、连接中、断开中和失败状态均保持置灰。 / Prevented AppKit from automatically re-enabling Copy Proxy Environment; it is now available only while the proxy is running and remains disabled in all other states.

## 1.3.4 - 2026-07-22

### 界面 / Interface

- 设置页所有备注文案改为完整换行显示，行高随内容增长；自动选择节点、局域网、协议类型、系统代理与 User Agent 等说明不再出现省略号。 / Settings descriptions now wrap without truncation and rows grow with their content, including automatic selection, LAN, protocol, system-proxy, and User Agent details.

## 1.3.3 - 2026-07-22

### 界面 / Interface

- 首页连接按钮整体缩小约 10%，并同步调整电源符号、圆角、阴影与运行光晕，使首屏视觉重心更轻，同时保留充足的点击区域。 / Reduced the Home connection control by about 10% and proportionally refined its symbol, corners, shadow, and active glow while preserving a generous hit target.

## 1.3.2 - 2026-07-22

### 稳定性与数据一致性 / Reliability and data consistency

- 修复并发刷新、节点切换持久化、规则热重载失败回滚和系统代理残留时的状态错位。 / Fixed stale concurrent refreshes, node-selection persistence races, routing-rule reload rollback, and inconsistent system-proxy recovery.
- 连接启动阶段现在可主动取消；核心异常退出和系统代理恢复失败会显示真实状态，不再长期停留在“正在连接”。 / Connecting can now be cancelled, and unexpected core exits or proxy-restore failures surface their real state instead of remaining stuck on Connecting.
- 关闭控制窗口不再终止正在运行的代理；只有明确退出才清理核心、系统代理和菜单栏资源。 / Closing the control window now keeps the proxy alive; explicit Quit owns full core, system-proxy, and menu-bar cleanup.
- 自定义直连/代理域名同时应用到 DNS 与流量路由，保持自定义直连、自定义代理、中国规则集的优先级一致。 / Custom direct/proxy domains now affect both DNS and traffic routing with consistent priority over the China rule sets.

### 性能与安全 / Performance and security

- 显式测速继续在后台并分批并发执行，结果逐步排序并持久化；规则列表避免重复排序计算。 / Explicit URL Test continues in the background with bounded parallel workers, progressive persisted results, and no repeated rule-list sorting.
- 持久日志统一脱敏代理链接、订阅 Token、密码、授权头与 UUID，并增加回归测试。 / Persistent logs now redact proxy links, subscription tokens, passwords, authorization headers, and UUIDs, with regression coverage.
- 移除未使用的 gVisor 构建标签，同时保留 DHCP、QUIC、uTLS 与 macOS 必需能力，缩小正式核心和安装包。 / Removed the unused gVisor build tag while retaining DHCP, QUIC, uTLS, and required macOS capabilities to reduce the release core and package size.

### 界面与工程 / Interface and engineering

- 测速停止、危险删除、弹窗尺寸、滚动提示、每分钟时间刷新、初始焦点、VoiceOver 与菜单栏反馈统一为原生交互。 / Speed-test stopping, destructive confirmations, sheet sizing, scroll indicators, minute refreshes, initial focus, VoiceOver, and menu-bar feedback now follow one native interaction model.
- 核心错误补齐中英文文案，版本解析避免超大数字崩溃，公共 Swift 依赖经 GitHub Advisory Database 检查无已知匹配公告。 / Core errors are bilingual, version parsing no longer crashes on oversized numbers, and public Swift dependencies have no matching GitHub Advisory Database entries.

## 1.2.4 - 2026-07-21

### 界面

- 建立全局字体层级并覆盖首页、节点、规则、设置与全部弹窗：页面标题、行标题、正文、辅助文字、说明、协议标签和等宽信息不再各自定义字号或字重。
- 统一节点名称与设置项为 15pt 常规字重，减少过重标题感，同时提高正文与辅助信息的一致性和可读性。

## 1.2.3 - 2026-07-21

### 工程清理

- 删除已废弃的测速 URL 常量；测速统一由 sing-box 原生 API 管理。

## 1.2.2 - 2026-07-21

### 界面

- 修复添加节点、规则和设置弹窗的实际渲染宽度；在最小主窗口下保留明确左右留白，不再超过主窗口可用宽度。

## 1.2.1 - 2026-07-21

### 稳定性与安全

- 修复运行中热重载丢失 sing-box 原生 API 会话的问题，规则修改与规则集更新后保持可控状态。
- 中国 IP/域名规则集改为完整代际切换：离线基线、7 天检查、失败后 1 小时重试、Git 提交与 blob 摘要校验，以及原子激活。
- 修复 Apple Silicon 核心的可复现构建校验：保留 macOS 必需的 Mach-O 元数据，同时精确排除 CGO 链接器生成的非语义差异。
- 默认正式校验包含 sing-box 引擎启动与热重载冒烟测试，避免仅靠配置语法检查放行。

## 1.0.7 - 2026-07-21

### 节点与连接体验

- 首页统一展示全部机场与本地节点，保留 URL Test 历史延迟并按结果排序。
- 修复配置与节点来源错位、切换刷新迟缓和自动选择节点后的首页状态不同步。
- 导入成功后自动关闭完成弹窗，完善未连接状态下的节点测速体验。

### 界面与交互

- 统一页面间距、卡片、列表行、主题颜色、对话框和进度反馈组件。
- 完善弹窗焦点恢复、键盘操作、VoiceOver 语义和深色模式一致性。
- 统一底部导航为“首页、节点、规则、设置”，清理无效入口与废弃界面代码。

### 稳定性与工程

- 修复代理端口保存重复提交、弹窗处理中误关闭和重复初始化风险。
- 增加 UI 规范防回退检查，并接入本地提交、正式构建与 GitHub CI。
- 完善代理核心启动、热重载、退出、订阅导入、数据库迁移与真实安装包生命周期验证。

> macOS 安装包使用 ad-hoc 签名，不包含 Apple 公证；请以 GitHub Release 页面中的安装包和验收记录为准。
