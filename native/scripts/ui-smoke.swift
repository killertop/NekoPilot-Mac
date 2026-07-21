#!/usr/bin/env swift

import ApplicationServices
import AppKit
import Foundation

guard AXIsProcessTrusted() else {
    fputs("[ui-smoke] SKIP: the test runner has no macOS Accessibility permission\n", stderr)
    exit(77)
}

guard CommandLine.arguments.count == 2,
      let rawPID = Int32(CommandLine.arguments[1]) else {
    fputs("usage: ui-smoke.swift PID\n", stderr)
    exit(2)
}

let application = AXUIElementCreateApplication(rawPID)
NSRunningApplication(processIdentifier: rawPID)?.activate(options: [])
_ = AXUIElementSetAttributeValue(
    application,
    kAXFrontmostAttribute as CFString,
    kCFBooleanTrue
)
Thread.sleep(forTimeInterval: 0.5)

func values(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else { return [] }
    if CFGetTypeID(value) == AXUIElementGetTypeID() {
        return [value as! AXUIElement]
    }
    return value as? [AXUIElement] ?? []
}

func text(_ element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

func descendants() -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = values(application, attribute: kAXWindowsAttribute)
    var index = 0
    while index < queue.count, result.count < 2_000 {
        let element = queue[index]
        index += 1
        result.append(element)
        queue.append(contentsOf: values(element, attribute: kAXChildrenAttribute))
    }
    return result
}

func labels() -> [String] {
    descendants().flatMap { element in
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { text(element, attribute: $0) }
    }
}

func contains(_ alternatives: [String]) -> Bool {
    let snapshot = labels()
    return alternatives.contains { expected in snapshot.contains(where: { $0.contains(expected) }) }
}

func press(_ alternatives: [String]) -> Bool {
    for element in descendants() {
        let candidates = [kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { text(element, attribute: $0) }
        if alternatives.contains(where: { expected in candidates.contains(where: { $0 == expected }) }),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
    }
    return false
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("[ui-smoke] \(message)\n", stderr)
        let snapshot = Array(Set(labels())).sorted().prefix(100).joined(separator: " | ")
        fputs("[ui-smoke] visible accessibility labels: \(snapshot)\n", stderr)
        exit(1)
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return false
}

let accessibilityAvailable = waitUntil {
    !values(application, attribute: kAXWindowsAttribute).isEmpty
}
guard accessibilityAvailable else {
    fputs("[ui-smoke] SKIP: the packaged app's accessibility tree is unavailable to this runner\n", stderr)
    exit(77)
}
let accessibilityLabelsAvailable = waitUntil { !labels().isEmpty }
guard accessibilityLabelsAvailable else {
    fputs("[ui-smoke] SKIP: the runner cannot read labels from the packaged app's accessibility tree\n", stderr)
    exit(77)
}

require(waitUntil { contains(["测速", "Speed Test"]) }, "Home did not expose the speed-test action")
require(press(["节点", "Nodes"]), "Could not activate the Nodes tab")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["添加节点", "Add Node"]) }, "Nodes tab did not expose Add Node")
require(press(["添加节点", "Add Node"]), "Could not open the Add Node sheet")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["导入", "Import"]) }, "Add Node sheet did not expose Import")
require(press(["取消", "Cancel"]), "Could not dismiss the Add Node sheet")
Thread.sleep(forTimeInterval: 0.4)
require(press(["规则", "Rules"]), "Could not activate the Rules tab")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["添加规则", "Add Rule"]) }, "Rules tab did not expose Add Rule")
require(press(["规则说明", "Rule Information"]), "Could not open rule information")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["优先级", "Priority"]) }, "Rule information did not expose priority")
require(press(["关闭", "Close"]), "Could not dismiss rule information")
Thread.sleep(forTimeInterval: 0.4)
require(press(["添加规则", "Add Rule"]), "Could not open Add Rule")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["支持换行", "Paste multiple values"]) }, "Add Rule did not expose bulk input")
require(press(["完成", "Done"]), "Could not dismiss Add Rule")
Thread.sleep(forTimeInterval: 0.4)
require(press(["设置", "Settings"]), "Could not activate the Settings tab")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["自动选择节点", "Automatic Node Selection"]) }, "Settings tab did not expose automatic selection")
require(contains(["GitHub"]), "Settings tab did not expose GitHub releases")
require(press(["User Agent 设置", "User Agent Settings"]), "Could not open User Agent settings")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["默认（sing-box）", "Default (sing-box)"]) }, "User Agent settings did not expose the default preset")
require(contains(["SFM 1.12"]), "User Agent settings did not expose the SFM preset")
require(press(["自定义", "Custom"]), "Could not select the custom User Agent preset")
Thread.sleep(forTimeInterval: 0.2)
require(waitUntil { contains(["输入自定义 User Agent", "Enter a custom User Agent"]) }, "Custom User Agent did not expose an editable field")
require(press(["取消", "Cancel"]), "Could not dismiss User Agent settings")
Thread.sleep(forTimeInterval: 0.3)
require(press(["首页", "Home"]), "Could not return to the Home tab")
Thread.sleep(forTimeInterval: 0.4)
require(waitUntil { contains(["测速", "Speed Test"]) }, "Home did not recover after tab navigation")

print("[ui-smoke] OK: Home, Nodes, Rules help/add, Settings/User Agent, and return navigation")
