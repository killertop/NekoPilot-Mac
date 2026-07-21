#!/usr/bin/env swift

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let rawPID = Int32(CommandLine.arguments[1]) else {
    fputs("usage: window-count.swift PID\n", stderr)
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let count = windows.filter { window in
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == rawPID,
          (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = (bounds["Width"] as? NSNumber)?.doubleValue,
          let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
        return false
    }
    return width >= 200 && height >= 200
}.count

print(count)
