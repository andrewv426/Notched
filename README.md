# Notched

A timer that lives in your MacBook's notch.

- **Click the notch** and it opens into a timer. Pick Focus 50, Focus 25, Break or Custom, then press play. For Custom, type minutes (45 → 45:00) and press Return. Move the pointer away and the notch closes by itself.
- **Glance while it runs.** Closed, the notch grows thin wings: a progress ring on the left, the time left on the right.
- **Pomodoro.** A break follows each focus: 10 minutes after a 50, 5 after a 25. When a phase ends, the next one is already selected, so starting it is one click.
- **Done.** Silent: a dot pulses in the wings until you open the notch.
- **Coding agents.** With the Claude Code hooks installed (below), the notch shows your agents. While they work and nothing else is showing, narrow wings show a spinner and a count. When one finishes or needs your input, the wings pulse with the project's name until you have seen it. Click the notch for the list, and click a row to bring that agent's app to the front. A running timer keeps its wings, and agents show as a dot on them.
- Without a notch (an external display, a closed lid), it lives in a small pill at the top centre of the screen.
- Sleep does not pause the timer: 25 minutes means 25 real minutes.

Right-click the open notch to quit.

## Show coding agents

Notched learns what Claude Code is doing from its hooks. That covers the `claude` CLI in any terminal and Claude Code inside T3 Code. Install Notched first, then:

```bash
Scripts/agent-hooks.sh print       # show the hooks; changes nothing
Scripts/agent-hooks.sh install     # copy the helper to ~/Library/Application Support/Notched/bin and add the hooks to ~/.claude/settings.json
Scripts/agent-hooks.sh uninstall   # remove exactly those hooks and the helper
```

`install` saves a backup of `settings.json` before changing it, and running it twice changes nothing. Each hook runs `notched-agent`, which writes one small file per session to `~/Library/Application Support/Notched/agents` in about 5 ms and always exits 0, so a hook can never slow down or fail a turn, even when Notched is not running. Nothing is sent anywhere, and the agent's messages are not stored.

A finished turn stays until you have seen it in the open notch, or for an hour. An agent whose process has exited while it was working leaves at once.

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
  Notch/                    controller, panel, views
  Agents/                   the agent inbox watcher and the focuser
Agent/                      notched-agent, the hook helper (embedded in Notched.app/Contents/Helpers)
Shared/                     process-table lookups used by the app and the helper
  Debug/                    the in-app self-test (Debug builds only)
Packages/NotchedKit/
  Sources/NotchedCore/      every rule: countdown, phases, opening, typing, agents, layout geometry
  Tests/                    unit tests
Scripts/                    verify.sh, selftest.sh, vm-selftest.sh, agent-hooks.sh
docs/architecture.md        how the pieces fit, and why
```

## Testing

| Command | Runs |
|---|---|
| `./Scripts/verify.sh` | Package build, all tests, the hooks script test (temporary files only), app build, disk image |
| `./Scripts/verify.sh --ui` | The above, plus the in-app self-test in the background |
| `Scripts/vm-selftest.sh` | `verify.sh` inside the Tart VM, then the self-test in the foreground there, so the keyboard-focus checks run too |

The self-test drives the real panel with synthetic pointer events and key presses, waits on the real deadline alarm, and renders the panel to PNG files in `.build/selftest/`. In the background it uses an off-screen synthetic notch, and never takes the keyboard.
