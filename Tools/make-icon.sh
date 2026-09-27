#!/bin/sh
# Régénère App/icon.png et App/AppIcon.icns à partir du symbole partagé (Sources/Mark.swift).
set -e
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -swift-version 5 -O -o "$TMP/make-icon" Sources/Mark.swift Tools/make-icon/main.swift
"$TMP/make-icon" App/icon.png

ICONSET="$TMP/Sillio.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s App/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) App/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o App/AppIcon.icns
echo "OK → App/AppIcon.icns"
