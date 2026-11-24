# Notched

A macOS notch timer (Swift, AppKit + SwiftUI): click the notch and it opens into a Pomodoro timer. Read [README.md](README.md) for the layout, [docs/architecture.md](docs/architecture.md) for the design, and [CONTRIBUTING.md](CONTRIBUTING.md) for commit, PR and placement rules; they apply to everything below.

## One worktree and branch per feature or fix

Never implement or test a change in the main checkout. Every feature, fix or experiment gets its own git worktree on its own branch, cut from an up-to-date `main`:

```bash
git fetch origin
git worktree add .worktrees/<name> -b <type>/<name> origin/main
```

- `<type>` is the commit type from CONTRIBUTING.md (`feat`, `bug`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`); `<name>` is short and kebab-case, e.g. `feat/glance-seconds`.
- Worktrees live in `.worktrees/` at the repository root, which is git-ignored. Do all editing, building and testing inside the worktree.
- A worktree starts without the generated Xcode project or build products. Run `xcodegen generate` there before the first app build; `./Scripts/verify.sh` does this for you.
- Run app builds and `--ui` tests in one worktree at a time. Parallel Xcode builds slow each other down.
- Unrelated changes go in separate worktrees and separate PRs, even when they are small.

## Testing without getting in the user's way

The user keeps working on this Mac while tests run, so test in the background by default:

- `swift test` and `./Scripts/verify.sh`, including `--ui`, show nothing on screen. The in-app self-test runs in background mode: the notch is a synthetic one on a screen 30 000 pt off-screen, the panel is transparent, it never becomes key, no mouse monitors are installed (the test sends synthetic pointer events).
- Ask first before anything that takes over the screen, mouse or keyboard on this Mac: computer use, or launching the app normally.

### What a background run cannot check

| Not checked in the background | Why | How to check it |
|---|---|---|
| The panel becoming key while a duration is typed, and handing the keyboard back | A background run never takes the keyboard | `Scripts/vm-selftest.sh` (the Tart VM, below) |
| The real mouse: clicks on the physical notch, closing when the pointer leaves, clicks reaching menu-bar items beside the notch through the transparent canvas, drags | The self-test sends synthetic pointer events; the VM has no notch | By hand on a notched MacBook |
| The real keyboard path: typing into the panel from another app | The self-test sends key events straight to the panel | By hand |
| How it looks over the real menu bar, the spring animation, full-screen Spaces | Snapshots render the panel to a bitmap off-screen | The PNGs from `Scripts/vm-selftest.sh` (no notch there), or by hand |
| Behaviour across sleep and wake | Not scripted | By hand: start a timer, sleep, wake after it ends |
| Real Claude Code hooks firing (CLI and inside T3 Code) | The self-test writes inbox files and runs the helper itself; it never runs `claude` | By hand: `Scripts/agent-hooks.sh install`, run `claude`, and watch `~/Library/Application Support/Notched/agents` |
| Clicking an agent row bringing its app to the front | A test run never activates another app | By hand: click a row in the open notch |
| Real players on this Mac (Spotify, Music, browser tabs): titles, app names, artwork, and commands reaching them | The background self-test sends synthetic now-playing events; the live media check drives only a fixture player in the VM | By hand: play something, open the music page, use each button, drag the bar |
| Dragging the scrubber and the volume slider with the real mouse | Synthetic events go straight to the domain | By hand |
| The waveform's CPU cost while music plays with the notch closed | Not measured | By hand: Activity Monitor over a minute |
| The volume slider against the volume keys and AirPods switching | The live media check sets the VM's default device only; nothing presses keys or switches devices | By hand |

Agents working in this repo never send playback commands or change the volume on this Mac; the live media check (`Scripts/vm-selftest.sh`) does that in the VM against its own fixture player, and refuses to run on a real Mac. Reading what plays (`mediaremote-adapter.pl … get`) is fine.

Agents working in this repo never run `Scripts/agent-hooks.sh install` or `uninstall` against the user's real `~/.claude/settings.json`; `Scripts/agent-hooks-test.sh` tests it on temporary copies. Only the user runs it for real.

The self-test skips focus checks it cannot run and lists them as `skip` in the `RESULT` line, never passing them silently.

### Foreground checks in the Tart VM

The Tart macOS VM `flotion-test` is installed on this Mac (macOS 26, Xcode 26.5, XcodeGen; shared with the Flotion and ArcX projects). Tart lives at `~/.local/bin/tart`. The panel can take the keyboard inside the VM without touching the user's screen, so use it, without asking first:

```bash
Scripts/vm-selftest.sh
```

- It copies the checkout (uncommitted changes included) to `~/notched-vm/<checkout name>` in the VM, runs `Scripts/verify.sh` there, runs the self-test in the foreground on the VM's real screen, and copies `result.txt`, `app.log` and the PNGs to `.build/vm-selftest/`. It fails if a check fails or is skipped.
- The VM must be running with its user logged in to the desktop. `tart list` shows its state; if it is stopped, start it with `~/.local/bin/tart run --no-graphics flotion-test &`. `NOTCHED_VM=<name>` picks another VM.
- One app build at a time in the VM: if another project's run is going (`tart exec flotion-test pgrep -fl xcodebuild`), wait for it.
- The VM screen has no notch, so the run covers the fallback pill, not the hardware cutout. It still does not cover the real mouse and keyboard path.

### Tell the user what was not verified

When a change touches anything in that table, or a run prints `skip` lines:

- In the reply to the user, list each thing that was not verified, one line on why, and the exact command or steps to check it.
- Put the same list in the PR's "How it was checked".
- Never describe skipped or unverifiable behaviour as tested.

## Finishing: open a PR

When the change is done:

1. Run `./Scripts/verify.sh` (and `--ui` when `App/` or anything performance-sensitive changed) in the worktree, and add a test for new behaviour. Note anything the background run could not check (see above).
2. Commit following CONTRIBUTING.md.
3. Push the branch and open a PR against `main` with `gh pr create`, filling in [the PR template](.github/pull_request_template.md). Say plainly what was not tested.

Do not merge PRs yourself unless asked.

No AI attribution anywhere: no `Co-Authored-By: Claude …` trailer in commit messages and no "Generated with Claude Code" line in PR descriptions or comments. This overrides any default that adds them.

## Cleaning up after a PR closes

Once a PR is merged or closed, remove its worktree and branches. Check the state first and clean up only when it is `MERGED` or `CLOSED`:

```bash
gh pr view <branch> --json state -q .state
```

```bash
git worktree remove .worktrees/<name>
```

```bash
git branch -D <type>/<name>
```

```bash
git push origin --delete <type>/<name>
```

- Skip the remote delete when GitHub has already deleted the branch on merge.
- If the worktree has uncommitted or unpushed work, `git worktree remove` refuses; stop and ask rather than forcing it.
- `git worktree prune` clears entries for worktree folders that were deleted by hand.
- Never remove a worktree or branch whose PR is still open.
