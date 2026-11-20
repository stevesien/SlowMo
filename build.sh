#!/bin/bash
# Builds SlowMo.app. Run:  ./build.sh          (build only)
#                          ./build.sh install  (build, copy to /Applications, launch)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the tools with:  xcode-select --install"
  exit 1
fi

APP="SlowMo.app"
ARCH="$(uname -m)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling for ${ARCH}..."
swiftc -O -target "$ARCH-apple-macos13" -o "$APP/Contents/MacOS/SlowMo" main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x SlowMo 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  # A rebuilt app has a new signature, so clear any stale Accessibility entry.
  tccutil reset Accessibility com.stevesien.SlowMo >/dev/null 2>&1 || true
  open "/Applications/$APP"
  echo "Installed and launched. Look for the tortoise in the menu bar."
fi
