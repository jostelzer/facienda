# Facienda

**Things that must be done. A little less on your mind.**

Mission control for AI agents: lay out your work on a visual board, and Claude or Codex carry it out on your Mac.

![Facienda in dark mode, with illustrative demo data](Assets/Brand/facienda-app-preview-dark.png)

Agents are good at doing a task and bad at waiting for something. Instead of a dozen chat windows and a reply you almost missed, Facienda shows all the work on one board and pulls you in only when it needs you.

- **Spatial board.** Groups of tasks, each with a generated image and a place on the board. You find work by where it sits.
- **Claude or Codex, per task.** Execution stays in their apps; Facienda owns the big picture.
- **The fork.** When an agent finishes a step, it continues, watches something, or hands the next action back to you.
- **Your own to-dos too**, with dates, next to the agents' work.
- **Memory** that learns how you work.
- **Local.** Mac only, on your own machine.

## Build

With Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen), no Apple developer account needed:

```sh
scripts/dev-build.sh --open
```

Pull requests are welcome; start with [CONTRIBUTING.md](CONTRIBUTING.md).

Facienda is a beta. Report problems in [Issues](https://github.com/jostelzer/facienda/issues), security issues as described in [SECURITY.md](SECURITY.md). Apache License 2.0, see [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
