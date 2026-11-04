#!/usr/bin/env python3
"""ui_toggle.py — find the switch/checkbox belonging to a labelled settings row.

Usage: ui_toggle.py <ui.xml> "<label substring>"

Prints:  <idx> <cx> <cy> <checked:True|False>

Selection is row-aware, not just "nearest switch by y":
  * the label node is the shortest matching text/desc node (avoids containers),
  * candidates must share the label's vertical band,
  * a switch to the RIGHT of the label wins (LTR settings rows),
  * ties are broken by vertical distance.
This stops a lookup for "Bluetooth" from grabbing a switch in the row above.

Exits 1 when the label or any checkable node is missing.
"""
import re
import sys
import xml.etree.ElementTree as ET


def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\s*", b or "")
    return tuple(map(int, m.groups())) if m else None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: ui_toggle.py <ui.xml> \"<label>\"")
    xmlp, label = sys.argv[1], sys.argv[2].strip().casefold()

    root = ET.parse(xmlp).getroot()
    nodes = []
    for i, el in enumerate(root.iter()):
        a = el.attrib
        b = parse_bounds(a.get("bounds", ""))
        if not b:
            continue
        nodes.append({
            "idx": i,
            "label": a.get("text", "") or a.get("content-desc", ""),
            "checkable": a.get("checkable") == "true",
            "checked": a.get("checked") == "true",
            "enabled": a.get("enabled", "true") != "false",
            "bounds": b,
        })

    matches = [n for n in nodes if label in n["label"].casefold() and n["enabled"]]
    if not matches:
        sys.stderr.write("label not found: %s\n" % label)
        sys.exit(1)
    # exact match first, then shortest label, then smallest area
    t = sorted(matches, key=lambda n: (
        n["label"].casefold() != label,
        len(n["label"]),
        (n["bounds"][2] - n["bounds"][0]) * (n["bounds"][3] - n["bounds"][1]),
    ))[0]

    checks = [n for n in nodes if n["checkable"] and n["enabled"]]
    if not checks:
        sys.stderr.write("no checkable node found in %s\n" % xmlp)
        sys.exit(1)

    tx1, ty1, tx2, ty2 = t["bounds"]
    tcx, tcy = (tx1 + tx2) // 2, (ty1 + ty2) // 2
    th = max(1, ty2 - ty1)

    def score(c):
        cx1, cy1, cx2, cy2 = c["bounds"]
        ccx, ccy = (cx1 + cx2) // 2, (cy1 + cy2) // 2
        # vertical overlap / proximity to the label row
        band = min(th, 80)
        in_band = 0 if abs(ccy - tcy) <= max(30, band) else 1
        right = 0 if ccx >= tcx else 1
        return (in_band, right, abs(ccy - tcy), abs(ccx - tcx))

    c = min(checks, key=score)
    x1, y1, x2, y2 = c["bounds"]
    print("%d %d %d %s" % (c["idx"], (x1 + x2) // 2, (y1 + y2) // 2,
                           "True" if c["checked"] else "False"))


if __name__ == "__main__":
    main()
