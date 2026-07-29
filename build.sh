#!/bin/sh
# PowerToggle.app 빌드 → ~/Applications/PowerToggle.app
set -e

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
APP="${1:-$HOME/Applications/PowerToggle.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>PowerToggle</string>
	<key>CFBundleDisplayName</key><string>PowerToggle</string>
	<key>CFBundleIdentifier</key><string>com.hyoju.powertoggle</string>
	<key>CFBundleExecutable</key><string>PowerToggle</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<!-- 아래 DT* 키가 없으면 AppKit이 이 번들을 구형 SDK 빌드로 보고
	     레거시 메뉴바 규격(24pt)을 적용해 상태 항목이 안 보인다. -->
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTPlatformVersion</key><string>__SDK_VERSION__</string>
	<key>DTSDKName</key><string>macosx__SDK_VERSION__</string>
	<key>DTSDKBuild</key><string>__SDK_BUILD__</string>
	<key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
	<key>BuildMachineOSBuild</key><string>__OS_BUILD__</string>
</dict>
</plist>
PLIST

# 실제 SDK 값으로 치환
/usr/bin/sed -i '' \
	-e "s/__SDK_VERSION__/$(xcrun --show-sdk-version)/g" \
	-e "s/__SDK_BUILD__/$(xcrun --show-sdk-build-version)/g" \
	-e "s/__OS_BUILD__/$(sw_vers -buildVersion)/g" \
	"$APP/Contents/Info.plist"

echo "컴파일 중..."
swiftc -O -target "$(uname -m)-apple-macos12.0" \
	-framework Cocoa \
	"$SRC_DIR/PowerToggle.swift" \
	-o "$APP/Contents/MacOS/PowerToggle"

# 로컬 실행용 ad-hoc 서명
codesign --force --sign - "$APP" 2>/dev/null || echo "(서명 건너뜀)"

echo "빌드 완료: $APP"
