#!/usr/bin/env python3
"""클로드워쳐가 상태를 받으려면 필요한 훅을 ~/.claude/settings.json에 넣는다.

위젯은 클로드 코드가 보내는 훅으로만 상태를 판단한다. 훅이 없으면 받아서
띄워도 캐릭터가 아무것도 안 한다 — 그래서 이 스크립트가 있다.

    python3 scripts/setup_hooks.py            무엇을 할지만 보여준다
    python3 scripts/setup_hooks.py --write    실제로 넣는다
    python3 scripts/setup_hooks.py --remove   이 스크립트가 넣은 것만 뺀다

⚠️ **남의 훅을 절대 덮어쓰지 않는다.** 이벤트마다 배열이 있고 거기에 항목을
덧붙이는 구조라, 이미 쓰고 있는 훅이 있으면 그 옆에 나란히 선다. 지울 때도
우리 것만 골라 뺀다 (`is_ours` 참조 — 우리 포트로 POST하는 것이 기준이다).

⚠️ 쓰기 전에 반드시 백업을 남긴다. settings.json이 깨지면 그 사람의 모든
프로젝트가 영향을 받는다.
"""
import argparse
import json
import os
import shutil
import sys
from datetime import datetime

SETTINGS = os.path.expanduser("~/.claude/settings.json")

# 이 표식이 든 명령만 우리 것으로 본다. 지울 때 남의 훅을 건드리지 않으려는 것이다.
MARK = "claude-watcher"

# 위젯이 상태를 가르는 데 쓰는 이벤트들.
#
# PostToolUse가 없으면 도구가 끝난 것을 알 수 없어 '작업 중'으로 굳는다.
# SessionEnd가 없으면 끝난 세션이 계속 살아 있는 것처럼 보인다.
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Notification",
    "Stop",
    "StopFailure",
    "SessionEnd",
]

# 도구 이름으로 거르는 이벤트. 나머지는 matcher가 없다.
MATCHED = {"PreToolUse", "PostToolUse"}


# 위젯의 답을 세션에 넘기는 이벤트. 대표가 할 일 페이지에서 바꾼 것을 한 줄로 알린다.
#
# ⚠️ **여기에 다른 이벤트를 넣지 않는다.** 훅의 답은 세션 맥락에 그대로 들어가고,
# PreToolUse 같은 이벤트는 답이 도구 실행을 막거나 바꿀 수 있다.
PASS_OUTPUT = {"UserPromptSubmit"}


def command(port, event=None):
    """페이로드를 그대로 위젯에 넘기는 한 줄.

    -m 2 로 끊고 || true 로 끝낸다. **위젯이 꺼져 있는 것이 정상 상태다** —
    거기서 훅이 실패하면 사용자의 모든 턴이 느려지거나 에러가 뜬다.
    PASS_OUTPUT 이벤트만 위젯의 답(stdout)을 살리고, 나머지는 버린다.
    """
    sink = "2>/dev/null" if event in PASS_OUTPUT else "> /dev/null 2>&1"
    return (
        "cat | curl -s -m 2 -X POST http://127.0.0.1:%d/ "
        "-H 'Content-Type: application/json' --data-binary @- "
        "%s || true  # %s" % (port, sink, MARK)
    )


def passes_output(cmd):
    return "> /dev/null" not in cmd


def is_ours(hook, port):
    """우리 훅인가.

    ⚠️ **표식만 보면 안 된다.** 이 스크립트가 생기기 전에 손으로 넣어 둔 훅에는
    표식이 없다. 그걸 남의 것으로 보면 같은 일을 하는 훅을 하나 더 넣어
    이벤트마다 curl이 두 번 돈다. 실제로 그럴 뻔했다(2026-09-09).

    구분하는 진짜 특징은 **우리 포트로 POST한다**는 것이다.
    """
    if not isinstance(hook, dict):
        return False
    cmd = str(hook.get("command", ""))
    return MARK in cmd or "127.0.0.1:%d" % port in cmd


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        return {}
    return json.loads(text)


def plan(settings, port, remove):
    """무엇이 바뀌는지 계산한다. (새 설정, 사람이 읽을 변경 목록)"""
    out = json.loads(json.dumps(settings))  # 깊은 복사
    hooks = out.setdefault("hooks", {})
    changes = []

    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            changes.append("건너뜀 %s — 모양이 배열이 아니다" % event)
            continue

        mine = [g for g in groups
                if isinstance(g, dict)
                and any(is_ours(h, port) for h in g.get("hooks", []) or [])]

        if remove:
            if mine:
                for g in mine:
                    groups.remove(g)
                changes.append("뺌   %s" % event)
            continue

        line = command(port, event)
        if mine:
            # 답을 넘기는지만 맞춘다. 손으로 넣은 옛 훅도 다른 부분은 그대로 둔다.
            want = event in PASS_OUTPUT
            stale = [h for g in mine for h in g.get("hooks", [])
                     if is_ours(h, port) and passes_output(str(h.get("command", ""))) != want]
            if stale:
                for h in stale:
                    h["command"] = line
                changes.append("바꿈 %s — 위젯의 답을 %s" % (event, "세션에 넘긴다" if want else "버린다"))
            else:
                changes.append("그대로 %s — 이미 있다" % event)
            continue

        group = {"hooks": [{"type": "command", "command": line}]}
        if event in MATCHED:
            group["matcher"] = "*"
        groups.append(group)
        others = len(groups) - 1
        changes.append("넣음 %s%s" % (
            event, "  (남의 훅 %d개 옆에)" % others if others else ""))

    # 빈 배열은 남기지 않는다.
    for event in list(hooks):
        if hooks[event] == []:
            del hooks[event]
    if not hooks:
        del out["hooks"]
    return out, changes


def main():
    ap = argparse.ArgumentParser(
        description="클로드워쳐 훅을 ~/.claude/settings.json에 넣는다")
    ap.add_argument("--write", action="store_true", help="실제로 저장한다")
    ap.add_argument("--remove", action="store_true", help="넣었던 훅을 뺀다")
    ap.add_argument("--port", type=int, default=9876, help="위젯이 듣는 포트")
    args = ap.parse_args()

    try:
        settings = load()
    except json.JSONDecodeError as e:
        print("❌ %s 를 읽지 못했다: %s" % (SETTINGS, e))
        print("   JSON이 깨져 있다. 먼저 고친 뒤 다시 부른다 — "
              "여기서 덮어쓰면 남은 설정까지 잃는다.")
        return 1

    updated, changes = plan(settings, args.port, args.remove)

    print("대상: %s" % SETTINGS)
    for c in changes:
        print("  %s" % c)

    if updated == settings:
        print("\n바뀔 것이 없다.")
        return 0

    if not args.write:
        print("\n[미리보기] 실제로 넣으려면 --write 를 붙인다.")
        return 0

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    if os.path.exists(SETTINGS):
        backup = "%s.bak-%s" % (SETTINGS, datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(SETTINGS, backup)
        print("\n백업: %s" % backup)

    # 임시 파일에 먼저 쓰고 옮긴다. 쓰다 말고 죽어도 원본이 남는다.
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(updated, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print("저장했다. 이미 열려 있는 세션은 다시 띄워야 훅이 붙는다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
