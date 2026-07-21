import Testing
@testable import NekoPilotCore

@Suite("Subscription User Agent presets")
struct SubscriptionUserAgentPresetTests {
    @Test("Known values restore their matching preset")
    func knownValuesMatch() {
        #expect(SubscriptionUserAgentPreset.matching("default") == .standard)
        #expect(SubscriptionUserAgentPreset.matching("sing-box 1.13.14") == .standard)
        #expect(SubscriptionUserAgentPreset.matching(SubscriptionUserAgentPreset.sfm.detail ?? "") == .sfm)
    }

    @Test("Unknown values remain editable as custom values")
    func unknownValueIsCustom() {
        #expect(SubscriptionUserAgentPreset.matching("ProviderClient/2") == .custom)
        #expect(SubscriptionUserAgentPreset.custom.resolvedValue(custom: " ProviderClient/2 ") == "ProviderClient/2")
    }
}
