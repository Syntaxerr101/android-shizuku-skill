#!/usr/bin/env python3
"""ui_toggle.py — locate the toggle (checkable) switch in the row with a given label.

Usage: ui_toggle.py <ui.xml> "<label substring>"

Prints:  <idx> <cx> <cy> <checked>
   checked is the literal True/False of the switch ("checked" attribute), so the
   caller can decide whether a tap is needed and verify the result afterwards.

Selection: among all checkable nodes, pick the one whose vertical center is
closest to the labelled text node's vertical center (i.e. the switch on the same
row, even when the row itself is not marked checkable). Exits 1 with a message
when the label or any checkable node is missing.
"""
import sys
import re
import xml.etree.ElementTree as ET


def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(\d+),(\d+)\]\[(\d+),(\d+)\]\s*", b or "")
    return tuple(map(int, m.groups())) if m else None


def main():
    xmlp, label = sys.argv[1], sys.argv[2].lower()
    root = ET.parse(xmlp).getroot()

    nodes = []
    for i, el in enumerate(root.iter()):
        a = el.attrib
        b = parse_bounds(a.get("bounds", ""))
        if not b:
            continue
        nodes.append({
            "idx": i,
            "label": (a.get("text", "") or a.get("content-desc", "")),
            "checkable": a.get("checkable") == "true",
            "checked": a.get("checked") == "true",
            "bounds": b,
        })

    text_nodes = [n for n in nodes if label in n["label"].lower()]
    if not text_nodes:
        sys.stderr.write("label not found: %s\n" % label)
        sys.exit(1)
    t = text_nodes[0]
    tcy = (t["bounds"][1] + t["bounds"][3]) // 2

    checks = [n for n in nodes if n["checkable"]]
    if not checks:
        sys.stderr.write("no checkable node found in %s\n" % xmlp)
        sys.exit(1)

    n = min(checks, key=lambda c: abs((c["bounds"][1] + c["bounds"][3]) // 2 - tcy))
    x1, y1, x2, y2 = n["bounds"]
    print("%d %d %d %s" % (n["idx"], (x1 + x2) // 2, (y1 + y2) // 2,
                           "True" if n["checked"] else "False"))


if __name__ == "__main__":
    main()
