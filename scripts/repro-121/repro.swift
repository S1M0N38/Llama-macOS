import AppKit
import CoreGraphics
import Foundation

// Repro driver for ggml-org/Llama-macOS#121.
//
// Opens the status-item menu through the app's own `show menu` AppleScript
// command, then moves the pointer down the menu rows immediately, before the
// open animation / initial layout has settled. That is the window in which
// AppKit drops the mouseExited that would clear the previous row: every row the
// pointer crosses stays highlighted.
//
// Requires the app to be running with hover tracing enabled:
//   LB_HOVER_TRACE=1 LB_HOVER_TRACE_LEAN=1 LB_HOVER_TRACE_PATH=/tmp/llama-hover.log
//
// Usage:
//   swift repro.swift [--runs 5] [--step 3] [--delay-us 16000] [--settle-ms 0]
//                     [--log /tmp/llama-hover.log] [--bundle-id app.llama.Llama.dev]
//
// Exit code 0 means every run reproduced (>=2 rows highlighted at once).

struct Options {
  var runs = 5
  var step: Double = 3
  var delayUs: UInt32 = 16_000
  var settleMs: UInt32 = 0
  var log = "/tmp/llama-hover.log"
  var bundleId = "app.llama.Llama.dev"

  static func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 1
    while i < args.count {
      switch args[i] {
      case "--runs": o.runs = Int(args[i + 1]) ?? o.runs; i += 2
      case "--step": o.step = Double(args[i + 1]) ?? o.step; i += 2
      case "--delay-us": o.delayUs = UInt32(args[i + 1]) ?? o.delayUs; i += 2
      case "--settle-ms": o.settleMs = UInt32(args[i + 1]) ?? o.settleMs; i += 2
      case "--log": o.log = args[i + 1]; i += 2
      case "--bundle-id": o.bundleId = args[i + 1]; i += 2
      case "--help", "-h":
        print("see header of this file"); exit(0)
      default:
        print("unknown argument: \(args[i])"); exit(2)
      }
    }
    return o
  }
}

let opts = Options.parse(CommandLine.arguments)

// MARK: - Log reading

func readLines() -> [[String: Any]] {
  guard let text = try? String(contentsOfFile: opts.log, encoding: .utf8) else { return [] }
  return text.split(separator: "\n").compactMap {
    guard let data = $0.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

func menuFrame(from lines: [[String: Any]]) -> NSRect? {
  let pattern = #"num=\d+ frame=\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}"#
  let regex = try! NSRegularExpression(pattern: pattern)
  for line in lines.reversed() {
    guard let raw = line["menuWindow"] as? String else { continue }
    let text = raw as NSString
    guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: text.length))
    else { continue }
    let v = (0..<4).map { Double(text.substring(with: m.range(at: $0 + 1)))! }
    return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
  }
  return nil
}

// MARK: - Mouse / keyboard

let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main!
let mainHeight = mainScreen.frame.height

func quartzPoint(_ p: NSPoint) -> CGPoint {
  // CGEvent positions are top-left based, in global display points; AppKit
  // screen coordinates are bottom-left based.
  CGPoint(x: p.x, y: mainHeight - p.y)
}

func moveMouse(to p: NSPoint) {
  let event = CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved,
    mouseCursorPosition: quartzPoint(p), mouseButton: .left)!
  event.post(tap: .cghidEventTap)
}

func pressEscape() {
  CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!.post(tap: .cghidEventTap)
  usleep(20_000)
  CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
}

func showMenu() {
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  task.arguments = ["-e", "tell application id \"\(opts.bundleId)\" to show menu"]
  task.standardOutput = FileHandle.nullDevice
  task.standardError = FileHandle.nullDevice
  try? task.run()  // deliberately not waited: it blocks until the menu closes
}

// MARK: - One run

func runOnce(index: Int, menu: NSRect) -> Bool {
  let beforeCount = readLines().count

  // Park on the status item, above the menu. A real user clicks here.
  let x = menu.midX
  let statusItem = NSPoint(x: x, y: menu.maxY + 8)
  moveMouse(to: statusItem)
  usleep(120_000)

  // Ask the app to open its menu.
  showMenu()

  // Wait until the app logs menuWillOpen. The log is written synchronously, so
  // this is as close as an external driver can get to the real click.
  var opened = false
  for _ in 0..<400 {
    let lines = readLines()
    if lines.count > beforeCount,
      lines.dropFirst(beforeCount).contains(where: { $0["ev"] as? String == "menuWillOpen" })
    {
      opened = true
      break
    }
    usleep(5_000)
  }
  guard opened else {
    print("run \(index): FAILED TO OPEN MENU")
    return false
  }

  if opts.settleMs > 0 { usleep(opts.settleMs * 1000) }

  // Sweep from just inside the menu's top edge to just above its bottom edge.
  var y = menu.maxY - 20
  let endY = menu.minY + 10
  moveMouse(to: NSPoint(x: x, y: y))
  usleep(10_000)
  while y > endY {
    y -= opts.step
    moveMouse(to: NSPoint(x: x, y: y))
    usleep(opts.delayUs)
  }

  // Leave the menu so nothing under the pointer can legitimately be lit.
  moveMouse(to: NSPoint(x: menu.minX - 60, y: menu.midY))
  usleep(60_000)
  moveMouse(to: NSPoint(x: max(20, menu.minX - 300), y: menu.midY))

  // Give the event queue time to drain and the invariant checker to settle.
  sleep(2)

  let slice = readLines().dropFirst(beforeCount)
  var maxLit = 0
  var multi = 0
  var stale = 0
  for line in slice {
    guard line["ev"] as? String == "VIOLATION" else { continue }
    let n = (line["highlighted"] as? [String])?.count ?? 0
    maxLit = max(maxLit, n)
    if line["kind"] as? String == "multiple-highlighted" { multi += 1 }
    if line["kind"] as? String == "stale-highlight" { stale += 1 }
  }
  let reproduced = multi > 0

  if let last = slice.last(where: { $0["ev"] as? String == "snapshotImage" }),
    let path = last["path"] as? String
  {
    print("run \(index): maxLit=\(maxLit) multi=\(multi) stale=\(stale) snapshot=\(path)")
  } else {
    print("run \(index): maxLit=\(maxLit) multi=\(multi) stale=\(stale)")
  }
  return reproduced
}

// MARK: - Main

var all = readLines()
var frame = menuFrame(from: all)
if frame == nil {
  // No menu has been opened since the app launched: open once just to learn
  // the window frame, then close again. Keep the pointer far away so this open
  // does not consume the first-hover trigger.
  print("no menu frame in log; priming with one open/close")
  moveMouse(to: NSPoint(x: 80, y: 80))
  usleep(150_000)
  showMenu()
  for _ in 0..<400 {
    usleep(5_000)
    if menuFrame(from: readLines()) != nil { break }
  }
  pressEscape()
  usleep(800_000)
  frame = menuFrame(from: readLines())
}
guard let menu = frame else {
  print("could not determine the menu window frame from \(opts.log)")
  print("is the app running with LB_HOVER_TRACE=1?")
  exit(1)
}

print("menu frame: \(NSStringFromRect(menu))")
print("runs=\(opts.runs) step=\(opts.step) delayUs=\(opts.delayUs) settleMs=\(opts.settleMs)")

var successes = 0
for run in 1...opts.runs {
  if runOnce(index: run, menu: menu) { successes += 1 }
  // Close the menu for the next run.
  pressEscape()
  usleep(700_000)
}

print("")
print("REPRODUCED \(successes)/\(opts.runs) runs")
exit(successes == opts.runs ? 0 : 1)
