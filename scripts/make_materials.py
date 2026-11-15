#!/usr/bin/env python3
"""Converts LaserGRBL's StandardMaterials.psh (XML) to Resources/Materials.json.
usage: make_materials.py <StandardMaterials.psh> <output.json>"""
import sys, json, xml.etree.ElementTree as ET

ns = {"m": "http://tempuri.org/MaterialDB.xsd"}
root = ET.parse(sys.argv[1]).getroot()
out = []
for e in root.findall("m:Materials", ns):
    g = lambda k: (e.find(f"m:{k}", ns).text or "").strip() if e.find(f"m:{k}", ns) is not None else ""
    if g("Visible").lower() == "false":
        continue
    try:
        out.append({
            "id": g("id"), "machine": g("Model"), "name": g("Material"), "thickness": g("Thickness") or "-",
            "action": "cut" if g("Action").lower().startswith("cut") else "engrave",
            "power": float(g("Power") or 100), "speed": float(g("Speed") or 1000),
            "passes": int(float(g("Cycles") or 1)), "notes": g("Remarks"),
        })
    except ValueError:
        pass
out.sort(key=lambda m: (m["machine"], m["name"], m["action"]))
json.dump(out, open(sys.argv[2], "w"), ensure_ascii=False, indent=0, separators=(",", ":"))
print(len(out), "materials,", len({m["machine"] for m in out}), "machines")
