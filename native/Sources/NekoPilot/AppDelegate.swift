import AppKit
import Darwin
import Foundation
import NekoPilotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var statusItemController: StatusItemController?
    private var terminationPending = false
    private var terminationFinished = false
    private var instanceLockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_: Notification) {
        guard acquireInstanceLock() else {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppPaths.bundleIdentifier
            )
            .first { $0.processIdentifier != getpid() }?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        statusItemController = StatusItemController(model: model)
        presentMainWindow()
        // SwiftUI does not create its initial WindowGroup while the process is
        // already an accessory app on current macOS. Switch only after the
        // first native window has appeared so the Dock icon can still be
        // hidden without suppressing the window.
        NSApp.setActivationPolicy(.accessory)
        model.initialize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func application(_: NSApplication, open urls: [URL]) {
        showMainWindow()
        urls.forEach { model?.handleDeepLink($0) }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if terminationFinished { return .terminateNow }
        if terminationPending { return .terminateLater }
        guard let model else { return .terminateNow }
        terminationPending = true
        Task { @MainActor [weak self] in
            let cleanup = Task { await model.shutdown() }
            let completion = FirstCompletion()
            Task {
                await cleanup.value
                await completion.resolve(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await completion.resolve(false)
            }
            let clean = await completion.wait()
            if !clean {
                cleanup.cancel()
                AppLogger.shared.error("termination cleanup exceeded 20 seconds; ownership markers retained for recovery")
            }
            self?.statusItemController?.remove()
            self?.statusItemController = nil
            self?.terminationFinished = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        statusItemController?.remove()
        if instanceLockDescriptor >= 0 {
            flock(instanceLockDescriptor, LOCK_UN)
            close(instanceLockDescriptor)
            instanceLockDescriptor = -1
        }
    }

    @objc private func willSleep() {
        Task { @MainActor [weak self] in self?.model?.handleSleep() }
    }

    @objc private func didWake() {
        Task { @MainActor [weak self] in self?.model?.handleWake() }
    }

    func showMainWindow() {
        presentMainWindow()
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func acquireInstanceLock() -> Bool {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppPaths.bundleIdentifier)-\(getuid()).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        instanceLockDescriptor = descriptor
        return true
    }
}

private actor FirstCompletion {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
