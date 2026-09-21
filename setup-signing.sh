#!/bin/zsh
set -euo pipefail

# TCC stores privacy grants against an app's designated requirement. Use a
# real signing identity so Jev remains the same app after each rebuild.
IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/sed -n 's/^[[:space:]]*[0-9][[:space:]]*) \([A-F0-9][A-F0-9]*\) .*/\1/p' | /usr/bin/head -n 1)"

if [[ -z "$IDENTITY" ]]; then
    # A valid Apple signing identity is best because macOS can retain TCC
    # approval across rebuilds. Keep development usable without Xcode when a
    # certificate has expired or is unavailable; the bundle is still signed,
    # but macOS may ask once again after a rebuild.
    print -u2 "No valid Apple code-signing identity is available; using an ad-hoc bundle signature."
    print -r -- "-"
    exit 0
fi

print -r -- "$IDENTITY"
