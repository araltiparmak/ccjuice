#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="CCJuice.app"

# Some Command Line Tools versions ship the 'SwiftBridging' module in two identical
# modulemap files, which breaks swiftc ("redefinition of module 'SwiftBridging'").
# When both files are present, mask one copy with an empty file via a compiler VFS
# overlay — no sudo, nothing on disk is modified.
SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
EXTRA_FLAGS=()
if [[ -f "$SWIFT_INC/bridging.modulemap" && -f "$SWIFT_INC/module.modulemap" ]]; then
    OVERLAY_DIR="$(mktemp -d)"
    trap 'rm -rf "$OVERLAY_DIR"' EXIT
    touch "$OVERLAY_DIR/empty.modulemap"
    cat > "$OVERLAY_DIR/overlay.yaml" <<EOF
{
  "version": 0,
  "roots": [
    {
      "name": "$SWIFT_INC",
      "type": "directory",
      "contents": [
        { "name": "bridging.modulemap", "type": "file", "external-contents": "$OVERLAY_DIR/empty.modulemap" }
      ]
    }
  ]
}
EOF
    EXTRA_FLAGS=(-vfsoverlay "$OVERLAY_DIR/overlay.yaml")
fi

swiftc -swift-version 5 -O "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" CCJuice.swift -o CCJuice

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
mv CCJuice "$APP/Contents/MacOS/"

# Ad-hoc signature by default, plus the hardened runtime. The app holds an OAuth
# bearer token in memory, and the hardened runtime is what stops another process
# running as the same user from attaching a debugger to it or injecting a library
# through DYLD_INSERT_LIBRARIES to read that token back out. The app needs no
# entitlement exceptions — it links only system frameworks.
#
# An ad-hoc signature changes with every build, and macOS ties the Keychain
# "Always Allow" grant to it, so the consent dialog returns after a rebuild. If
# you already have a code-signing identity (an Apple Development certificate from
# Xcode, for example), sign with it instead and the grant survives rebuilds:
#
#   CODESIGN_IDENTITY="Apple Development" ./build.sh
#
# The script itself never creates or installs certificates — putting a signing
# certificate into your trust store is a much larger ask than clicking Allow.
codesign --force --options runtime -s "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

echo "Built: $PWD/$APP"
echo "Launch with: open $APP"
