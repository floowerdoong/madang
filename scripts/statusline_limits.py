#!/usr/bin/env python3
"""상태줄에 남은 한도를 찍고, 같은 값을 위젯으로 넘긴다.

클로드 코드는 상태줄 명령에 매 턴 stdin으로 JSON을 물려준다. 그 안의
`rate_limits`에 5시간 창·7일 창의 사용률(0-100)과 초기화 시각(유닉스 초)이
들어 있다. **이 값은 여기 말고는 얻을 길이 없다** — 로컬 어디에도 안 남고,
transcript에도 없다.

그래서 이 스크립트가 두 가지를 한다.

1. 터미널 상태줄에 한 줄 찍는다 (`5h 62% · 7d 41%`)
2. 같은 값을 위젯 훅 서버로 넘겨 책상줄에 막대로 뜨게 한다

⚠️ **어떤 일이 있어도 터미널을 깨지 않는다.** 매 턴 도는 자리라, 여기서
예외가 새거나 오래 걸리면 사용자가 치는 모든 턴이 그만큼 느려지거나
상태줄이 에러로 덮인다. 전부 try/except로 감싸고 늘 0으로 끝낸다.

⚠️ **값은 첫 API 응답 뒤에만 온다.** 세션을 막 열었을 때는 `rate_limits`가
아예 없다. 그때는 아무것도 찍지 않고 넘기지도 않는다 — 0%로 보이면 안 된다.
"""
import json
import os
import sys

PORT = os.environ.get("CLAUDE_WATCHER_PORT", "9876")
URL = "http://127.0.0.1:%s/" % PORT

# 위젯이 꺼져 있는 것이 정상 상태다. 붙는 데 오래 끌지 않는다.
TIMEOUT = 0.4


def window(raw):
    """창 하나를 {사용률, 초기화} 로. 모양이 어긋나면 None."""
    if not isinstance(raw, dict):
        return None
    pct = raw.get("used_percentage")
    at = raw.get("resets_at")
    if not isinstance(pct, (int, float)) or not isinstance(at, (int, float)):
        return None
    return {"사용률": float(pct), "초기화": int(at)}


def push(limits):
    """위젯에 넘긴다. 위젯이 없으면 조용히 지나간다."""
    try:
        import urllib.request

        body = json.dumps(
            {"hook_event_name": "RateLimits", "rate_limits": limits}
        ).encode("utf-8")
        req = urllib.request.Request(
            URL, data=body, headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=TIMEOUT).close()
    except Exception:
        pass


def line(limits):
    """상태줄에 찍을 한 줄. 남은 시간까지 넣으면 길어져서 %만 쓴다."""
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        w = limits.get(key)
        if w:
            parts.append("%s %.0f%%" % (label, w["사용률"]))
    return " · ".join(parts)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if not isinstance(payload, dict):
        return

    raw = payload.get("rate_limits")
    if not isinstance(raw, dict):
        # 구독이 아니거나 아직 첫 응답 전이다. 지어내지 않는다.
        return

    limits = {}
    for key in ("five_hour", "seven_day", "spend_limit"):
        w = window(raw.get(key))
        if w:
            limits[key] = w
    if not limits:
        return

    push(limits)
    text = line(limits)
    if text:
        sys.stdout.write(text)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 상태줄은 무슨 일이 있어도 조용히 실패한다.
        pass
    sys.exit(0)
