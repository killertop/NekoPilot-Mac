import NekoPilotCore
import SwiftUI

struct RulesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @State private var showingAdd = false
    @State private var showingHelp = false
    @State private var editingRule: RoutingRule?
    @State private var addAction: RuleAction = .direct
    @State private var addKind: RuleKind = .domain
    @State private var search = ""
    @State private var feedback: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 6) {
                SectionTitle("\(L10n.text("自定义规则", "Custom Rules")) · \(model.rules.count)") {
                    Button { showingHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("规则说明", "Rule Information"))
                }

                if model.rules.count > 12 {
                    TextField(L10n.text("筛选规则", "Filter rules"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.bottom, 2)
                }

                AppCard {
                    LazyVStack(spacing: 0) {
                        if visibleRules.isEmpty, !model.rules.isEmpty {
                            Text(L10n.text("没有匹配的规则", "No matching rules"))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(16)
                            AppDivider()
                        } else {
                            ForEach(Array(visibleRules.enumerated()), id: \.element.id) { index, rule in
                                ruleRow(rule)
                                if index < visibleRules.count - 1 { AppDivider() }
                            }
                            if !visibleRules.isEmpty { AppDivider() }
                        }

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

                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 5)
                }

                Text(L10n.text("连接时即时生效；未连接时将在下次连接生效。", "Applies live while connected, or on the next connection."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, feedback == nil ? 7 : 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: 448)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingHelp) {
            RuleHelpSheet(isPresented: $showingHelp)
        }
        .sheet(isPresented: $showingAdd) {
            AddRuleSheet(
                model: model,
                isPresented: $showingAdd,
                action: $addAction,
                kind: $addKind
            )
        }
        .sheet(item: $editingRule) { rule in
            EditRuleSheet(model: model, rule: rule) { mutation in
                if mutation.hasCrossActionConflict {
                    feedback = L10n.text("该地址也存在于另一动作中，将按规则优先级生效。", "This address also exists under another action; priority order applies.")
                }
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
        }
    }

    private var visibleRules: [RoutingRule] {
        let rules = RuleMutation.sorted(model.rules)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? rules : rules.filter { $0.value.lowercased().contains(query) }
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        HStack(spacing: 8) {
            Button { editingRule = rule } label: {
                HStack(spacing: 8) {
                    RuleActionBadge(action: rule.action)
                    RuleKindChip(kind: rule.kind)
                    Text(rule.value)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
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
}

private struct AddRuleSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @Binding var action: RuleAction
    @Binding var kind: RuleKind
    @State private var input = ""
    @State private var saving = false
    @State private var feedback: String?
    @State private var feedbackIsWarning = false

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                sheetHeader(L10n.text("添加规则", "Add Rule")) { isPresented = false }

                ruleSection(L10n.text("动作", "Action")) {
                    Picker("", selection: $action) {
                        Text(L10n.text("直连", "Direct")).tag(RuleAction.direct)
                        Text(L10n.text("代理", "Proxy")).tag(RuleAction.proxy)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(action.color)
                }

                ruleSection(L10n.text("匹配", "Match")) {
                    Picker("", selection: $kind) {
                        Text(L10n.text("域名", "Domain")).tag(RuleKind.domain)
                        Text(L10n.text("后缀", "Suffix")).tag(RuleKind.domainSuffix)
                        Text(L10n.text("IP 段", "IP CIDR")).tag(RuleKind.ipCIDR)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("\(placeholder)\n\(L10n.text("支持换行、英文或中文逗号批量添加", "Paste multiple values separated by new lines or commas"))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $input)
                            .font(.system(size: 12.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(5)
                    }
                    .frame(height: 86)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12)) }

                    Button {
                        add()
                    } label: {
                        Group {
                            if saving { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
                        }
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(action.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(L10n.text("添加", "Add"))
                }

                RulePreview(action: action, kind: kind, value: firstValue.isEmpty ? placeholder : firstValue)

                if let feedback {
                    Label(feedback, systemImage: feedbackIsWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(feedbackIsWarning ? Color.orange : Color.green)
                }

                RulePriorityHint()

                Button(L10n.text("完成", "Done")) { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)
        }
        .frame(width: 400)
    }

    private var placeholder: String { kind.placeholder }

    private var firstValue: String {
        input.split(whereSeparator: { ["\n", "\r", ",", "，"].contains($0) })
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func add() {
        Task {
            saving = true
            defer { saving = false }
            guard let result = await model.addRules(action: action, kind: kind, input: input) else { return }
            input = ""
            feedbackIsWarning = result.hasCrossActionConflict
            if result.hasCrossActionConflict {
                feedback = L10n.text("已添加；相同地址也存在于另一动作中。", "Added; the same address also exists under another action.")
            } else if result.added > 1 || result.duplicates > 0 {
                feedback = L10n.text("已添加 \(result.added) 条 · 跳过 \(result.duplicates) 条重复", "Added \(result.added) · skipped \(result.duplicates) duplicate(s)")
            } else {
                feedback = L10n.text("已添加，可继续输入下一条", "Added. You can continue with another rule.")
            }
        }
    }
}

private struct EditRuleSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let rule: RoutingRule
    let onSaved: (RuleEditMutation) -> Void
    let onCancel: () -> Void
    @State private var action: RuleAction
    @State private var kind: RuleKind
    @State private var value: String
    @State private var saving = false

    init(
        model: AppModel,
        rule: RoutingRule,
        onSaved: @escaping (RuleEditMutation) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.rule = rule
        self.onSaved = onSaved
        self.onCancel = onCancel
        _action = State(initialValue: rule.action)
        _kind = State(initialValue: rule.kind)
        _value = State(initialValue: rule.value)
    }

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                sheetHeader(L10n.text("编辑规则", "Edit Rule"), close: onCancel)
                ruleSection(L10n.text("动作", "Action")) {
                    Picker("", selection: $action) {
                        Text(L10n.text("直连", "Direct")).tag(RuleAction.direct)
                        Text(L10n.text("代理", "Proxy")).tag(RuleAction.proxy)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(action.color)
                }
                ruleSection(L10n.text("匹配", "Match")) {
                    let kinds = RuleMutation.compatibleKinds(for: rule.kind)
                    if kinds.count == 1 {
                        RuleKindChip(kind: kind)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        Picker("", selection: $kind) {
                            ForEach(kinds, id: \.self) { candidate in
                                Text(candidate.title).tag(candidate)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
                TextField(kind.placeholder, text: $value)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                RulePreview(action: action, kind: kind, value: value.isEmpty ? kind.placeholder : value)
                RulePriorityHint()
                HStack {
                    Spacer()
                    Button(L10n.text("取消", "Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task {
                            saving = true
                            let result = await model.updateRule(rule, action: action, kind: kind, value: value)
                            saving = false
                            if let result { onSaved(result) }
                        }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text(L10n.text("保存", "Save")) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
        }
        .frame(width: 400)
    }
}

private struct RuleHelpSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            AppVisual.background(colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.text("规则说明", "Rule Information"))
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("关闭", "Close"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        helpSection(L10n.text("动作", "Action")) {
                            helpRow {
                                RuleActionBadge(action: .direct)
                                Text(L10n.text("不经过代理，适合局域网、国内或可信地址。", "Bypass the proxy for LAN, domestic, or trusted addresses."))
                            }
                            AppDivider()
                            helpRow {
                                RuleActionBadge(action: .proxy)
                                Text(L10n.text("强制通过当前代理节点访问。", "Force traffic through the selected proxy node."))
                            }
                        }

                        helpSection(L10n.text("匹配", "Match")) {
                            ForEach(Array(RuleKind.allCases.enumerated()), id: \.element) { index, kind in
                                helpRow {
                                    RuleKindChip(kind: kind)
                                    Text(kind.title).frame(width: 48, alignment: .leading)
                                    Text(kind.placeholder)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if index < RuleKind.allCases.count - 1 { AppDivider() }
                            }
                        }

                        helpSection(L10n.text("优先级", "Priority")) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    RuleActionBadge(action: .direct)
                                    Image(systemName: "chevron.right").font(.system(size: 9))
                                    RuleActionBadge(action: .proxy)
                                    Image(systemName: "chevron.right").font(.system(size: 9))
                                    Text(L10n.text("内置中国直连", "Built-in China Direct"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(L10n.text("自定义直连优先于自定义代理；两者都优先于内置中国规则。同一地址同时存在时，靠前的动作生效。", "Custom Direct precedes Custom Proxy; both precede built-in China rules. Earlier actions win when the same address appears more than once."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(13)
                        }

                        Label(
                            L10n.text("连接时规则会即时重载；未连接时在下次连接生效。", "Rules reload live while connected, or apply on the next connection."),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }

                AppDivider(leading: 0)
                Button(L10n.text("关闭", "Close")) { isPresented = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
        }
        .frame(width: 390, height: 570)
    }

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            AppCard { content() }
        }
    }

    private func helpRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
    }
}

private struct RuleActionBadge: View {
    let action: RuleAction

    var body: some View {
        Text(action.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(action.color)
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 22)
            .background(action.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}

private struct RuleKindChip: View {
    let kind: RuleKind

    var body: some View {
        Text("\(kind.glyph) \(kind.abbreviation)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 22)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}

private struct RulePreview: View {
    let action: RuleAction
    let kind: RuleKind
    let value: String

    var body: some View {
        Text("\(action.title)：\(kind.preview(value))")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(action.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

private struct RulePriorityHint: View {
    var body: some View {
        Text(L10n.text("优先级：自定义直连 > 自定义代理 > 内置中国直连", "Priority: Custom Direct > Custom Proxy > Built-in China Direct"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

private func sheetHeader(_ title: String, close: @escaping () -> Void) -> some View {
    HStack {
        Text(title).font(.system(size: 19, weight: .semibold))
        Spacer()
        Button(action: close) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 18))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L10n.text("关闭", "Close"))
    }
}

private func ruleSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        content()
    }
}

private extension RuleAction {
    var title: String {
        self == .direct ? L10n.text("直连", "Direct") : L10n.text("代理", "Proxy")
    }

    var color: Color { self == .direct ? .green : .accentColor }
}

private extension RuleKind {
    var title: String {
        switch self {
        case .domain: L10n.text("域名", "Domain")
        case .domainSuffix: L10n.text("后缀", "Suffix")
        case .ipCIDR: L10n.text("IP 段", "IP CIDR")
        }
    }

    var glyph: String {
        switch self {
        case .domain: "="
        case .domainSuffix: "*."
        case .ipCIDR: "/"
        }
    }

    var abbreviation: String {
        switch self {
        case .domain: "DOM"
        case .domainSuffix: "SFX"
        case .ipCIDR: "CIDR"
        }
    }

    var placeholder: String {
        switch self {
        case .domain: "example.com"
        case .domainSuffix: ".example.com"
        case .ipCIDR: "192.168.1.0/24"
        }
    }

    func preview(_ value: String) -> String {
        switch self {
        case .domain: L10n.text("域名 \(value)", "Domain \(value)")
        case .domainSuffix: L10n.text("以 \(value) 结尾的域名", "Domains ending in \(value)")
        case .ipCIDR: L10n.text("IP 段 \(value)", "IP range \(value)")
        }
    }
}
