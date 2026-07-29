#!/bin/sh
# PowerToggle 설치.
#   1) 앱 빌드 → ~/Applications/PowerToggle.app
#   2) CLI 3종 설치 → ~/.local/bin (lid, caf, caffeinate shim)
#   3) 기본 설정 파일 + sudoers 템플릿 생성
#   4) 로그인 항목 등록 (--no-login-item 으로 생략)
#
# 이 스크립트는 root 권한을 쓰지 않는다. sudoers 규칙은 설치하지 않고 템플릿만
# 만들어두며, 실제 적용은 메뉴의 "비밀번호 없이 토글하기 설정..." 에서 한다.

set -e

SRC=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
CONF="$HOME/.config/caffeinate-toggle"
APP="$HOME/Applications/PowerToggle.app"
LABEL="com.hyoju.powertoggle"
LOGIN_ITEM=1

for arg in "$@"; do
	case "$arg" in
		--no-login-item) LOGIN_ITEM=0 ;;
		-h | --help)
			sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
	esac
done

[ "$(uname -s)" = "Darwin" ] || {
	echo "macOS 전용입니다." >&2
	exit 1
}
command -v swiftc > /dev/null || {
	echo "swiftc가 필요합니다. Xcode 또는 Command Line Tools를 설치하세요:" >&2
	echo "  xcode-select --install" >&2
	exit 1
}

echo "[1/4] 앱 빌드"
sh "$SRC/build.sh" "$APP"

echo "[2/4] CLI 설치: $BIN"
mkdir -p "$BIN"
for f in lid caf caffeinate; do
	cp "$SRC/bin/$f" "$BIN/$f"
	chmod +x "$BIN/$f"
done

echo "[3/4] 설정 파일"
mkdir -p "$CONF"
[ -f "$CONF/mode" ] || printf 'auto\n' > "$CONF/mode"
sed "s/__USER__/$(id -un)/g" "$SRC/sudoers/pmset-lid-toggle.in" > "$CONF/pmset-lid-toggle.sudoers"
visudo -c -f "$CONF/pmset-lid-toggle.sudoers" > /dev/null && echo "  sudoers 템플릿 문법 확인됨"

echo "[4/4] 실행"
if [ "$LOGIN_ITEM" = "1" ]; then
	PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
	mkdir -p "$(dirname "$PLIST")"
	cat > "$PLIST" << PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$APP/Contents/MacOS/PowerToggle</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><false/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL
	launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
	launchctl bootstrap "gui/$(id -u)" "$PLIST"
	echo "  로그인 항목 등록됨"
else
	open "$APP"
fi

case ":$PATH:" in
	*":$BIN:"*) ;;
	*)
		echo
		echo "주의: $BIN 이 PATH에 없습니다. caffeinate shim이 동작하지 않습니다."
		echo "셸 설정에 추가하세요:  export PATH=\"\$HOME/.local/bin:\$PATH\""
		;;
esac

echo
echo "설치 완료. 메뉴바에 번개 아이콘이 나타납니다."
echo "안 보이면 README의 '아이콘이 안 보일 때'를 확인하세요."
