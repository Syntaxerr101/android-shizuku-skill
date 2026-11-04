#!/usr/bin/env python3
"""ui_resolve.py — resolve a tap target inside a uiautomator dump.

Usage: ui_resolve.py <ui.xml> <target>

target forms:
  <idx>            node index printed by ui_parse.py
  text:<SUBSTR>    text or content-desc (exact match first, then substring)
  id:<SUBSTR>      resource-id (exact suffix first, then substring)
  xy:<x>,<y>       raw coordinate, no tree lookup

Matching a label returns the ACTIONABLE element: the node itself when it is
clickable/checkable, otherwise its nearest clickable/checkable ancestor. This is
why "text:Bluetooth" hits the row/switch, never the screen title.

Prints:   IDX CX CY CLASS "<label>"
Exits 1 when nothing matches, 2 on bad usage.
"""
import re
import sys
import xml.etree.ElementTree as ET


def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\s*", b or "")
    return tuple(map(int, m.groups())) if m else None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: ui_resolve.py <ui.xml> <target>")
    xmlp, target = sys.argv[1], sys.argv[2]

    if target.startswith("xy:"):
        try:
            x, y = target[3:].split(",", 1)
            print("-1 %d %d xy xy" % (int(x), int(y)))
            return
        except ValueError:
            sys.exit("target xy:<x>,<y> expected")

    try:
        root = ET.parse(xmlp).getroot()
    except Exception as exc:
        sys.exit("cannot parse %s: %s" % (xmlp, exc))

    nodes = []
    emap = {}
    for i, el in enumerate(root.iter()):
        emap[id(el)] = i
        a = el.attrib
        nodes.append({
            "idx": i,
            "text": a.get("text", ""),
            "desc": a.get("content-desc", ""),
            "rid": a.get("resource-id", ""),
            "bounds": parse_bounds(a.get("bounds", "")),
            "class": a.get("class", "").rsplit(".", 1)[-1],
            "clickable": a.get("clickable") == "true" or a.get("long-clickable") == "true",
            "checkable": a.get("checkable") == "true",
            "scrollable": a.get("scrollable") == "true",
            "enabled": a.get("enabled", "true") != "false",
        })

    parent = [-1] * len(nodes)

    def walk(el, pidx):
        idx = emap[id(el)]
        parent[idx] = pidx
        for child in el:
            walk(child, idx)

    walk(root, -1)

    def label(n):
        return n["text"] or n["desc"]

    if target.isdigit():
        hits = [n for n in nodes if n["idx"] == int(target)]
        exact = hits
    elif target.startswith("text:"):
        q = target[5:].strip().casefold()
        exact = [n for n in nodes if label(n).casefold() == q]
        hits = exact or [n for n in nodes if q in label(n).casefold()]
    elif target.startswith("id:"):
        q = target[3:].strip().casefold()
        exact = [n for n in nodes if n["rid"].casefold() == q or n["rid"].casefold().endswith("/" + q)]
        hits = exact or [n for n in nodes if q in n["rid"].casefold()]
    else:
        sys.exit("target must be <idx>, text:<s>, id:<s> or xy:<x>,<y>")

    if not hits:
        sys.exit("no node matches %r" % target)

    # Map every match to its actionable element (self or nearest clickable ancestor)
    # and rank. Closer ancestors beat distant ones; exact matches beat substrings.
    scored = []
    for n in hits:
        tgt = n
        depth = 0
        while tgt is not None and not (tgt["clickable"] or tgt["checkable"]):
            p = parent[tgt["idx"]]
            if p < 0:
                tgt = None
                break
            tgt = nodes[p]
            depth += 1
        if tgt is None or not tgt["bounds"] or not tgt["enabled"]:
            continue
        if tgt["scrollable"] and not (tgt["clickable"] or tgt["checkable"]):
            continue
        self_hit = 1 if tgt is n else 0
        is_exact = 1 if n in exact else 0
        area = max(1, (tgt["bounds"][2] - tgt["bounds"][0]) *
                   (tgt["bounds"][3] - tgt["bounds"][1]))
        scored.append(((-is_exact, depth, -self_hit, area), tgt, n))

    if not scored:
        # Nothing actionable: fall back to the matching node itself if visible.
        cands = [n for n in hits if n["bounds"] and n["enabled"]]
        if not cands:
            sys.exit("no visible node for %r" % target)
        n = cands[0]
        tgt = n
    else:
        scored.sort(key=lambda item: item[0])
        _, tgt, n = scored[0]

    if len(hits) > 1:
        print("# %d matches for %r; picked idx %d" % (len(hits), target, tgt["idx"]),
              file=sys.stderr)

    x1, y1, x2, y2 = tgt["bounds"]
    print('%d %d %d %s %r' % (tgt["idx"], (x1 + x2) // 2, (y1 + y2) // 2,
                              tgt["class"], label(n) or label(tgt)))


if __name__ == "__main__":
    main()
