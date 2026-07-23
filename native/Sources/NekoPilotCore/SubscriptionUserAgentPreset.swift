import Foundation

public enum SubscriptionUserAgentPreset: String, CaseIterable, Identifiable, Sendable {
    case standard
    case sfm
    case sfa
    case sfi
    case custom

    public static let defaultValue = "sing-box 1.14.0-beta.1"
    private static let legacyDefaultValues: Set<String> = ["sing-box 1.14.0-alpha.48"]

    public var id: String { rawValue }

    public var detail: String? {
        switch self {
        case .standard: Self.defaultValue
        case .sfm: "SFM/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .sfa: "SFA/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .sfi: "SFI/1.12.9 (Build 1; sing-box 1.12.12; language zh_CN)"
        case .custom: nil
        }
    }

    public func resolvedValue(custom: String) -> String {
        self == .custom
            ? custom.trimmingCharacters(in: .whitespacesAndNewlines)
            : detail ?? Self.defaultValue
    }

    public static func matching(_ value: String) -> SubscriptionUserAgentPreset {
        if value == "default" || value == Self.defaultValue || legacyDefaultValues.contains(value) {
            return .standard
        }
        return allCases.first(where: { $0 != .custom && $0.detail == value }) ?? .custom
    }
}
