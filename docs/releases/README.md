# Preparing and publishing a release

`dev` holds day-to-day commits. `main` receives one reviewed squash commit per release. Keep `dev` in the private development repository if its history should remain private; push only `main` and release tags to the public repository. Contributor fixes accepted on `main` must also return to `dev`.

## Prepare

1. Finish and test the intended `dev` revision. Use a separate worktree on the existing `main` branch so ongoing development is undisturbed.
2. On `main`, run `git merge --squash <reviewed-dev-commit>`.
3. Set `MARKETING_VERSION` in `project.yml` and write `docs/releases/VERSION.md`. The project version is the single source of truth; `--version` only checks it. Use patch versions for fixes and minor versions for feature releases while the app is pre-1.0.
4. Run `scripts/dev-build.sh --test` and review the diff, notes, and any screenshot. Screenshots must use fictional demo data.
5. Commit the whole release once, for example `Release 0.3.0`. Record the reviewed dev commit in the private release report, keeping private history references out of the public message.
6. Run `scripts/release.sh --prepare`. It requires a clean `main`, builds a detached checkout of its exact commit, runs smoke checks and creates a review archive under `build/releases/`. It does not use a signing account, upload to Apple or GitHub, create a tag, push, or install the app. `--dry-run` is a compatibility alias for this local preparation.

The archive has an ad-hoc signature for local review. `release.json` records its commit, version, UTC build number (to the second), and SHA-256 hashes of the archive and committed notes. Keep the archive, notes, manifest and `sparkle/` tools together. The build's `source/` worktree and `derived/` cache are intermediate output; they are not needed to publish.

## Publish, only after approval

Push the reviewed `main` commit to the public remote, then run:

```sh
scripts/release.sh --publish /absolute/path/to/prepared-release
```

Publication verifies the manifest, committed notes, public `main`, unused version, and increasing Sparkle build number. It uses the prepared archive without recompiling. It signs with Developer ID, notarizes the app and DMG through Apple, staples both, and signs the Sparkle update. It preserves the existing appcast; failure to download it stops publication. Finally it creates the GitHub release targeting the exact built commit and records the tag locally. Every attempt uses a new output directory; it never deletes earlier output.

Publishing needs the maintainer's Developer ID certificate, the `facienda` notarytool keychain profile and the Sparkle private key. Signing credentials never belong in the repository. If GitHub creation succeeds but local tagging fails, inspect the remote release before doing anything else; do not recreate or move a published tag. If notarization times out, the log retains its submission ID.

After the release, merge `main` back into `dev` normally (not a squash). This preserves the complete development history and records a common base for the next release. Never reset or force-push `dev` to make it resemble `main`.
