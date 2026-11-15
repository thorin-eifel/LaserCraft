#!/usr/bin/env python3
"""Writes Resources/{en,de,fr,es,it,pt-BR}.lproj/Localizable.strings from translations.py and checks nothing is missing."""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import extract_keys
import translations as T
import translations_extra as X
import translations_r3 as R3

# release 3 strings: (de, fr, es, it, pt-BR)
for _k, _v in R3.R3.items():
    T.UI[_k] = (_v[0], _v[1])
    X.EXTRA[_k] = (_v[2], _v[3], _v[4])

root = pathlib.Path(__file__).resolve().parent.parent
keys = extract_keys.keys()
missing = [k for k in keys if k not in T.UI and not k.startswith("state.")]
missing += [k for k in keys if k.startswith("state.") and k not in T.UI]
if missing:
    print("MISSING TRANSLATIONS:")
    for k in missing:
        print("  ", k)
    sys.exit(1)

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def write(lang, idx):
    lines = [f"/* LaserGRBL for macOS - {lang} */"]
    for k in keys:
        v = k if lang == "en" else T.UI[k][idx]
        # state.* keys always need a value, also in English
        if k.startswith("state."):
            v = k.split(".", 1)[1] if lang == "en" else T.UI[k][idx]
            if lang == "en":
                v = {"AutoHold": "Hold (automatic)", "Connecting": "Connecting…", "Door": "Door open", "Home": "Homing", "Check": "Check mode", "Tool": "Tool change", "Cooling": "Cooling"}.get(v, v)
        lines.append(f'"{esc(k)}" = "{esc(v)}";')
    if lang != "en":
        i = idx
        errs, alms, sets = (T.ERRORS_DE, T.ALARMS_DE, T.SETTINGS_DE) if lang == "de" else (T.ERRORS_FR, T.ALARMS_FR, T.SETTINGS_FR)
        for n, (t, d) in sorted(errs.items()):
            lines.append(f'"grbl.error.{n}.title" = "{esc(t)}";')
            lines.append(f'"grbl.error.{n}.detail" = "{esc(d)}";')
        for n, (t, d) in sorted(alms.items()):
            lines.append(f'"grbl.alarm.{n}.title" = "{esc(t)}";')
            lines.append(f'"grbl.alarm.{n}.detail" = "{esc(d)}";')
        for n, v in sorted(sets.items()):
            lines.append(f'"grbl.setting.{n}.name" = "{esc(v)}";')
        for n, v in sorted((T.SETTING_DETAILS_DE if lang == "de" else T.SETTING_DETAILS_FR).items()):
            lines.append(f'"grbl.setting.{n}.detail" = "{esc(v)}";')
        for en, tr in T.UNITS.items():
            lines.append(f'"grbl.unit.{esc(en)}" = "{esc(tr[idx])}";')
    d = root / "Resources" / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")

for lang, idx in (("en", 0), ("de", 0), ("fr", 1)):
    write(lang, idx)

# Spanish, Italian, Brazilian Portuguese: interface only (Grbl's own messages fall back to English)
extra_missing = [k for k in keys if k not in X.EXTRA]
if extra_missing:
    print("MISSING TRANSLATIONS (es/it/pt-BR):")
    for k in extra_missing:
        print("  ", k)
    sys.exit(1)
for lang, idx in (("es", 0), ("it", 1), ("pt-BR", 2)):
    lines = [f"/* LaserCraft - {lang} */"]
    for k in keys:
        v = X.EXTRA[k][idx]
        if v.count("%") != k.count("%"):
            print("FORMAT MISMATCH", lang, k)
            sys.exit(1)
        lines.append(f'"{esc(k)}" = "{esc(v)}";')
    d = root / "Resources" / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {len(keys)} keys x 6 languages")
