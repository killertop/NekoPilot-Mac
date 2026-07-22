import NekoPilotCore
import SwiftUI

struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @State private var showingStopOptions = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            ScrollView {
                VStack(spacing: 0) {
                    powerHero
                        .padding(.top, AppVisual.pageTopPadding)

                    connectionStatus
                        .padding(.top, 16)

                    nodesSection(now: context.date)
                        .padding(.top, 17)
                }
                .padding(.horizontal, AppVisual.pageHorizontalPadding)
                .padding(.bottom, AppVisual.pageBottomPadding)
                .frame(maxWidth: AppVisual.pageMaximumWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .alert(
            L10n.text("停止测速？", "Stop Speed Test?"),
            isPresented: $showingStopOptions
        ) {
            Button(L10n.text("继续测速", "Continue Testing"), role: .cancel) { }
            Button(L10n.text("恢复测速前结果", "Restore Previous Results"), role: .destructive) {
                Task { await model.cancelURLTest(policy: .restorePreviousResults) }
            }
            Button(L10n.text("保存已完成结果", "Keep Completed Results")) {
                Task { await model.cancelURLTest(policy: .keepPartialResults) }
            }
        } message: {
            Text(L10n.text(
                "请选择保留已经完成的测速结果，或恢复到本次测速开始前的历史结果。",
                "Keep measurements that have completed, or restore the history from before this test started."
            ))
        }
        .onChange(of: model.isURLTesting) { testing in
            if !testing { showingStopOptions = false }
        }
    }

    private var powerHero: some View {
        ZStack {
            if model.status.isRunning || model.status.isBusy {
                Circle()
                    .fill(Color.accentColor.opacity(model.status.isRunning ? 0.22 : 0.12))
                    .frame(width: 196, height: 196)
                    .blur(radius: 34)
            }

            Button {
                Task { await model.toggleConnection() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .fill(tileGradient)
                        .shadow(
                            color: model.status.isRunning ? Color.accentColor.opacity(0.32) : Color.black.opacity(colorScheme == .dark ? 0.42 : 0.11),
                            radius: model.status.isRunning ? 15 : 12,
                            y: 7
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 40, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.72), lineWidth: 1)
                        }

                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(powerColor)
                }
                .frame(width: 144, height: 144)
                .contentShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            }
            .buttonStyle(.plain)
            // Starting is cancellable; otherwise a slow network or system
            // proxy command leaves the user staring at an inert power button.
            // A stop already in progress remains disabled to avoid overlapping
            // stop transactions.
            .disabled(model.status == .stopping)
            .accessibilityLabel(powerButtonAccessibilityLabel)
        }
        .frame(height: 144)
    }

    private var tileGradient: LinearGradient {
        if model.status.isRunning {
            return LinearGradient(
                colors: [
                    Color(red: 77 / 255, green: 163 / 255, blue: 1),
                    Color.accentColor,
                    Color(red: 0, green: 98 / 255, blue: 204 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255), Color(red: 35 / 255, green: 35 / 255, blue: 37 / 255), Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)]
            : [.white, Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255), Color(red: 242 / 255, green: 242 / 255, blue: 246 / 255)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var powerColor: Color {
        if model.status.isRunning { return .white }
        if model.status.isBusy { return .accentColor }
        return AppVisual.tertiaryLabel(colorScheme)
    }

    private var powerButtonAccessibilityLabel: String {
        switch model.status {
        case .running: return L10n.disconnect
        case .starting: return L10n.text("取消连接", "Cancel Connection")
        case .stopping: return L10n.stopping
        case .stopped, .failed: return L10n.connect
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status == .stopped ? AppVisual.tertiaryLabel(colorScheme) : model.status.tint)
                .frame(width: 5, height: 5)
            Text(model.status.localizedTitle)
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(model.status == .stopped ? Color.secondary : Color.primary)
        }
        .frame(height: 20)
    }

    private func nodesSection(now: Date) -> some View {
        VStack(spacing: 6) {
            SectionTitle(nodesSectionTitle(now: now)) {
                Button {
                    if model.isURLTesting {
                        showingStopOptions = true
                    } else {
                        model.runURLTest()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if model.isURLTesting {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(model.isURLTesting ? L10n.text("停止", "Stop") : L10n.text("测速", "Speed Test"))
                    }
                    .font(AppTypography.captionEmphasized)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.nodes.isEmpty)
                .accessibilityLabel(model.isURLTesting ? L10n.text("停止测速", "Stop Speed Test") : L10n.text("开始测速", "Start Speed Test"))
                .accessibilityHint(model.isURLTesting
                    ? L10n.text("保留已经完成的测速结果", "Keeps results that have already completed")
                    : L10n.text("逐步更新并按延迟排序节点", "Updates and sorts nodes by latency as results arrive"))
                .help(model.isURLTesting
                    ? L10n.text("停止并保留已完成结果", "Stop and keep completed results")
                    : L10n.text("开始测速", "Start speed test"))
            }

            AppCard {
                if model.nodes.isEmpty {
                    EmptyStateView(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: L10n.text("还没有节点", "No Nodes Yet"),
                        message: L10n.text("前往“节点”导入机场订阅或单节点", "Import a subscription or proxy link from Nodes")
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.nodeRows) { row in
                            nodeRow(row, now: now)
                            if row.id != model.nodeRows.last?.id { AppDivider() }
                        }
                    }
                }
            }
        }
    }

    private func nodeRow(_ row: NodeListRow, now: Date) -> some View {
        let node = row.node
        let selected = model.selectedNode == node.runtimeTag
        return Button {
            Task { await model.selectNode(node) }
        } label: {
            HStack(spacing: 8) {
                if model.showProtocol {
                    Text(node.protocolName.uppercased())
                        .font(AppTypography.badge)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, height: 20)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }

                Text(row.displayName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if row.hasDuplicateDisplayName {
                    Text("· \(row.sourceName)")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)
                delayLabel(node, now: now)
                    .frame(minWidth: 46, alignment: .trailing)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.displayName) · \(row.sourceName)")
    }

    @ViewBuilder
    private func delayLabel(_ node: ProxyNode, now: Date) -> some View {
        if let delay = model.delayHistory[node.runtimeTag]?.delay {
            Text("\(delay)ms")
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(isStale(node, now: now) ? Color.secondary : Color.primary)
        } else if model.delayHistory[node.runtimeTag] != nil {
            Text(L10n.text("超时", "Timeout"))
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)
        } else {
            Text("—")
                .font(AppTypography.body)
                .foregroundStyle(AppVisual.tertiaryLabel(colorScheme))
        }
    }

    private func nodesSectionTitle(now: Date) -> String {
        let title = L10n.text("全部节点", "All Nodes")
        guard let date = model.delayHistory.values.map(\.measuredAt).max() else { return title }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: now)
        return "\(title) · \(relative)"
    }

    private func isStale(_ node: ProxyNode, now: Date) -> Bool {
        guard let measuredAt = model.delayHistory[node.runtimeTag]?.measuredAt else { return false }
        return now.timeIntervalSince(measuredAt) > 30 * 60
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

}
