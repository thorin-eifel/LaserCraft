# Design notes — Apple macOS UI kit

The look of the app follows the "Apple macOS 27 UI Kit" (Sketch library) that was provided with the request:
https://www.sketch.com/s/57153a31-3379-4737-8ac6-dbfd6525f052/symbols
Only the public (signed-out) view of the library could be read: component names, sizes, colours and a few
rendered examples. What was taken from it:

| Kit component | What it says | Where it is applied |
|---|---|---|
| Titlebars and Toolbars | Icon buttons sit in capsule groups of 1–6 items (24 pt high); inactive window = lighter capsule | Toolbar is split into groups separated by `ToolbarSpacer(.fixed)` (macOS 26+): laser connection · connect · job (Start / Pause / Stop) · files · panels |
| Alerts | Side-by-side buttons; preferred action blue and first, Cancel neutral, destructive red | `NSAlert` dialogs (Start job, Set zero, write settings) put the confirming button first; sheets use `.borderedProminent` for the default button; Stop uses the destructive role |
| Buttons | Bordered buttons come in mini/small/regular/large; destructive = red | Inspector uses `.controlSize(.small)`; delete/stop buttons use `role: .destructive` |
| Segmented Controls, Sliders, Steppers, Toggles, Progress Indicators | Standard system controls | Overrides (segmented rapids, sliders), passes (stepper), grouped-form switches, linear progress in the status bar |
| Sidebars / Windows | Content area + side panel, title and subtitle in the titlebar | Windows-style arrangement: control column on the left (resizable split view), preview and button row on the right; window title = job name, subtitle = machine state |
| Tooltips | Short help text on icon-only controls | Every toolbar icon has `.help` and an accessibility label |
| Text styles / colours | 13 pt body, 12 pt secondary; labels in 85 % / 70 % / 55 % black; corner radius 6 | Only system text styles and semantic colours (`.primary`, `.secondary`) so light and dark mode follow the system |

Icons are SF Symbols (`Icons.swift` maps the short names used in the code to symbol names).

## Apple Human Interface Guidelines — audit (macOS)

Checked against the "Working Rules for Coding Agents" summary of the HIG (snapshot 15 Nov 2026).

| Rule | Status |
|---|---|
| System components first; Liquid Glass only on the controls layer, no custom bar backgrounds | Standard `Window`, `.toolbar`, `.inspector`, `Form`, `Table`, `ProgressView`; the only custom surface is the preview canvas (content layer, solid) |
| One prominent action | Only **Start** (toolbar) and the default button of a sheet are `.borderedProminent`; **Stop** has the destructive role |
| Window title describes content | Title = job name ("No Job Loaded" when empty), subtitle = machine state |
| Every toolbar item exists in the menu bar | Machine, Job and View menus mirror all toolbar actions; Settings on ⌘, ; no system shortcut is overridden (⌘. is the conventional Stop) |
| Semantic colours / fonts; light, dark and Increase Contrast | `.primary`/`.secondary`, system text styles; the preview grid gets stronger lines with Increase Contrast; the legend becomes opaque with Reduce Transparency; no in-app theme switch |
| Minimum sizes (macOS: text 10 pt, controls 20 pt) | Smallest text is 10 pt, smallest control 20 pt high |
| Not colour alone | Machine state is a word plus a dot; errors are red text with an explanation |
| Accessibility labels | Every icon-only button has a label (`Label` with hidden icon, `.help`); the preview canvas is one element with a spoken summary (name, size, time) |
| Risky actions confirmed | Start job, Set Zero, writing Grbl settings, removing a button and restoring the defaults ask first; alerts use specific button titles |
| Writing | Title-case, verb-first button and menu titles; errors say what to do; empty states name the next action |
| Localisation | English, German, French; all strings localised |
| Drag and drop has an alternative | Dropping a file works; Open G-code / Import Image do the same |

Deliberate deviations from the HIG summary:

* Icons are SF Symbols, as the HIG recommends (an earlier version used UXWing SVGs; they were replaced on request).
* **The preview stays a white sheet in dark mode** — it shows the workpiece, as in other CAM/CAD tools; burn lines are dark on light.
* Alarm "Unlock / Home" buttons sit in the status bar at the bottom edge; the same commands are in the Machine menu and
  the controls panel, so nothing critical depends on that edge.
