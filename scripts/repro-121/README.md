# Reproducing #121 — stuck menu-row hover highlights

DEBUG-only lab for [ggml-org/Llama-macOS#121](https://github.com/ggml-org/Llama-macOS/issues/121):
after moving over the model rows, several stay filled at once.

The key part is not a screenshot. It is an app-side invariant — *at most one row
may be highlighted, and a highlighted row must contain the pointer* — checked
20 times a second while the menu is open. When it fails, the app logs the full
row state and writes a PNG of the menu using AppKit's own drawing path.

## Result

On a fresh app, `repro-fresh.sh` reproduces reliably (3/3 here). A run leaves
**13 rows** filled at once. The trace for that session:

```
enters=182  exits=165  unpaired=17  max-lit=13  screen-coord-locations=165
```

- 17 `mouseEntered` events never got a matching `mouseExited`.
- Every delivered exit carried **screen coordinates** in `locationInWindow`.
- 13 rows were still filled when the pointer left the menu.

Exact counts vary by a few events per run; `unpaired` and `max-lit` are the
stable signals.

## Quick start

```sh
cd scripts/repro-121
./build.sh
./launch.sh                 # deterministic 22-model fixture + tracing
swift repro.swift --runs 1  # open menu + sweep the rows immediately
```

Expected tail:

```
run 1: maxLit=13 multi=… snapshot=/tmp/llama-hover-snapshots/…
REPRODUCED 1/1 runs
```

For repeatable attempts, restart the app between runs:

```sh
./repro-fresh.sh 1          # or 3
```

Analyse a session:

```sh
python3 summary.py /tmp/llama-hover.log
```

Stop the app with `./stop.sh`.

Requires Accessibility permission for the terminal (to post mouse events).
`repro.swift` reads the menu window frame from the trace and opens the menu via
the app's own `show menu` AppleScript command, so it works wherever the status
item is.

## How the reproduction works

1. `launch.sh` enables the DEBUG `SimulatedModels` fixture: 22 fake installed
   models, no downloads, no network, identical every launch.
2. `repro.swift` parks the pointer on the status item, opens the menu, waits for
   `menuWillOpen` in the trace, then sweeps down at 3 px / 16 ms starting
   immediately. The timing is the trigger: the pointer is already moving while
   the rows are laid out.
3. `HoverTrace` records every tracking-area enter/exit, every highlight change
   and who caused it (`mouseEntered`, `mouseExited`, `updateTrackingAreas`), and
   raw `NSEvent` locations in verbose mode.
4. The invariant check runs on a timer added to `.common`, so it keeps firing
   during AppKit's menu-tracking run loop. It waits 400 ms after the pointer
   stops before judging, so a lagging event queue is not reported as a bug.
5. On a violation it writes `/tmp/llama-hover-snapshots/violation-*.png` and a
   `snapshot` line with every row's frame, `isHighlighted`, tracking areas and
   pointer position.

Restarting the app matters: a failing session processes nearly every posted
mouse move (~181 enters). A later open in the same process usually coalesces to
about one sample per row (~17 enters) and does not fail. The exact AppKit path
that is taken depends on main-thread timing; restarting makes the attempt
repeatable instead of a coin flip.

## Manual reproduction

1. `./launch.sh`
2. Click the Llama status item.
3. Immediately move the pointer down over the installed rows.
4. Several rows stay filled after the pointer leaves them.

Restart before each attempt. A 1-second pause before moving is the control:

```sh
swift repro.swift --runs 1 --settle-ms 1000   # normally 0/1
```

## Root cause

`ItemView` keeps its own `isHighlighted` boolean: it sets it in `mouseEntered`
and clears it only in `mouseExited`. That assumes the two events are a reliable
pair. Inside view-backed `NSMenuItem`s they are not:

1. **Exits carry screen coordinates.** `mouseExited.locationInWindow` is in
   screen space, not window space. In a reproduced session the menu was at
   screen x≈1931 and the row-local pointer x was ≈165, but the exit reported
   ≈2058. AppKit's tracking state is updated from that bogus point, so the next
   move emits `mouseEntered` again — the log shows `exit → enter → exit → enter`
   on every move within a row.
2. **The exit at a row boundary is dropped.** The next row's `mouseEntered`
   arrives; the previous row's `mouseExited` does not. Because nothing else
   clears a row, it stays filled. Crossing N boundaries leaves N rows lit.

The first missed exit in a run:

```json
{"ev":"VIOLATION","kind":"multiple-highlighted",
 "highlighted":["ggml-org/gemma-4-E2B-it-GGUF:Q8_0",
                "HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive:Q6_K_P"]}
```

The screenshot written at that moment shows both rows filled. The attached
issue video shows the same accumulation over several rows.

Why the app ended up here: every menu item is created **disabled**, so clicking
a row does not close the menu. Disabled items are outside AppKit's highlight
path — AppKit never makes them the highlighted item and never calls
`menu(_:willHighlight:)` for them. `ItemView` therefore reimplements hover with
an `NSTrackingArea`, and that reimplementation inherits the unreliable exit
delivery.

## Apple references

- **Apple Developer Forums 749138** — “NSMenuItem's custom view property returns
  wrong `locationInWindow` value on `mouseExited`”:
  <https://developer.apple.com/forums/thread/749138>
- **Using Tracking-Area Objects** — enters and exits are documented as paired;
  tracking-rect edges are inclusive at top/left and exclusive at bottom/right
  (adjacent rows share an edge):
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html>
- **`NSMenuDelegate.menu(_:willHighlight:)`** — “Only one item per menu can be
  highlighted at a time”:
  <https://developer.apple.com/documentation/appkit/nsmenudelegate/menu(_:willhighlight:)>
- **Views in Menu Items** — a view in a menu item receives mouse events
  normally; resizing during menu tracking is not supported:
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/ViewsInMenuItems.html>
- **`NSMenuItem.view`** — the view owns drawing, the menu owns selection state:
  <https://developer.apple.com/documentation/appkit/nsmenuitem/view>

## What an Apple-correct fix would be

Let the menu own the highlight: enable the items and mirror
`menu(_:willHighlight:)` onto the rows (`highlightEnabled` still suppresses
non-interactive rows). AppKit then guarantees one highlighted item, and there is
no enter/exit pairing to lose. Alternatively, move this UI to an `NSPopover`.

PR #125's “clear siblings on every enter” is the minimal containment: it removes
the visual accumulation but leaves the dropped exits in the trace.

## Files

| file | purpose |
| --- | --- |
| `Llama/Menu/HoverTrace.swift` | trace, invariant check, PNG snapshots |
| `Llama/Menu/ItemView.swift` | trace points in the real hover path (behaviour unchanged) |
| `Llama/Menu/MenuController.swift` | menu open/rebuild tracing |
| `scripts/repro-121/repro.swift` | menu-open + pointer sweep + detection |
| `scripts/repro-121/repro-fresh.sh` | restart app and repeat |
| `scripts/repro-121/summary.py` | per-session event analysis |
| `scripts/repro-121/lldb.sh` | optional: attach with hover breakpoints |
| `scripts/repro-121/launch.sh` | restart with tracing + fixture |

All instrumentation is gated by `LB_HOVER_TRACE` and compiled only in DEBUG;
with the variable unset the app behaves as before.

## Cleanup

```sh
./stop.sh
defaults delete app.llama.Llama.dev simulateModels
rm -f /tmp/llama-hover.log
rm -rf /tmp/llama-hover-snapshots
```

## Troubleshooting

- **No violations on a second attempt** — restart with `./repro-fresh.sh`.
- **Menu does not open** — the Debug bundle id is `app.llama.Llama.dev`; check
  `/tmp/llama-hover.log` for `sessionStart`.
- **Pointer does not move** — grant Accessibility (and Input Monitoring on some
  macOS versions) to the terminal.
- **No PNG** — `launch.sh` sets `LB_HOVER_SNAPSHOTS=1`; check the snapshot
  directory.
- **Want verbose detail** — `./launch.sh --verbose` also logs raw `NSEvent`s
  and every `updateTrackingAreas` pass.
