# Changelog

## Unreleased — Release 1 Beta 6 (1.0.0-beta.6)

- **DXF and PDF import** (*File → Import Vector File…*): DXF lines, arcs, circles, ellipses, polylines with bulges, splines and
  blocks with the drawing's units and layer names; PDF vector paths of any page at real size (also inside form objects).
- **Pause and focus per layer:** *Pause before this layer* (laser off, message, `M0`; Resume continues) and *Lower focus per
  pass* (Z axis, back to Z0 at the end). The simulator understands `M0` and Z moves. Older project files still open.
- **Review of the code for safety and errors:** files from the internet can no longer crash the importers (a DXF with an infinite
  angle or `1e308` radius used to stop the app; SVG, DXF and PDF now drop shapes with non-finite or absurd coordinates);
  importing a Grbl settings file only sends plain `$n=value` lines (a file with `$RST=*` or `$J=…` can no longer reach the
  machine); failed saves of settings and projects are reported and leave no half-written files; notification titles with
  non-ASCII letters are encoded for ntfy. New tests feed the SVG, DXF, PDF and G-code readers hostile data.

## Release 1 Beta 5 (1.0.0-beta.5)

- **Layout editor:** zoom and pan (pinch, ⌘-scroll, ⌘+ ⌘− ⌘0, scrolling, Space + drag); **turning by any angle** with a handle that
  snaps every 15° (⌥ = free) — pictures included, they are resampled when the job is made; **several objects** (Shift-click, ⌘A) that
  move, copy and delete together; **Align** and **Distribute**; **Array** with rows × columns, gaps and consecutive `{n}` numbers.
- **Tracing with curves:** Bézier curve fitting (corner detection + Schneider's algorithm) for outlines and centerlines — rounder shapes and far
  fewer lines. Not a Potrace port; the old method stays available.
- **Scan offset** for two-way picture engraving, with a nine-block test pattern (*Tools → Test Patterns → Scan offset*) and a field in
  the picture import.
- **Older Grbl:** error and alarm messages given as text (Grbl 0.9) are mapped to the usual numbers; the `GrblHAL` welcome line is
  recognised. Tests for the 0.9 status format.
- **Updates with Sparkle** are built in (framework embedded, `scripts/make_appcast.sh`, docs/RELEASING.md). They switch on when
  `SUPublicEDKey` is added to Info.plist; until then the GitHub release check is used.
- **Hardware matrix** ("Tested with") in the README and issue templates for hardware reports and bugs.
- **Languages:** Nederlands and Polski (about 80 % of the interface: menus, buttons, labels, messages; longer explanations and Grbl's own messages stay English until a native speaker completes them; missing texts fall back to English).

## Release 1 Beta 4 (1.0.0-beta.4)

- **Keyboard:** arrows jog, ⌥+arrow big steps, Page up / down for Z, `+` `−` jog step, `[` `]` jog speed, ⌃↑ ⌃↓ power override,
  ⌃1…⌃9 custom buttons; *Settings → Keyboard* to change every key (conflict detection, restore defaults). Keys are ignored while a
  text field is edited.
- **Continuous jogging:** hold a key or pad button to keep moving, release to stop (jog cancel `0x85`; pieces of about half a
  second so that the machine limits are respected).
- **Emergency Stop** button and menu command (⌥⌘.): jog cancel, hold, soft reset and `M5`, always without confirmation.
- **Buffer watchdog:** counters are set right again when Grbl's receive buffer is empty for 3 s while lines are still counted as
  unanswered.
- **Push message** to ntfy.sh or a JSON webhook when a job ends, with a minimum duration and a privacy switch for the file name;
  **Dock progress** (bar, percentage, remaining time).
- **Console:** filter (sent / received / messages / errors), search, timestamps, auto-scroll on / off.
- **Save G-code:** options for header, footer, passes and LF / CRLF line endings.
- **Job history:** the last 40 jobs with picture, result and a copy of the G-code; open them again with a double-click.
- Spanish, Italian and Portuguese strings for all of it.

## Release 1 Beta 3 (1.0.0-beta.3)

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
