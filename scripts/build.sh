#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Facienda.xcodeproj -scheme Facienda -configuration Release -derivedDataPath build -allowProvisioningUpdates build "$@"
codesign --verify --deep --strict build/Build/Products/Release/Facienda.app
# The daily-use app and every helper carry the team's identity and no debugger entitlement.
for item in build/Build/Products/Release/Facienda.app build/Build/Products/Release/Facienda.app/Contents/Helpers/*; do
    if codesign -d --entitlements - --xml "$item" 2>/dev/null | grep -q get-task-allow; then
        echo "$item carries get-task-allow, so other processes could attach to it." >&2; exit 1
    fi
    team="$(codesign -dv "$item" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ -z "$team" ] || [ "$team" = "not set" ]; then echo "$item is not signed with a Team ID." >&2; exit 1; fi
done
python3 scripts/integration_smoke.py --helpers build/Build/Products/Release/Facienda.app/Contents/Helpers --workspace
python3 scripts/claude_smoke.py --helpers build/Build/Products/Release/Facienda.app/Contents/Helpers
python3 scripts/test_helper_replacement.py --helpers build/Build/Products/Release/Facienda.app/Contents/Helpers
