#!/usr/bin/env python3
"""Summarise a Llama hover trace (see ../../Llama/Menu/HoverTrace.swift).

Usage:
  python3 summary.py /tmp/llama-hover.log
  python3 summary.py /tmp/llama-hover.log --verbose

Sessions are delimited by menuWillOpen/menuDidClose. For each one it reports
the tells that matter for issue #121:

  enters / exits / unpaired
      how many tracking-area transitions AppKit delivered, and how many enters
      never got a matching exit. A non-zero "unpaired" is the bug's fuel: the
      row that entered and never exited is still highlighted.
  max-lit / lit-at-close
      the largest number of rows highlighted at once, and how many were still
      filled when the menu closed. The issue is max-lit > 1.
  screen-coord-locations
      mouseExited events whose locationInWindow is in screen space (x near the
      menu's screen x instead of the row-local x). In a failing session this is
      usually equal to the number of exits.
  entered-while-lit
      concrete first examples: an enter for row B while row A was still lit.
"""

import json
import re
import sys


def parse(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def point(value):
    if not value:
        return None
    m = re.match(r"\{(-?[\d.]+), (-?[\d.]+)\}", value)
    return (float(m.group(1)), float(m.group(2))) if m else None


def menu_width(value):
    """Width from a `menuWindow` field: num=... frame={{x, y}, {w, h}} ..."""
    if not value:
        return None
    m = re.search(r"frame=\{\{[-\d.]+, [-\d.]+\}, \{([\d.]+), ([\d.]+)\}\}", value)
    return float(m.group(1)) if m else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    verbose = "--verbose" in sys.argv[2:]
    rows = parse(path)

    sessions = []
    current = None
    for row in rows:
        event = row.get("ev")
        if event == "sessionStart":
            print("launch:", row.get("version"), row.get("os"), row.get("app"))
            print("        simulated models:", row.get("simulateModels"))
        if event == "menuWillOpen":
            current = {
                "open": row,
                "enters": 0,
                "exits": 0,
                "max_lit": 0,
                "violations": [],
                "entered_while_lit": [],
                "screen_coord_locations": 0,
                "lit": set(),
                "max_lit_set": set(),
                "snapshots": [],
                "width": None,
            }
            sessions.append(current)
        if current is None:
            continue

        if event == "menuDidClose":
            current["close"] = row
            current["lit_at_close"] = set(current["lit"])
        elif event == "state":
            w = menu_width(row.get("menuWindow"))
            if w:
                current["width"] = w
        elif event == "mouseEntered":
            current["enters"] += 1
            label = row.get("label") or row.get("viewClass") or "?"
            others = current["lit"] - {label}
            if row.get("highlightEnabled") and others:
                entry = (label, tuple(sorted(others)))
                if not current["entered_while_lit"] or current["entered_while_lit"][-1] != entry:
                    current["entered_while_lit"].append(entry)
        elif event == "mouseExited":
            current["exits"] += 1
            loc = point(row.get("eventLocationInWindow"))
            width = current["width"] or 400
            if loc and loc[0] > width + 50:
                current["screen_coord_locations"] += 1
        elif event == "setHighlight":
            label = row.get("label") or "?"
            if row.get("effective"):
                current["lit"].add(label)
            else:
                current["lit"].discard(label)
            if len(current["lit"]) > current["max_lit"]:
                current["max_lit"] = len(current["lit"])
                current["max_lit_set"] = set(current["lit"])
        elif event == "VIOLATION":
            n = len(row.get("highlighted") or [])
            current["max_lit"] = max(current["max_lit"], n)
            current["violations"].append(row)
        elif event == "snapshotImage":
            current["snapshots"].append(row.get("path"))

    if not sessions:
        print("no menu sessions found (is the app tracing?)")
        return 1

    for i, s in enumerate(sessions, 1):
        opened = s["open"]
        closed = s.get("close")
        dur = round(float(closed["t"]) - float(opened["t"]), 2) if closed else None
        print(f"session {i} (seq {opened.get('seq')}, {dur}s, {opened.get('items')} items)")
        print(
            f"  enters={s['enters']} exits={s['exits']} "
            f"unpaired={s['enters'] - s['exits']} "
            f"max-lit={s['max_lit']} lit-at-close={len(s.get('lit_at_close', s['lit']))} "
            f"violations={len(s['violations'])} "
            f"screen-coord-locations={s['screen_coord_locations']}"
        )
        if s["max_lit_set"]:
            print("  max lit rows:")
            for name in sorted(s["max_lit_set"]):
                print("   ", name)
        if s["entered_while_lit"]:
            print("  first enters while another row was still lit:")
            for new_row, still_lit in s["entered_while_lit"][:3]:
                print(f"    {new_row!r} arrived while {still_lit!r} was lit")
        if s["snapshots"]:
            print("  snapshots:")
            for p in s["snapshots"][:3]:
                print("   ", p)
        if verbose:
            for v in s["violations"][:10]:
                print("   VIOLATION", v.get("kind"), v.get("highlighted"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
