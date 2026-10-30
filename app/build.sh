#!/bin/zsh
# Builds Ripple Drive.app from main.swift + Info.plist (+ AppIcon.icns) and signs it ad hoc.
#   ./build.sh                 -> ~/Applications/Ripple Drive.app
#   ./build.sh /path/To.app    -> somewhere else
# Needs the Xcode Command Line Tools (swiftc). The compiler's temp output stays out of Google Drive.
set -e
cd "${0:A:h}"
OUT="${1:-$HOME/Applications/Ripple Drive.app}"
B=$(mktemp -d)
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -o "$B/RippleDrive" main.swift search.swift
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$B/RippleDrive" "$OUT/Contents/MacOS/"
cp Info.plist "$OUT/Contents/"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$OUT/Contents/Resources/"
codesign --force --sign - --identifier com.ripplemedia.RippleDrive "$OUT"
rm -rf "$B"
print "Built $OUT"
