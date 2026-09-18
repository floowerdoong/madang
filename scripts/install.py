#!/usr/bin/env python3
"""빌드한 위젯을 저장소 밖의 설치본으로 옮겨 놓는다.

**왜 있나** — 지금까지는 저장소의 `build/` 안에서 바로 띄워 썼다. 그래서 새로
빌드해 배포할 때마다 쓰던 위젯을 껐다 켜야 했고, 그 사이 훅이 날아갔다.
오픈소스 준비 작업을 하는 동안에만 여섯 번 그랬다(2026-09-09).

앱 개발과 같은 모양으로 가른다 — **소스는 고치는 곳, 설치본은 쓰는 곳.**
소스를 아무리 뒤집어도(히스토리 재작성 포함) 설치본은 흔들리지 않는다.
새 버전은 이 스크립트를 다시 부를 때만 올라간다.

    python3 scripts/install.py            무엇을 할지만 보여준다
    python3 scripts/install.py --write    실제로 설치한다
    python3 scripts/install.py --run      설치하고 띄운다 (--write 포함)
    python3 scripts/install.py --update   새로 빌드한 앱으로 설치본을 갈아 끼운다(데이터는 안 건드린다)
    python3 scripts/install.py --swap     저장소 위젯을 내리고, 데이터를 새로 옮겨, 설치본을 띄워 건수를 대조한다

**`--swap`은 처음 떼어낼 때 한 번 쓴다(2026-09-15).** 저장소 위젯이 쓰던 데이터가 원본이다.
설치 자리에 옛 설치본(9/9에 시험 삼아 만든 것)이 있으면 지우지 않고 `ClaudeWatcher.bak-<시각>`으로
비켜 두고 새로 만든다. 데이터를 복사한 뒤 원본과 바이트가 같은지, 띄운 뒤 API가 파일과 같은
건수를 돌려주는지 대조한다. 어긋나면 설치본을 내리고 저장소 위젯을 다시 띄운다.

설치본은 자기완결이다. 앱·그림·설정이 한 폴더에 있어 저장소를 지워도 돈다.

    ~/Applications/Madang/
    ├── Madang.app
    ├── art/
    └── (설정 파일들 — watched_projects.json · chat_log.json …)

⚠️ **훅과 상태줄은 따라오지 않는다.** `~/.claude/settings.json`이 저장소 안의
스크립트를 절대경로로 부르고 있다. 저장소를 지우거나 옮기면 그쪽이 깨진다.
이 스크립트는 거기를 건드리지 않는다 — 고칠 일이면 사람이 정한다.
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(HERE, "build/macos/Build/Products/Release/Madang.app")
DEST = os.path.expanduser("~/Applications/Madang")
# 이름을 「마당」으로 바꾸기 전에 쓰던 자리(2026-09-16 이사). 남아 있으면 통째로 옮겨 온다 —
# 여기에 할 일·대화 기록·프로젝트·근무기록이 들어 있어 새로 만들면 오늘까지의 기록이 통째로 사라진다.
OLD_DEST = os.path.expanduser("~/Applications/ClaudeWatcher")
OLD_APP_NAME = "claude_watcher.app"

# 설치본이 들고 가야 하는 개인 파일들. 없으면 그냥 넘어간다.
#
# ⚠️ **옮기지 않고 복사한다.** 원본을 그대로 둬야 잘못됐을 때 예전처럼
# 저장소에서 띄워 되돌릴 수 있다.
CONFIG = [
    "watched_projects.json",
    "chat_log.json",
    "tasks.json",
    "window_state.json",
    "blocked_paths.json",
    "todo_key.json",
    "todo_open.json",
    "usage_cache.json",
    # ⚠️ 9/14 노션을 떠나며 생긴 원본들 — 9/9에 만든 목록에 없어 그대로 설치하면 빈 채로 떴다.
    "projects.json",
    "sessions.json",
    "worklog.json",
]

# 날짜 스냅샷·직전본(`tasks.json.2026-09-15.bak` 따위). 되돌릴 곳이라 같이 간다.
SNAP_OF = ("tasks.json.", "projects.json.", "sessions.json.", "worklog.json.")

# 폴더째 옮기는 것 — 대화에 붙인 그림.
DIRS = ["pasted"]

PORT = 9876


def running():
    """지금 도는 위젯들의 pid. 설치본과 저장소 것을 나눠 준다."""
    out = {"설치본": [], "저장소": []}
    try:
        raw = subprocess.run(
            ["ps", "-eo", "pid=,command="], capture_output=True, text=True
        ).stdout
    except Exception:
        return out
    # 이름을 바꾸는 날에는 **옛 이름으로 도는 것도** 찾아야 한다 — 못 찾으면 안 내린 채로 갈아 끼우게 된다.
    # 대시보드 창 앱(Helpers/MadangDashboard.app)도 같이 내린다 — 빠뜨리면 갈아 끼울 때마다 옛 창이 쌓인다(9/17).
    marks = ("Madang.app/Contents/MacOS/Madang",
             "MadangDashboard.app/Contents/MacOS/MadangDashboard",
             "claude_watcher.app/Contents/MacOS/claude_watcher")
    for line in raw.splitlines():
        line = line.strip()
        if not any(m in line for m in marks):
            continue
        pid, _, cmd = line.partition(" ")
        if not pid.isdigit():
            continue
        here = DEST in cmd or OLD_DEST in cmd
        out["설치본" if here else "저장소"].append(int(pid))
    return out


STATUSLINE = "statusline_limits.py"


def plan():
    steps = []
    if not os.path.isdir(APP):
        return None, ["❌ 빌드된 앱이 없다: %s\n   먼저 flutter build macos --release" % APP]

    steps.append(("앱", "%s → %s/Madang.app" % (
        os.path.basename(APP), DEST)))
    art = os.path.join(HERE, "art")
    if os.path.isdir(art):
        steps.append(("그림", "art/ → %s/art" % DEST))
    if os.path.exists(os.path.join(HERE, "scripts", STATUSLINE)):
        steps.append(("상태줄", "scripts/%s → %s/scripts" % (STATUSLINE, DEST)))

    for name in CONFIG:
        src = os.path.join(HERE, name)
        if not os.path.exists(src):
            continue
        if os.path.exists(os.path.join(DEST, name)):
            steps.append(("설정", "%s — 이미 있다, 그대로 둔다" % name))
        else:
            steps.append(("설정", "%s → 복사 (원본은 그대로)" % name))
    return steps, []


def copy_tree(src, dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)


def install():
    os.makedirs(DEST, exist_ok=True)
    copy_tree(APP, os.path.join(DEST, "Madang.app"))

    art = os.path.join(HERE, "art")
    if os.path.isdir(art):
        copy_tree(art, os.path.join(DEST, "art"))

    # 상태줄 스크립트 — ⚠️ **설치본에 둔다.** 전역 설정(`~/.claude/settings.json`)의 statusLine이
    # 저장소 안을 가리키면 저장소를 옮기거나 이름만 바꿔도 한도 표시가 통째로 사라진다(2026-09-18).
    src = os.path.join(HERE, "scripts", STATUSLINE)
    if os.path.exists(src):
        os.makedirs(os.path.join(DEST, "scripts"), exist_ok=True)
        shutil.copy2(src, os.path.join(DEST, "scripts", STATUSLINE))

    for name in CONFIG:
        src = os.path.join(HERE, name)
        dst = os.path.join(DEST, name)
        # ⚠️ **이미 있으면 덮어쓰지 않는다.** 설치본에서 쓰던 대화와 등록이
        # 저장소의 옛 사본으로 되돌아가면 통째로 잃는다.
        if os.path.exists(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)


def sha(path):
    import hashlib
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def counts(root):
    """파일로 센 건수 — 띄운 뒤 API가 같은 수를 돌려주는지 대조한다."""
    import json
    out = {}
    for name, key in (("tasks.json", "tasks"), ("projects.json", "projects"),
                      ("sessions.json", "sessions"), ("worklog.json", "days")):
        try:
            with open(os.path.join(root, name), encoding="utf-8") as f:
                out[name] = len(json.load(f).get(key, []))
        except Exception:
            out[name] = None
    return out


def api_tasks():
    import json
    import urllib.parse
    import urllib.request
    root = os.path.dirname(os.path.dirname(HERE))  # 02_무위다라니 — 루트에서 부르면 전부 본다
    q = urllib.parse.urlencode({"cwd": root})
    with urllib.request.urlopen("http://127.0.0.1:%d/todo/api/tasks?%s" % (PORT, q), timeout=3) as r:
        return len(json.load(r)["tasks"])


def port_pids():
    raw = subprocess.run(["lsof", "-tiTCP:%d" % PORT, "-sTCP:LISTEN"],
                         capture_output=True, text=True).stdout
    return [int(x) for x in raw.split() if x.isdigit()]


def wait_port(up, seconds=25):
    import time
    for _ in range(seconds * 2):
        if bool(port_pids()) == up:
            return True
        time.sleep(0.5)
    return False


def swap():
    import signal
    import time
    if not os.path.isdir(APP):
        print("❌ 빌드된 앱이 없다 — 먼저 flutter build macos --release")
        return 1
    alive = running()
    if alive["설치본"]:
        print("❌ 설치본이 이미 돈다 (pid %s). swap은 처음 떼어낼 때만 쓴다." % alive["설치본"])
        return 1
    # 1) 저장소 위젯을 내린다 — 도는 중에 복사하면 그 사이 바뀐 것이 빠진다.
    for pid in alive["저장소"]:
        os.kill(pid, signal.SIGTERM)
    if alive["저장소"] and not wait_port(False):
        print("❌ 저장소 위젯이 안 내려간다. 손으로 내린 뒤 다시 부른다.")
        return 1
    time.sleep(1)
    # 2) 옛 설치본은 비켜 둔다(지우지 않는다).
    if os.path.exists(DEST):
        bak = "%s.bak-%s" % (DEST, time.strftime("%Y%m%d-%H%M%S"))
        os.rename(DEST, bak)
        print("옛 설치본을 비켜 뒀다: %s" % bak)
    os.makedirs(DEST)
    copy_tree(APP, os.path.join(DEST, "Madang.app"))
    if os.path.isdir(os.path.join(HERE, "art")):
        copy_tree(os.path.join(HERE, "art"), os.path.join(DEST, "art"))
    names = [n for n in CONFIG if os.path.exists(os.path.join(HERE, n))]
    names += [n for n in sorted(os.listdir(HERE)) if n.startswith(SNAP_OF) and n.endswith(".bak")]
    for n in names:
        shutil.copy2(os.path.join(HERE, n), os.path.join(DEST, n))
    for d in DIRS:
        if os.path.isdir(os.path.join(HERE, d)):
            copy_tree(os.path.join(HERE, d), os.path.join(DEST, d))
    # 3) 바이트 대조
    bad = [n for n in names if sha(os.path.join(HERE, n)) != sha(os.path.join(DEST, n))]
    want = counts(HERE)
    print("복사 %d개 · 건수 %s" % (len(names), want))
    if bad or counts(DEST) != want:
        print("❌ 복사본이 원본과 다르다: %s — 저장소 위젯을 다시 띄운다" % bad)
        subprocess.run(["open", APP])
        return 1
    # 4) 파인더처럼 띄운다(작업 디렉토리가 / 인 채로 설정을 찾는지까지 본다).
    subprocess.run(["open", os.path.join(DEST, "Madang.app")])
    if not wait_port(True):
        print("❌ 설치본이 포트를 안 연다 — 저장소 위젯을 다시 띄운다")
        subprocess.run(["open", APP])
        return 1
    time.sleep(3)
    got = api_tasks()
    if got != want["tasks.json"]:
        print("❌ 설치본 API 할 일 %s건 ≠ 파일 %s건 — 설치본을 내리고 저장소 위젯을 다시 띄운다" % (got, want["tasks.json"]))
        for pid in port_pids():
            os.kill(pid, signal.SIGTERM)
        wait_port(False)
        subprocess.run(["open", APP])
        return 1
    print("✅ 설치본이 떴다 — API 할 일 %d건 = 파일 %d건. 저장소의 원본 데이터는 그대로 남아 있다." % (got, want["tasks.json"]))
    return 0


def migrate_name():
    """「클로드워쳐」 자리에 있던 설치본을 「마당」 자리로 옮긴다 (2026-09-16 이름 교체).

    폴더째 옮긴다 — 설정·대화 기록·tasks.json이 그 안에 있어서, 새로 만들면 오늘까지의 기록이
    통째로 사라진다. 옛 앱 껍데기는 지운다(새 앱을 바로 위에 복사하므로 둘이 남으면 헷갈린다).
    설정 폴더(Application Support)도 같이 옮긴다 — 자물쇠 표식이 여기 있다.
    """
    moved = []
    if not os.path.exists(DEST) and os.path.isdir(OLD_DEST):
        shutil.move(OLD_DEST, DEST)
        old_app = os.path.join(DEST, OLD_APP_NAME)
        if os.path.isdir(old_app):
            shutil.rmtree(old_app)
        moved.append("%s → %s" % (OLD_DEST, DEST))
    sup_new = os.path.expanduser("~/Library/Application Support/madang")
    sup_old = os.path.expanduser("~/Library/Application Support/claude-watcher")
    if not os.path.exists(sup_new) and os.path.isdir(sup_old):
        shutil.move(sup_old, sup_new)
        moved.append("%s → %s" % (sup_old, sup_new))
    for line in moved:
        print("📦 옮겼다: %s" % line)
    return moved


def update():
    """새 빌드로 갈아 끼운다 — 설치본을 내리고 앱(과 그림)만 바꿔 다시 띄운다. 데이터 파일은 손대지 않는다."""
    import signal
    import time
    if not os.path.isdir(APP):
        print("❌ 빌드된 앱이 없다 — 먼저 flutter build macos --release")
        return 1
    migrate_name()
    if not os.path.isdir(os.path.join(DEST, "Madang.app")):
        print("❌ 설치본이 없다 — 처음이면 --swap")
        return 1
    alive = running()
    if alive["저장소"]:
        print("⚠️ 저장소 쪽 위젯이 돈다 (pid %s) — 옆 인스턴스면 그대로 둔다." % alive["저장소"])
    before = counts(DEST)
    for pid in alive["설치본"]:
        os.kill(pid, signal.SIGTERM)
    if alive["설치본"] and not wait_port(False):
        print("❌ 설치본이 안 내려간다")
        return 1
    time.sleep(1)
    copy_tree(APP, os.path.join(DEST, "Madang.app"))
    # 그림은 저장소 것이 원본이다(새 캐릭터·프레임을 저장소에서 만든다).
    if os.path.isdir(os.path.join(HERE, "art")):
        copy_tree(os.path.join(HERE, "art"), os.path.join(DEST, "art"))
    subprocess.run(["open", os.path.join(DEST, "Madang.app")])
    if not wait_port(True):
        print("❌ 새 설치본이 포트를 안 연다")
        return 1
    time.sleep(3)
    got = api_tasks()
    ok = got == before["tasks.json"]
    print("%s 갈아 끼웠다 — API 할 일 %s건 / 파일 %s건" % ("✅" if ok else "❌", got, before["tasks.json"]))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="위젯을 설치본으로 옮긴다")
    ap.add_argument("--write", action="store_true", help="실제로 설치한다")
    ap.add_argument("--run", action="store_true", help="설치하고 띄운다")
    ap.add_argument("--update", action="store_true", help="새 빌드로 설치본을 갈아 끼운다")
    ap.add_argument("--swap", action="store_true", help="저장소 위젯 → 설치본으로 처음 떼어낸다")
    args = ap.parse_args()
    if args.swap:
        return swap()
    if args.update:
        return update()

    steps, errors = plan()
    for e in errors:
        print(e)
    if errors:
        return 1

    print("설치 자리: %s" % DEST)
    for kind, what in steps:
        print("  %-4s %s" % (kind, what))

    alive = running()
    if alive["저장소"]:
        print("\n⚠️ 저장소에서 돌던 위젯이 있다 (pid %s)." %
              ", ".join(str(p) for p in alive["저장소"]))
        print("   설치본을 띄우기 전에 내려야 포트가 겹치지 않는다.")
    if alive["설치본"]:
        print("\n설치본이 이미 돌고 있다 (pid %s). 갈아끼우려면 먼저 내린다." %
              ", ".join(str(p) for p in alive["설치본"]))

    if not (args.write or args.run):
        print("\n[미리보기] 실제로 설치하려면 --write 를 붙인다.")
        return 0

    install()
    print("\n설치했다.")

    if args.run:
        if alive["설치본"]:
            print("이미 돌고 있어 띄우지 않았다. 내린 뒤 다시 부른다.")
            return 0
        exe = os.path.join(
            DEST, "Madang.app/Contents/MacOS/Madang")
        subprocess.Popen([exe], cwd=DEST,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("띄웠다: %s" % exe)
    else:
        print("띄우려면: open %s/Madang.app" % DEST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
