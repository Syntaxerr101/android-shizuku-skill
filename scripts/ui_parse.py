#!/usr/bin/env python3
"""ui_parse.py — uiautomator XML -> JSON model + a compact agent-friendly listing.

Usage: ui_parse.py <ui.xml> <screen.json>

The listing is what an agent should read instead of the raw XML. Indices are
stable: every element including the <hierarchy> root is counted, matching
ui_resolve.py and ui_toggle.py.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET


def parse_bounds(b):
    m = re.fullmatch(r"\s*\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]\s*", b or "")
    if not m:
        return {"x1": 0, "y1": 0, "x2": 0, "y2": 0, "w": 0, "h": 0, "cx": 0, "cy": 0}
    x1, y1, x2, y2 = map(int, m.groups())
    return {"x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "w": max(0, x2 - x1), "h": max(0, y2 - y1),
            "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2}


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: ui_parse.py <ui.xml> <screen.json>")
    src, dst = sys.argv[1], sys.argv[2]

    try:
        root = ET.parse(src).getroot()
    except Exception as exc:
        sys.exit("ERR: cannot parse %s: %s" % (src, exc))

    nodes = []
    pkg = ""
    for el in root.iter():
        a = el.attrib
        cls = a.get("class", "")
        short = cls.rsplit(".", 1)[-1]
        b = parse_bounds(a.get("bounds", ""))
        if not pkg and a.get("package"):
            pkg = a.get("package")
        n = {
            "idx": len(nodes),
            "text": a.get("text", ""),
            "desc": a.get("content-desc", ""),
            "rid": a.get("resource-id", ""),
            "class": short,
            "fqn": cls,
            "pkg": a.get("package", ""),
            "clickable": a.get("clickable") == "true",
            "long_clickable": a.get("long-clickable") == "true",
            "checkable": a.get("checkable") == "true",
            "checked": a.get("checked") == "true",
            "selected": a.get("selected") == "true",
            "enabled": a.get("enabled") == "true",
            "visible": a.get("visible-to-user", "true") != "false" if a.get("visible-to-user") else True,
            "focused": a.get("focused") == "true",
            "scrollable": a.get("scrollable") == "true",
            "password": a.get("password") == "true",
            "editable": cls.endswith(("EditText", "AutoCompleteTextView")),
        }
        n.update(b)
        nodes.append(n)

    with open(dst, "w", encoding="utf-8") as f:
        json.dump(nodes, f, indent=1, ensure_ascii=False)

    interesting = [
        n for n in nodes
        if n["enabled"] and n["visible"] and (
            n["text"] or n["desc"] or n["clickable"] or n["long_clickable"]
            or n["checkable"] or n["editable"] or n["scrollable"] or n["focused"]
        )
    ]

    def marks(n):
        parts = []
        if n["clickable"] or n["long_clickable"]:
            parts.append("TAP")
        if n["editable"]:
            parts.append("FIELD")
        if n["checkable"]:
            parts.append("CHECK:" + ("true" if n["checked"] else "false"))
        if n["scrollable"]:
            parts.append("SCROLL")
        if n["focused"]:
            parts.append("FOCUS")
        return ",".join(parts)

    for n in interesting:
        label = (n["text"] or n["desc"]).replace("\n", "\\n").replace("\t", "\\t")
        if len(label) > 72:
            label = label[:69] + "..."
        rid = n["rid"].split("/")[-1] if n["rid"] else ""
        print('%4d | %-16s | %-16s | %-72s | [%d,%d][%d,%d] -> %d,%d%s' % (
            n["idx"], marks(n) or "-", n["class"][:16], label or "-",
            n["x1"], n["y1"], n["x2"], n["y2"], n["cx"], n["cy"],
            ("  #" + rid) if rid else ""))

    print("\n# %d raw nodes, %d actionable/textual | pkg=%s" %
          (len(nodes), len(interesting), pkg or "?"))


if __name__ == "__main__":
    main()
