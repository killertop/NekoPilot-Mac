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
    private var cancellables = Set<AnyCancellable>()
    private var copyFeedbackTask: Task<Void, Never>?
    private lazy var baseTemplateImage = loadTemplateImage()

    init(model: AppModel) {
        self.model = model
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
        let dotColor: NSColor?
        switch status {
        case .running:
            dotColor = .systemGreen
            toggleItem.title = L10n.disconnect
            toggleItem.isEnabled = true
        case .starting:
            dotColor = .systemOrange
            toggleItem.title = L10n.text("取消连接", "Cancel Connection")
            toggleItem.isEnabled = true
        case .stopping:
            dotColor = .systemOrange
            toggleItem.title = L10n.stopping
            toggleItem.isEnabled = false
        case .stopped:
            dotColor = nil
            toggleItem.title = L10n.connect
            toggleItem.isEnabled = true
        case .failed:
            dotColor = .systemRed
            toggleItem.title = L10n.connect
            toggleItem.isEnabled = true
        }
        statusItem.button?.image = statusImage(dotColor: dotColor)
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

    private func statusImage(dotColor: NSColor?) -> NSImage? {
        guard let baseTemplateImage else { return nil }
        guard let dotColor else {
            baseTemplateImage.isTemplate = true
            return baseTemplateImage
        }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            baseTemplateImage.draw(
                in: NSRect(x: 0, y: 0, width: 18, height: 18),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: 1, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
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
