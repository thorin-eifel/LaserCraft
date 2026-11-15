# Changelog

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
