import AppKit
import NekoPilotCore
import SwiftUI

struct NodeManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @State private var showingAdd = false
    @State private var editTarget: NekoPilotCore.Subscription?
    @State private var detailTarget: NekoPilotCore.Subscription?
    @State private var refreshErrorTarget: NekoPilotCore.Subscription?
    @State private var deleteTarget: NekoPilotCore.Subscription?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if model.subscriptions.isEmpty {
                        EmptyStateView(
                            icon: "tray",
                            title: L10n.text("没有节点来源", "No Node Sources"),
                            message: L10n.text("支持机场订阅 URL 和 VLESS、AnyTLS 等单节点链接", "Add a subscription URL or a VLESS/AnyTLS link")
                        )
                        .padding(.vertical, 32)
                    } else {
                        SectionTitle(L10n.text("节点来源", "Node Sources")) {
                            addNodeHeaderButton
                        }

                        sourceList(now: context.date)
                    }

                    if model.subscriptions.isEmpty { addNodeButton }
                }
                .padding(.horizontal, AppVisual.pageHorizontalPadding)
                .padding(.top, AppVisual.pageTopPadding)
                .padding(.bottom, AppVisual.pageBottomPadding)
                .frame(maxWidth: AppVisual.pageMaximumWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddNodeSheet(model: model, isPresented: $showingAdd)
        }
        .sheet(item: $editTarget) { target in
            EditSourceSheet(model: model, subscription: target, isPresented: Binding(
                get: { editTarget != nil },
                set: { if !$0 { editTarget = nil } }
            ))
        }
        .sheet(item: $detailTarget) { target in
            SourceDetailSheet(
                subscription: target,
                nodes: model.nodes.filter { $0.sourceIdentifier == target.identifier },
                isPresented: Binding(
                    get: { detailTarget != nil },
                    set: { if !$0 { detailTarget = nil } }
                )
            )
        }
        .sheet(item: $refreshErrorTarget) { target in
            RefreshErrorSheet(
                model: model,
                subscription: target,
                isPresented: Binding(
                    get: { refreshErrorTarget != nil },
                    set: { if !$0 { refreshErrorTarget = nil } }
                )
            )
        }
        .alert(
            L10n.text("删除节点来源？", "Delete Node Source?"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                deleteTarget = nil
            }
            Button(L10n.text("删除", "Delete"), role: .destructive) {
                deleteTarget = nil
                Task { await model.delete(target) }
            }
        } message: { target in
            let count = model.nodeCountsBySource[target.identifier, default: 0]
            Text(L10n.text(
                "将删除“\(target.name.isEmpty ? target.identifier : target.name)”及其 \(count) 个节点，此操作无法撤销。",
                "This removes “\(target.name.isEmpty ? target.identifier : target.name)” and its \(count) node(s). This cannot be undone."
            ))
        }
    }

    private var addNodeButton: some View {
        Button { showingAdd = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                Text(L10n.text("添加节点", "Add Node"))
                    .font(AppTypography.rowTitleEmphasized)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var addNodeHeaderButton: some View {
        Button { showingAdd = true } label: {
            Label(L10n.text("添加", "Add"), systemImage: "plus")
                .font(AppTypography.bodyEmphasized)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(L10n.text("添加节点", "Add Node"))
    }

    private func sourceList(now: Date) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(model.subscriptions) { subscription in
                sourceRow(subscription, now: now)
                if subscription.id != model.subscriptions.last?.id { AppDivider(leading: 64) }
            }
        }
        .background(AppVisual.card(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppVisual.separator(colorScheme), lineWidth: 0.5)
        }
        .shadow(color: AppVisual.cardShadow(colorScheme), radius: 2, y: 1)
    }

    private func sourceRow(_ subscription: NekoPilotCore.Subscription, now: Date) -> some View {
        HStack(spacing: 10) {
            Button { detailTarget = subscription } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(AppVisual.fill(colorScheme))
                        Image(systemName: sourceIcon(subscription))
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(subscription.sourceType == .subscription ? Color.accentColor : .secondary)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.name.isEmpty ? subscription.identifier : subscription.name)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(sourceSubtitle(subscription, now: now))
                            .font(AppTypography.secondary)
                            .foregroundStyle(sourceSubtitleColor(subscription))
                            .lineLimit(1)
                            .help(model.subscriptionRefreshErrors[subscription.identifier] ?? "")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if subscription.sourceType == .subscription {
                Button {
                    Task { await model.refresh(subscription) }
                } label: {
                    Group {
                        if model.refreshingSubscriptionIDs.contains(subscription.identifier) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(L10n.text("更新", "Update"))
                        }
                    }
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 36, minHeight: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.refreshingSubscriptionIDs.contains(subscription.identifier))
                .accessibilityLabel(L10n.text(
                    "更新 \(subscription.name.isEmpty ? subscription.identifier : subscription.name)",
                    "Update \(subscription.name.isEmpty ? subscription.identifier : subscription.name)"
                ))
            }

            if model.subscriptionRefreshErrors[subscription.identifier] != nil {
                Button {
                    refreshErrorTarget = subscription
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("查看更新失败原因", "View update failure reason"))
                .help(L10n.text("查看更新失败原因", "View update failure reason"))
            }

            Menu {
                Button {
                    editTarget = subscription
                } label: {
                    Label(L10n.text("编辑", "Edit"), systemImage: "pencil")
                }
                .disabled(model.refreshingSubscriptionIDs.contains(subscription.identifier))
                Divider()
                Button(role: .destructive) {
                    deleteTarget = subscription
                } label: {
                    Label(L10n.text("删除", "Delete"), systemImage: "trash")
                }
                .disabled(model.refreshingSubscriptionIDs.contains(subscription.identifier))
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(AppVisual.card(colorScheme), in: Circle())
                    .overlay { Circle().stroke(AppVisual.separator(colorScheme), lineWidth: 0.5) }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text(
                "管理 \(subscription.name.isEmpty ? subscription.identifier : subscription.name)",
                "Manage \(subscription.name.isEmpty ? subscription.identifier : subscription.name)"
            ))
            .help(L10n.text("管理节点来源", "Manage node source"))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }

    private func sourceSubtitle(_ subscription: NekoPilotCore.Subscription, now: Date) -> String {
        if model.subscriptionRefreshErrors[subscription.identifier] != nil {
            return L10n.text("更新失败", "Update failed")
        }
        let count = model.nodeCountsBySource[subscription.identifier, default: 0]
        if subscription.sourceType == .localLink {
            return L10n.text("本地节点，不自动更新", "Local node, no automatic updates")
        }
        let time = Self.relativeDateFormatter.localizedString(for: subscription.lastUpdateTime, relativeTo: now)
        return L10n.text("\(count) 个节点 · 更新于 \(time)", "\(count) node(s) · updated \(time)")
    }

    private func sourceSubtitleColor(_ subscription: NekoPilotCore.Subscription) -> Color {
        model.subscriptionRefreshErrors[subscription.identifier] == nil ? .secondary : .red
    }

    private func sourceIcon(_ subscription: NekoPilotCore.Subscription) -> String {
        subscription.sourceType == .subscription ? "arrow.down.circle.fill" : "link.circle.fill"
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct RefreshErrorSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let subscription: NekoPilotCore.Subscription
    @Binding var isPresented: Bool

    private var errorMessage: String {
        model.subscriptionRefreshErrors[subscription.identifier]
            ?? L10n.text("未提供具体错误信息。", "No detailed error was provided.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.red)
                Text(L10n.text("更新失败", "Update Failed"))
                    .font(AppTypography.dialogTitle)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("关闭", "Close"))
            }

            Text(subscription.name.isEmpty ? subscription.identifier : subscription.name)
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(errorMessage)
                .font(AppTypography.secondary)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppVisual.fill(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                Button(L10n.text("关闭", "Close")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await model.refresh(subscription)
                        if model.subscriptionRefreshErrors[subscription.identifier] == nil {
                            isPresented = false
                        }
                    }
                } label: {
                    if model.refreshingSubscriptionIDs.contains(subscription.identifier) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.text("重试", "Retry"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.refreshingSubscriptionIDs.contains(subscription.identifier))
            }
        }
        .padding(AppVisual.sheetPadding)
        .frame(width: AppVisual.sheetWidth)
    }
}

private struct AddNodeSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var input = ""
    @State private var name = ""
    @State private var importing = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("添加节点", "Add Node"))
                    .font(AppTypography.dialogTitle)
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("粘贴机场订阅 URL，或 VLESS、Trojan、AnyTLS、Hysteria2、TUIC、VMess、Shadowsocks 单节点链接。", "Paste a subscription URL or a supported single-node link."))
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
            TextField(L10n.text("名称（可选）", "Name (optional)"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $input)
                .font(AppTypography.monoBody)
                .focused($inputFocused)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)) }
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        importing = true
                        let success = await model.importNode(input, name: name.nilIfBlank)
                        importing = false
                        if success { isPresented = false }
                    }
                } label: {
                    if importing { ProgressView().controlSize(.small) } else { Text(L10n.text("导入", "Import")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppVisual.sheetPadding)
        .frame(width: AppVisual.sheetWidth)
        .onAppear { inputFocused = true }
    }
}

private struct EditSourceSheet: View {
    @ObservedObject var model: AppModel
    let subscription: NekoPilotCore.Subscription
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var input: String
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    init(model: AppModel, subscription: NekoPilotCore.Subscription, isPresented: Binding<Bool>) {
        self.model = model
        self.subscription = subscription
        _isPresented = isPresented
        _name = State(initialValue: subscription.name)
        _input = State(initialValue: subscription.subscriptionURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("编辑节点", "Edit Node Source")).font(AppTypography.dialogTitle)
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text(
                subscription.sourceType == .subscription
                    ? L10n.text("名称会立即保存；仅修改机场 URL 时重新下载并校验节点。", "Names save instantly. Nodes are downloaded and validated only when the subscription URL changes.")
                    : L10n.text("名称会立即保存；仅修改节点链接时重新解析并校验。", "Names save instantly. The node is parsed and validated only when its link changes.")
            )
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
            TextField(L10n.text("名称", "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            TextEditor(text: $input)
                .font(AppTypography.monoBody)
                .frame(minHeight: 110)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)) }
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        saving = true
                        let success = await model.edit(subscription, name: name, input: input)
                        saving = false
                        if success { isPresented = false }
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text(L10n.text("保存", "Save")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(AppVisual.sheetPadding)
        .frame(width: AppVisual.sheetWidth)
        .onAppear { nameFocused = true }
    }
}

private struct SourceDetailSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let subscription: NekoPilotCore.Subscription
    let nodes: [ProxyNode]
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.name.isEmpty ? subscription.identifier : subscription.name)
                            .font(AppTypography.rowTitleEmphasized)
                            .lineLimit(1)
                        Text(L10n.text("节点来源详情", "Node Source Details"))
                            .font(AppTypography.secondary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(spacing: 14) {
                        AppCard {
                            VStack(spacing: 0) {
                                infoRow(
                                    L10n.text("来源类型", "Source Type"),
                                    subscription.sourceType == .subscription
                                        ? L10n.text("机场订阅", "Subscription")
                                        : L10n.text("本地节点", "Local Node")
                                )
                                AppDivider()
                                infoRow(L10n.text("节点数量", "Node Count"), "\(nodes.count)")
                                AppDivider()
                                infoRow(L10n.text("上次更新", "Last Updated"), formattedDate)
                            }
                        }

                        if let url = subscription.subscriptionURL, !url.isEmpty {
                            AppCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        subscription.sourceType == .subscription
                                            ? L10n.text("订阅 URL", "Subscription URL")
                                            : L10n.text("节点链接", "Node Link")
                                    )
                                        .font(AppTypography.captionEmphasized)
                                        .foregroundStyle(.secondary)
                                    Text(url)
                                        .font(AppTypography.monoCaption)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                    Button {
                                        copyToPasteboard(url)
                                    } label: {
                                        Label(
                                            subscription.sourceType == .subscription
                                                ? L10n.text("复制订阅 URL", "Copy Subscription URL")
                                                : L10n.text("复制节点链接", "Copy Node Link"),
                                            systemImage: "doc.on.doc"
                                        )
                                            .font(AppTypography.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("节点配置", "Node Configurations"))
                                .font(AppTypography.sectionTitle)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            AppCard {
                                if nodes.isEmpty {
                                    Text(L10n.text("没有节点", "No nodes"))
                                        .font(AppTypography.body)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(18)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                                            nodeSummary(node)
                                            if index < nodes.count - 1 { AppDivider() }
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            copyToPasteboard(configurationSummary)
                        } label: {
                            Label(L10n.text("复制配置摘要", "Copy Configuration Summary"), systemImage: "doc.on.doc")
                                .font(AppTypography.bodyEmphasized)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .background(AppVisual.card(colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(width: AppVisual.sheetWidth)
        .frame(minHeight: 360, idealHeight: 440, maxHeight: AppVisual.sheetMaximumHeight)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func nodeSummary(_ node: ProxyNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(displayName(node))
                    .font(AppTypography.body)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(node.protocolName.uppercased())
                    .font(AppTypography.badge)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(endpointSummary(node))
                .font(AppTypography.monoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tlsSummary(node))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: subscription.lastUpdateTime)
    }

    private func displayName(_ node: ProxyNode) -> String {
        let prefix = "\(node.protocolName.uppercased()) · "
        return node.originalTag.hasPrefix(prefix)
            ? String(node.originalTag.dropFirst(prefix.count))
            : node.originalTag
    }

    private func endpointSummary(_ node: ProxyNode) -> String {
        let server = node.outbound["server"]?.stringValue ?? "—"
        let port = node.outbound["server_port"]?.numberValue.map { String(Int($0)) } ?? "—"
        return "\(server):\(port)"
    }

    private func tlsSummary(_ node: ProxyNode) -> String {
        guard let tls = node.outbound["tls"]?.objectValue,
              tls["enabled"]?.boolValue == true else {
            return L10n.text("TLS：关闭", "TLS: Off")
        }
        let mode = tls["reality"]?.objectValue == nil ? "TLS" : "Reality"
        if let serverName = tls["server_name"]?.stringValue, !serverName.isEmpty {
            return "\(mode) · SNI \(serverName)"
        }
        return mode
    }

    private var configurationSummary: String {
        var lines = [
            "\(L10n.text("来源", "Source")): \(subscription.name.isEmpty ? subscription.identifier : subscription.name)",
            "\(L10n.text("类型", "Type")): \(subscription.sourceType == .subscription ? L10n.text("机场订阅", "Subscription") : L10n.text("本地节点", "Local Node"))",
            "\(L10n.text("节点数量", "Node Count")): \(nodes.count)",
            "\(L10n.text("上次更新", "Last Updated")): \(formattedDate)",
        ]
        for node in nodes {
            lines.append("\(displayName(node)) · \(node.protocolName.uppercased()) · \(endpointSummary(node)) · \(tlsSummary(node))")
        }
        return lines.joined(separator: "\n")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
