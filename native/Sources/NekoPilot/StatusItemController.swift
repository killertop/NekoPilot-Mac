import AppKit
import Combine
import Foundation
import NekoPilotCore

@MainActor
final class StatusItemController: NSObject {
    private weak var model: AppModel?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let toggleItem = NSMenuItem()
    private let copyItem = NSMenuItem()
    private let showWindowAction: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var copyFeedbackTask: Task<Void, Never>?
    private lazy var baseTemplateImage = loadTemplateImage()

    init(model: AppModel, showWindowAction: @escaping () -> Void) {
        self.model = model
        self.showWindowAction = showWindowAction
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureMenu()
        statusItem.menu = menu
        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update(status: $0) }
            .store(in: &cancellables)
        update(status: model.status)
    }

    func remove() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        cancellables.removeAll()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureMenu() {
        // AppKit otherwise re-enables actionable menu items automatically,
        // overriding the connection-state gate applied in update(status:).
        menu.autoenablesItems = false
        let show = NSMenuItem(title: L10n.showWindow, action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        toggleItem.target = self
        toggleItem.action = #selector(toggleConnection)
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        copyItem.title = L10n.copyProxyEnvironment
        copyItem.action = #selector(copyEnvironment)
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func update(status: EngineStatus) {
        switch status {
        case .running:
            toggleItem.title = L10n.disconnect
            toggleItem.isEnabled = true
        case .starting:
            toggleItem.title = L10n.text("取消连接", "Cancel Connection")
            toggleItem.isEnabled = true
        case .stopping:
            toggleItem.title = L10n.stopping
            toggleItem.isEnabled = false
        case .stopped:
            toggleItem.title = L10n.connect
            toggleItem.isEnabled = true
        case .failed:
            toggleItem.title = L10n.connect
            toggleItem.isEnabled = true
        }
        statusItem.button?.image = statusImage(for: status)
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = "NekoPilot · \(status.localizedTitle)"
        if !status.isRunning {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            copyItem.title = L10n.copyProxyEnvironment
        }
        copyItem.isEnabled = status.isRunning
        copyItem.toolTip = status.isRunning
            ? L10n.text("已连接，可复制当前代理环境变量", "Connected. Copy the active proxy environment variables.")
            : L10n.text("连接后才能复制代理环境变量", "Connect before copying proxy environment variables.")
    }

    private func loadTemplateImage() -> NSImage? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "menu-bar-template", withExtension: "png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("native/Resources/menu-bar-template.png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources/menu-bar-template.png"),
        ].compactMap { $0 }
        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let image = NSImage(contentsOf: source) else {
            let fallback = NSImage(systemSymbolName: "shield", accessibilityDescription: "NekoPilot")
            fallback?.isTemplate = true
            return fallback
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func statusImage(for status: EngineStatus) -> NSImage? {
        guard let baseTemplateImage else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            baseTemplateImage.draw(
                // The shield is geometrically centered but visually top-heavy.
                // Lower the top-heavy shield by 1.5pt to match the optical
                // baseline of standard macOS menu-bar icons without changing
                // its size. The status badge has its own balanced position.
                in: NSRect(x: 1, y: 0.5, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let badgeRect = NSRect(x: 12.75, y: 1.5, width: 4, height: 4)
            switch status {
            case .running:
                NSBezierPath(ovalIn: badgeRect).fill()
            case .starting, .stopping:
                let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 0.4, dy: 0.4))
                ring.lineWidth = 1.1
                ring.stroke()
            case .failed:
                let inset = badgeRect.insetBy(dx: 0.6, dy: 0.6)
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
                cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
                cross.move(to: NSPoint(x: inset.minX, y: inset.maxY))
                cross.line(to: NSPoint(x: inset.maxX, y: inset.minY))
                cross.lineWidth = 1.15
                cross.lineCapStyle = .round
                cross.stroke()
            case .stopped:
                break
            }
            return true
        }
        // A single monochrome alpha mask lets macOS choose the correct menu
        // bar foreground in light, dark, tinted, and accessibility modes.
        image.isTemplate = true
        return image
    }

    @objc private func showWindow() {
        showWindowAction()
    }

    @objc private func toggleConnection() {
        guard let model else { return }
        Task { await model.toggleConnection() }
    }

    @objc private func copyEnvironment() {
        guard model?.status.isRunning == true, let port = model?.proxyPort else { return }
        let value = """
        export http_proxy=http://127.0.0.1:\(port)
        export https_proxy=http://127.0.0.1:\(port)
        export all_proxy=socks5://127.0.0.1:\(port)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copyFeedbackTask?.cancel()
        copyItem.title = L10n.text("已复制", "Copied")
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copyItem.title = L10n.copyProxyEnvironment
            self?.copyFeedbackTask = nil
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
