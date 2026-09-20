#!/bin/zsh
# 앱에 넣어 배포할 tmux를 소스에서 빌드한다 — 받은 사람이 Homebrew·관리자 암호 없이 쓰게(2026-09-17 대표 결정).
#
#   scripts/build_tmux.sh        → build/tmux/tmux + build/tmux/licenses/
#
# 왜 직접 빌드하나 — Homebrew의 tmux는 빌드한 맥의 macOS(예: 26) 전용이라 그대로 넣으면 옛 macOS에서 안 뜬다.
# 앱과 같은 macOS 12 기준으로 빌드하고, libevent·utf8proc는 정적으로 넣고, ncurses는 맥 기본 것을 쓴다
# (터미널 정보 /usr/share/terminfo 에 tmux-256color 가 있다). 결과는 맥 기본 라이브러리에만 기대는 파일 하나다.
#
# ⚠️ 새 SDK가 macOS 27 함수(pipe2 등)를 있다고 알려 주는데, 그대로 쓰면 옛 macOS에서 튕긴다.
#    `-Werror=unguarded-availability-new`로 그런 함수가 섞이면 빌드를 멈추고, libevent는 pipe2를 끈다.
set -euo pipefail

ROOT=${0:a:h:h}
OUT="$ROOT/build/tmux"
WORK="$ROOT/build/tmux-src"

TMUX_V=3.5a
LIBEVENT_V=2.1.12-stable
UTF8PROC_V=2.9.0
typeset -A SUM
SUM[tmux]=16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951
SUM[libevent]=92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb
SUM[utf8proc]=18c1626e9fc5a2e192311e36b3010bfc698078f692888940f1fa150547abb0c1

fetch() {  # 이름 주소 — 받고 체크섬이 다르면 멈춘다
  local f="$WORK/$1.tar.gz"
  [[ -f "$f" ]] || curl -sSLf -o "$f" "$2"
  local got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  if [[ "$got" != "${SUM[$1]}" ]]; then
    echo "❌ $1 체크섬이 다르다 ($got)"; rm -f "$f"; exit 1
  fi
}

rm -rf "$WORK/src" "$WORK/out"
mkdir -p "$WORK/src" "$WORK/out" "$OUT/licenses"
fetch tmux     "https://github.com/tmux/tmux/releases/download/$TMUX_V/tmux-$TMUX_V.tar.gz"
fetch libevent "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_V/libevent-$LIBEVENT_V.tar.gz"
fetch utf8proc "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$UTF8PROC_V.tar.gz"
for n in tmux libevent utf8proc; do tar xzf "$WORK/$n.tar.gz" -C "$WORK/src"; done

export MACOSX_DEPLOYMENT_TARGET=12.0
export CFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2 -Werror=unguarded-availability-new"
P="$WORK/out"

echo "▶ libevent"
(cd "$WORK/src/libevent-$LIBEVENT_V" && ac_cv_func_pipe2=no ./configure --prefix="$P" --disable-shared --enable-static \
   --disable-openssl --disable-samples --disable-libevent-regress >/dev/null && make -j8 >/dev/null 2>&1 && make install >/dev/null)

echo "▶ utf8proc"
(cd "$WORK/src/utf8proc-$UTF8PROC_V" && make -j8 libutf8proc.a CFLAGS="$CFLAGS" >/dev/null 2>&1 \
   && mkdir -p "$P/lib" "$P/include" && cp libutf8proc.a "$P/lib/" && cp utf8proc.h "$P/include/")

echo "▶ tmux $TMUX_V"
(cd "$WORK/src/tmux-$TMUX_V" && \
   LIBEVENT_CORE_CFLAGS="-I$P/include" LIBEVENT_CORE_LIBS="$P/lib/libevent_core.a" \
   LIBUTF8PROC_CFLAGS="-I$P/include" LIBUTF8PROC_LIBS="$P/lib/libutf8proc.a" \
   ./configure --enable-utf8proc >/dev/null && make -j8 >/dev/null 2>&1)

cp "$WORK/src/tmux-$TMUX_V/tmux" "$OUT/tmux"
cp "$WORK/src/tmux-$TMUX_V/COPYING" "$OUT/licenses/tmux-COPYING"
cp "$WORK/src/libevent-$LIBEVENT_V/LICENSE" "$OUT/licenses/libevent-LICENSE"
cp "$WORK/src/utf8proc-$UTF8PROC_V/LICENSE.md" "$OUT/licenses/utf8proc-LICENSE.md"

# 맥 기본 라이브러리 말고 다른 것에 기대면 받은 사람 맥에서 안 뜬다 — 여기서 막는다.
if otool -L "$OUT/tmux" | tail -n +2 | grep -v -E '^\s*/usr/lib/'; then
  echo "❌ 맥 기본이 아닌 라이브러리에 기댄다"; exit 1
fi
echo "✅ $OUT/tmux — $("$OUT/tmux" -V) · $(otool -l "$OUT/tmux" | grep -A3 LC_BUILD_VERSION | grep minos | xargs)"
