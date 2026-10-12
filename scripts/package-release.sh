#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
task_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
task_tag="${1:-v$task_version}"
task_semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$task_version" =~ $task_semver ]] || [ "$task_tag" != "v$task_version" ]; then
    printf '%s\n' "版本标签必须为 v${task_version}，收到：${task_tag}" >&2
    exit 1
fi
if [[ ! "$task_build" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "构建号必须为正整数" >&2
    exit 1
fi
./scripts/build-app.sh
task_staging="$(mktemp -d "$task_root/build/.release.XXXXXX")"
task_mounted=0
cleanup() {
    if [ "$task_mounted" = 1 ]; then hdiutil detach "$task_staging/mount" >/dev/null || true; fi
    rm -rf "$task_staging"
}
trap cleanup EXIT
check_app() {
    local task_checked="$1"
    plutil -lint "$task_checked/Contents/Info.plist"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_checked/Contents/Info.plist")" = "$task_version"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$task_checked/Contents/Info.plist")" = "$task_build"
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$task_checked/Contents/Info.plist")" = '14.0'
    test "$(lipo -archs "$task_checked/Contents/MacOS/PicGlide")" = 'arm64'
    test -s "$task_checked/Contents/Resources/PicGlide.icns"
    cmp LICENSE "$task_checked/Contents/Resources/PicGlide-LICENSE.txt"
    cmp .build/checkouts/libwebp-Xcode/LICENSE "$task_checked/Contents/Resources/libwebp-LICENSE.txt"
    codesign --verify --strict "$task_checked"
}
task_app="$task_root/build/PicGlide.app"
check_app "$task_app"
task_name="PicGlide-$task_version-arm64"
mkdir "$task_staging/packages" "$task_staging/dmg" "$task_staging/unzip" "$task_staging/mount"
ditto "$task_app" "$task_staging/dmg/PicGlide.app"
ln -s /Applications "$task_staging/dmg/Applications"
hdiutil create -volname "PicGlide $task_version" -srcfolder "$task_staging/dmg" -format UDZO "$task_staging/packages/$task_name.dmg"
hdiutil verify "$task_staging/packages/$task_name.dmg"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$task_staging/mount" "$task_staging/packages/$task_name.dmg" >/dev/null
task_mounted=1
check_app "$task_staging/mount/PicGlide.app"
test "$(readlink "$task_staging/mount/Applications")" = '/Applications'
hdiutil detach "$task_staging/mount" >/dev/null
task_mounted=0
ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_staging/packages/$task_name.zip"
ditto -x -k "$task_staging/packages/$task_name.zip" "$task_staging/unzip"
check_app "$task_staging/unzip/PicGlide.app"
cd "$task_staging/packages"
shasum -a 256 "$task_name.dmg" "$task_name.zip" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
awk -v header="## [$task_version]" '
    index($0, header) == 1 { found=1; next }
    found && /^## / { exit }
    found { print; if ($0 ~ /[^[:space:]]/) lines++ }
    END { if (!found || !lines) exit 1 }
' "$task_root/CHANGELOG.md" > release-notes.md
cat >> release-notes.md <<'NOTES'
适用于 macOS 14 及更新版本、Apple Silicon。下载 DMG 后将 PicGlide 拖入 Applications，或解压 ZIP 后安装。

本版本未使用 Developer ID 签名和 Apple 公证。首次打开可能需要在系统设置的“隐私与安全性”中确认；请先核对下载来源。
NOTES
cd "$task_root"
mkdir -p build/releases
task_output="$task_root/build/releases/$task_version"
if [ -e "$task_output" ]; then mv "$task_output" "$task_staging/previous"; fi
if ! mv "$task_staging/packages" "$task_output"; then
    if [ -e "$task_staging/previous" ]; then mv "$task_staging/previous" "$task_output"; fi
    exit 1
fi
printf '%s\n' "Packaged: $task_output"
