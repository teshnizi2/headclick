# HeadClick handover

## What it is
A native Swift menu-bar app for macOS 15+. The webcam finds your face (Google MediaPipe Face Landmarker). Your **eyes move the cursor**: it goes where you look, and head movement should not matter. Face gestures (blinks, winks, mouth open, brows, head tilt and so on) click, drag, scroll or pause. A head pointer is kept as an option in Settings. The cursor snaps to clickable things (through Accessibility) when one is within about 60 px of the gaze point. It is a demo and experiment, not a daily driver.

## Status
- Built and working in code. `swift test` passes (64 tests, all on synthetic faces and traces). A timing-sensitive test or two failed in 2 of 6 runs while the Mac was busy; rerun if so.
- **Never tested on a real face end to end.** The head-invariance of the gaze and the click gestures are unproven live.
- **Engine speed is unmeasured on a quiet Mac.** The only live run was on a very busy machine (31 ms median per frame). The goal is 10 ms or less. The camera itself gives 30 fps.
- Realistic limit for any webcam: about 2 to 3 cm (75 to 125 px) of gaze error with good front light and a fresh calibration. Snapping to buttons is what makes it usable.

## Build and run
```bash
scripts/fetch-mediapipe.sh   # downloads MediaPipe 1.2.3 and the model into vendor/ (SHA-256 pinned)
scripts/bundle.sh            # builds and signs build/HeadClick.app
swift test                   # unit tests (no camera needed)
open build/HeadClick.app     # starts PAUSED; the guided start opens on first launch
```
Signing: set `HEADCLICK_IDENTITY` or put an identity name in an untracked `scripts/identity.local`. Without one the app is signed ad-hoc and macOS asks for Camera and Accessibility again after every rebuild.

## Permissions
- **Camera**: to see your face.
- **Accessibility**: to move and click the cursor and to find clickable targets.
Both are granted per app, in System Settings, Privacy and Security.

## Safety rules (never weaken)
- The app always starts paused.
- Any real mouse or keyboard input, or Esc, pauses it. Events HeadClick posts itself are tagged and ignored, with a 1 s grace after a resume. Ctrl-Opt-P also pauses.
- Face lost for more than 1 s is a hard pause that needs an explicit resume.
- Resume is refused until the eyes are calibrated.
- `--test-seconds N` is capped at 10 s and hard-quits from a background thread. Only `--test-seconds N --active` may start unpaused. Keep every live test at 10 s or less.
- The guide never drives the real cursor.

## Code map
`Sources/HeadClickCore` (logic, testable):
- `MediaPipeEngine.swift`: loads libmediapipe at run time (dlopen) and returns landmarks and blendshapes.
- `Camera.swift`, `FaceFrame.swift`, `Pipeline.swift`: capture and the frame type.
- `Gaze.swift`: gaze estimator (iris, head pose, ridge regression) and the 13-dot calibrator.
- `GazePointer.swift`: eye pointer: median, fixation lock, freeze while a click arms, snap, drift fix.
- `Pointer.swift`: the head pointer option.
- `Gesture.swift`, `Detector.swift`: gesture detection with hysteresis, triggers and guards.
- `Calibration.swift`: gesture calibration (rest, peak, talk test).
- `Profile.swift`: gesture-to-action profiles and saving.
- `Controller.swift`: ties it together and posts the mouse events.
- `Guide.swift`, `GuideSynth.swift`: the guided start and its synthetic demo data.

`Sources/HeadClick` (the app): `AppModel.swift` (state, menu), `GuideView.swift`, `GazeCalibrationView.swift`, `SettingsView.swift`, `Overlay.swift` (ring, toast, meters), `SafetyGuard.swift`, `Recorder.swift` (`--record` for live runs), `SelfTest.swift`, `CameraTest.swift`.

`Tests/HeadClickTests`: synthetic gaze, pointer, gesture, calibration and guide tests. `docs/webgrid.html` is a target page for checking gaze.

## Next steps, in order
1. **Live run of the guide on a real face.** Camera, Eyes (13 dots), Look (error in cm), Clicks, Summary. Note the cm error, whether moving the head moves the cursor, and which gestures misfire. Use `--record` to log a run.
2. **Four parts to borrow** from the survey of existing tools:
   - The head-to-gaze leak compensator from `jazelly/gazefuse` (`GazeHeadLeakCompensator.swift`), fed by MediaPipe yaw and pitch. It is Apache-2.0, so add a line to `ThirdParty/NOTICE`. It assumes you look at the target; write our own tests for the case where you chase the cursor.
   - Click-confirmed bias learning: a capped median offset, learned only from clicks that hit a snapped target.
   - Calibration with gentle head motion on purpose (BMVC 2025), which makes the fit less sensitive to head pose.
   - A "face the light" brightness gate with a warning. Poor light adds 2 to 4 degrees of error in other people's tests.
3. **Measure engine speed** on a quiet Mac (goal 10 ms or less per frame). If it is slower, consider skipping frames or a smaller input.
4. **Demo video.**

## Working together
Branch off `main`, one topic per branch, open a pull request into `main`, and let the other person review before merging. Don't push straight to `main`. Run `swift test` before opening a PR.
