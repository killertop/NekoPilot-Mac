import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var enabled = false
    @Published var errorMessage: String?

    init() { refresh() }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }
}
