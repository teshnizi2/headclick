# HeadClick

Camera-only cursor control for macOS. **Your eyes move the pointer**: the cursor goes where you look (the head does not matter), and any facial gesture you choose clicks, drags, scrolls or pauses. The older head pointer is still there as an option in Settings. A demo and experiment, not a daily driver.

MIT licensed, written from scratch. Face tracking is Google MediaPipe Face Landmarker (Apache-2.0, see `ThirdParty/NOTICE`), called through its C API.

## Build and run
Needs macOS 15+, Xcode (Swift 6) and the Apple Development signing identity named in `scripts/bundle.sh` (set `HEADCLICK_IDENTITY` to use another).

```bash
scripts/bundle.sh          # fetches MediaPipe 1.2.3 + model into vendor/ (once, SHA-256 pinned), builds, signs build/HeadClick.app
open build/HeadClick.app   # menu-bar app; starts PAUSED
swift test                 # unit tests, no camera needed
build/HeadClick.app/Contents/MacOS/HeadClick --selftest   # loads the engine and reads a sample portrait
```

Nothing is installed system-wide. Everything lives in this folder.

## Guided start (first thing to try)
On the first launch HeadClick opens a full-screen **Guided start** (and any time from the menu: **Guided start…**). It walks you through, one step at a time, each with at most 10 s of action (the 13-dot eye calibration is 9.5 s for the 9 dots plus 6 s for the 4 check dots), a visible countdown, big text, and Back / Skip / Esc = stop:
1. **Camera check**: live picture with the face mesh, a big ✓ "I can see your face", fps and engine ms, and what to fix (light, distance, hold still).
2. **Eyes (required)**: look at 9 dots, then 4 check dots. You may move your head naturally; only the eyes matter. Shows the mean error in cm. The calibration is saved (`~/Library/Application Support/HeadClick/gaze.json`), so it is not needed on every launch.
3. **Look**: five dots (centre, left, right, top, bottom). The orange dot is where HeadClick thinks you look, with the same smoothing and fixation lock as the real cursor; each dot shows its error in cm.
4. **Click gestures**: left click, right click, double click, scroll and pause, taken from your current profile. Do each 3 times; a live meter shows the threshold line. If it fails you can try again, calibrate that gesture, or continue.
5. **Summary**: what worked, what misfired while you only looked around, and the numbers. Saved to `docs/guided-run-<date>.txt` (and `guided-run-latest.txt`). Then a big **Start controlling the cursor** button (it refuses while the eyes are not calibrated).

Safety: during the guide nothing moves the real cursor and no click is ever posted (the guide uses throw-away controllers). The trackpad stays usable for the buttons. Esc stops the guide. The real controller stays paused until you press "Start controlling the cursor".

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

**Eye pointer.** Menu → **Pointer** picks Eyes (default) or Head. In Eyes mode the cursor follows a smoothed gaze estimate: a 0.25 s median, a *fixation lock* (while you look at one spot the cursor only drifts slowly; a real jump of the gaze moves it after about 0.1 s), and it freezes while your eyes are closed, so a blink never throws it. **Snap to buttons and links** (on by default, needs Accessibility) moves the cursor to the centre of the nearest clickable thing within 60 px once your gaze has rested for 0.2 s. While a click gesture is arming the cursor is frozen, and the existing click rewind still applies. **Calibrate eyes (13 dots)…** redoes the calibration; **Fix drift: look at the centre dot** is a 1.5 s recentre that shifts the model so the middle of the screen reads as the middle. Eyes mode will not resume until the eyes are calibrated.

Menu → **Calibrate head pointer…** (only used in Head mode) sets speed from your comfortable head range. **Talk test…** replays you reading aloud against each gesture and warns which ones fire while you talk. `docs/webgrid.html` is a click-the-targets page for comparing modes (`?n=5` for 5 targets). In Head mode, Settings also has the older **gaze jump**.

## Debug and tooling
`--show-guide`, `--show-settings`, `--show-debug` (52 live blendshape bars), `--show-overlay`, `--camera-test [s]`, `--record <file>` (writes cursor spread, clicks, actions fired, fps, engine ms when a `--test-seconds` run ends), `--snapshot <window title> <abs png path> [delay s]`.

## Known limits
Webcam gaze is 2–5 cm off (about 100–250 px on a laptop), so small targets are hard to hit by gaze alone: snapping to buttons helps, and Head mode is there if you need precision. The gaze model learns from the head positions you had during calibration; very different seating positions need a recalibration (or the one-dot drift fix). Mouth and brow gestures fire while talking unless the talk guard catches them. Written for a single built-in camera and the main display.
