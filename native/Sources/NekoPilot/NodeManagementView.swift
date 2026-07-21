import AppKit
import NekoPilotCore
import SwiftUI

struct NodeManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @State private var showingAdd = false
    @State private var editTarget: NekoPilotCore.Subscription?
    @State private var detailTarget: NekoPilotCore.Subscription?

    var body: some View {
        ScrollView(showsIndicators: false) {
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
                        Button {
                            Task { await model.refreshAllSubscriptions() }
                        } label: {
                            HStack(spacing: 5) {
                                if model.isRefreshingAllSubscriptions {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(model.isRefreshingAllSubscriptions ? L10n.text("正在更新", "Updating") : L10n.text("更新全部", "Update All"))
                            }
                            .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(
                            model.isRefreshingAllSubscriptions ||
                                !model.refreshingSubscriptionIDs.isEmpty ||
                                !model.subscriptions.contains(where: { $0.sourceType == .subscription })
                        )
                    }

                    sourceList

                    Button { showingAdd = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                            Text(L10n.text("添加节点", "Add Node"))
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: 448)
            .frame(maxWidth: .infinity)
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
    }

    private var sourceList: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.subscriptions) { subscription in
                sourceRow(subscription)
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

    private func sourceRow(_ subscription: NekoPilotCore.Subscription) -> some View {
        HStack(spacing: 10) {
            Button { detailTarget = subscription } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(AppVisual.fill(colorScheme))
                        Image(systemName: "globe.asia.australia.fill")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(AppVisual.tertiaryLabel(colorScheme))
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.name.isEmpty ? subscription.identifier : subscription.name)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(sourceSubtitle(subscription))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 36, minHeight: 28)
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingAllSubscriptions || model.refreshingSubscriptionIDs.contains(subscription.identifier))
            }

            Menu {
                Button {
                    detailTarget = subscription
                } label: {
                    Label(L10n.text("详情", "Details"), systemImage: "info.circle")
                }
                if subscription.sourceType == .subscription {
                    Button {
                        Task { await model.refresh(subscription) }
                    } label: {
                        Label(L10n.text("更新", "Update"), systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        model.isRefreshingAllSubscriptions ||
                            model.refreshingSubscriptionIDs.contains(subscription.identifier)
                    )
                }
                Button {
                    editTarget = subscription
                } label: {
                    Label(L10n.text("编辑", "Edit"), systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    Task { await model.delete(subscription) }
                } label: {
                    Label(L10n.text("删除", "Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
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
        .frame(minHeight: 68)
    }

    private func sourceSubtitle(_ subscription: NekoPilotCore.Subscription) -> String {
        let count = model.nodeCountsBySource[subscription.identifier, default: 0]
        if subscription.sourceType == .localLink {
            return L10n.text("本地节点，不自动更新", "Local node, no automatic updates")
        }
        let time = Self.relativeDateFormatter.localizedString(for: subscription.lastUpdateTime, relativeTo: Date())
        return L10n.text("\(count) 个节点 · 更新于 \(time)", "\(count) node(s) · updated \(time)")
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct AddNodeSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var input = ""
    @State private var name = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("添加节点", "Add Node"))
                    .font(.title2.bold())
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("粘贴机场订阅 URL，或 VLESS、Trojan、AnyTLS、Hysteria2、TUIC、VMess、Shadowsocks 单节点链接。", "Paste a subscription URL or a supported single-node link."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(L10n.text("名称（可选）", "Name (optional)"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $input)
                .font(.system(size: 12, design: .monospaced))
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
    }
}

private struct EditSourceSheet: View {
    @ObservedObject var model: AppModel
    let subscription: NekoPilotCore.Subscription
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var input: String
    @State private var saving = false

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
                Text(L10n.text("编辑节点", "Edit Node Source")).font(.title2.bold())
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
            TextField(L10n.text("名称", "Name"), text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $input)
                .font(.system(size: 12, design: .monospaced))
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
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                        Text(L10n.text("节点来源详情", "Node Source Details"))
                            .font(.system(size: 12))
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

                ScrollView(showsIndicators: false) {
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
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(url)
                                        .font(.system(size: 11, design: .monospaced))
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
                                            .font(.system(size: 12, weight: .medium))
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
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            AppCard {
                                if nodes.isEmpty {
                                    Text(L10n.text("没有节点", "No nodes"))
                                        .font(.system(size: 13))
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
                                .font(.system(size: 14, weight: .medium))
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
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
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
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(node.protocolName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(endpointSummary(node))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(tlsSummary(node))
                .font(.system(size: 11))
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
