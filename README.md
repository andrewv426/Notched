# Notched

A timer that lives in your MacBook's notch.

- **Hover or click the notch** and it opens into a timer. Pick 1, 5, 10 or 25 minutes, or click the display and type digits (they fill HH:MM:SS from the right, like a microwave), then Return.
- **Glance while it runs.** Closed, the notch grows thin wings: a progress ring on the left, the time left on the right.
- **Done.** The wings turn orange, Glass plays and a notification is posted. Opening the notch silences it; Restart or Dismiss is one click.
- Without a notch (an external display, a closed lid), it lives in a small pill at the top centre of the screen.
- Sleep does not pause the timer: 25 minutes means 25 real minutes.

Right-click the open notch to quit.

## Requirements

macOS 26 or later on Apple Silicon, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```bash
./Scripts/verify.sh
```

```bash
open .build/xcode/Build/Products/Debug/Notched.app
```

`verify.sh` generates the Xcode project, builds everything, runs the tests and makes the disk image. To work in Xcode, run `xcodegen generate` and open `Notched.xcodeproj`.

## Install

Every `./Scripts/verify.sh` run also builds a Release app, wraps it in `.build/Notched-<version>.dmg`, and installs it from that image into `/Applications`, so you can launch Notched from Spotlight. If a copy from `/Applications` is running, it is quit first and relaunched after. `--no-dmg` skips the image and the install; `Scripts/package.sh --no-install` builds the image only. The app is ad-hoc signed and not notarized, so it launches on the Mac that built it. On another Mac, Gatekeeper blocks a downloaded copy until it is allowed in System Settings › Privacy & Security.

## Layout

```
App/                        the macOS app
  Notch/                    controller, panel, views, alerter
  Debug/                    the in-app self-test (Debug builds only)
Packages/NotchedKit/
  Sources/NotchedCore/      every rule: countdown, hover, editing, layout geometry
  Tests/                    unit tests
Scripts/                    verify.sh, selftest.sh, vm-selftest.sh
docs/architecture.md        how the pieces fit, and why
```

## Testing

| Command | Runs |
|---|---|
| `./Scripts/verify.sh` | Package build, all tests, app build, disk image |
| `./Scripts/verify.sh --ui` | The above, plus the in-app self-test in the background |
| `Scripts/vm-selftest.sh` | `verify.sh` inside the Tart VM, then the self-test in the foreground there, so the keyboard-focus checks run too |

The self-test drives the real panel with synthetic pointer events and key presses, waits on the real deadline alarm, and renders the panel to PNG files in `.build/selftest/`. In the background it uses an off-screen synthetic notch, never takes the keyboard and makes no sound.
