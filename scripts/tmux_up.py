#!/usr/bin/env python3
"""등록된 프로젝트마다 tmux 세션을 만들고 그 안에서 클로드를 띄운다.

재부팅하면 세션이 전부 날아가 프로젝트마다 터미널 탭을 다시 열고 `claude`를
다시 치게 되는데, 그 반복을 없애는 것이 목적이다.

    python3 tmux_up.py              등록된 프로젝트 전부 기동 (이미 있으면 건너뜀)
    python3 tmux_up.py --dry-run    무엇을 할지만 보여준다
    python3 tmux_up.py --no-claude  세션만 만들고 claude는 띄우지 않는다
    python3 tmux_up.py --yolo       이번만 승인을 생략한다 (기본은 승인창을 받는다)
    python3 tmux_up.py yolo         승인 생략이 켜져 있나 본다
    python3 tmux_up.py yolo on|off  계속 켜 두거나 끈다 (위젯 자물쇠 버튼과 같다)
    python3 tmux_up.py list         세션 상태 보기
    python3 tmux_up.py attach 이름   해당 프로젝트 세션에 붙는다
    python3 tmux_up.py detach 이름   붙어 있는 창을 떼어낸다 (세션은 유지)
    python3 tmux_up.py kill 이름     해당 세션을 내린다 (명시적으로 요청할 때만)

붙은 화면에서 빠져나오려면 Ctrl+b 를 누르고 뗀 뒤 d 를 누른다.
한글 입력 상태면 d 대신 ㅇ 을 눌러도 되게 걸어 두었다. 창을 그냥 닫아도 세션은 산다.

읽는 파일은 watched_projects.json이다. 위젯의 `+` 버튼이 쓰는 그 파일이고,
여기가 프로젝트 목록의 단일 출처다.
"""

import argparse
import json
import os
import subprocess
import sys
import unicodedata
from pathlib import Path

# tmux는 절대경로로 부른다. GUI에서 띄운 프로세스는 PATH가 얕을 수 있다.
TMUX_CANDIDATES = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

ROOT = Path(__file__).resolve().parent.parent
PROJECTS_FILE = ROOT / "watched_projects.json"

# tmux 세션 이름에 쓸 수 없는 문자. 마침표와 콜론은 창·패널 지정 문법이라 금지된다.
FORBIDDEN = ".: \t\n/"

# 세션을 만들 때 잡아둘 화면 크기.
# 클로드 코드는 alternate screen을 쓰기 때문에 capture-pane이 스크롤백을 못 준다.
# 곧 '보이는 화면'이 전부라서, 기본 80×24로 두면 읽어갈 내용이 그만큼 잘린다.
PANE_WIDTH = 120
PANE_HEIGHT = 60

# 세션 안에서 칠 기본 명령.
#
# ⚠️ main.dart의 Tmux.launchCommand와 **같아야 한다.** 위젯에서 띄운 세션과
# cw로 띄운 세션이 다르게 굴면 어느 쪽에서 띄웠는지를 기억해야 한다.
# 그 규칙은 flutter test가 이 파일을 직접 읽어 확인한다.
#
# ⚠️ 승인창을 받는 쪽이 기본이다. 예전에는 반대였다 —
# --dangerously-skip-permissions가 기본이고 안전한 쪽이 옵트인이었다.
# "지켜보는 폴더가 전부 본인 것"이라는 전제로 그렇게 뒀는데, 남이 받아 쓰는
# 도구가 되면 그 전제가 깨진다. 그래서 뒤집었다(2026-09-09).
LAUNCH_COMMAND = "claude"

# 승인을 생략하고 띄울 때. --yolo 옵션이나 CLAUDE_WATCHER_YOLO=1로 켠다.
#
# 폴더 신뢰 확인창은 이 플래그로도 안 사라진다. 2026-08-05에 실제로 띄워
# 확인했다 — `1. Yes, I trust this folder`가 그대로 나온다.
SKIP_COMMAND = "claude --dangerously-skip-permissions"


# 승인 생략을 켜 두는 파일. **설치 자리와 상관없이 한 곳이다.**
#
# ⚠️ main.dart 의 Tmux.yoloPath 와 같은 경로여야 한다. 위젯에서 띄운 세션과
# cw 로 띄운 세션이 다르게 굴면 어느 쪽에서 띄웠는지를 기억해야 하는데,
# 그건 못 지킬 약속이다.
#
# 예전에는 각자 자기 뿌리를 봤다. 설치본을 저장소에서 떼어내자 바로 갈렸다 —
# 책상은 🔓인데 cw yolo 는 꺼짐이라고 했다(2026-09-09).
YOLO_FILE = os.path.join(
    os.path.expanduser("~"), "Library", "Application Support",
    "madang", "yolo")


def yolo_on(args):
    """승인을 생략할까. --yolo · CLAUDE_WATCHER_YOLO=1 · yolo 파일 셋 중 하나."""
    if getattr(args, "yolo", False):
        return True
    if os.environ.get("CLAUDE_WATCHER_YOLO") == "1":
        return True
    return os.path.exists(YOLO_FILE)


def launch_command(args):
    """세션 안에서 칠 명령."""
    return SKIP_COMMAND if yolo_on(args) else LAUNCH_COMMAND


def cmd_yolo(args):
    """승인 생략을 켜고 끈다. 위젯 책상의 자물쇠 버튼과 같은 파일을 다룬다."""
    env_on = os.environ.get("CLAUDE_WATCHER_YOLO") == "1"

    if args.state is None:
        state = "켜짐" if (env_on or os.path.exists(YOLO_FILE)) else "꺼짐"
        print("승인 생략: %s" % state)
        if env_on:
            print("  환경변수 CLAUDE_WATCHER_YOLO=1 로 켜져 있다 — 파일로는 못 끈다")
        print("  표식 파일: %s (%s)" %
              (YOLO_FILE, "있음" if os.path.exists(YOLO_FILE) else "없음"))
        print("  바꾸려면: cw yolo on   /   cw yolo off")
        return

    want = args.state == "on"
    if want:
        os.makedirs(os.path.dirname(YOLO_FILE), exist_ok=True)
        with open(YOLO_FILE, "w", encoding="utf-8") as f:
            f.write("이 파일이 있으면 세션을 승인 생략으로 띄운다.\n"
                    "지우면 승인창을 받는다. 위젯 책상의 자물쇠 버튼이 이 파일을 다룬다.\n")
        print("승인 생략을 켰다. 다음에 띄우는 세션부터 적용된다.")
    else:
        if os.path.exists(YOLO_FILE):
            os.remove(YOLO_FILE)
        print("승인창을 받도록 되돌렸다. 다음에 띄우는 세션부터 적용된다.")
        if env_on:
            print("  ⚠️ 그런데 환경변수 CLAUDE_WATCHER_YOLO=1 이 켜져 있어 "
                  "이 셸에서는 여전히 생략된다")

    # ⚠️ 이미 떠 있는 세션은 안 바뀐다. 플래그는 클로드가 시작할 때 정해진다.
    res = tmux("list-sessions", "-F", "#{session_name}")
    names = [n for n in res.stdout.splitlines() if n.strip()]
    if names:
        print("  떠 있는 세션 %d개는 그대로다: %s%s" %
              (len(names), ", ".join(sorted(names)[:4]),
               " …" if len(names) > 4 else ""))


def find_tmux():
    for path in TMUX_CANDIDATES:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    found = subprocess.run(["which", "tmux"], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    print("❌ tmux를 찾지 못했습니다. `brew install tmux` 후 다시 실행하세요.")
    sys.exit(1)


TMUX = None  # main에서 채운다


def tmux(*args, check=False):
    return subprocess.run([TMUX, *args], capture_output=True, text=True, check=check)


def session_name(path):
    """경로에서 세션 이름을 만든다. 위젯·스크립트가 같은 규칙을 써야 한다.

    폴더 이름을 그대로 쓰되 tmux가 싫어하는 문자만 밑줄로 바꾼다.
    한글은 그대로 둔다 — tmux는 문제없이 받는다.
    """
    base = unicodedata.normalize("NFC", path.rstrip("/")).split("/")[-1]
    name = "".join("_" if c in FORBIDDEN else c for c in base)
    return name[:60] or "project"


def load_projects():
    if not PROJECTS_FILE.exists():
        print(f"❌ 등록된 프로젝트가 없습니다: {PROJECTS_FILE}")
        print("   위젯의 + 버튼으로 폴더를 먼저 등록하세요.")
        sys.exit(1)
    data = json.loads(PROJECTS_FILE.read_text(encoding="utf-8"))
    raw = data.get("projects", data) if isinstance(data, dict) else data

    projects, used = [], {}
    for item in raw:
        path = unicodedata.normalize("NFC", item["path"]).rstrip("/")
        name = session_name(path)
        # 폴더 이름이 겹치면 뒤에 번호를 붙여 갈라준다.
        if name in used:
            used[name] += 1
            name = f"{name}-{used[name]}"
        else:
            used[name] = 1
        projects.append({
            "path": path,
            "label": item.get("name") or Path(path).name,
            "session": name,
            "exists": Path(path).is_dir(),
        })
    return projects


def has_session(name):
    return tmux("has-session", "-t", f"={name}").returncode == 0


# 한글 입력 상태에서는 d가 ㅇ으로 들어가 detach가 먹지 않는다.
# 자주 쓰는 키만 한글 자판 자리에도 같이 걸어둔다.
HANGUL_KEYS = [
    ("ㅇ", "detach-client"),   # d
    ("ㅊ", "new-window"),      # c
    ("ㅌ", "kill-pane"),       # x
    ("ㅈ", "list-sessions"),   # s
]


def bind_hangul_keys():
    for key, command in HANGUL_KEYS:
        tmux("bind-key", "-T", "prefix", key, command)


def cmd_up(args):
    projects = load_projects()
    started, skipped, missing = [], [], []
    if not args.dry_run:
        bind_hangul_keys()

    for p in projects:
        if not p["exists"]:
            missing.append(p)
            continue
        if has_session(p["session"]):
            skipped.append(p)
            continue

        if args.dry_run:
            started.append(p)
            continue

        # 셸을 먼저 띄우고 그 안에서 claude를 친다.
        # 세션의 주인이 셸이라 클로드를 종료해도 세션은 남는다.
        #
        # 크기를 지정하는 이유: capture-pane은 '보이는 화면'만 돌려준다.
        # 기본 80×24로 만들면 위젯이 읽어갈 내용이 그만큼 잘린다.
        r = tmux("new-session", "-d", "-s", p["session"], "-c", p["path"],
                 "-x", str(PANE_WIDTH), "-y", str(PANE_HEIGHT))
        if r.returncode != 0:
            print(f"❌ {p['label']}: 세션 생성 실패 — {r.stderr.strip()}")
            continue
        if not args.no_claude:
            tmux("send-keys", "-t", p["session"], launch_command(args), "Enter")
        started.append(p)

    head = "[미리보기] " if args.dry_run else ""
    if started:
        verb = "띄울 예정" if args.dry_run else "기동"
        cmd = "(claude 없이 세션만)" if args.no_claude else f"$ {launch_command(args)}"
        print(f"{head}▶️  {verb} {len(started)}개  {cmd}")
        for p in started:
            print(f"    {p['session']:24} {p['path']}")
    if skipped:
        print(f"⏭️  이미 떠 있어 건너뜀 {len(skipped)}개: "
              + ", ".join(p["session"] for p in skipped))
    if missing:
        print(f"⚠️  폴더가 없어 건너뜀 {len(missing)}개: "
              + ", ".join(p["label"] for p in missing))
    if not args.dry_run and started:
        print(f"\n붙으려면: python3 {Path(__file__).name} attach {started[0]['label']}")


def cmd_list(args):
    projects = load_projects()
    out = tmux("list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{session_windows}")
    live = {}
    if out.returncode == 0:
        for line in out.stdout.strip().splitlines():
            name, attached, windows = line.split("\t")
            live[name] = (attached != "0", windows)

    print(f"{'프로젝트':<22} {'세션':<24} 상태")
    print("-" * 62)
    for p in projects:
        if p["session"] in live:
            attached, windows = live[p["session"]]
            state = f"● 떠 있음 ({'붙어 있음' if attached else '떨어져 있음'}, 창 {windows})"
        else:
            state = "○ 없음"
        print(f"{p['label']:<22} {p['session']:<24} {state}")

    # 등록되지 않았는데 떠 있는 세션도 알려준다.
    known = {p["session"] for p in projects}
    others = [n for n in live if n not in known]
    if others:
        print(f"\n등록 밖 세션: {', '.join(others)}")


def _resolve(target):
    """프로젝트 표시이름이나 세션 이름 아무거나 받아 세션 이름으로 바꾼다."""
    for p in load_projects():
        if target in (p["label"], p["session"]):
            return p["session"]
    return session_name(target)


def cmd_attach(args):
    name = _resolve(args.target)
    if not has_session(name):
        print(f"❌ 세션이 없습니다: {name}")
        print("   먼저 `python3 tmux_up.py` 로 기동하세요.")
        sys.exit(1)
    # attach는 터미널을 넘겨받아야 하므로 프로세스를 교체한다.
    os.execv(TMUX, [TMUX, "attach-session", "-t", name])


def cmd_detach(args):
    """다른 창에서 세션을 떼어낸다. 키가 안 먹을 때 쓸 수 있는 우회로다."""
    name = _resolve(args.target)
    if not has_session(name):
        print(f"세션이 없습니다: {name}")
        return
    r = tmux("detach-client", "-s", name)
    if r.returncode == 0:
        print(f"↩️  떼어냈습니다: {name} (세션은 계속 살아 있습니다)")
    else:
        print(f"붙어 있는 창이 없습니다: {name}")


def cmd_kill(args):
    name = _resolve(args.target)
    if not has_session(name):
        print(f"세션이 이미 없습니다: {name}")
        return
    tmux("kill-session", "-t", name)
    print(f"🛑 내렸습니다: {name}")


def main():
    global TMUX
    TMUX = find_tmux()

    parser = argparse.ArgumentParser(add_help=True, description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd")

    up = sub.add_parser("up", help="등록된 프로젝트 전부 기동 (기본)")
    up.add_argument("--dry-run", action="store_true", help="무엇을 할지만 보여준다")
    up.add_argument("--no-claude", action="store_true", help="세션만 만들고 claude는 띄우지 않는다")
    up.add_argument("--yolo", action="store_true",
                    help="승인을 생략하고 띄운다 (기본은 승인창을 받는다)")

    yl = sub.add_parser("yolo", help="승인 생략을 켜고 끈다 (인자 없으면 지금 상태)")
    yl.add_argument("state", nargs="?", choices=["on", "off"])

    sub.add_parser("list", help="세션 상태 보기")
    at = sub.add_parser("attach", help="세션에 붙는다")
    at.add_argument("target")
    dt = sub.add_parser("detach", help="붙어 있는 창을 떼어낸다 (세션은 유지)")
    dt.add_argument("target")
    kl = sub.add_parser("kill", help="세션을 내린다")
    kl.add_argument("target")

    # 인자 없이 부르면 up으로 본다. --dry-run 같은 옵션만 준 경우도 마찬가지다.
    argv = sys.argv[1:]
    if not argv or argv[0].startswith("-"):
        argv = ["up", *argv]
    args = parser.parse_args(argv)

    {"up": cmd_up, "list": cmd_list, "attach": cmd_attach,
     "detach": cmd_detach, "kill": cmd_kill, "yolo": cmd_yolo}[args.cmd](args)


if __name__ == "__main__":
    main()
