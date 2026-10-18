#!/bin/bash
# Prepare locally by default. Only --publish uploads to Apple and GitHub.
# scripts/release.sh [--prepare] [--version X.Y.Z]
# scripts/release.sh --publish /absolute/path/to/prepared-release
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
metadata="$root/scripts/release_metadata.py"
mode=prepare
requested=""
prepared=""
while test $# -gt 0; do
    case "$1" in
        --prepare|--dry-run) mode=prepare; shift ;;
        --publish) mode=publish; prepared="${2:?--publish needs a prepared release directory}"; shift 2 ;;
        --version) requested="${2:?--version needs a number such as 0.3.0}"; shift 2 ;;
        *) echo "Usage: scripts/release.sh [--prepare] [--version X.Y.Z] | --publish DIRECTORY" >&2; exit 2 ;;
    esac
done
fail() { echo "$*" >&2; exit 1; }
test "$(git branch --show-current)" = main || fail "Release from main, after squashing and reviewing dev."
test -z "$(git status --porcelain)" || fail "The release checkout must be clean, including untracked files."
commit="$(git rev-parse HEAD)"
version="$(git show "$commit:project.yml" | python3 "$metadata" version)"
test -z "$requested" || test "$requested" = "$version" || fail "Requested $requested differs from project.yml ($version)."
# Only tags in main's ancestry define its previous releases.
git tag --merged "$commit" --list 'v[0-9]*' | python3 "$metadata" newer "$version"
if git rev-parse --verify --quiet "refs/tags/v$version" >/dev/null; then fail "v$version already exists; never reuse a release tag."; fi
git cat-file -e "$commit:docs/releases/$version.md" || fail "Commit docs/releases/$version.md before preparing the release."
repository="jostelzer/facienda"

if test "$mode" = prepare; then
    # Seconds keep builds distinct; publication also checks against the live appcast.
    build_number="$(date -u +%Y%m%d%H%M%S)"
    mkdir -p "$root/build/releases"
    output="$(mktemp -d "$root/build/releases/$version-$build_number.XXXXXX")"
    source="$output/source"
    git worktree add --quiet --detach "$source" "$commit"
    derived="$output/derived"
    app="$derived/Build/Products/Tester/Facienda.app"
    cd "$source"
    xcodegen generate
    # A local review build: no signing account, timestamp service or notarization upload.
    xcodebuild -project Facienda.xcodeproj -scheme Facienda -configuration Tester -derivedDataPath "$derived" \
        CURRENT_PROJECT_VERSION="$build_number" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
        OTHER_CODE_SIGN_FLAGS=--timestamp=none build
    codesign --verify --deep --strict "$app"
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" || fail "Built version differs from committed project.yml."
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")" = "$build_number" || fail "Built build number differs from the release."
    python3 scripts/integration_smoke.py --helpers "$app/Contents/Helpers" --workspace
    python3 scripts/claude_smoke.py --helpers "$app/Contents/Helpers"
    python3 scripts/test_helper_replacement.py --helpers "$app/Contents/Helpers"
    # Keep only the small Sparkle tools with the archive; build caches can be removed after review.
    ditto "$derived/SourcePackages/artifacts/sparkle/Sparkle/bin" "$output/sparkle"
    ditto -c -k --keepParent "$app" "$output/Facienda.zip"
    git show "$commit:docs/releases/$version.md" > "$output/notes.md"
    python3 "$metadata" record "$output" --commit "$commit" --version "$version" --build "$build_number"
    echo "Prepared Facienda $version locally: $output"
    echo "The archive is ad-hoc signed for review, not notarized for distribution. Nothing was uploaded or tagged."
    echo "After approval and pushing this main commit: scripts/release.sh --publish '$output'"
    exit 0
fi

# Verify the exact prepared files before any remote or signing operation. Never rebuild during publication.
prepared="$(cd "$prepared" && pwd)"
fields="$(python3 "$metadata" verify "$prepared")"
read -r prepared_commit prepared_version build_number <<< "$fields"
test "$prepared_commit" = "$commit" && test "$prepared_version" = "$version" || fail "Prepared release does not match this main commit and version."
git show "$commit:docs/releases/$version.md" | cmp -s - "$prepared/notes.md" || fail "Prepared release notes differ from the commit."
if ! published_commit="$(gh api "repos/$repository/commits/main" --jq .sha)" || test "$published_commit" != "$commit"; then
    fail "Push the reviewed main commit to $repository before publishing."
fi
if ! existing_tags="$(git ls-remote --tags "https://github.com/$repository.git")"; then fail "Could not check release tags in $repository."; fi
printf '%s\n' "$existing_tags" | awk '{sub("refs/tags/", "", $2); print $2}' | python3 "$metadata" newer "$version"
# An exact-name check also refuses nonstandard or annotated tag collisions.
if printf '%s\n' "$existing_tags" | awk '{print $2}' | grep -Fxq "refs/tags/v$version"; then fail "v$version already exists in $repository; refusing to reuse its tag."; fi
output="$(mktemp -d "$prepared/publish.XXXXXX")"
# Failure to retrieve an existing feed must never silently discard earlier updates.
latest="$(gh api "repos/$repository/releases?per_page=100" --jq '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty')"
if test -n "$latest"; then
    gh release download "$latest" --repo "$repository" --pattern appcast.xml --dir "$output"
    python3 - "$output/appcast.xml" "$build_number" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in root.findall('./channel/item'):
    old = item.findtext(namespace + 'version')
    enclosure = item.find('enclosure')
    if old is None and enclosure is not None:
        old = enclosure.get(namespace + 'version')
    if not old or not old.isdigit():
        raise SystemExit('Cannot verify the previous Sparkle build number.')
    if int(sys.argv[2]) <= int(old):
        raise SystemExit('Prepared build is not newer than the published appcast; prepare again.')
PY
fi
sparkle_bin="$prepared/sparkle"
app="$output/Facienda.app"
dmg="$output/Facienda-$version.dmg"
notes="$prepared/notes.md"
ditto -x -k "$prepared/Facienda.zip" "$output"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" || fail "Prepared app version mismatch."
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")" = "$build_number" || fail "Prepared app build mismatch."
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
test -n "$public_key" && test "$public_key" = "$("$sparkle_bin/generate_keys" -p)" || fail "The Sparkle signing key differs from the app's public key."
identity="${FACIENDA_SIGNING_IDENTITY:-Developer ID Application}"
profile=facienda
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
# Entitlements and appcast tooling come from the pinned source, not the working checkout.
git show "$commit:Sources/FaciendaApp/Facienda.entitlements" > "$output/Facienda.entitlements"
sign --entitlements "$output/Facienda.entitlements" "$app"
codesign --verify --deep --strict "$app"
if codesign -d --entitlements - "$app" 2>/dev/null | grep -qE 'icloud|get-task-allow'; then fail "The release must carry neither iCloud nor debugger entitlements."; fi
notarize() {
    local id status attempt
    id="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --output-format json | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
    echo "Notarizing $1 as $id"
    for ((attempt=0; attempt<240; attempt++)); do
        if status="$(xcrun notarytool info "$id" --keychain-profile "$profile" --output-format json 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)"; then
            case "$status" in
                Accepted) return 0 ;;
                "In Progress") ;;
                *) xcrun notarytool log "$id" --keychain-profile "$profile" >&2; fail "Notarization: $status ($id)." ;;
            esac
        fi
        sleep 30
    done
    fail "Notarization still pending after two hours. Submission: $id. Nothing published."
}
ditto -c -k --keepParent "$app" "$output/Facienda-notarization.zip"
notarize "$output/Facienda-notarization.zip"
xcrun stapler staple "$app"
staging="$output/dmg"
mkdir "$staging"
ditto "$app" "$staging/Facienda.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Facienda -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
spctl --assess --type execute --verbose "$app"
signature="$("$sparkle_bin/sign_update" "$dmg")"
git show "$commit:scripts/appcast.py" > "$output/appcast.py"
python3 "$output/appcast.py" --appcast "$output/appcast.xml" --version "$version" --build "$build_number" \
    --url "https://github.com/$repository/releases/download/v$version/Facienda-$version.dmg" \
    --signature "$signature" --notes "$notes" --minimum-system 26.0
gh release create "v$version" --repo "$repository" --target "$commit" --title "Facienda $version" --notes-file "$notes" "$dmg" "$output/appcast.xml"
git tag -a "v$version" "$commit" -m "Facienda $version"
echo "Published Facienda $version: https://github.com/$repository/releases/tag/v$version"
