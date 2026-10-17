# Contributing

Thanks for looking. Facienda is young, has one maintainer and still changes shape, so:

- **Bugs and small fixes:** open a pull request.
- **Anything bigger** (a feature, a new screen, a refactor): open an issue first and wait for a yes. A pull request for something we haven't agreed on may be closed, even a good one.
- **Security problems:** don't open an issue or pull request. See [SECURITY.md](SECURITY.md).

## Build

You need macOS 26, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). You don't need an Apple developer account.

```sh
scripts/dev-build.sh           # build
scripts/dev-build.sh --test    # build, then run the tests
scripts/dev-build.sh --open    # build, then open it on sample data
```

The app lands in `build/Build/Products/Debug/Facienda.app` as Facienda Development, signed ad hoc. Debug builds and their helpers default to `~/facienda-development`, with their own library pointer, backups, chat index, speech downloads and memory caches. Release builds keep using `~/facienda`. A development build does not import the installed app's data or settings. `--open` uses sample data instead.

This prevents accidental mixing of libraries; it is not a sandbox. Choosing another library explicitly still opens it, and connecting Codex or Claude changes that account's agent configuration. Review outside contributions before running them, or use a separate macOS account with test data and test agent accounts.

Dictation downloads fixed model and tokenizer revisions, verifies their content hashes and stores them together. Older unversioned speech downloads are left in place but are not reused; the first use of dictation with this version downloads the reviewed snapshot again. Settings → Storage can move all dictation downloads to the Trash.

`scripts/build.sh`, `install.sh` and `release.sh` are the maintainer's signed builds and need the maintainer's Apple team.

## Pull requests

- One change per pull request, small enough to review in one sitting.
- Write it like the code around it. [AGENTS.md](AGENTS.md) has the conventions, for you and for your coding agent.
- Run `scripts/dev-build.sh --test` and say how you tested. For anything visible, add a before and after screenshot in light and dark.
- Using Claude, Codex or another agent is fine. You're answerable for every line, and please say in the pull request that you used one.
- Changes to agent permissions, the helpers, link handling or the release scripts get a slow, careful review. Explain why they're needed.

By submitting a contribution you agree it is licensed under the Apache License 2.0, as section 5 of the [LICENSE](LICENSE) says.
