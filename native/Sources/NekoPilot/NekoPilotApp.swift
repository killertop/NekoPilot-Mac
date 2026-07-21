import AppKit
import SwiftUI
import NekoPilotCore

@main
struct NekoPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NekoPilot") {
            RootView(model: model)
                .onAppear { appDelegate.attach(model) }
        }
        .defaultSize(width: 371, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button(L10n.quit) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}
