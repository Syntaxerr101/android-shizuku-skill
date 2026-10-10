#!/usr/bin/env python3
"""ui_wait_check.py — evaluate one predicate against a ui.xml dump.

Usage: ui_wait_check.py <ui.xml> <predicate>

predicates:
  text:<sub>   every (text | content-desc) joined, case-insensitive contains sub
  gone:<sub>   no node contains sub
  pkg:<pkg>    current UI's package equals pkg

Prints YES or NO (exit 0 or 1).
"""
import sys
import xml.etree.ElementTree as ET

pred = sys.argv[2]
root = ET.parse(sys.argv[1]).getroot()

texts = []
pkgs = set()
for el in root.iter():
    t = el.attrib.get("text", "") or ""
    d = el.attrib.get("content-desc", "") or ""
    if t:
        texts.append(t)
    if d:
        texts.append(d)
    p = el.attrib.get("package", "")
    if p:
        pkgs.add(p)
blob = " ".join(texts).lower()

def yes(msg="YES"):
    print(msg)
    sys.exit(0)

if pred.startswith("text:"):
    if pred[5:].lower() in blob:
        yes()
elif pred.startswith("gone:"):
    if pred[5:].lower() not in blob:
        yes()
elif pred.startswith("pkg:"):
    q = pred[4:]
    if any(p == q or p.startswith(q) for p in pkgs):
        yes()
else:
    sys.stderr.write("unknown predicate: %s\n" % pred)

print("NO")
sys.exit(1)