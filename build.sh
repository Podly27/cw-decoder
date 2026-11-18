#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/build/IC-9700 CW.app"
cache="$(mktemp -d)"
trap 'rm -rf "$cache"' EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -module-cache-path "$cache" Decoder.swift AudioSpectrum.swift main.swift -o "$app/Contents/MacOS/IC9700CW"
cp Info.plist "$app/Contents/"
cp assets/CWDecoder.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
