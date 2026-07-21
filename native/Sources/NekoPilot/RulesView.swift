import NekoPilotCore
import SwiftUI

struct RulesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @State private var showingAdd = false
    @State private var editingRule: RoutingRule?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 6) {
                SectionTitle("\(L10n.text("自定义规则", "Custom Rules")) · \(model.rules.count)") {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .help(L10n.text("添加域名、后缀或 IP 段规则", "Add domain, suffix, or IP CIDR rules"))
                }

                AppCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule)
                            if index < model.rules.count - 1 { AppDivider() }
                        }

                        if !model.rules.isEmpty { AppDivider() }

                        Button { showingAdd = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(L10n.text("添加规则", "Add Rule"))
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(L10n.text("规则模式连接时即时生效；未连接时将在下次连接生效。", "Rules apply live while connected, or on the next connection."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 7)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: 448)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingAdd) {
            AddRuleSheet(model: model, isPresented: $showingAdd)
        }
        .sheet(item: $editingRule) { rule in
            EditRuleSheet(model: model, rule: rule) {
                editingRule = nil
            }
        }
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        HStack(spacing: 8) {
            Button { editingRule = rule } label: {
                HStack(spacing: 8) {
                    Text(rule.action == .direct ? L10n.text("直连", "Direct") : L10n.text("代理", "Proxy"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(rule.action == .direct ? Color.green : Color.accentColor)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background((rule.action == .direct ? Color.green : Color.accentColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()

                    Text(kindTitle(rule.kind))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(AppVisual.fill(colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()

                    Text(rule.value)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { editingRule = rule } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("编辑规则", "Edit Rule"))

            Button(role: .destructive) {
                Task { await model.deleteRule(rule) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppVisual.tertiaryLabel(colorScheme))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("删除规则", "Delete Rule"))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func kindTitle(_ kind: RuleKind) -> String {
        switch kind {
        case .domain: L10n.text("域名", "DOMAIN")
        case .domainSuffix: L10n.text("后缀", "SUFFIX")
        case .ipCIDR: L10n.text("IP 段", "IP CIDR")
        }
    }
}

private struct AddRuleSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var action: RuleAction = .direct
    @State private var kind: RuleKind = .domain
    @State private var value = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("添加规则", "Add Rule")).font(.title2.bold())
                Spacer()
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Picker(L10n.text("动作", "Action"), selection: $action) {
                Text(L10n.text("直连", "Direct")).tag(RuleAction.direct)
                Text(L10n.text("代理", "Proxy")).tag(RuleAction.proxy)
            }
            .pickerStyle(.segmented)
            Picker(L10n.text("匹配", "Match"), selection: $kind) {
                Text(L10n.text("域名", "Domain")).tag(RuleKind.domain)
                Text(L10n.text("后缀", "Suffix")).tag(RuleKind.domainSuffix)
                Text(L10n.text("IP 段", "IP CIDR")).tag(RuleKind.ipCIDR)
            }
            .pickerStyle(.segmented)
            TextField(placeholder, text: $value)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { isPresented = false }
                Button {
                    Task {
                        saving = true
                        let success = await model.addRule(action: action, kind: kind, value: value)
                        saving = false
                        if success { isPresented = false }
                    }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text(L10n.text("保存", "Save")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private var placeholder: String {
        switch kind {
        case .domain: "example.com"
        case .domainSuffix: ".example.com"
        case .ipCIDR: "192.168.0.0/16"
        }
    }
}

private struct EditRuleSheet: View {
    @ObservedObject var model: AppModel
    let rule: RoutingRule
    let onClose: () -> Void
    @State private var action: RuleAction
    @State private var kind: RuleKind
    @State private var value: String
    @State private var saving = false

    init(model: AppModel, rule: RoutingRule, onClose: @escaping () -> Void) {
        self.model = model
        self.rule = rule
        self.onClose = onClose
        _action = State(initialValue: rule.action)
        _kind = State(initialValue: rule.kind)
        _value = State(initialValue: rule.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("编辑规则", "Edit Rule")).font(.title2.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Picker(L10n.text("动作", "Action"), selection: $action) {
                Text(L10n.text("直连", "Direct")).tag(RuleAction.direct)
                Text(L10n.text("代理", "Proxy")).tag(RuleAction.proxy)
            }
            .pickerStyle(.segmented)
            Picker(L10n.text("匹配", "Match"), selection: $kind) {
                Text(L10n.text("域名", "Domain")).tag(RuleKind.domain)
                Text(L10n.text("后缀", "Suffix")).tag(RuleKind.domainSuffix)
                Text(L10n.text("IP 段", "IP CIDR")).tag(RuleKind.ipCIDR)
            }
            .pickerStyle(.segmented)
            TextField(placeholder, text: $value)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("保存", "Save")) {
                    Task {
                        saving = true
                        let success = await model.updateRule(rule, action: action, kind: kind, value: value)
                        saving = false
                        if success { onClose() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private var placeholder: String {
        switch kind {
        case .domain: "example.com"
        case .domainSuffix: ".example.com"
        case .ipCIDR: "192.168.0.0/16"
        }
    }
}
