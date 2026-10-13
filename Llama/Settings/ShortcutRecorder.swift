import Carbon.HIToolbox
import SwiftUI

/// Display / conversion helpers for the hotkey combo. Lives here (with the
/// only UI that renders combos) rather than in GlobalHotkey.swift, which stays
/// a pure registration wrapper.
extension GlobalHotkey.Combo {
  /// Human-readable form, e.g. "⌥Space" or "⌃⇧K" -- modifier symbols in the
  /// canonical macOS order (⌃⌥⇧⌘) followed by the key's name.
  var displayString: String {
    var symbols = ""
    if modifiers & controlKey != 0 { symbols += "⌃" }
    if modifiers & optionKey != 0 { symbols += "⌥" }
    if modifiers & shiftKey != 0 { symbols += "⇧" }
    if modifiers & cmdKey != 0 { symbols += "⌘" }
    return symbols + Self.keyName(for: keyCode)
  }

  /// Builds a combo from an NSEvent keypress, translating AppKit modifier
  /// flags to the Carbon mask `RegisterEventHotKey` expects. Returns `nil`
  /// when the combo isn't usable as a global hotkey: it needs ⌘, ⌥, or ⌃
  /// (a bare key or shift-only combo would shadow normal typing everywhere).
  static func from(event: NSEvent) -> GlobalHotkey.Combo? {
    var mods = 0
    if event.modifierFlags.contains(.control) { mods |= controlKey }
    if event.modifierFlags.contains(.option) { mods |= optionKey }
    if event.modifierFlags.contains(.shift) { mods |= shiftKey }
    if event.modifierFlags.contains(.command) { mods |= cmdKey }
    guard mods & (cmdKey | optionKey | controlKey) != 0 else { return nil }
    return GlobalHotkey.Combo(keyCode: Int(event.keyCode), modifiers: mods)
  }

  /// Name for a virtual key code: named keys (Space, arrows, F-keys, ...)
  /// from a fixed table, character keys from the current keyboard layout.
  private static func keyName(for keyCode: Int) -> String {
    if let special = specialKeyNames[keyCode] { return special }
    return layoutKeyName(for: keyCode) ?? "Key \(keyCode)"
  }

  /// Keys whose layout translation is empty or unreadable (whitespace,
  /// control, navigation, function keys).
  private static let specialKeyNames: [Int: String] = [
    kVK_Space: "Space",
    kVK_Return: "↩",
    kVK_Tab: "⇥",
    kVK_Escape: "⎋",
    kVK_Delete: "⌫",
    kVK_ForwardDelete: "⌦",
    kVK_LeftArrow: "←",
    kVK_RightArrow: "→",
    kVK_UpArrow: "↑",
    kVK_DownArrow: "↓",
    kVK_Home: "↖",
    kVK_End: "↘",
    kVK_PageUp: "⇞",
    kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
    kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
  ]

  /// Translates a key code to its base character in the user's current
  /// keyboard layout (so e.g. the key that types ";" on QWERTY shows as "M"
  /// on AZERTY). Uppercased for display, matching how macOS renders shortcuts.
  private static func layoutKeyName(for keyCode: Int) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data

    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let status = layoutData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> OSStatus in
      guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
        return OSStatus(paramErr)
      }
      return UCKeyTranslate(
        layout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,  // no modifiers -- we want the key's base character
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        chars.count,
        &length,
        &chars
      )
    }
    guard status == noErr, length > 0 else { return nil }
    let name = String(utf16CodeUnits: chars, count: length)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name.uppercased()
  }
}

/// A button that records a key combo: click to arm, then press the desired
/// shortcut. While armed it swallows keystrokes via a local event monitor;
/// Escape, clicking the button again, clicking anywhere else, or switching
/// apps cancels. Combos without ⌘/⌥/⌃ are ignored (they'd shadow normal
/// typing system-wide).
///
/// Known quirk (prototype scope): the currently-registered hotkey is still
/// live while recording, so re-pressing the *current* combo toggles the
/// capture panel instead of recording -- harmless, since re-recording the
/// same combo would be a no-op anyway.
struct ShortcutRecorder: View {
  /// `nil` means no shortcut is set -- the button then invites recording one.
  @Binding var combo: GlobalHotkey.Combo?

  @State private var recording = false
  @State private var monitor: Any?
  @FocusState private var focused: Bool
  /// The button's frame in window coordinates (SwiftUI's top-left origin),
  /// for telling a click outside it apart from one on it.
  @State private var frameInWindow: CGRect = .zero

  var body: some View {
    Button {
      recording ? stopRecording() : startRecording()
    } label: {
      Text(recording ? "Press shortcut…" : (combo?.displayString ?? "Record shortcut"))
        .foregroundStyle(recording || combo == nil ? .secondary : .primary)
    }
    // While armed, the button takes keyboard focus so the system draws its
    // focus ring -- like a focused text field -- saying keystrokes are being
    // captured. The label change alone read like a disabled button.
    // `.edit` (focus that updates state over time, as a text field's does)
    // is what lets a click give focus without system-wide "Keyboard
    // navigation"; a plain Button only has `.activate` focus, which doesn't.
    .focusable(interactions: .edit)
    .focused($focused)
    .onChange(of: recording) { focused = recording }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameInWindow = $0 }
    // Switching to another app cancels too -- the local monitor can't see its
    // keystrokes, so staying armed would just leave a stale ring behind.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      stopRecording()
    }
    // If the row disappears mid-recording (window closed), drop the monitor.
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
      // A click outside the button cancels, like blurring a text field, and
      // still goes through to whatever was clicked. Clicking empty space
      // doesn't move keyboard focus on macOS, so this can't hang off focus
      // changes. A click on the button itself is left to its action, which
      // already toggles recording off.
      if event.type == .leftMouseDown {
        if !isOnButton(event) { stopRecording() }
        return event
      }
      if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
        stopRecording()
        return nil
      }
      if let newCombo = GlobalHotkey.Combo.from(event: event) {
        combo = newCombo
        stopRecording()
        return nil
      }
      // Modifierless keystroke -- not a valid global shortcut; swallow it and
      // keep listening.
      return nil
    }
  }

  /// Whether a mouse event landed on the button. AppKit's window coordinates
  /// have a bottom-left origin, SwiftUI's a top-left one -- flip y against
  /// the content view's height to compare. (Not `contentView.convert`: the
  /// settings window's content view isn't flipped, so that yields the same
  /// bottom-left point.)
  private func isOnButton(_ event: NSEvent) -> Bool {
    guard let contentView = event.window?.contentView else { return false }
    let p = event.locationInWindow
    return frameInWindow.contains(CGPoint(x: p.x, y: contentView.bounds.height - p.y))
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
  }
}
