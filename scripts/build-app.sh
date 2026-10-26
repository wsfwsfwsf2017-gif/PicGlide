#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build -c release --arch arm64 --product PicGlide
task_bin="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$task_root/build"
task_staging="$(mktemp -d "$task_root/build/.PicGlide.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
task_app="$task_staging/PicGlide.app"
task_output="$task_root/build/PicGlide.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
install -m 755 "$task_bin/PicGlide" "$task_app/Contents/MacOS/PicGlide"
install -m 644 Resources/Info.plist "$task_app/Contents/Info.plist"
install -m 644 LICENSE "$task_app/Contents/Resources/PicGlide-LICENSE.txt"
install -m 644 docs/agent.md "$task_app/Contents/Resources/Agent使用说明.md"
task_iconset="$task_root/.build/PicGlide.iconset"
swift scripts/make-icon.swift "$task_iconset"
iconutil -c icns "$task_iconset" -o "$task_app/Contents/Resources/PicGlide.icns"
install -m 644 .build/checkouts/libwebp-Xcode/LICENSE "$task_app/Contents/Resources/libwebp-LICENSE.txt"
if [ -f .build/checkouts/libwebp-Xcode/libwebp/COPYING ]; then
    install -m 644 .build/checkouts/libwebp-Xcode/libwebp/COPYING "$task_app/Contents/Resources/libwebp-COPYING.txt"
fi
plutil -lint "$task_app/Contents/Info.plist"
codesign --force --sign - "$task_app"
codesign --verify --strict "$task_app"
if [ -e "$task_output" ]; then
    mv "$task_output" "$task_staging/previous.app"
fi
if ! mv "$task_app" "$task_output"; then
    if [ -e "$task_staging/previous.app" ]; then
        mv "$task_staging/previous.app" "$task_output"
    fi
    exit 1
fi
printf '%s\n' "Built: $task_output"
du -sh "$task_output"
