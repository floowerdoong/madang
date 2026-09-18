#!/bin/zsh
# 대시보드 창 앱(MadangDashboard.app)을 만들어 빌드된 Madang.app 안에 넣는다.
#
#   scripts/build_dash.sh            build/macos/Build/Products/Release/Madang.app 안에
#   scripts/build_dash.sh <Madang.app 경로>
#
# 왜 따로 있나 — 같은 프로세스에 Flutter 엔진이 있으면 WKWebView에서 한글이 자모로 갈라진다(2026-09-17).
# `flutter build macos --release` 뒤에 부른다. install.py는 Madang.app을 통째로 복사하므로 그 안의 이 앱도 따라간다.
set -e
ROOT=${0:a:h:h}
APP=${1:-$ROOT/build/macos/Build/Products/Release/Madang.app}
SRC=$ROOT/macos/Dashboard/main.swift
OUT=$APP/Contents/Helpers/MadangDashboard.app
[[ -d $APP ]] || { echo "Madang.app이 없다: $APP"; exit 1 }

mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -target arm64-apple-macos12.0 -o "$OUT/Contents/MacOS/MadangDashboard" "$SRC"
cp "$APP/Contents/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Madang</string>
<key>CFBundleDisplayName</key><string>Madang</string>
<key>CFBundleIdentifier</key><string>com.muwidarani.madang.dashboard</string>
<key>CFBundleExecutable</key><string>MadangDashboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHumanReadableCopyright</key><string>MUWIDARANI</string>
</dict></plist>
EOF
# 본 앱과 같은 서명으로 — 애드혹이면 애드혹, 인증서면 그 인증서(권한이 재빌드마다 안 풀리게).
IDENT=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)
if [[ -n $IDENT && $IDENT != *"(unavailable)"* ]]; then
  codesign --force --sign "$IDENT" "$OUT" >/dev/null 2>&1 || codesign --force --sign - "$OUT"
else
  codesign --force --sign - "$OUT"
fi
echo "✓ $OUT"
