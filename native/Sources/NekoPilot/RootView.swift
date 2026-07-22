import SwiftUI

struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch model.selectedTab {
                    case .home: HomeView(model: model)
                    case .nodes: NodeManagementView(model: model)
                    case .rules: RulesView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                AppDivider(leading: 0)
                HStack(spacing: 0) {
                    tabButton(.home, icon: "house", selectedIcon: "house.fill", title: L10n.home)
                    tabButton(.nodes, icon: "square.stack.3d.up", selectedIcon: "square.stack.3d.up.fill", title: L10n.nodes)
                    tabButton(.rules, icon: "arrow.triangle.branch", selectedIcon: "arrow.triangle.branch", title: L10n.rules)
                    tabButton(.settings, icon: "gearshape", selectedIcon: "gearshape.fill", title: L10n.settings)
                }
                .frame(height: AppVisual.tabBarHeight)
                .background(AppVisual.background(colorScheme))
            }
        }
        .frame(
            minWidth: 360,
            idealWidth: 371,
            maxWidth: 520,
            minHeight: 560,
            idealHeight: 600,
            maxHeight: 760
        )
        .alert(
            L10n.text("操作失败", "Operation Failed"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("知道了", "OK"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            model.pendingDeepLink?.shouldConnect == true
                ? L10n.text("导入并连接？", "Import and Connect?")
                : L10n.text("导入外部配置？", "Import External Configuration?"),
            isPresented: Binding(
                get: { model.pendingDeepLink != nil },
                set: { presented in
                    if !presented, model.pendingDeepLink != nil { model.cancelDeepLink() }
                }
            )
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                model.cancelDeepLink()
            }
            Button(
                model.pendingDeepLink?.shouldConnect == true
                    ? L10n.text("导入并连接", "Import and Connect")
                    : L10n.text("导入", "Import")
            ) {
                model.confirmDeepLink()
            }
        } message: {
            Text(
                model.pendingDeepLink?.shouldConnect == true
                    ? L10n.text(
                        "此配置来自外部链接。继续后会导入节点并立即连接；请仅接受可信来源。",
                        "This configuration came from an external link. Continuing imports it and connects immediately. Only accept trusted sources."
                    )
                    : L10n.text(
                        "此配置来自外部链接。请仅导入你信任的节点来源。",
                        "This configuration came from an external link. Only import node sources you trust."
                    )
            )
        }
        .alert(
            L10n.text("允许局域网连接？", "Allow LAN Connections?"),
            isPresented: Binding(
                get: { model.pendingLANEnable },
                set: { presented in
                    if !presented, model.pendingLANEnable { model.cancelAllowLAN() }
                }
            )
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                model.cancelAllowLAN()
            }
            Button(L10n.text("允许", "Allow")) {
                model.confirmAllowLAN()
            }
        } message: {
            Text(
                L10n.text(
                    "局域网内任何设备都可使用该代理。请仅在可信网络中开启。",
                    "Any device on the local network can use this proxy. Enable it only on trusted networks."
                )
            )
        }
        .alert(
            L10n.text("发现新版本", "Update Available"),
            isPresented: Binding(
                get: { model.availableUpdate != nil },
                set: { if !$0 { model.dismissAvailableUpdate() } }
            )
        ) {
            Button(L10n.text("稍后", "Later"), role: .cancel) {
                model.dismissAvailableUpdate()
            }
            Button(L10n.text("前往下载", "Download")) {
                model.openAvailableUpdate()
            }
        } message: {
            Text(
                L10n.text(
                    "GitHub 已发布 \(model.availableUpdate?.version ?? "")，是否打开正式版下载页面？",
                    "Version \(model.availableUpdate?.version ?? "") is available on GitHub. Open the official download page?"
                )
            )
        }
    }

    private func tabButton(_ tab: MainTab, icon: String, selectedIcon: String, title: String) -> some View {
        let isSelected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? selectedIcon : icon)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .frame(height: 22)
                    .background {
                        if isSelected, tab == .rules {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 29, height: 27)
                        }
                    }
                Text(title)
                    .font(AppTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : AppVisual.inactiveTab(colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
