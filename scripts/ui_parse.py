#!/usr/bin/env python3
"""ui_parse.py — turn a uiautomator XML dump into a JSON model + a readable screen.txt.

Usage: ui_parse.py <ui.xml> <screen.json>
Prints a condensed, indexed, agent-friendly listing to stdout.
"""
import sys, re, json
import xml.etree.ElementTree as ET

def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(\d+),(\d+)\]\[(\d+),(\d+)\]\s*", b or "")
    if not m:
        return {"x1":0,"y1":0,"x2":0,"y2":0,"w":0,"h":0,"cx":0,"cy":0}
    x1,y1,x2,y2 = map(int, m.groups())
    return {"x1":x1,"y1":y1,"x2":x2,"y2":y2,"w":x2-x1,"h":y2-y1,"cx":(x1+x2)//2,"cy":(y1+y2)//2}

def main():
    src, dst = sys.argv[1], sys.argv[2]
    tree = ET.parse(src)
    root = tree.getroot()
    nodes = []
    for el in root.iter():
        a = el.attrib
        cls = a.get("class","").rsplit(".",1)[-1]
        b = parse_bounds(a.get("bounds",""))
        n = {
            "idx": len(nodes),
            "text": a.get("text",""),
            "desc": a.get("content-desc",""),
            "rid": a.get("resource-id",""),
            "class": cls,
            "pkg": a.get("package",""),
            "clickable": a.get("clickable") == "true",
            "long_clickable": a.get("long-clickable") == "true",
            "checkable": a.get("checkable") == "true",
            "checked": a.get("checked") == "true",
            "selected": a.get("selected") == "true",
            "enabled": a.get("enabled") == "true",
            "focused": a.get("focused") == "true",
            "scrollable": a.get("scrollable") == "true",
            "password": a.get("password") == "true",
            "editable": a.get("class","").endswith("EditText"),
        }
        n.update(b)
        nodes.append(n)

    with open(dst, "w") as f:
        json.dump(nodes, f, indent=1)

    interesting = [
        n for n in nodes
        if n["enabled"] and (n["text"] or n["desc"] or n["clickable"]
                             or n["long_clickable"] or n["checkable"] or n["editable"]
                             or n["scrollable"])
    ]
    def marks(n):
        parts = []
        if n["clickable"] or n["long_clickable"]: parts.append("TAP")
        if n["editable"]: parts.append("FIELD")
        if n["checkable"]: parts.append("CHECK" + (":%s" % n["checked"]))
        if n["scrollable"] and not (n["clickable"]): parts.append("SCROLL")
        return ",".join(parts)
    lines = []
    for n in interesting:
        label = (n["text"] or n["desc"]).replace("\n", "\\n")
        if len(label) > 56: label = label[:53] + "..."
        rid = n["rid"].split("/")[-1] if n["rid"] else ""
        lines.append(
            f'{n["idx"]:>4} | {marks(n):<10} | {n["class"]:<18} | {label or "-"!r:<58} '
            f'| [{n["x1"]},{n["y1"]}][{n["x2"]},{n["y2"]}] -> {n["cx"]},{n["cy"]}'
            + (f'  #{rid}' if rid else ""))
    print("\n".join(lines))
    print(f"\n# {len(nodes)} raw nodes, {len(interesting)} actionable/textual | pkg={nodes[1]["pkg"] if len(nodes)>1 else "?"}")

if __name__ == "__main__":
    main()