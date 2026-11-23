# Contributing

## Before you commit

```bash
./Scripts/verify.sh          # package build, all tests, app build, disk image, install into /Applications (--no-dmg skips both)
./Scripts/verify.sh --ui     # also the in-app self-test (in the background)
Scripts/vm-selftest.sh       # the self-test in the foreground in the Tart VM
```

Warnings are errors in every target.

## Commits

```
type(scope): summary in the imperative, 72 characters at most
```

| Type | Use it for |
|---|---|
| `feat` | A capability a user can now see |
| `bug` | A fix for behaviour that was wrong |
| `perf` | Faster or lighter with the same behaviour |
| `refactor` | Restructuring with no behaviour change |
| `test` | Tests, fixtures or the verify gate only |
| `docs` | Documentation and templates only |
| `build` | Project config, dependencies, build scripts |
| `chore` | Anything else that does not touch shipped code |

Scopes are optional: `core`, `panel`, `app`.

Keep one logical change per commit, and make each commit build on its own. Turn on the commit message template once per clone:

```bash
git config commit.template .gitmessage
```

## Pull requests

The title follows the commit format. Fill in the description from [the template](.github/pull_request_template.md): what changes, why, a table of changed files, visuals for UI changes (the self-test writes PNGs to `.build/selftest/`), and how it was checked, including what was not tested.

## Where things go

| Change | Place | Test it in |
|---|---|---|
| Timer, hover, open/close, editing, layout sizes, anything a rule decides | `Packages/NotchedKit/Sources/NotchedCore` | `NotchedCoreTests` |
| The panel, mouse monitors, key presses, screen and wake observers | `App/Notch/NotchController.swift`, `NotchPanel.swift` | `App/Debug/SelfTest.swift` |
| How it looks | `App/Notch/NotchView.swift` | `App/Debug/SelfTest.swift` snapshots |
| Sound and notifications | `App/Notch/Alerter.swift` | By hand |

Rules belong in the package, where they run headless in milliseconds. `App/` turns input into `NotchEvent`s and matches AppKit to `NotchState`'s projections; it makes no decisions. If you are about to write an `if` about timer or hover behaviour in `App/`, it belongs in `NotchState.reduce`.
