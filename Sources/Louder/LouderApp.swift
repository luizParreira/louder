import AppKit
import SwiftUI

@main
struct LouderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(isOn: appDelegate.controller.isOn)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = LouderController()
    private var observers: [NSObjectProtocol] = []
    private var isDuplicate = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherInstanceIsRunning() {
            isDuplicate = true
            NSApp.terminate(nil)
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        let controller = controller
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { controller.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { controller.systemDidWake() }
            },
        ]
        controller.restoreOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isDuplicate { return }
        controller.shutdown()
    }

    /// Two copies would each tap the other's boosted output (each excludes only itself).
    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
    }
}
