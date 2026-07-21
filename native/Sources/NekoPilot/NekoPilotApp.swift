import AppKit
import SwiftUI
import NekoPilotCore

@main
struct NekoPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup("NekoPilot") {
            Group {
                if let model = bootstrap.model {
                    RootView(model: model)
                        .onAppear { appDelegate.attach(model) }
                } else {
                    StartupFailureView(message: bootstrap.errorMessage)
                }
            }
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

@MainActor
private final class AppBootstrap: ObservableObject {
    let model: AppModel?
    let errorMessage: String

    init() {
        do {
            model = try AppModel()
            errorMessage = ""
        } catch {
            model = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(L10n.text("NekoPilot 无法启动", "NekoPilot Could Not Start"))
                .font(.system(size: 19, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button(L10n.quit) { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(minWidth: 360, idealWidth: 371, minHeight: 560, idealHeight: 600)
    }
}
