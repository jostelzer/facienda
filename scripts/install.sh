#!/bin/bash
# Stage a complete app on fresh inodes. The previous installation is kept only until the new one passes its checks.
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-build/Build/Products/Release/Facienda.app}"
destination="/Applications/Facienda.app"
if pgrep -f '^/Applications/Facienda[.]app/Contents/MacOS/Facienda($| )' >/dev/null; then
    echo 'Quit Facienda before installing the update.' >&2
    exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" = org.facienda.mac
codesign --verify --deep --strict "$source_app"
identifier="$(uuidgen)"
staged="/Applications/.Facienda-$identifier.app"
backup="$PWD/.local/install-backups/Facienda-$identifier.app"
ditto "$source_app" "$staged"
codesign --verify --deep --strict "$staged"
python3 scripts/integration_smoke.py --helpers "$staged/Contents/Helpers" --workspace
python3 scripts/claude_smoke.py --helpers "$staged/Contents/Helpers"
if test -e "$destination"; then
    mkdir -p "$(dirname "$backup")"
    mv "$destination" "$backup"
fi
if ! mv "$staged" "$destination"; then
    if test -e "$backup"; then mv "$backup" "$destination"; fi
    exit 1
fi
if ! { codesign --verify --deep --strict "$destination" &&
        python3 scripts/integration_smoke.py --helpers "$destination/Contents/Helpers" --workspace &&
        python3 scripts/claude_smoke.py --helpers "$destination/Contents/Helpers"; }; then
    if test -e "$backup"; then rm -rf "$destination"; mv "$backup" "$destination"; echo 'The new app failed its checks; the previous one is back.' >&2; fi
    exit 1
fi
# Each app is a few hundred megabytes: the previous one is not kept.
rm -rf "$backup"
echo "Installed: $destination"
