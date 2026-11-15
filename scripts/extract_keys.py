#!/usr/bin/env python3
"""Lists every user-visible English string used in the Swift sources (the localization keys)."""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
funcs = r'(?:Text|Button|Section|Picker|Toggle|TextField|LabeledContent|IconLabel|help|alert|Window|CommandMenu|Label|LocalizedStringKey|L|tr|arrow|row|slider|navigationTitle|Stepper|item|rowLabel|make|Menu|UnitRow|ControlRow)'
lit = re.compile(funcs + r'\(\s*"((?:[^"\\]|\\.)*)"')
extra = re.compile(r'prompt:\s*Text\("((?:[^"\\]|\\.)*)"\)')
rawvals = re.compile(r'case\s+(?:[a-zA-Z0-9]+\s*=\s*"((?:[^"\\]|\\.)*)"[,\s]*)+')

def keys():
    found = set()
    for f in (root / "Sources").rglob("*.swift"):
        if f.name == "CodeTables.swift":
            continue
        text = f.read_text()
        for m in lit.finditer(text):
            found.add(m.group(1))
        for m in re.finditer(r'\b(?:L|help|Button)\([^"\n]*\? "((?:[^"\\]|\\.)*)" : "((?:[^"\\]|\\.)*)"', text):  # ternary
            found.add(m.group(1)); found.add(m.group(2))
        for m in extra.finditer(text):
            found.add(m.group(1))
        for m in re.finditer(r'arrow\(\.\w+,\s*"[^"]*",\s*-?\d+,\s*"((?:[^"\\]|\\.)*)"', text):
            found.add(m.group(1))
        if f.name == "RasterConverter.swift":
            for m in re.finditer(r'=\s*"([^"]+)"', text):
                pass
    # enum display names (RawRepresentable cases used as picker labels)
    rc = (root / "Sources/LaserGRBLCore/RasterConverter.swift").read_text()
    for block in re.findall(r'enum (?:GrayFormula|DitherMode|FillDirection|RasterTool)[^{]*\{(.*?)\n\}', rc, re.S):
        for v in re.findall(r'=\s*"([^"]+)"', block):
            found.add(v)
    for st in ["Disconnected", "Connecting", "Idle", "Run", "Hold", "Door", "Home", "Alarm", "Check", "Jog", "Sleep", "Tool", "Cooling", "AutoHold"]:
        found.add("state." + st)
    # names shown through LocalizedStringKey(variable), which the patterns above cannot see (BUILT_IN_PRESETS)
    found.update(["Photo", "Fast draft", "Fine detail", "Sharp logo", "Black and white dots"])
    out = set()
    for k in found:
        k = k.replace('\\"', '"')
        if k in ("state.", "grbl.") or k.strip() == "" or "\\(" in k or k in ("$", "X", "Y", "OK", "LaserGRBL", "LaserCraft", "main", "mm", "mm/min", "S", "G0", "G1", "G-code", "⚠︎ ", "⚠︎", "100%", "50%", "25%", "%", "W", "h", "°", "–"):
            continue
        out.add(k)
    return sorted(out)

if __name__ == "__main__":
    for k in keys():
        print(k)
