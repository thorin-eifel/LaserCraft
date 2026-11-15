# Changelog

## Unreleased — Release 1 Beta 3 (1.0.0-beta.3)

- **Crop to Subject** in the picture import (and for pictures in the layout editor): cuts away the empty border around the
  motif (transparent or flat background); *Reset Crop* undoes it.
- **Go to Center** button next to *Go to Zero*: moves the laser head to the middle of the work area (from `$130` / `$131`).
  It is added once to your saved button set and can be deleted again.
- Spacing and alignment: one set of form controls (labels left, fields and units in fixed columns, vertically centred) in the
  picture, SVG, text, trace, test-pattern, profile and settings dialogs; numbers no longer show thousands separators
  ("3000", not "3.000").
- Picture import, SVG, text and trace dialogs open as large as the main window, so the preview gets all the room.
- **SVG import** (paths with curves and arcs, shapes, groups, transforms, viewBox and units), **text** (Hershey single-stroke
  font from LaserGRBL, installed fonts as outlines, `{n}` `{date}` `{time}` placeholders) and **picture tracing** (outline and
  centerline). Burn as lines, fill (hatching) or both; **shortest-travel ordering** (nearest neighbour + 2-opt) and
  **inner shapes first**.
- **Layout editor** with objects, layers, per-object settings, snap, undo / redo and **project files** (`.lasercraft`).
- **Materials** database (906 entries from LaserGRBL) with your own entries and JSON import / export.
- **Test patterns:** power vs. speed (with *Save as Material*), cutting test with kerf, shake test, line-distance / focus test
  and calibration square with a `$100` / `$101` calculator.
- **Network machines:** Telnet, WebSocket and TCP transports (Network.framework), Bonjour search; the controller no longer
  depends on a serial port.
- **Firmware detection** for grblHAL, FluidNC, Ortur and Longer with their own error, alarm and setting tables.
- **Machine profiles** (loaded when connecting) and **laser statistics** with power-weighted lifetime.
- **Camera** window with snapshots and time-lapse during jobs.
- Info.plist: camera, local-network and Bonjour descriptions; SVG and project document types; hardened-runtime entitlement
  for the camera (`Resources/LaserCraft.entitlements`).
- Not included: DXF / PDF import, Potrace curve fitting (the tracer makes straight segments), Marlin / Smoothieware, firmware
  flasher, free rotation of pictures (90° steps only), zoom and pan in the layout editor.

## Release 1 Beta 2

- **Checks before every start:** the safety dialog and the preview list problems — job bigger than the machine, job sticking
  out of the machine area (with soft limits), laser mode off, power above `$30`, speed above `$110/$111`. The machine area
  turns red when the job does not fit.
- **Simulator:** *Simulator (demo machine)* in the port list; a Grbl 1.1 look-alike that moves at the programmed speed.
- **Click-to-jog:** double-click in the preview moves the head; live pointer coordinates.
- **Diagnostics:** *Copy Diagnostic Report*, *Save Console Log…*.
- **Menus:** *Open Recent*, zoom shortcuts (⌘+ ⌘− ⌘0).

- **The Mac no longer goes to sleep while a job is running** (it may sleep before and after). The status bar shows
  "Mac stays awake"; *Settings → Job → Power* can switch it off or also keep the display on. If the Mac is forced to sleep
  anyway (closed lid) the job is paused first and you are told after waking up.
- Confirmed by the author on a real Grbl 1.1 laser (Seeeduino Nano).
- **Resume a job from a line** (*Job → Resume Job from Line…*, right-click a G-code line): remembers where the last run stopped,
  moves there with the laser off and restores feed, units, motion mode and power first.
- **Picture import:** crop, rotate, mirror, saveable presets (five built in), resolution helper with laser spot size and an
  engraving-time estimate.
- **Auto-cooling** (work / rest cycles with the laser off) and **auto-reconnect** after a dropped USB connection.
- **Updates:** *Check for Updates…* and an optional daily check against the GitHub releases.
- **Languages:** Español, Italiano and Português (Brasil) added (interface; Grbl's own messages stay in English there).
- **Distribution:** universal app (Apple silicon + Intel), `scripts/make_dmg.sh`, `scripts/notarize.sh`, Developer ID signing
  option and `docs/RELEASING.md`.
- **Changed:** a job now counts as finished when Grbl reports idle after the last line, not at the last "ok" — this also keeps
  the Mac awake until the final move is done and sends the notification at the right moment.

## Release 1 Beta 1 — 1.0.0-beta.1

First public beta of LaserCraft, a native macOS controller for Grbl laser engravers.

**Please note:** this beta was developed and tested against a *simulated* Grbl 1.1 controller. It has not been verified on
real laser hardware yet. Test with the laser off or at low power first and report what you find.

### Included

- Serial connection to Grbl 0.9 / 1.1 controllers with live status, position and buffer.
- G-code loading, preview (zoom, pan, progress overlay), time estimate, saving.
- Picture import: line-to-line and 1-bit dithering (9 methods), three directions, grayscale, brightness, contrast,
  white clip, invert, power range, M3 / M4, size and offset.
- Job streaming with flow control, header / footer / passes, pause / resume / stop / soft reset.
- Jogging, home, unlock, set zero, frame; real-time speed, rapid and power overrides.
- G-code list with ✓ / ✕, console, Grbl `$` configuration (edit, export, import), custom buttons with icons.
- Laser-safety check with countdown and "I am wearing laser safety glasses" box before every start and every
  laser-on button (cannot be turned off).
- Sounds (connection, countdown, job, errors, alarms), alerts, notification when a job finishes.
- Settings: language (English / Deutsch / Français), light / dark appearance, sounds, notifications, connection,
  job defaults, preview options.
- macOS design: toolbar, split view, Settings window, SF Symbols, VoiceOver labels, keyboard shortcuts.
- README, user manual with screenshots, example files.

### Known limits

- Not tested on real hardware; the app is signed ad hoc (right-click → Open on first launch); Apple silicon build.
- Not included compared with the Windows LaserGRBL: SVG import, vectorizing, firmware flashing, WiFi, Marlin / Smoothie.
