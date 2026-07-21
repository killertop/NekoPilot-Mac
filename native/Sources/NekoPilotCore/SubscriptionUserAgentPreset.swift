import Foundation

public enum SubscriptionUserAgentPreset: String, CaseIterable, Identifiable, Sendable {
    case standard
    case sfm
    case sfa
    case sfi
    case custom

    public var id: String { rawValue }

    public var detail: String? {
        switch self {
        case .standard: "sing-box 1.14.0-alpha.26"
        case .sfm: "SFM/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .sfa: "SFA/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .sfi: "SFI/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .custom: nil
        }
    }

    public func resolvedValue(custom: String) -> String {
        self == .custom
            ? custom.trimmingCharacters(in: .whitespacesAndNewlines)
            : detail ?? "sing-box 1.14.0-alpha.26"
    }

    public static func matching(_ value: String) -> SubscriptionUserAgentPreset {
        if value == "default" || value == "sing-box 1.14.0-alpha.26" { return .standard }
        return allCases.first(where: { $0 != .custom && $0.detail == value }) ?? .custom
    }
}
