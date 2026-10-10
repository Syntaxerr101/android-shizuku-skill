#!/usr/bin/env python3
"""ui_resolve.py — resolve a tap target inside a ui.xml dump.

Usage: ui_resolve.py <ui.xml> <target>

target forms:
  <idx>            node index (from ui_parse.py screen.txt)
  text:<SUBSTR>    a node whose text or content-desc contains SUBSTR
                   (exact case-insensitive match preferred, then substring;
                    scrollable containers are skipped as tap targets)

Prints:   IDX <cx> <cy> <CLASS> "<label>"
Exits 1 with a message when nothing matches.
"""
import sys, re
import xml.etree.ElementTree as ET

def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(\d+),(\d+)\]\[(\d+),(\d+)\]\s*", b or "")
    return tuple(map(int, m.groups())) if m else None

def main():
    xmlp, target = sys.argv[1], sys.argv[2]
    root = ET.parse(xmlp).getroot()
    nodes = []
    for el in root.iter():
        a = el.attrib
        nodes.append({
            "idx": len(nodes),
            "text": a.get("text",""),
            "desc": a.get("content-desc",""),
            "bounds": parse_bounds(a.get("bounds","")),
            "class": a.get("class","").rsplit(".",1)[-1],
            "clickable": a.get("clickable")=="true" or a.get("long-clickable")=="true",
            "scrollable": a.get("scrollable")=="true",
            "enabled": a.get("enabled")=="true",
            "pkg": a.get("package",""),
        })

    def label(n): return n["text"] or n["desc"]

    if target.isdigit():
        hits = [n for n in nodes if n["idx"] == int(target)]
    elif target.startswith("text:"):
        q = target[5:]
        hits = [n for n in nodes if (q.lower() == label(n).lower())]
        if not hits:
            hits = [n for n in nodes if q.lower() in label(n).lower()]
    else:
        print("target must be <idx> or text:<substring>"); sys.exit(2)

    # prefer enabled, clickable, non-scrollable targets
    def rank(n):
        return (n["clickable"], not n["scrollable"], n["enabled"], len(label(n)) > 0)

    cands = [n for n in hits if n["bounds"] and n["enabled"]]
    if not cands:
        print(f"no tappable node for {target!r}; node exists but not enabled/visible"); sys.exit(1)
    cands.sort(key=rank, reverse=True)
    n = cands[0]
    x1,y1,x2,y2 = n["bounds"]
    cx, cy = (x1+x2)//2, (y1+y2)//2
    if len(cands) > 1:
        print(f"# WARNING: {len(cands)} matches for {target!r}; picked idx {n['idx']}", file=sys.stderr)
    print(f"{n['idx']} {cx} {cy} {n['class']} {label(n)!r}")

if __name__ == "__main__":
    main()