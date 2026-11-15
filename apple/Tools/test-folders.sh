#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc Sources/RoomFolder.swift Tests/main.swift -o "$scratch/folder-tests"
"$scratch/folder-tests"
