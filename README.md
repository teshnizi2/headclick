# HeadClick

Camera-only cursor control for macOS. Your head moves the pointer; any facial gesture you choose clicks, drags, scrolls or pauses. Optional gaze jump: look somewhere and the cursor jumps there, the head fine-tunes. A demo and experiment, not a daily driver.

MIT licensed, written from scratch. Face tracking is Google MediaPipe Face Landmarker (Apache-2.0, see `ThirdParty/NOTICE`), called through its C API.

## Build and run
Needs macOS 15+, Xcode (Swift 6) and the Apple Development signing identity named in `scripts/bundle.sh` (set `HEADCLICK_IDENTITY` to use another).

```bash
scripts/bundle.sh          # fetches MediaPipe 1.2.3 + model into vendor/ (once, SHA-256 pinned), builds, signs build/HeadClick.app
open build/HeadClick.app   # menu-bar app; starts PAUSED
swift test                 # 47 unit tests, no camera needed
build/HeadClick.app/Contents/MacOS/HeadClick --selftest   # loads the engine and reads a sample portrait
```

Nothing is installed system-wide. Everything lives in this folder.

## Guided start (first thing to try)
On the first launch HeadClick opens a full-screen **Guided start** (and any time from the menu: **Guided start…**). It walks you through, one step at a time, each with at most 10 s of action, a visible countdown, big text, and Back / Skip / Esc = stop:
1. **Camera check**: live picture with the face mesh, a big ✓ "I can see your face", fps and engine ms, and what to fix (light, distance, hold still).
2. **Pointer**: calibration if you have none, then dots (centre, then the edges). The guide draws its own orange pointer dot; look at each dot and turn your head until the dot is on it.
3. **Click gestures**: left click, right click, double click, scroll and pause, taken from your current profile. Do each 3 times; a live meter shows the threshold line. If it fails you can try again, calibrate that gesture, or continue.
4. **Gaze (optional)**: the 9-dot calibration plus 4-dot check, with the error in cm.
5. **Summary**: what worked, what misfired while you only looked and moved, and the numbers. Saved to `docs/guided-run-<date>.txt` (and `guided-run-latest.txt`). Then a big **Start controlling the cursor** button.

Safety: during the guide your head never moves the real cursor and no click is ever posted (the guide uses throw-away controllers). The trackpad stays usable for the buttons. Esc stops the guide. The real controller stays paused until you press "Start controlling the cursor".

Guide flags: `--show-guide` opens it at launch; `--guide-demo` runs it with a scripted fake user (no camera, a still portrait as the "face", labelled DEMO) so you can watch every screen; `--guide-speed N` (fake frames per tick), `--guide-skip S` (fast-forward S fake seconds first), `--guide-shots <dir>` saves a PNG of every step into `<dir>/guided-*.png` and quits. These need `--test-seconds N` (N ≤ 10) like any live run. Screenshots are in `docs/guided-*.png`; the portrait is `test-face.jpg`, a stock sample picture, not you.

## Permissions
- **Camera**: asked on first launch.
- **Accessibility**: needed to move the cursor and click. The menu shows "Grant Accessibility…" until it is on (System Settings → Privacy & Security → Accessibility). Signing with a fixed identity keeps both grants across rebuilds.

## Safety (always on)
- HeadClick **starts paused**. Resume with the menu or ⌃⌥P.
- **Any real mouse, trackpad or key input, or Esc, pauses it.** (Input HeadClick posts itself is tagged and ignored; there is a 1 s grace after a resume.)
- **Face out of view for more than 1 s pauses it**; you resume explicitly.
- Live test runs: `--test-seconds N` quits the app after N seconds (N capped at 10). Only `--test-seconds N --active` starts unpaused.
- Hotkeys: ⌃⌥P pause/resume, ⌃⌥R recenter, ⌃⌥O filming overlay.

## Using it
Menu bar icon → Settings. One row per action (left/right/double/middle click, drag, scroll up/down, pause, recenter): pick a gesture, a trigger (quick / hold / hold 1.2 s / while held) and sensitivity (Slight / Default / Exaggerated). The bar shows how strongly you make the gesture; the line is where it fires. Warnings appear for gestures that fire while talking or move the cursor. "Calibrate" measures your own neutral and peak for that gesture.

Gestures: mouth open, smile, pucker, raise/lower brows, wink left/right, double blink, long blink, mouth left/right, head tilt left/right, half smile left/right, cheek puff, nose scrunch, jaw left/right, lips pressed, nod, shake.
Built-in profiles: **Quiet desk** (mouth/brows), **Talk-safe** (winks and blinks, nothing on the mouth), **Eyes only**, **Expressive**. Profiles are JSON in `~/Library/Application Support/HeadClick/`; "Save as…" makes your own.

Menu → **Calibrate pointer…** sets speed from your comfortable head range. **Talk test…** replays you reading aloud against each gesture and warns which ones fire while you talk. **Calibrate gaze…** runs 9 dots plus a 4-dot check and reports the mean error in cm; then switch on **Gaze jump** (or **Gaze only** for the comparison). `docs/webgrid.html` is a click-the-targets page for comparing modes (`?n=5` for 5 targets).

## Debug and tooling
`--show-guide`, `--show-settings`, `--show-debug` (52 live blendshape bars), `--show-overlay`, `--camera-test [s]`, `--record <file>` (writes cursor spread, clicks, actions fired, fps, engine ms when a `--test-seconds` run ends), `--snapshot <window title> <abs png path> [delay s]`.

## Known limits
Webcam gaze is 2–5 cm off, so gaze only gets the cursor near; the head does the precision. Mouth and brow gestures fire while talking unless the talk guard catches them. Written for a single built-in camera and the main display.
