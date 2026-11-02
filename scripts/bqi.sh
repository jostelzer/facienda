#!/bin/bash
# Build, quit, install and reopen Facienda in one step, signed with the maintainer's team like build.sh.
# Everything goes to .local/bqi.log; only the outcome is printed, so an agent spends one short step on it.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
log="$PWD/.local/bqi.log"
: > "$log"
fail() { echo "bqi failed while $1. Last lines of $log:" >&2; tail -n 25 "$log" >&2; exit 1; }

bash scripts/build.sh >>"$log" 2>&1 || fail "building"
osascript -e 'quit app id "org.facienda.mac"' >>"$log" 2>&1
for _ in $(seq 1 60); do
    pgrep -f '^/Applications/Facienda[.]app/Contents/MacOS/Facienda($| )' >/dev/null || break
    sleep 1
done
pgrep -f '^/Applications/Facienda[.]app/Contents/MacOS/Facienda($| )' >/dev/null && fail "waiting for Facienda to quit"
bash scripts/install.sh >>"$log" 2>&1 || fail "installing"
open /Applications/Facienda.app
echo "Installed and reopened Facienda from $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Sources project.yml || echo ' with uncommitted changes'). Log: $log"
