#!/bin/bash
# Build, sign, notarize and publish a Tester release of the committed code: scripts/release.sh [--version X.Y.Z] [--dry-run]
# The first release is 0.1.0; after that each release adds one to the last number (0.1.0, 0.1.1, …). Bigger steps such as
# 0.2.0 or 1.0.0 are always chosen with --version. Notes come from docs/releases/VERSION.md and show in the update.
# The commit is tagged vX.Y.Z once published. --dry-run still uploads the app and DMG to Apple for notarization; it skips GitHub publishing and local tagging.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
requested=""
dry_run=""
while test $# -gt 0; do
    case "$1" in
        --version) requested="${2:?--version needs a number such as 0.2.0}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) echo "Usage: scripts/release.sh [--version X.Y.Z] [--dry-run]" >&2; exit 2 ;;
    esac
done
last="$(git tag --list 'v[0-9]*' --sort=-version:refname | head -1)"
last="${last#v}"
if test -n "$requested"; then
    version="$requested"
elif test -z "$last"; then
    version="0.1.0"
else
    IFS=. read -r major minor patch <<< "$last"
    version="$major.$minor.$((patch + 1))"
fi
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Versions look like 0.2.0, not $version." >&2; exit 2; fi
if test -n "$last" && { test "$version" = "$last" || test "$(printf '%s\n%s\n' "$last" "$version" | sort -V | tail -1)" != "$version"; }; then
    echo "$version is not after the last release, $last." >&2; exit 2
fi
commit="$(git rev-parse HEAD)"
if released="$(git tag --points-at "$commit" --list 'v[0-9]*' | head -1)" && test -n "$released"; then
    echo "This commit is already released as $released; commit what changed first." >&2; exit 1
fi
notes="$root/docs/releases/$version.md"
if ! test -f "$notes"; then echo "Write the notes for $version in docs/releases/$version.md first." >&2; exit 1; fi
if test -n "$(git status --porcelain --untracked-files=no)"; then
    echo "Uncommitted changes are left out: the release is built from $(git rev-parse --short HEAD)."
fi
echo "Releasing Facienda $version from $(git rev-parse --short HEAD)${last:+ (last release: $last)}"

repository="jostelzer/facienda"
# Published releases must identify the source that was built, even if main moves during notarization.
# A dry run may still build an unpublished commit; it never creates a GitHub release.
if test -z "$dry_run"; then
    if ! published_commit="$(gh api "repos/$repository/commits/$commit" --jq .sha)" || test "$published_commit" != "$commit"; then
        echo "The release commit must already exist in $repository. Publish the reviewed source first." >&2
        exit 1
    fi
    if ! existing_tag="$(git ls-remote --tags "https://github.com/$repository.git" "refs/tags/v$version")"; then
        echo "Could not check the release tag in $repository." >&2
        exit 1
    fi
    if test -n "$existing_tag"; then
        echo "v$version already exists in $repository; refusing to reuse its tag." >&2
        exit 1
    fi
fi
# Any Developer ID Application certificate in the keychain; set FACIENDA_SIGNING_IDENTITY to pick one.
identity="${FACIENDA_SIGNING_IDENTITY:-Developer ID Application}"
profile="facienda"
derived="$root/build/tester"
output="$derived/release"
app="$derived/Build/Products/Tester/Facienda.app"
dmg="$output/Facienda-$version.dmg"
# Sparkle installs whichever build number is higher, so each release counts minutes.
build_number="$(date -u +%Y%m%d%H%M)"

# A clean checkout of the commit, so the tag names exactly the code testers run.
source="$root/build/release-source"
if test -d "$source"; then
    git -C "$source" checkout --quiet --force --detach "$commit"
    git -C "$source" clean -fdxq
else
    git worktree add --detach "$source" "$commit"
fi
cd "$source"
xcodegen generate
xcodebuild -project Facienda.xcodeproj -scheme Facienda -configuration Tester -derivedDataPath "$derived" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" build
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
if test -z "$public_key" || test "$public_key" != "$("$sparkle_bin/generate_keys" -p)"; then
    echo "Set SPARKLE_PUBLIC_KEY in project.yml to the output of: $sparkle_bin/generate_keys -p" >&2
    exit 1
fi

# Apple can take an hour for a new team, and a dropped connection must not lose the submission: keep asking until it answers.
notarize() {
    local id status
    id="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --output-format json | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
    echo "Notarizing $1 as $id"
    until status="$(xcrun notarytool info "$id" --keychain-profile "$profile" --output-format json 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)" \
        && test "$status" != "In Progress"; do sleep 30; done
    if test "$status" != Accepted; then
        xcrun notarytool log "$id" --keychain-profile "$profile" >&2
        echo "Notarization of $1: $status" >&2
        return 1
    fi
}

# Notarization needs every executable signed with Developer ID, the hardened runtime and a timestamp, inside out.
sign() { codesign --force --sign "$identity" --options runtime --timestamp "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 ! -name Sparkle.framework -print0 | while IFS= read -r -d '' item; do sign "$item"; done
find "$app/Contents/Helpers" "$app/Contents/Resources" -type f -perm -111 -print0 | while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q Mach-O; then sign "$item"; fi
done
sign --entitlements Sources/FaciendaApp/Facienda.entitlements "$app"
codesign --verify --deep --strict "$app"
if codesign -d --entitlements - "$app" 2>/dev/null | grep -qE 'icloud|get-task-allow'; then
    echo "The Tester build must carry neither iCloud nor debugger entitlements." >&2; exit 1
fi

python3 scripts/integration_smoke.py --helpers "$app/Contents/Helpers" --workspace
python3 scripts/claude_smoke.py --helpers "$app/Contents/Helpers"
python3 scripts/test_helper_replacement.py --helpers "$app/Contents/Helpers"

rm -rf "$output"; mkdir -p "$output"
ditto -c -k --keepParent "$app" "$output/Facienda.zip"
notarize "$output/Facienda.zip"
xcrun stapler staple "$app"
rm "$output/Facienda.zip"

staging="$output/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Facienda.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Facienda -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
rm -rf "$staging"
codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
spctl --assess --type execute --verbose "$app"

# The feed keeps every earlier version; the latest release always carries the whole appcast.
if ! gh release download --repo "$repository" --pattern appcast.xml --dir "$output" 2>/dev/null; then
    echo "No earlier appcast in $repository; starting a new one."
fi
signature="$("$sparkle_bin/sign_update" "$dmg")"
python3 scripts/appcast.py --appcast "$output/appcast.xml" --version "$version" --build "$build_number" \
    --url "https://github.com/$repository/releases/download/v$version/Facienda-$version.dmg" \
    --signature "$signature" --notes "$notes" --minimum-system 26.0

if test -n "$dry_run"; then
    echo "Dry run: $dmg and $output/appcast.xml are ready; nothing was published."
    exit 0
fi
gh release create "v$version" --repo "$repository" --target "$commit" --title "Facienda $version" --notes-file "$notes" "$dmg" "$output/appcast.xml"
git -C "$root" tag -a "v$version" "$commit" -m "Facienda $version"
echo "Published Facienda $version: https://github.com/$repository/releases/tag/v$version (tagged v$version)"
