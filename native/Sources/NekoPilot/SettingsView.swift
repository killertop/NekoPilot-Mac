import AppKit
import NekoPilotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var login = LaunchAtLoginController()
    @State private var showingPort = false
    @State private var showingDirectDNS = false
    @State private var showingUserAgent = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                primaryCard
                secondaryCard
                aboutCard

                VStack(spacing: 2) {
                    Text("\(L10n.text("版本", "Version")) \(version)")
                    Text("© 2026 NekoPilot")
                }
                .font(AppTypography.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, AppVisual.pageHorizontalPadding)
            .padding(.top, AppVisual.pageTopPadding)
            .padding(.bottom, AppVisual.pageBottomPadding)
            .frame(maxWidth: .infinity)
            .appOverlayScrollers()
        }
        .sheet(isPresented: $showingPort) {
            ProxyPortSheet(model: model, isPresented: $showingPort)
        }
        .sheet(isPresented: $showingDirectDNS) {
            DirectDNSSheet(model: model, isPresented: $showingDirectDNS)
        }
        .sheet(isPresented: $showingUserAgent) {
            UserAgentSheet(model: model, isPresented: $showingUserAgent)
        }
        .alert(
            L10n.text("无法修改开机启动", "Unable to Change Login Item"),
            isPresented: Binding(
                get: { login.errorMessage != nil },
                set: { if !$0 { login.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("知道了", "OK"), role: .cancel) { login.errorMessage = nil }
        } message: {
            Text(login.errorMessage ?? "")
        }
    }

    private var primaryCard: some View {
        AppCard {
            VStack(spacing: 0) {
                toggleRow(
                    icon: "gauge.with.dots.needle.50percent",
                    iconColor: AppVisual.standardSettingIcon,
                    title: L10n.text("自动选择节点", "Automatic Node Selection"),
                    subtitle: model.automaticSelectionSummary,
                    value: Binding(
                        get: { model.autoSelect },
                        set: { value in Task { await model.setAutoSelect(value) } }
                    )
                )
                AppDivider(leading: 52)
                toggleRow(
                    icon: "power",
                    iconColor: AppVisual.secondarySettingIcon,
                    title: L10n.text("开机启动", "Launch at Login"),
                    value: Binding(get: { login.enabled }, set: { login.setEnabled($0) })
                )
                AppDivider(leading: 52)
                toggleRow(
                    icon: "wifi.router",
                    iconColor: AppVisual.cautionSettingIcon,
                    title: L10n.text("局域网连接", "LAN Connections"),
                    subtitle: L10n.text("让同一局域网设备使用本机代理", "Let LAN devices use this proxy"),
                    value: Binding(
                        get: { model.allowLAN },
                        set: { value in Task { await model.setAllowLAN(value) } }
                    )
                )
                AppDivider(leading: 52)
                Button { showingPort = true } label: {
                    settingRow(
                        icon: "cable.connector",
                        iconColor: AppVisual.standardSettingIcon,
                        title: L10n.text("代理端口", "Proxy Port"),
                        subtitle: L10n.text("HTTP/SOCKS 混合入站端口", "Mixed HTTP/SOCKS inbound port"),
                        trailing: "\(model.proxyPort)",
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var secondaryCard: some View {
        AppCard {
            VStack(spacing: 0) {
                Button { showingDirectDNS = true } label: {
                    settingRow(
                        icon: "server.rack",
                        iconColor: AppVisual.standardSettingIcon,
                        title: L10n.text("直连 DNS", "Direct DNS"),
                        subtitle: L10n.text("打开直连 DNS 设置", "Open direct DNS settings"),
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
                AppDivider(leading: 52)
                toggleRow(
                    icon: "tag",
                    iconColor: AppVisual.standardSettingIcon,
                    title: L10n.text("显示协议类型", "Show Protocol Type"),
                    subtitle: L10n.text("在节点列表中显示每个节点的协议类型", "Show protocol labels in the node list"),
                    value: Binding(
                        get: { model.showProtocol },
                        set: { value in Task { await model.setShowProtocol(value) } }
                    )
                )
                AppDivider(leading: 52)
                Button { showingUserAgent = true } label: {
                    settingRow(
                        icon: "wrench.and.screwdriver",
                        iconColor: AppVisual.standardSettingIcon,
                        title: L10n.text("User Agent 设置", "User Agent Settings"),
                        subtitle: SubscriptionUserAgentPreset.summary(for: model.userAgent),
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("User Agent 设置", "User Agent Settings"))
                AppDivider(leading: 52)
                toggleRow(
                    icon: "network",
                    iconColor: AppVisual.standardSettingIcon,
                    title: L10n.text("自动设置系统代理", "Set System Proxy Automatically"),
                    subtitle: L10n.text("连接时接管 HTTP、HTTPS 和 SOCKS", "Manage HTTP, HTTPS, and SOCKS while connected"),
                    value: Binding(
                        get: { !model.skipSystemProxy },
                        set: { value in Task { await model.setSkipSystemProxy(!value) } }
                    )
                )
            }
        }
    }

    private var aboutCard: some View {
        AppCard {
            VStack(spacing: 0) {
                Button {
                    if let url = URL(string: "https://github.com/killertop/NekoPilot-Mac") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    settingRow(
                        icon: "chevron.left.forwardslash.chevron.right",
                        iconColor: AppVisual.standardSettingIcon,
                        title: "GitHub",
                        subtitle: L10n.text("源码、问题反馈与版本更新", "Source, issues, and releases"),
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
                AppDivider(leading: 52)
                settingRow(
                    icon: "info.circle",
                    iconColor: AppVisual.secondarySettingIcon,
                    title: L10n.text("版本", "Version"),
                    subtitle: "NekoPilot for macOS",
                    trailing: version
                )
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? L10n.text("开发版", "Development")
    }

    private func toggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        value: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTypography.rowTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle ?? "")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 52 : 64)
        .contentShape(Rectangle())
    }

    private func settingRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        trailing: String? = nil,
        chevron: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AppTypography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

private struct ProxyPortSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var port: String
    @State private var saving = false
    @FocusState private var portFocused: Bool

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        _port = State(initialValue: String(model.proxyPort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("代理端口", "Proxy Port")).font(AppTypography.dialogTitle)
            Text(L10n.text("HTTP/SOCKS 混合入站端口", "Mixed HTTP/SOCKS inbound port"))
                .font(AppTypography.body).foregroundStyle(.secondary)
            TextField("16789", text: $port)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.monoBody)
                .focused($portFocused)
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let value = Int(port) else { return }
                    Task {
                        saving = true
                        let success = await model.setProxyPort(value)
                        saving = false
                        if success { isPresented = false }
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text(L10n.text("保存", "Save")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || Int(port).map { !(1 ... 65_535).contains($0) } ?? true)
            }
        }
        .padding(AppVisual.sheetPadding)
        .frame(width: AppVisual.sheetWidth)
        .onAppear { portFocused = true }
    }
}

private struct DirectDNSSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var value: String
    @State private var saving = false
    @FocusState private var valueFocused: Bool

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        _value = State(initialValue: model.directDNS)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("直连 DNS", "Direct DNS"))
                    .font(AppTypography.dialogTitle)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("关闭", "Close"))
            }
            Text(L10n.text("用于直连域名解析的 DNS 服务器地址", "DNS server used to resolve direct connections"))
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)
            TextField("223.5.5.5", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.monoBody)
                .focused($valueFocused)
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("保存", "Save")) {
                    Task {
                        saving = true
                        let success = await model.setDirectDNS(value)
                        saving = false
                        if success { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppVisual.sheetPadding)
        .frame(width: AppVisual.sheetWidth)
        .onAppear { valueFocused = true }
    }
}

private struct UserAgentSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var selected: SubscriptionUserAgentPreset
    @State private var customValue: String
    @State private var saving = false
    @FocusState private var customFocused: Bool

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let preset = SubscriptionUserAgentPreset.matching(model.userAgent)
        _selected = State(initialValue: preset)
        _customValue = State(initialValue: preset == .custom ? model.userAgent : "")
    }

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.text("User Agent 设置", "User Agent Settings"))
                        .font(AppTypography.dialogTitle)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("关闭", "Close"))
                }
                .padding(.horizontal, AppVisual.sheetPadding)
                .padding(.top, AppVisual.sheetPadding)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AppCard {
                            VStack(spacing: 0) {
                                ForEach(SubscriptionUserAgentPreset.allCases) { preset in
                                    Button { selected = preset } label: {
                                        HStack(spacing: 11) {
                                            Image(systemName: selected == preset ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 17, weight: .regular))
                                                .foregroundStyle(selected == preset ? Color.accentColor : AppVisual.tertiaryLabel(colorScheme))
                                                .frame(width: 22)
                                            Text(preset.title)
                                                .font(AppTypography.rowTitle)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 13)
                                        .frame(height: 42)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(preset.title)
                                    .accessibilityValue(selected == preset ? L10n.text("已选择", "Selected") : (preset.detail ?? ""))
                                    .accessibilityAddTraits(selected == preset ? .isSelected : [])
                                    if preset != SubscriptionUserAgentPreset.allCases.last { AppDivider(leading: 48) }
                                }
                            }
                        }

                        if selected == .custom {
                            TextField(L10n.text("输入自定义 User Agent", "Enter a custom User Agent"), text: $customValue)
                                .textFieldStyle(.roundedBorder)
                                .font(AppTypography.monoBody)
                                .focused($customFocused)
                                .accessibilityLabel(L10n.text("输入自定义 User Agent", "Enter a custom User Agent"))
                        } else if let detail = selected.detail {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("当前请求标识", "Current request identifier"))
                                    .font(AppTypography.captionEmphasized)
                                    .foregroundStyle(.secondary)
                                Text(detail)
                                    .font(AppTypography.monoCaption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                        }

                        Text(L10n.text(
                            "仅用于获取机场订阅；部分服务会根据客户端标识返回不同格式。",
                            "Used only for subscription requests. Some providers return different formats based on this identifier."
                        ))
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AppVisual.sheetPadding)
                    .padding(.bottom, 12)
                    .appOverlayScrollers()
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 360)

                AppDivider(leading: 0)
                HStack {
                    Spacer()
                    Button(L10n.text("取消", "Cancel")) { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task {
                            saving = true
                            let success = await model.setUserAgent(selected.resolvedValue(custom: customValue))
                            saving = false
                            if success { isPresented = false }
                        }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text(L10n.text("保存", "Save")) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (selected == .custom && customValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                .padding(.horizontal, AppVisual.sheetPadding)
                .frame(height: 52)
            }
        }
        .frame(width: AppVisual.sheetWidth)
        .frame(maxHeight: AppVisual.sheetMaximumHeight)
        .onAppear {
            if selected == .custom { customFocused = true }
        }
        .onChange(of: selected) { value in
            if value == .custom {
                DispatchQueue.main.async { customFocused = true }
            }
        }
    }
}

private extension SubscriptionUserAgentPreset {
    var title: String {
        switch self {
        case .standard: L10n.text("默认（sing-box）", "Default (sing-box)")
        case .sfm: "SFM 1.12"
        case .sfa: "SFA 1.12"
        case .sfi: "SFI 1.12"
        case .custom: L10n.text("自定义", "Custom")
        }
    }

    static func summary(for value: String) -> String {
        let preset = matching(value)
        return preset == .custom ? L10n.text("自定义标识", "Custom identifier") : preset.title
    }
}
