// Usage: swift scripts/winshot.swift <owner> <out-prefix> — screenshots each on-screen window of an app.
import AppKit
let owner = CommandLine.arguments[1], prefix = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var n = 0
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    let id = w[kCGWindowNumber as String] as! Int
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(id)", "\(prefix)-\(n).png"]
    try! p.run(); p.waitUntilExit()
    print("\(prefix)-\(n).png", w[kCGWindowName as String] ?? "")
    n += 1
}
