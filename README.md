# Softclose

**Your desktop folds away as you close the lid.**

Softclose reads the hinge angle from the sensor in your MacBook, captures the
live desktop, and renders it as a sheet folding away from you — tilting,
blurring and falling into shadow as the lid comes down, settling back flat as it
opens.

[![Buy me a coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-support-FFDD00?style=flat-square&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/matej2510)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-black?style=flat-square)

> Inspired by [Bendy](https://trybendy.app), a paid app that does this
> beautifully. This is an independent implementation written from scratch — if
> you like the idea, go and buy theirs too.

## Requirements

- macOS 14 Sonoma or later
- An Apple silicon MacBook with a lid angle sensor
- Screen Recording permission, so the desktop can be captured

## Install

```bash
./install.sh          # build, install to /Applications, re-arm permission, launch
./build.sh            # just the bundle, into build/Softclose.app
```

The build compiles the Swift package, compiles `Bend.metal` into a metallib,
assembles the bundle and ad-hoc signs it.

### Ad-hoc signing and permissions

Screen Recording permission is remembered per signature. Because `build.sh`
signs ad-hoc, **every rebuild looks like a different app to macOS**. The failure
is a quiet one: the switch in Privacy settings still reads as on, but capture
fails with *"the user declined TCCs"*, because the grant no longer matches the
binary.

`install.sh` handles it by running
`tccutil reset ScreenCapture io.github.matejcok1234.softclose` after each build,
so the next launch asks cleanly rather than failing against a stale approval. If
you would rather grant it once and never again, sign with a stable self-signed
identity instead of ad-hoc.

## Using it

Softclose lives in the menu bar; there is no Dock icon and no window unless you
open Settings.

- **Style** — Silk (mostly fold), Shade (falls into shadow), Frost (softens to
  frosted glass). Each is a weighting of the same three sliders, so touching a
  slider drops you into Custom.
- **Clears at** — above this hinge angle the desktop is left alone and capture
  stops. On first launch Softclose takes the angle your lid is sitting at and
  clears just below it, so there is no permanent fold on a laptop held at 90°.
- **Drag the angle myself** — ignores the sensor and holds the fold wherever you
  put the slider. The easiest way to choose a look, and the only way to see the
  effect on a Mac without the sensor.
- **⌥⌘B** — pause and resume from anywhere. Uses Carbon's hot key API, which
  needs no Accessibility permission.

Under **Advanced** are the constants the three style sliders scale — the fold
depth in degrees, the widest blur radius, the lens distance, and the stiffness
of the spring that follows the hinge. The settings window floats above the
overlay on purpose, so all of it can be tuned against a live fold.

Settings live in `defaults`, so a look can be inspected or scripted:

```bash
defaults read io.github.matejcok1234.softclose
defaults write io.github.matejcok1234.softclose manualAngle -float 45
defaults delete io.github.matejcok1234.softclose manualAngle
```

## How it works

| | |
|---|---|
| `LidAngleSensor` | The hinge shows up as an Apple HID device (`las`) on the sensor usage page, usage `0x8A`. It pushes input reports of `[0x01, low, high]` — degrees, little-endian — so Softclose listens instead of polling. A half-second heartbeat re-reads the feature report, which also catches Screen Recording being granted while running. |
| `ScreenCapture` | ScreenCaptureKit, filtered to exclude Softclose's own windows — the overlay is showing the capture, so including it would feed the picture back into itself. Frames arrive as `IOSurface`-backed Metal textures; nothing is copied to the CPU. |
| `AppStatus` | Live runtime state, kept apart from persisted settings so the readout can move without the settings view being rebuilt under a slider mid-drag. |
| `BendRenderer` | Eases toward the reported angle with a critically damped spring: the sensor jumps in whole degrees, the spring makes it fluid. That easing is the "settles". |
| `Bend.metal` | The desktop is a sheet hinged along its bottom edge. Each row is rotated a little further than the one below it, so it curves into a circular arc rather than tipping as a rigid plane — that curve is what reads as a fold. Shading falls off along it, with ambient occlusion at the hinge. |

### Two things worth knowing about the shaders

The blur runs at half resolution with nine taps either side, which puts the taps
`sigma/3` apart — more than a texel once the blur widens, and sampling detail
finer than the gap turns it into stripes. Each tap reads from the mip level
where its own spacing is one texel, so it averages the pixels it steps over.

The cross-fade to the blurred copy saturates early rather than tracking blur
strength. A lasting half-and-half mix keeps sharp edges visible *through* the
blur, which reads as a double image rather than as frost.

## Privacy

Frames are captured, rendered and discarded on device. Nothing is recorded,
saved or uploaded, and Softclose makes no network connections of any kind.

The overlay is deliberately left visible to other recorders, so the fold can be
screen-recorded — excluding it would make it invisible to QuickTime and ⌘⇧5.

## Layout

```
Sources/Softclose/
  main.swift            NSApplication, accessory activation policy
  AppDelegate.swift     Menu bar, hot key, permission state
  BendController.swift  Ties the hinge to the screen; starts and stops everything
  LidAngleSensor.swift  HID
  ScreenCapture.swift   ScreenCaptureKit
  BendRenderer.swift    Metal render loop and the easing spring
  OverlayWindow.swift   Borderless, click-through, above everything
  SettingsView.swift    SwiftUI settings
  Settings.swift        Persistence, style presets, the angle→progress curve
  AppStatus.swift       Live runtime state for the UI
  Click.swift           The click when the desktop clears, synthesised
  Shaders/Bend.metal    Fold, blur, shading
Tools/
  MakeIcon.swift        Draws the icon at every size iconutil wants
  RenderPreview.swift   Renders the fold against a mock desktop, for judging it
                        without permissions or a moving lid
probe/
  lidprobe.swift        Dumps the raw lid angle sensor reports
  inputprobe.swift      Confirms the sensor pushes input reports
```

`Tools/RenderPreview.swift` is the fastest way to iterate on the look — it needs
no permissions and no moving lid:

```bash
swiftc -O Tools/RenderPreview.swift -o build/renderpreview
./build/renderpreview build/preview      # → PNGs at a range of hinge angles
```

## Support

If this made your laptop nicer to close, you can
[buy me a coffee](https://buymeacoffee.com/matej2510). ☕

## Licence

MIT — see [LICENSE](LICENSE).
