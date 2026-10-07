# PostureGuard

**Slouch, and your screen edges glow red. Sit up, and it fades.**

PostureGuard is a tiny macOS menu bar app that watches your sitting posture through your Mac's camera. When you lean too close, drop your head, or slouch for too long, a soft red glow pulses around the edges of your screens until you sit up straight again.

<!-- Demo: add a GIF here, e.g. ![demo](docs/demo.gif) -->

## Features

- **Gentle red glow.** A pulsing glow around every screen edge, with a short message like "Sit up straight: slouching". Clicks pass through, so you can keep working.
- **Learns *your* good posture.** A 3-second calibration records how you sit when you sit well, from wherever your camera is. It works even if the camera is on a laptop to the side of a big external monitor.
- **Four checks.** Too close to the screen, head dropping, slouching shoulders, and head tilt.
- **No false alarms for quick moves.** Bad posture has to last 10, 25 or 45 seconds (your choice) before you're warned.
- **Snooze.** Pause reminders for 30 minutes during a meeting or a movie.
- **Private by design.** Everything runs on your Mac with Apple's Vision framework. No internet, no images saved, and the camera turns off when the screen is locked or the Mac sleeps.
- **Light on the battery.** Only 5 camera frames per second are analyzed.

## Requirements

- macOS 14.6 (Sonoma) or later
- A Mac with a camera (built-in, external, or an iPhone via Continuity Camera)

## Installation (no coding needed)

1. Go to the [**Releases**](../../releases) page and download `PostureGuard.zip`.
2. Unzip it and drag **PostureGuard.app** into your **Applications** folder.
3. Open the app. macOS will warn that it "cannot verify the developer", because the app is not notarized by Apple. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to PostureGuard.
5. Click **Allow** when the app asks for camera access.
6. Calibration starts automatically: sit up straight, look at the screen you use most, and hold still for a few seconds.
7. Optional: click the menu bar icon and turn on **Launch at login**.

If **Open Anyway** doesn't appear, run this in Terminal and open the app again:

```bash
xattr -cr /Applications/PostureGuard.app
```

## Usage

Click the figure icon in the menu bar (it turns into a warning sign while you're slouching):

| Menu item | What it does |
|---|---|
| Enabled | Turn posture tracking on or off |
| Calibrate (sit up straight)… | Learn your good posture again |
| Sensitivity | Gentle (warn after 45 s), Normal (25 s) or Strict (10 s) |
| Snooze for 30 minutes | Pause reminders for a while |
| Preview the warning | Show the glow for 3 seconds |
| Launch at login | Start PostureGuard automatically |
| Quit | Quit the app |

**Tips**

- Calibrate again whenever you change your chair, desk height, or camera position.
- Want to test it quickly? Choose **Strict**, then lean toward the screen for 10 seconds.
- If your shoulders aren't visible to the camera, PostureGuard still works using your face only.

## How it works

1. **Measure.** Apple's Vision framework finds your face (size, position and head tilt) and, when visible, your nose and shoulders (`VNDetectHumanBodyPoseRequest`).
2. **Compare.** Each measurement is compared with your calibrated posture, averaged over the last ~2 seconds:
   - face much bigger → too close to the screen
   - face much lower → head is dropping
   - nose closer to the shoulders → slouching
   - head pitch changed a lot → head is tilted
3. **Wait.** Only if bad posture lasts longer than your sensitivity setting does the glow appear.
4. **Glow.** A click-through window on every screen draws a red edge with a large shadow and a slow pulse. It fades out 1.5 seconds after you sit up.

## Build from source

1. Clone the repository and open the project:

   ```bash
   git clone https://github.com/khodiboev/PostureGuard.git
   cd PostureGuard
   open PostureGuard.xcodeproj
   ```

2. In Xcode, select the **PostureGuard** target, then go to **Signing & Capabilities**:
   - Set **Team** to your own Apple ID (a free *Personal Team* works).
   - Change the **Bundle Identifier** to something unique, e.g. `com.yourname.PostureGuard`.

3. Press **⌘R** to build and run.

Thresholds for each sensitivity level are in `PostureMonitor.swift` (`Sensitivity.limits`).

## Troubleshooting

| Problem | Fix |
|---|---|
| "No camera access" in the menu | System Settings → Privacy & Security → **Camera** → enable PostureGuard |
| Calibration fails ("Face not detected") | Improve the lighting and make sure your face is visible to the camera |
| Warnings when you're sitting fine | Calibrate again from your normal position, or switch to **Gentle** |
| No warnings when you slouch | Switch to **Strict**, and make sure you calibrated while sitting up straight |
| Shows "Away from the camera" | Your face isn't visible; check the camera angle or lighting |

## Project structure

```
PostureGuard/
├── PostureGuardApp.swift   # App entry point + menu bar menu
├── PostureMonitor.swift    # Camera, Vision measurements, calibration, warning logic
└── GlowOverlay.swift       # Red edge glow on every screen + calibration card
```

## License

[MIT](LICENSE)
