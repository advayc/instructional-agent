#!/bin/zsh
set -euo pipefail

# TCC records the code-signing requirement of an app, not just its bundle ID.
# An ad-hoc signature changes that requirement on every compilation, which is
# why an enabled Screen Recording switch can still result in a new permission
# prompt. Prefer a valid Apple identity, and create one stable, local signing
# identity for development when the login keychain has none.
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
LOCAL_LABEL="Jev Local Development"

identity_for_label() {
    /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
        | /usr/bin/awk -v label="$1" 'index($0, "\"" label "\"") { print $2; exit }'
}

APPLE_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
    | /usr/bin/sed -n 's/^[[:space:]]*[0-9][[:space:]]*) \([A-F0-9][A-F0-9]*\) .*/\1/p' \
    | /usr/bin/head -n 1)"

if [[ -n "$APPLE_IDENTITY" ]]; then
    print -r -- "$APPLE_IDENTITY"
    exit 0
fi

LOCAL_IDENTITY="$(identity_for_label "$LOCAL_LABEL")"
if [[ -n "$LOCAL_IDENTITY" ]]; then
    print -r -- "$LOCAL_IDENTITY"
    exit 0
fi

BUILD_TEMP="$(/usr/bin/mktemp -d /private/tmp/jev-local-signing.XXXXXX)"
trap '/bin/rm -rf "$BUILD_TEMP"' EXIT
P12_PASSWORD="$(/usr/bin/openssl rand -hex 24)"

print -u2 "Creating a stable local Jev development signing identity in your login keychain."
/usr/bin/openssl req -new -newkey rsa:2048 -x509 -nodes -sha256 -days 3650 \
    -subj "/CN=$LOCAL_LABEL/" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$BUILD_TEMP/key.pem" \
    -out "$BUILD_TEMP/cert.pem" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export \
    -inkey "$BUILD_TEMP/key.pem" \
    -in "$BUILD_TEMP/cert.pem" \
    -out "$BUILD_TEMP/identity.p12" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1
/usr/bin/security import "$BUILD_TEMP/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
/usr/bin/security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$BUILD_TEMP/cert.pem"

LOCAL_IDENTITY="$(identity_for_label "$LOCAL_LABEL")"
if [[ -z "$LOCAL_IDENTITY" ]]; then
    print -u2 "Jev could not create a usable local signing identity. Open Keychain Access, unlock the login keychain, and rerun the build."
    exit 1
fi

print -r -- "$LOCAL_IDENTITY"
