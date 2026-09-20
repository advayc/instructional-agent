#!/bin/zsh
set -a
source "$(dirname "$0")/.env"
set +a
exec swift "$(dirname "$0")/jev.swift" "$@"
