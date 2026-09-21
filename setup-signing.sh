#!/bin/zsh
set -euo pipefail

# TCC stores privacy grants against an app's designated requirement. Use a
# real signing identity so Jev remains the same app after each rebuild.
IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/sed -n 's/^[[:space:]]*[0-9][[:space:]]*) \([A-F0-9][A-F0-9]*\) .*/\1/p' | /usr/bin/head -n 1)"

if [[ -z "$IDENTITY" ]]; then
    print -u2 "No usable macOS code-signing identity was found. Add an Apple Development or Developer ID identity to your login keychain, then rerun the build."
    exit 1
fi

print -r -- "$IDENTITY"
