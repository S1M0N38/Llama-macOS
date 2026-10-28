import AppKit

/// DEBUG-only instrumentation for the menu-row hover highlight (issue #121).
///
/// Everything here is compiled out of release builds and is inert unless the
/// `LB_HOVER_TRACE` environment variable is set, so normal app behaviour is
/// unchanged. The point is to record the AppKit side of hover handling —
/// tracking-area enters/exits, tracking-area rebuilds, highlight transitions,
/// menu rebuilds and raw mouse events — plus a periodic invariant check that
/// catches the moment more than one row is lit, or a lit row no longer has the
/// pointer over it.
///
/// Usage:
///   LB_HOVER_TRACE=1 LB_HOVER_TRACE_PATH=/tmp/llama-hover.log \
///     ./build/Build/Products/Debug/Llama.app/Contents/MacOS/Llama
///
/// Optional:
///   LB_HOVER_TRACE_VERBOSE=1     log every raw mouse-moved event in the menu
///   LB_HOVER_SNAPSHOTS=1         write a PNG of the menu on a violation
///
/// Log format: one JSON object per line.
enum HoverTrace {

  // MARK: - Configuration

  static var isEnabled: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["LB_HOVER_TRACE"] != nil
    #else
      false
    #endif
  }

  #if DEBUG
    private static let verbose =
      ProcessInfo.processInfo.environment["LB_HOVER_TRACE_VERBOSE"] != nil
    /// Low-overhead mode: log highlight transitions and violations only, not
    /// the full tracking-area / raw-event firehose. Use this when timing
    /// matters (the app must keep up with real mouse events).
    private static let lean =
      ProcessInfo.processInfo.environment["LB_HOVER_TRACE_LEAN"] != nil
    private static let snapshotsEnabled =
      ProcessInfo.processInfo.environment["LB_HOVER_SNAPSHOTS"] != nil
    private static let logPath =
      ProcessInfo.processInfo.environment["LB_HOVER_TRACE_PATH"] ?? "/tmp/llama-hover.log"
    private static let snapshotDirectory = "/tmp/llama-hover-snapshots"

    private static var handle: FileHandle?
    private static var sequence = 0
    private static var started = false
    private static var tickTimer: Timer?
    private static var eventMonitor: Any?

    private static weak var menu: NSMenu?
    private static var menuIsOpen = false

    /// Last set of lit rows + pointer position, used to avoid logging an
    /// identical state twenty times a second.
    private static var lastStateSignature = ""
    private static var lastViolationSignature = ""
    private static var violationStreak = 0
    private static var snapshotCount = 0
    private static var lastSettledMouse = NSPoint.zero
    private static var lastMouseMoveAt = Date.distantPast

    // MARK: - Lifecycle

    /// Starts tracing for the given status-item menu. Safe to call more than once.
    static func start(menu: NSMenu) {
      guard isEnabled, !started else { return }
      started = true
      self.menu = menu

      try? FileManager.default.createDirectory(
        atPath: snapshotDirectory, withIntermediateDirectories: true)

      FileManager.default.createFile(atPath: logPath, contents: nil)
      handle = FileHandle(forWritingAtPath: logPath)

      log(
        "sessionStart",
        extra: [
          "app": Bundle.main.bundlePath,
          "version": AppInfo.shortVersion,
          "build": AppInfo.buildNumber,
          "os": ProcessInfo.processInfo.operatingSystemVersionString,
          "simulateModels": UserDefaults.standard.bool(forKey: "simulateModels"),
          "screens": NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ";"),
          "mainScreen": NSScreen.main.map { NSStringFromRect($0.frame) } ?? "nil",
          "log": logPath,
        ])

      // Raw event stream, before AppKit dispatches it. This shows whether
      // mouse-moved/entered/exited events reach the app at all, and when.
      if !lean {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
        .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp, .keyDown,
      ]) { event in
        guard isEnabled else { return event }
        if event.type == .mouseMoved && !verbose && !menuIsOpen { return event }
        var fields: [String: Any] = [
          "type": eventName(event.type),
          "window": event.windowNumber,
          "windowClass": event.window.map { String(describing: type(of: $0)) } ?? "nil",
          "locationInWindow": NSStringFromPoint(event.locationInWindow),
          "screenMouse": NSStringFromPoint(NSEvent.mouseLocation),
          "menuIsOpen": menuIsOpen,
        ]
        if let area = event.trackingArea {
          fields["trackingAreaRect"] = NSStringFromRect(area.rect)
          fields["trackingAreaOwner"] = area.owner.map { String(describing: type(of: $0)) } ?? "nil"
          fields["trackingAreaOptions"] = String(area.options.rawValue)
        }
        log("nsevent", extra: fields)
        return event
        }
      }

      // Run-loop timer added to .common so it keeps firing while the menu runs
      // its event-tracking loop. This is the detector: it checks the invariant
      // even when no tracking-area event fires.
      let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
        check(phase: "tick")
      }
      RunLoop.main.add(timer, forMode: .common)
      tickTimer = timer
    }

    static func menuWillOpen(_ menu: NSMenu) {
      guard isEnabled else { return }
      self.menu = menu
      menuIsOpen = true
      lastStateSignature = ""
      lastViolationSignature = ""
      log(
        "menuWillOpen",
        extra: menuWindowFields(for: menu).merging(["items": menu.numberOfItems]) { $1 })
      check(phase: "menuWillOpen")
    }

    static func menuDidClose(_ menu: NSMenu) {
      guard isEnabled else { return }
      log("menuDidClose", extra: menuWindowFields(for: menu))
      check(phase: "menuDidClose")
      menuIsOpen = false
      lastStateSignature = ""
      lastViolationSignature = ""
    }

    static func rebuildStarted(_ menu: NSMenu) {
      guard isEnabled else { return }
      log(
        "rebuildStart",
        extra: menuWindowFields(for: menu).merging(
          ["items": menu.numberOfItems, "menuIsOpen": menuIsOpen]) { $1 })
    }

    static func rebuildFinished(_ menu: NSMenu) {
      guard isEnabled else { return }
      log(
        "rebuildEnd",
        extra: menuWindowFields(for: menu).merging(
          ["items": menu.numberOfItems, "menuIsOpen": menuIsOpen]) { $1 })
      check(phase: "rebuildEnd")
    }

    // MARK: - Per-view events

    static func log(
      _ event: String,
      view: ItemView,
      nsEvent: NSEvent? = nil,
      extra: [String: Any] = [:]
    ) {
      guard isEnabled else { return }
      if lean && event != "mouseEntered" && event != "mouseExited" { return }
      var fields = viewFields(view)
      fields["highlighted"] = view.isHighlighted
      fields["highlightEnabled"] = view.highlightEnabled
      fields["label"] = view.traceLabel
      if let nsEvent {
        fields["eventType"] = eventName(nsEvent.type)
        fields["eventLocationInWindow"] = NSStringFromPoint(nsEvent.locationInWindow)
        fields["eventWindow"] = nsEvent.windowNumber
        fields["eventScreenMouse"] = NSStringFromPoint(NSEvent.mouseLocation)
        if let area = nsEvent.trackingArea {
          fields["trackingAreaRect"] = NSStringFromRect(area.rect)
          fields["trackingAreaOptions"] = String(area.options.rawValue)
          fields["trackingAreaOwner"] = area.owner.map {
            String(describing: type(of: $0))
          } ?? "nil"
        }
      }
      for (key, value) in extra { fields[key] = value }
      log(event, extra: fields)
    }

    /// Records a highlight request. `source` names the caller so the log shows
    /// whether a row was cleared by its own mouseExited or by something else.
    static func logHighlightChange(
      _ view: ItemView, requested: Bool, effective: Bool, was: Bool, source: String
    ) {
      guard isEnabled else { return }
      var fields = viewFields(view)
      fields["requested"] = requested
      fields["effective"] = effective
      fields["was"] = was
      fields["changed"] = was != effective
      fields["source"] = source
      fields["label"] = view.traceLabel
      log("setHighlight", extra: fields)
    }

    // MARK: - Invariant check

    /// The bug is "more than one row lit at once", so check exactly that:
    /// every lit row must contain the pointer, and at most one row may be lit.
    static func check(phase: String) {
      guard isEnabled, let menu else { return }

      let rows = menu.items.compactMap { $0.view as? ItemView }
      guard !rows.isEmpty else { return }

      let window = rows.compactMap(\.window).first
      let mouseInWindow = window?.mouseLocationOutsideOfEventStream
      let mouseScreen = NSEvent.mouseLocation

      // A tick can be processed while AppKit still has queued mouse moves to
      // dispatch (its tracking events lag the physical pointer). Only judge the
      // invariant once the pointer has been still for a while; the bug leaves
      // rows lit after the pointer stops, so this loses nothing.
      if mouseScreen != lastSettledMouse {
        lastSettledMouse = mouseScreen
        lastMouseMoveAt = Date()
      }
      let pointerSettled = Date().timeIntervalSince(lastMouseMoveAt) > 0.4
      if phase == "tick" && !pointerSettled {
        return
      }

      var inside: [ObjectIdentifier: Bool] = [:]
      for row in rows {
        guard let mouseInWindow else {
          inside[ObjectIdentifier(row)] = false
          continue
        }
        let local = row.convert(mouseInWindow, from: nil)
        // Adjacent rows share an exact edge and AppKit's tracking rectangles
        // include their top edge; NSRect.contains excludes maxY. Inset by a
        // point so a pointer sitting exactly on the shared edge isn't a false
        // "stale highlight".
        inside[ObjectIdentifier(row)] = row.bounds.insetBy(dx: -1, dy: -1).contains(local)
      }

      let highlighted = rows.filter(\.isHighlighted)
      let outsideLit = highlighted.filter { !(inside[ObjectIdentifier($0)] ?? false) }

      let signature =
        highlighted.map(\.traceLabel).joined(separator: ",")
        + "|mouse=" + (mouseInWindow.map(NSStringFromPoint) ?? "nil")

      let violationKind: String?
      if highlighted.count > 1 {
        violationKind = "multiple-highlighted"
      } else if !outsideLit.isEmpty {
        violationKind = "stale-highlight"
      } else {
        violationKind = nil
      }

      if signature != lastStateSignature {
        lastStateSignature = signature
        log(
          "state",
          extra: [
            "phase": phase,
            "highlighted": highlighted.map(\.traceLabel),
            "highlightedCount": highlighted.count,
            "mouseInWindow": mouseInWindow.map(NSStringFromPoint) ?? "nil",
            "mouseScreen": NSStringFromPoint(mouseScreen),
            "menuIsOpen": menuIsOpen,
            "items": menu.numberOfItems,
            "menuWindow": menuWindowFields(for: menu)["menuWindow"] ?? "nil",
            "zombieRows": zombieRows(in: menu).count,
            "appActive": NSApp.isActive,
            "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil",
          ])
      }

      guard let violationKind else {
        lastViolationSignature = ""
        violationStreak = 0
        return
      }

      // A tick can land between posting a mouse move and AppKit dispatching it,
      // so a single tick is not evidence. Require the violation to persist for
      // ~200ms; event-driven checks (enters/exits) are synchronous and immediate.
      violationStreak += 1
      if phase == "tick" && violationStreak < 4 { return }

      let violationSignature =
        violationKind + "|" + highlighted.map(\.traceLabel).joined(separator: ",")
      guard violationSignature != lastViolationSignature else { return }
      lastViolationSignature = violationSignature

      log(
        "VIOLATION",
        extra: [
          "kind": violationKind,
          "phase": phase,
          "highlighted": highlighted.map(\.traceLabel),
          "outsideLit": outsideLit.map(\.traceLabel),
          "mouseInWindow": mouseInWindow.map(NSStringFromPoint) ?? "nil",
          "mouseScreen": NSStringFromPoint(mouseScreen),
        ])

      dumpSnapshot(reason: "violation", menu: menu)
      writeSnapshotImageIfEnabled(menu: menu)
    }

    // MARK: - Snapshot

    /// One log line describing every menu item and row view in detail.
    static func dumpSnapshot(reason: String, menu: NSMenu? = nil) {
      guard isEnabled, !lean || reason == "violation", let menu = menu ?? self.menu else { return }
      let menuWindow = menu.items.compactMap { $0.view?.window }.first
      var fields = menuWindowFields(for: menu)
      fields["reason"] = reason
      fields["items"] = menu.numberOfItems
      fields["autoenablesItems"] = menu.autoenablesItems
      fields["highlightedItemIndex"] = menu.highlightedItem.flatMap { item in
        menu.index(of: item) >= 0 ? menu.index(of: item) : nil
      } ?? -1
      fields["rows"] = menu.items.enumerated().map { index, item -> String in
        guard let view = item.view else { return "#\(index) view=nil" }
        var parts = [
          "#\(index)",
          "class=\(type(of: view))",
          "frame=\(NSStringFromRect(view.frame))",
          "visibleRect=\(NSStringFromRect(view.visibleRect))",
          "inWindow=\(view.window != nil)",
          "enabled=\(item.isEnabled)",
          "itemHighlighted=\(item.isHighlighted)",
        ]
        if let row = view as? ItemView {
          let mouseInWindow = view.window?.mouseLocationOutsideOfEventStream
          let local = mouseInWindow.map { view.convert($0, from: nil) }
          parts.append("label=\(row.traceLabel)")
          parts.append("rowHighlighted=\(row.isHighlighted)")
          parts.append("highlightEnabled=\(row.highlightEnabled)")
          parts.append("mouseLocal=\(local.map(NSStringFromPoint) ?? "nil")")
          parts.append("mouseInside=\(local.map { view.bounds.contains($0) } ?? false)")
          parts.append(
            "trackingAreas=\(view.trackingAreas.map { NSStringFromRect($0.rect) }.joined(separator: "|"))"
          )
        }
        return parts.joined(separator: " ")
      }
      fields["zombieRows"] = zombieRows(in: menu)
      fields["menuWindow"] = menuWindow.map {
        "num=\($0.windowNumber) frame=\(NSStringFromRect($0.frame)) level=\($0.level.rawValue) class=\(type(of: $0)) screen=\($0.screen.map { NSStringFromRect($0.frame) } ?? "nil")"
      } ?? "nil"
      log("snapshot", extra: fields)
    }

    /// Dumps a PNG of the menu window using AppKit's own drawing path. This
    /// does not need Screen Recording permission, unlike `screencapture`.
    private static func writeSnapshotImageIfEnabled(menu: NSMenu) {
      guard snapshotsEnabled, snapshotCount < 40 else { return }
      guard
        let window = menu.items.compactMap({ $0.view?.window }).first,
        let content = window.contentView,
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
      else { return }
      content.cacheDisplay(in: content.bounds, to: rep)
      guard let png = rep.representation(using: .png, properties: [:]) else { return }
      snapshotCount += 1
      let path = "\(snapshotDirectory)/violation-\(snapshotCount)-\(sequence).png"
      do {
        try png.write(to: URL(fileURLWithPath: path))
        log("snapshotImage", extra: ["path": path, "count": snapshotCount])
      } catch {
        log("snapshotImageFailed", extra: ["path": path, "error": error.localizedDescription])
      }
    }

    /// ItemViews that are still in the menu window's view tree but no longer
    /// belong to any item in the menu. These are what a menu rebuild during
    /// tracking can leave behind; they are invisible to `menu.items`.
    static func zombieRows(in menu: NSMenu) -> [String] {
      guard
        let window = menu.items.compactMap({ $0.view?.window }).first
          ?? self.menu?.items.compactMap({ $0.view?.window }).first,
        let content = window.contentView
      else { return [] }
      var result: [String] = []
      func walk(_ view: NSView) {
        if let row = view as? ItemView, row.enclosingMenuItem == nil {
          result.append(
            "\(type(of: row)) label=\(row.traceLabel) frame=\(NSStringFromRect(row.frame))"
              + " lit=\(row.isHighlighted) superview=\(row.superview.map { String(describing: type(of: $0)) } ?? "nil")"
          )
        }
        for subview in view.subviews { walk(subview) }
      }
      walk(content)
      return result
    }

    // MARK: - Helpers

    private static func viewFields(_ view: ItemView) -> [String: Any] {
      var fields: [String: Any] = [
        "viewClass": String(describing: type(of: view)),
        "object": String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16),
        "frame": NSStringFromRect(view.frame),
        "bounds": NSStringFromRect(view.bounds),
        "visibleRect": NSStringFromRect(view.visibleRect),
        "inWindow": view.window != nil,
        "itemIndex": view.enclosingMenuItem.flatMap { item in
          item.menu.map { $0.index(of: item) }
        } ?? -1,
        "itemEnabled": view.enclosingMenuItem?.isEnabled ?? false,
        "itemHighlighted": view.enclosingMenuItem?.isHighlighted ?? false,
        "trackingAreas": view.trackingAreas.map { NSStringFromRect($0.rect) },
      ]
      if let window = view.window {
        let mouse = window.mouseLocationOutsideOfEventStream
        let local = view.convert(mouse, from: nil)
        fields["mouseInWindow"] = NSStringFromPoint(mouse)
        fields["mouseLocal"] = NSStringFromPoint(local)
        fields["mouseInside"] = view.bounds.insetBy(dx: -1, dy: -1).contains(local)
        fields["windowClass"] = String(describing: type(of: window))
        fields["windowNumber"] = window.windowNumber
        fields["windowFrame"] = NSStringFromRect(window.frame)
        let rectInWindow = view.convert(view.bounds, to: nil)
        fields["frameInWindow"] = NSStringFromRect(rectInWindow)
        fields["frameOnScreen"] = NSStringFromRect(window.convertToScreen(rectInWindow))
      }
      fields["menuHighlightedItem"] = view.enclosingMenuItem?.menu?.highlightedItem.map {
        String(describing: type(of: $0))
      } ?? "nil"
      return fields
    }

    private static func menuWindowFields(for menu: NSMenu) -> [String: Any] {
      guard let window = menu.items.compactMap({ $0.view?.window }).first else {
        return ["menuWindow": "nil", "menuIsOpen": menuIsOpen]
      }
      return [
        "menuWindow": "num=\(window.windowNumber) frame=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue) class=\(type(of: window))",
        "menuIsOpen": menuIsOpen,
        "screen": window.screen.map { NSStringFromRect($0.frame) } ?? "nil",
      ]
    }

    private static func eventName(_ type: NSEvent.EventType) -> String {
      switch type {
      case .mouseMoved: return "mouseMoved"
      case .mouseEntered: return "mouseEntered"
      case .mouseExited: return "mouseExited"
      case .leftMouseDown: return "leftMouseDown"
      case .leftMouseUp: return "leftMouseUp"
      case .keyDown: return "keyDown"
      default: return "type(\(type.rawValue))"
      }
    }

    private static func log(_ event: String, extra: [String: Any]) {
      guard isEnabled else { return }
      sequence += 1
      var fields: [String: Any] = [
        "seq": sequence,
        "t": String(format: "%.6f", Date().timeIntervalSince1970),
        "ev": event,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "mainThread": Thread.isMainThread,
      ]
      for (key, value) in extra { fields[key] = value }
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
        var line = String(data: data, encoding: .utf8)
      else { return }
      line += "\n"
      handle?.seekToEndOfFile()
      handle?.write(Data(line.utf8))
    }
  #else
    static func start(menu: NSMenu) {}
    static func menuWillOpen(_ menu: NSMenu) {}
    static func menuDidClose(_ menu: NSMenu) {}
    static func rebuildStarted(_ menu: NSMenu) {}
    static func rebuildFinished(_ menu: NSMenu) {}
    static func log(_ event: String, view: ItemView, nsEvent: NSEvent? = nil, extra: [String: Any] = [:])
    {}
    static func logHighlightChange(
      _ view: ItemView, requested: Bool, effective: Bool, was: Bool, source: String
    ) {}
    static func check(phase: String) {}
    static func dumpSnapshot(reason: String, menu: NSMenu? = nil) {}
  #endif
}
