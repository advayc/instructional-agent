#!/bin/zsh
set -a
source "$(dirname "$0")/.env"
set +a
if [[ -x "$(dirname "$0")/jev" ]]; then exec "$(dirname "$0")/jev" "$@"; fi
exec swift "$(dirname "$0")/jev.swift" "$@"
