#!/usr/bin/env python3
"""Print rows of one xctrace table: ./trace-dump.py <trace> <schema> [filter-substring]"""
import subprocess, sys, xml.etree.ElementTree as ET
trace, schema = sys.argv[1], sys.argv[2]
needle = sys.argv[3] if len(sys.argv) > 3 else None
xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                      f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                     capture_output=True, text=True).stdout
ids = {}
def val(e):
    r = e.get("ref")
    if r: return ids.get(r, "")
    v = e.get("fmt") or (e.text or "").strip()
    if not v and len(e): v = " ".join(filter(None, (val(c) for c in e)))
    if e.get("id"): ids[e.get("id")] = v
    return v
for row in ET.fromstring(xml).iter("row"):
    line = " | ".join(v for v in (val(c) for c in row) if v)
    if not needle or needle in line: print(line[:260])
