import NekoPilotCore
import SwiftUI

struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                powerHero
                    .padding(.top, 20)

                connectionStatus
                    .padding(.top, 16)

                nodesSection
                    .padding(.top, 17)

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: 448)
            .frame(maxWidth: .infinity)
        }
    }

    private var powerHero: some View {
        ZStack {
            if model.status.isRunning || model.status.isBusy {
                Circle()
                    .fill(Color.accentColor.opacity(model.status.isRunning ? 0.22 : 0.12))
                    .frame(width: 220, height: 220)
                    .blur(radius: 38)
            }

            Button {
                Task { await model.toggleConnection() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .fill(tileGradient)
                        .shadow(
                            color: model.status.isRunning ? Color.accentColor.opacity(0.32) : Color.black.opacity(colorScheme == .dark ? 0.42 : 0.11),
                            radius: model.status.isRunning ? 17 : 14,
                            y: 8
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 44, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.72), lineWidth: 1)
                        }

                    Image(systemName: "power")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(powerColor)
                }
                .frame(width: 160, height: 160)
                .contentShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.status.isBusy)
            .accessibilityLabel(model.status.isRunning ? L10n.disconnect : L10n.connect)
        }
        .frame(height: 160)
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

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status == .stopped ? AppVisual.tertiaryLabel(colorScheme) : model.status.tint)
                .frame(width: 5, height: 5)
            Text(model.status.localizedTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.status == .stopped ? Color.secondary : Color.primary)
        }
        .frame(height: 20)
    }

    private var nodesSection: some View {
        VStack(spacing: 6) {
            SectionTitle(nodesSectionTitle) {
                Button {
                    if model.isURLTesting {
                        model.cancelURLTest()
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.nodes.isEmpty)
                .accessibilityLabel(model.isURLTesting ? L10n.text("停止测速", "Stop Speed Test") : L10n.text("开始测速", "Start Speed Test"))
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
                        ForEach(model.sortedNodes) { node in
                            nodeRow(node)
                            if node.id != model.sortedNodes.last?.id { AppDivider() }
                        }
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let selected = model.selectedNode == node.runtimeTag
        let displayName = model.displayName(for: node)
        return Button {
            Task { await model.selectNode(node) }
        } label: {
            HStack(spacing: 8) {
                if model.showProtocol {
                    Text(node.protocolName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, height: 20)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }

                Text(displayName)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if duplicateDisplayNames.contains(displayName.localizedLowercase) {
                    Text("· \(model.sourceName(for: node))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)
                delayLabel(node)
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
        .help("\(displayName) · \(model.sourceName(for: node))")
    }

    @ViewBuilder
    private func delayLabel(_ node: ProxyNode) -> some View {
        if let delay = model.delayHistory[node.runtimeTag]?.delay {
            Text("\(delay)ms")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isStale(node) ? Color.secondary : Color.primary)
        } else if model.delayHistory[node.runtimeTag] != nil {
            Text(L10n.text("超时", "Timeout"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppVisual.tertiaryLabel(colorScheme))
        } else {
            Text("—")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppVisual.tertiaryLabel(colorScheme))
        }
    }

    private var nodesSectionTitle: String {
        let title = L10n.text("全部节点", "All Nodes")
        guard let date = model.delayHistory.values.map(\.measuredAt).max() else { return title }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(title) · \(relative)"
    }

    private var duplicateDisplayNames: Set<String> {
        let counts = model.sortedNodes.reduce(into: [String: Int]()) { result, node in
            result[model.displayName(for: node).localizedLowercase, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private func isStale(_ node: ProxyNode) -> Bool {
        guard let measuredAt = model.delayHistory[node.runtimeTag]?.measuredAt else { return false }
        return Date().timeIntervalSince(measuredAt) > 30 * 60
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

}
