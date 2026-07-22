import AppKit
import NekoPilotCore
import SwiftUI

/// Product visual tokens are explicit because macOS' default
/// `windowBackgroundColor` and materials are darker and blurrier than the
/// compact grouped surface used by NekoPilot.
enum AppVisual {
    static let pageMaximumWidth: CGFloat = 448
    static let pageHorizontalPadding: CGFloat = 20
    static let pageTopPadding: CGFloat = 20
    static let pageBottomPadding: CGFloat = 20
    static let tabBarHeight: CGFloat = 56
    static let cardRadius: CGFloat = 14

    /// Total width for attached sheets, including their internal padding.
    /// 324pt keeps the sheet below 90% of the 371pt default window while giving
    /// forms enough room for localized labels and long proxy values.
    static let sheetWidth: CGFloat = 324
    static let sheetPadding: CGFloat = 16
    static let sheetMaximumHeight: CGFloat = 480

    // Setting icons use one semantic palette: accent for ordinary actions,
    // secondary for passive information, and caution only for settings that
    // expand network exposure or require extra care.
    static var standardSettingIcon: Color { .accentColor }
    static var secondarySettingIcon: Color { .secondary }
    static var cautionSettingIcon: Color { .orange }

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255).opacity(0.5)
            : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.18)
    }

    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255).opacity(0.24)
            : Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255).opacity(0.12)
    }

    static func tertiaryLabel(_: ColorScheme) -> Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    static func inactiveTab(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.52) : Color.secondary.opacity(0.82)
    }

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.45) : .black.opacity(0.04)
    }
}

/// The compact desktop type scale. Text must use these tokens instead of
/// page-local numeric fonts so node names, settings rows and sheets keep the
/// same hierarchy at every window size.
enum AppTypography {
    static let dialogTitle = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 15, weight: .regular)
    static let rowTitleEmphasized = Font.system(size: 15, weight: .medium)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodyEmphasized = Font.system(size: 14, weight: .medium)
    static let secondary = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionEmphasized = Font.system(size: 11, weight: .medium)
    static let badge = Font.system(size: 10, weight: .semibold)
    static let monoBody = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
}

/// Keeps scroll feedback available without reserving the wide gutter used by
/// macOS' legacy "always show scroll bars" preference. The native overlay
/// scroller retains system animation, input, contrast, and accessibility.
private final class AppOverlayScrollerConfigurationView: NSView {
    private weak var configuredScrollView: NSScrollView?
    private var configurationScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }

    func configureEnclosingScrollView() {
        if let scrollView = enclosingScrollView {
            configure(scrollView)
            return
        }
        guard !configurationScheduled else { return }
        configurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationScheduled = false
            guard let scrollView = self.enclosingScrollView else { return }
            self.configure(scrollView)
        }
    }

    private func configure(_ scrollView: NSScrollView) {
        let verticalScrollerIsConfigured = scrollView.verticalScroller
            .map { $0.controlSize == .small } ?? true
        let horizontalScrollerIsConfigured = scrollView.horizontalScroller
            .map { $0.controlSize == .small } ?? true
        let alreadyConfigured = configuredScrollView === scrollView
            && scrollView.scrollerStyle == .overlay
            && scrollView.autohidesScrollers
            && verticalScrollerIsConfigured
            && horizontalScrollerIsConfigured
        guard !alreadyConfigured else { return }
        configuredScrollView = scrollView
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScroller?.controlSize = .small
    }
}

private struct AppOverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> AppOverlayScrollerConfigurationView {
        AppOverlayScrollerConfigurationView(frame: .zero)
    }

    func updateNSView(_ nsView: AppOverlayScrollerConfigurationView, context: Context) {
        nsView.configureEnclosingScrollView()
    }
}

extension View {
    /// Attach to content inside a ScrollView to replace its persistent gutter
    /// with a slim, transient overlay scroller.
    func appOverlayScrollers() -> some View {
        background(AppOverlayScrollerConfigurator().frame(width: 0, height: 0))
    }
}

struct AppCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(AppVisual.card(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: AppVisual.cardRadius, style: .continuous))
            .shadow(color: AppVisual.cardShadow(colorScheme), radius: 2.5, y: 1)
    }
}

struct AppDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    var leading: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(AppVisual.separator(colorScheme))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.title = title
        let built = trailing()
        self.trailing = built is EmptyView ? nil : AnyView(built)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 4)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title)
                .font(AppTypography.rowTitleEmphasized)
            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
    }
}

extension EngineStatus {
    var localizedTitle: String {
        switch self {
        case .stopped: L10n.text("未连接", "Disconnected")
        case .starting: L10n.text("正在连接", "Connecting")
        case .running: L10n.text("已连接", "Connected")
        case .stopping: L10n.text("正在断开", "Disconnecting")
        case .failed: L10n.text("连接失败", "Connection Failed")
        }
    }

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .starting, .stopping: .accentColor
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
