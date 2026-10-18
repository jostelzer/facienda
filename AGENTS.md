# Facienda — notes for agents

Facienda is a native Mac app in Swift 6 and SwiftUI, for macOS 26. These notes are for any coding agent working on it.

## Where things are

- `Sources/FaciendaApp`: the Mac app.
- `Sources/FaciendaCore`: the library (SQLite through GRDB), memory, and what the app and the helpers share.
- `Sources/FaciendaMCP`, `FaciendaHook`, `FaciendaDispatch`, `FaciendaMemory`: the command-line helpers bundled inside the app. Claude and Codex reach Facienda through them.
- `Sources/FaciendaBridge`: the connection to Codex and Claude: the Codex app server, the dispatcher, setup and background model calls.

## Build and test

- `scripts/dev-build.sh --test` builds the Debug app and runs the tests, with no Apple account. Run it before you call a change done.
- `project.yml` defines the Xcode project. `xcodegen generate` makes `Facienda.xcodeproj`, which is not in git, so never edit the generated project. A new file in an existing source folder is picked up on the next generate.
- `--demo` opens the app on sample data. Debug builds otherwise use their own library in `~/facienda-development`, with separate preferences, Application Support and caches. Do not select a production library when testing outside contributions; use a separate macOS account for untrusted code.
- `scripts/build.sh`, `install.sh` and `release.sh` sign with the maintainer's Apple team. Don't run them unless you're asked to.

## Code

- Write like the code around it: its naming, idiom and comment density. Comments say why, in plain sentences.
- Text in the interface is short and plain.
- Facienda treats agents as untrusted (see [SECURITY.md](SECURITY.md)). Changes to the helpers, permission rules or link handling need a reason in the pull request.

## Motion

Facienda's motion design lives in `enum Motion` in [Sources/FaciendaApp/Theme.swift](Sources/FaciendaApp/Theme.swift). Read it before you animate anything, and use its tokens rather than new timings.

- One curve, `cubic-bezier(0.65, 0, 0.35, 1)`, with no overshoot.
- `travel` 0.52 s across the window · `move` 0.34 s within the page · `fade` 0.16 s in place, and as the Reduce Motion stand-in.
- Every part of one change starts and lands together. No staged delays.
- Signals (running arc, unread ring, landing ripple, ⌘K flash, mic meter) keep their own clocks.

## Local notes

If `AGENTS.local.md` exists, read it too. It holds the maintainer's own shorthands and stays out of git.
