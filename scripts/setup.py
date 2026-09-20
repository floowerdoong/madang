#!/usr/bin/env python3
"""처음 받은 사람이 부르는 명령 하나 — 준비물 확인 → 빌드 → 설치 → 앱 켜기.

    python3 scripts/setup.py           전부 한다
    python3 scripts/setup.py --check   준비물만 본다

훅 연결과 지켜볼 폴더 등록은 **앱이 켜진 뒤 「처음 설정」 창에서 버튼으로** 한다.
여기서 하지 않는 까닭 — 둘 다 사람이 보고 누를 일이고(남의 settings.json을 고친다 · 폴더를 고른다),
앱 창에 두면 스크립트 없이 받은 사람도 같은 길로 온다.

⚠️ **이미 설치본이 있으면 설치 단계를 건너뛴다.** 쓰던 앱을 갈아 끼우는 일은
`install.py --update`의 몫이다 — 여기서 덮으면 도는 앱이 흔들린다.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.expanduser("~/Applications/Madang")
APP = os.path.join(DEST, "Madang.app")

# (이름, 찾는 방법, 없을 때 안내)
NEEDS = [
    ("tmux", ["tmux"], "brew install tmux"),
    ("Flutter", ["flutter"], "https://docs.flutter.dev/get-started/install/macos 안내대로 깐다"),
    ("Xcode", None, "앱스토어에서 Xcode를 깔고 한 번 켠 뒤: sudo xcodebuild -runFirstLaunch"),
    ("Claude Code", ["claude"], "curl -fsSL https://claude.ai/install.sh | bash"),
]


def find(names):
    """PATH와 흔한 자리에서 찾는다. GUI가 아니라 터미널에서 부르므로 PATH가 대개 맞다."""
    home = os.path.expanduser("~")
    extra = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.claude/local"]
    for n in names:
        hit = shutil.which(n) or shutil.which(n, path=os.pathsep.join(extra))
        if hit:
            return hit
    return None


def xcode():
    try:
        r = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return r.stdout.splitlines()[0] if r.returncode == 0 and r.stdout else None


def check():
    ok = True
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("❌ macOS · 애플 실리콘(arm64)에서만 돈다 — 지금: %s %s" % (platform.system(), platform.machine()))
        return False
    for name, names, how in NEEDS:
        where = xcode() if names is None else find(names)
        if where:
            print("  ✓ %-12s %s" % (name, where))
        else:
            ok = False
            print("  ✗ %-12s 없다 → %s" % (name, how))
    return ok


def run(cmd):
    print("\n$ %s" % " ".join(cmd))
    return subprocess.run(cmd, cwd=HERE).returncode == 0


def main():
    ap = argparse.ArgumentParser(description="마당을 처음 설치한다")
    ap.add_argument("--check", action="store_true", help="준비물만 본다")
    args = ap.parse_args()

    print("1) 준비물")
    if not check():
        print("\n빠진 것을 깐 뒤 다시 부른다.")
        return 1
    if args.check:
        return 0

    if os.path.isdir(APP):
        print("\n2) 설치본이 이미 있다: %s" % APP)
        print("   새 빌드로 갈아 끼우려면: flutter build macos --release && scripts/build_dash.sh && python3 scripts/install.py --update")
    else:
        flutter = find(["flutter"])
        print("\n2) 빌드 — 처음에는 몇 분 걸린다")
        if not (run([flutter, "pub", "get"]) and run([flutter, "build", "macos", "--release"])
                and run([os.path.join(HERE, "scripts", "build_dash.sh")])):
            print("\n❌ 빌드가 안 됐다. 위 글자를 그대로 이슈에 붙여 주면 본다.")
            return 1
        print("\n3) 설치 → %s" % DEST)
        if not run([sys.executable, "scripts/install.py", "--write"]):
            return 1

    print("\n4) 앱을 켠다")
    subprocess.run(["open", APP])
    print("   창에 「처음 설정」이 뜬다 — 거기서 **훅 연결하기**와 **폴더 고르기**를 누르면 끝이다.")
    print("   안 뜨면 ⚙ → 처음 설정.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
