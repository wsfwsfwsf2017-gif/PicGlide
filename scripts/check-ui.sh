#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_output="${1:?请指定验证输出目录}"
task_mode="${2:-smoke}"
case "$task_mode" in smoke|layout) ;; *) printf '%s\n' '检查类型必须为 smoke 或 layout' >&2; exit 2 ;; esac
swift build --arch arm64
task_bin="$(swift build --arch arm64 --show-bin-path)"
task_staging="$(mktemp -d "$task_root/.build/native-check.XXXXXX")"
task_app="$task_staging/PicGlide检查.app"
cleanup() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$task_app" >/dev/null 2>&1 || true
    rm -rf "$task_staging"
}
trap cleanup EXIT
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
install -m 755 "$task_bin/PicGlide" "$task_app/Contents/MacOS/PicGlide"
install -m 644 Resources/Info.plist "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.picglide.nativechecks' "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$task_app/Contents/Info.plist"
swift scripts/make-icon.swift "$task_staging/PicGlide.iconset"
iconutil -c icns "$task_staging/PicGlide.iconset" -o "$task_app/Contents/Resources/PicGlide.icns"
codesign --force --sign - "$task_app"
if [ "$task_mode" = layout ]; then
    PICGLIDE_LAYOUT_OUTPUT="$task_output" PICGLIDE_LAYOUT_ASSERT=1 "$task_app/Contents/MacOS/PicGlide"
else
    PICGLIDE_SMOKE_OUTPUT="$task_output" "$task_app/Contents/MacOS/PicGlide"
fi
