import Foundation

enum L10n {
    private static var chinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    static func text(_ chineseText: String, _ englishText: String) -> String {
        chinese ? chineseText : englishText
    }

    static var home: String { text("首页", "Home") }
    static var nodes: String { text("节点", "Nodes") }
    static var rules: String { text("规则", "Rules") }
    static var settings: String { text("设置", "Settings") }
    static var showWindow: String { text("显示窗口", "Show Window") }
    static var copyProxyEnvironment: String { text("复制代理环境变量", "Copy Proxy Environment") }
    static var quit: String { text("退出 NekoPilot", "Quit NekoPilot") }
    static var connect: String { text("连接", "Connect") }
    static var disconnect: String { text("断开连接", "Disconnect") }
    static var starting: String { text("正在连接…", "Connecting…") }
    static var stopping: String { text("正在断开…", "Disconnecting…") }
}
