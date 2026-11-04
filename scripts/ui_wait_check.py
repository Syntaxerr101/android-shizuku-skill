#!/usr/bin/env python3
"""ui_wait_check.py — evaluate one predicate against a uiautomator dump.

Usage: ui_wait_check.py <ui.xml> <predicate>

predicates:
  text:<sub>   any text/content-desc contains sub (case-insensitive)
  gone:<sub>   no text/content-desc contains sub
  pkg:<pkg>    foreground package equals <pkg> (or is a sub-package of it)

Prints YES (exit 0) or NO (exit 1).
"""
import sys
import xml.etree.ElementTree as ET


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: ui_wait_check.py <ui.xml> <predicate>")
    pred = sys.argv[2]
    root = ET.parse(sys.argv[1]).getroot()

    texts = []
    pkg = ""
    for el in root.iter():
        t = el.attrib.get("text", "")
        d = el.attrib.get("content-desc", "")
        if t:
            texts.append(t)
        if d:
            texts.append(d)
        if not pkg and el.attrib.get("package"):
            pkg = el.attrib["package"]

    blob = " ".join(texts).casefold()

    if pred.startswith("text:"):
        ok = pred[5:].casefold() in blob
    elif pred.startswith("gone:"):
        ok = pred[5:].casefold() not in blob
    elif pred.startswith("pkg:"):
        q = pred[4:]
        ok = pkg == q or pkg.startswith(q + ".")
    else:
        sys.stderr.write("unknown predicate: %s\n" % pred)
        sys.exit(2)

    print("YES" if ok else "NO")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
