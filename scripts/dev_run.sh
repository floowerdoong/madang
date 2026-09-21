#!/bin/zsh
# 고친 것을 확인하려고 위젯을 하나 더 띄운다.
#
# 왜 있나 — 예전에는 고칠 때마다 동현동현이 쓰는 위젯을 죽이고 다시 띄웠다.
# 하루에 여섯 번 넘게 끊긴 날이 있었다. 확인은 옆에 따로 띄운 판에서 한다.
#
#   scripts/dev_run.sh            빌드하고 확인용 판을 띄운다 (포트 9877)
#   scripts/dev_run.sh --no-build 이미 빌드된 것으로 띄우기만 한다
#   scripts/dev_run.sh --stop     확인용 판만 내린다
#   PORT=9878 scripts/dev_run.sh  포트를 바꾼다
#
# 본 판(포트 9876)은 **건드리지 않는다.** 새 빌드를 동현동현 위젯에 적용하려면
# 그쪽을 직접 껐다 켠다 — 그건 사람이 정할 일이다.
set -e

ROOT=${0:a:h:h}
PORT=${PORT:-9877}
BUNDLE="$ROOT/build/macos/Build/Products/Release/Madang.app"
DEV="$ROOT/build/dev/Madang-dev.app"
BIN="$DEV/Contents/MacOS/Madang"

stop_dev() {
  # 확인용 판만 고른다. 본 판을 같이 죽이면 이 스크립트의 존재 이유가 없다.
  local pids
  pids=$(pgrep -f "Madang-dev.app" || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill 2>/dev/null || true
    sleep 1
    echo "확인용 판 내렸다 (pid: $(echo $pids | tr '\n' ' '))"
  else
    echo "확인용 판은 떠 있지 않다"
  fi
}

if [[ "$1" == "--stop" ]]; then
  stop_dev
  exit 0
fi

if [[ "$1" != "--no-build" ]]; then
  echo "▶ 빌드 중…"
  (cd "$ROOT" && flutter build macos --release 2>&1 | tail -2)
  "$ROOT/scripts/build_dash.sh" "$BUNDLE" | tail -1   # 대시보드 창 앱(별도 프로세스)도 같이 넣는다(1.88.2)
fi

stop_dev

# 번들을 복사해 둔다. 다음 빌드가 원본을 덮어써도 지금 도는 판은 멀쩡하다.
mkdir -p "$(dirname "$DEV")"
rm -rf "$DEV"
cp -R "$BUNDLE" "$DEV"

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "⚠️  포트 $PORT 가 이미 쓰이고 있다. PORT=... 로 바꿔 띄운다"
  exit 1
fi

CLAUDE_WATCHER_PORT=$PORT nohup "$BIN" > "$ROOT/build/dev/dev.log" 2>&1 &
sleep 4

if pgrep -f "Madang-dev.app" >/dev/null; then
  echo "✅ 확인용 판 떴다 — 포트 $PORT · 로그 build/dev/dev.log"
  echo "   책상 왼쪽 위에 빨간 '확인용 $PORT' 표가 붙어 있다"
  echo "   본 판(포트 9876)은 건드리지 않았다"
else
  echo "❌ 못 띄웠다. 로그: $ROOT/build/dev/dev.log"
  tail -5 "$ROOT/build/dev/dev.log" 2>/dev/null || true
  exit 1
fi
