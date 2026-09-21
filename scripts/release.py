#!/usr/bin/env python3
"""받은 사람이 Flutter·Xcode 없이 켤 앱 zip을 만든다 — GitHub Releases에 올릴 파일.

    python3 scripts/release.py          빌드하고 zip을 만든다
    python3 scripts/release.py --no-build   이미 빌드된 앱으로 zip만

서명·공증 — 키체인에 「Developer ID Application」 인증서가 있으면 그것으로 서명하고(hardened runtime·타임스탬프),
공증 자격이 있으면 애플에 공증을 받아 앱에 붙인다(staple). 자격은 둘 중 하나로 준다 — 파일 안에 적지 않는다.

    --notary-profile <이름>     `xcrun notarytool store-credentials`로 키체인에 넣어 둔 이름
    MADANG_NOTARY_KEY · MADANG_NOTARY_KEY_ID · MADANG_NOTARY_ISSUER   App Store Connect API 키(.p8 경로·Key ID·Issuer ID)

인증서가 없으면 예전처럼 애드혹 서명이고, 받은 사람은 처음 한 번 「그래도 열기」를 눌러야 한다.

결과: build/release/Madang-<판>-macos-arm64.dmg — 열면 Madang과 「응용 프로그램」 바로가기, 끌어서 설치(일반 앱처럼, 9/17)
      build/release/Madang-<판>-macos-arm64.zip — 풀면 `Madang/` 폴더 하나(Madang.app + art/ + commands/회의.md + blocked_paths.example.json)

**폴더째 묶는다.** 앱은 그림(`art/`)과 설정을 `.app` 바로 옆에서 찾는다(`install.py`가 만드는 설치본과 같은 모양).
앱만 묶으면 캐릭터가 회색 네모로 뜬다.

⚠️ **공개본(`make_public.py`가 만든 저장소)에서 부른다.** 대표 저장소는 바탕화면 위젯이 켜져 있어
(`kWidgetMode = true`) 여기서 만들면 공개판과 다른 앱이 나간다 — 그래서 멈춘다.

2026-09-17 Developer ID 인증서 발급 — 1.82.0 앱으로 서명 → 공증(Accepted, 문제 0) → staple →
`spctl` 「Notarized Developer ID」까지 확인했다. hardened runtime에서 앱·내장 tmux가 정상으로 뜬다.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(HERE, "build/macos/Build/Products/Release/Madang.app")
OUT = os.path.join(HERE, "build/release")


def version():
    with open(os.path.join(HERE, "pubspec.yaml"), encoding="utf-8") as f:
        m = re.search(r"^version:\s*([0-9.]+)", f.read(), re.M)
    return m.group(1) if m else "0"


def developer_id():
    """키체인의 Developer ID Application 서명 이름. 없으면 None."""
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    m = re.search(r'"(Developer ID Application: [^"]+)"', out)
    return m.group(1) if m else None


def sign_app(app, ident):
    """안쪽부터 서명한다 — 바깥을 먼저 서명하면 안쪽을 고칠 때 바깥 서명이 깨진다."""
    base = ["codesign", "--force", "--timestamp", "--options", "runtime", "--sign", ident]
    tmux = os.path.join(app, "Contents/MacOS/tmux")
    if os.path.exists(tmux):
        subprocess.run(base + [tmux], check=True)
    fw = os.path.join(app, "Contents/Frameworks")
    for name in sorted(os.listdir(fw)) if os.path.isdir(fw) else []:
        if name.endswith((".framework", ".dylib")):
            subprocess.run(base + [os.path.join(fw, name)], check=True)
    helpers = os.path.join(app, "Contents/Helpers")
    for name in sorted(os.listdir(helpers)) if os.path.isdir(helpers) else []:
        if name.endswith(".app"):
            subprocess.run(base + [os.path.join(helpers, name)], check=True)
    ent = os.path.join(HERE, "macos/Runner/Release.entitlements")
    subprocess.run(base + ["--entitlements", ent, app], check=True)


DMG_WINDOW = (600, 400)
DMG_ICON_LEFT = (160, 190)   # Madang.app — scripts/make_dmg_background.py의 화살표와 맞춘다
DMG_ICON_RIGHT = (440, 190)  # 응용 프로그램


def make_dmg(app, dmg_path, ident, cred):
    """끌어서 설치하는 DMG. 배경·아이콘 자리는 Finder에 AppleScript로 잡는다(못 잡으면 기본 모양으로 그대로 만든다)."""
    work = os.path.join(OUT, "dmg")
    if os.path.exists(work):
        shutil.rmtree(work)
    src = os.path.join(work, "src")
    os.makedirs(os.path.join(src, ".background"))
    subprocess.run(["ditto", app, os.path.join(src, "Madang.app")], check=True)
    os.symlink("/Applications", os.path.join(src, "Applications"))
    bg = os.path.join(HERE, "macos/dmg/background.tiff")
    if os.path.exists(bg):
        shutil.copy2(bg, os.path.join(src, ".background", "background.tiff"))
    rw = os.path.join(work, "rw.dmg")
    subprocess.run(["hdiutil", "create", "-volname", "Madang", "-srcfolder", src, "-fs", "HFS+",
                    "-format", "UDRW", "-size", "120m", "-ov", rw], check=True, stdout=subprocess.DEVNULL)
    out = subprocess.run(["hdiutil", "attach", rw, "-readwrite", "-noverify", "-noautoopen", "-nobrowse"],
                         capture_output=True, text=True, check=True).stdout
    mount = [l.split("\t")[-1].strip() for l in out.splitlines() if "/Volumes/" in l][-1]
    vol = os.path.basename(mount)
    try:
        w, h = DMG_WINDOW
        script = f"""
tell application "Finder"
  tell disk "{vol}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {{200, 120, {200 + w}, {120 + h}}}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Madang.app" of container window to {{{DMG_ICON_LEFT[0]}, {DMG_ICON_LEFT[1]}}}
    set position of item "Applications" of container window to {{{DMG_ICON_RIGHT[0]}, {DMG_ICON_RIGHT[1]}}}
    update without registering applications
    delay 1
    close
  end tell
end tell"""
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            print("⚠️ DMG 창 모양을 못 잡았다(Finder 자동화 권한?) — 기본 모양으로 만든다: " + r.stderr.strip()[:200])
        subprocess.run(["sync"])
    finally:
        subprocess.run(["hdiutil", "detach", mount, "-quiet"])
    if os.path.exists(dmg_path):
        os.remove(dmg_path)
    subprocess.run(["hdiutil", "convert", rw, "-format", "UDZO", "-imagekey", "zlib-level=9", "-o", dmg_path],
                   check=True, stdout=subprocess.DEVNULL)
    shutil.rmtree(work)
    if not ident:
        return False
    subprocess.run(["codesign", "--force", "--timestamp", "--sign", ident, dmg_path], check=True)
    if not cred:
        return False
    print("▶ DMG도 공증에 보낸다")
    r = subprocess.run(["xcrun", "notarytool", "submit", dmg_path, "--wait", "--timeout", "30m"] + cred,
                       capture_output=True, text=True)
    print(r.stdout[-600:])
    if "status: Accepted" not in r.stdout:
        print("❌ DMG 공증이 통과하지 않았다\n" + r.stderr[-800:])
        return False
    subprocess.run(["xcrun", "stapler", "staple", dmg_path], check=True)
    return subprocess.run(["spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg_path]).returncode == 0


def notary_cred(profile):
    if profile:
        return ["--keychain-profile", profile]
    key, kid, iss = (os.environ.get("MADANG_NOTARY_" + k) for k in ("KEY", "KEY_ID", "ISSUER"))
    if key and kid and iss:
        return ["--key", key, "--key-id", kid, "--issuer", iss]
    return None


def notarize(app, cred, workdir):
    """공증을 받아 앱에 붙인다. 성공하면 True."""
    z = os.path.join(workdir, "notarize.zip")
    if os.path.exists(z):
        os.remove(z)
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", app, z], check=True)
    print("▶ 애플 공증에 보낸다 — 보통 몇 분 걸린다")
    r = subprocess.run(["xcrun", "notarytool", "submit", z, "--wait", "--timeout", "30m"] + cred, capture_output=True, text=True)
    os.remove(z)
    print(r.stdout[-1500:])
    if "status: Accepted" not in r.stdout:
        m = re.search(r"id: ([0-9a-f-]{36})", r.stdout)
        print("❌ 공증이 통과하지 않았다" + (" — 사유: xcrun notarytool log %s …" % m.group(1) if m else ""))
        print(r.stderr[-1500:])
        return False
    if subprocess.run(["xcrun", "stapler", "staple", app]).returncode != 0:
        print("❌ 공증 결과를 앱에 붙이지 못했다(staple)")
        return False
    return subprocess.run(["spctl", "-a", "-t", "exec", "-vv", app]).returncode == 0


def main():
    ap = argparse.ArgumentParser(description="배포용 앱 zip을 만든다")
    ap.add_argument("--no-build", action="store_true", help="빌드를 건너뛴다")
    ap.add_argument("--notary-profile", help="notarytool store-credentials로 넣어 둔 키체인 이름")
    ap.add_argument("--no-notarize", action="store_true", help="Developer ID로 서명만 하고 공증은 건너뛴다")
    ap.add_argument("--no-dmg", action="store_true", help="DMG는 만들지 않고 zip만")
    args = ap.parse_args()

    with open(os.path.join(HERE, "lib/main.dart"), encoding="utf-8") as f:
        if "const bool kWidgetMode = false;" not in f.read():
            print("❌ 바탕화면 위젯이 켜진 저장소다 — 공개본(make_public.py가 만든 곳)에서 부른다")
            return 1

    if not args.no_build:
        flutter = shutil.which("flutter")
        if not flutter:
            print("❌ flutter가 없다")
            return 1
        if subprocess.run([flutter, "build", "macos", "--release"], cwd=HERE).returncode != 0:
            return 1
    if not os.path.isdir(APP):
        print("❌ 빌드된 앱이 없다: %s" % APP)
        return 1
    # 대시보드 창 앱(Helpers/MadangDashboard.app) — flutter build는 이걸 안 만든다. 빠지면 대시보드 창이 안 뜬다(9/17).
    if subprocess.run([os.path.join(HERE, "scripts/build_dash.sh"), APP]).returncode != 0:
        print("❌ 대시보드 창 앱을 못 만들었다(scripts/build_dash.sh)")
        return 1
    # 안에 앱을 넣으면 바깥 서명의 봉인이 깨진다 — 여기서는 애드혹으로 다시 봉인하고, 최종 서명은 아래에서 Developer ID로 덮는다.
    subprocess.run(["codesign", "--force", "--sign", "-", APP], check=True, stderr=subprocess.DEVNULL)

    # 서명이 깨져 있으면 받은 사람 맥에서 「손상됐다」로 뜨고 「그래도 열기」도 안 나온다 — 먼저 본다.
    if subprocess.run(["codesign", "--verify", "--deep", "--strict", APP]).returncode != 0:
        print("❌ 앱 서명이 맞지 않는다")
        return 1

    os.makedirs(OUT, exist_ok=True)
    tmux = os.path.join(HERE, "build/tmux/tmux")
    if not os.path.exists(tmux):
        print("▶ 앱에 넣을 tmux가 없어 빌드한다(scripts/build_tmux.sh)")
        if subprocess.run([os.path.join(HERE, "scripts/build_tmux.sh")]).returncode != 0:
            return 1
    stage = os.path.join(OUT, "Madang")
    if os.path.exists(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    # cp -R 대신 ditto — 프레임워크 심볼릭 링크를 지켜야 서명이 안 깨진다.
    subprocess.run(["ditto", APP, os.path.join(stage, "Madang.app")], check=True)
    # tmux를 앱 안에 넣는다 — 받은 사람이 Homebrew 없이 쓰게(2026-09-17). 넣으면 앱 서명이 바뀌므로 애드혹으로 다시 서명한다.
    app_in = os.path.join(stage, "Madang.app")
    shutil.copy2(tmux, os.path.join(app_in, "Contents/MacOS/tmux"))
    lic = os.path.join(app_in, "Contents/Resources/ThirdParty")
    shutil.copytree(os.path.join(HERE, "build/tmux/licenses"), lic, dirs_exist_ok=True)
    # 그림을 앱 안에도 넣는다 — 응용 프로그램 폴더로 앱만 옮겨도 캐릭터가 뜨게(DMG, 9/17). 서명 전에 넣어야 서명이 덮는다.
    shutil.copytree(os.path.join(HERE, "art"), os.path.join(app_in, "Contents/Resources/art"), dirs_exist_ok=True)
    # /회의 명령도 앱 안에 — DMG로 받은 사람은 저장소가 없다. 처음 설정 「회의 명령 넣기」가 ~/.claude/commands/로 깐다.
    meeting_src = os.path.join(HERE, ".claude/commands/회의.md")
    if os.path.exists(meeting_src):
        os.makedirs(os.path.join(app_in, "Contents/Resources/commands"), exist_ok=True)
        shutil.copy2(meeting_src, os.path.join(app_in, "Contents/Resources/commands/meeting.md"))  # 영문 이름 — 한글 이름은 DMG에서 서명이 깨진다
    ident = developer_id()
    notarized = False
    if ident:
        print("▶ %s 로 서명한다" % ident)
        sign_app(app_in, ident)
    else:
        print("⚠️ Developer ID 인증서가 없어 애드혹으로 서명한다 — 받은 사람은 「그래도 열기」를 눌러야 한다")
        subprocess.run(["codesign", "--force", "--sign", "-", os.path.join(app_in, "Contents/MacOS/tmux")], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", app_in], check=True)
    if subprocess.run(["codesign", "--verify", "--deep", "--strict", app_in]).returncode != 0:
        print("❌ tmux를 넣은 뒤 서명 검사가 안 된다")
        return 1
    cred = None
    if ident and not args.no_notarize:
        cred = notary_cred(args.notary_profile)
        if not cred:
            print("⚠️ 공증 자격이 없다(--notary-profile 또는 MADANG_NOTARY_*) — 서명만 하고 공증은 건너뛴다")
        elif not notarize(app_in, cred, OUT):
            return 1
        else:
            notarized = True
    shutil.copytree(os.path.join(HERE, "art"), os.path.join(stage, "art"))
    # 회의 명령 — zip으로 받은 사람은 저장소가 없어 /회의 파일을 못 얻는다. README가 ~/.claude/commands/로 복사하라고 안내한다.
    meeting = os.path.join(HERE, ".claude/commands/회의.md")
    if os.path.exists(meeting):
        os.makedirs(os.path.join(stage, "commands"))
        shutil.copy2(meeting, os.path.join(stage, "commands", "회의.md"))
    example = os.path.join(HERE, "blocked_paths.example.json")
    if os.path.exists(example):
        shutil.copy2(example, os.path.join(stage, "blocked_paths.example.json"))
    zip_path = os.path.join(OUT, "Madang-%s-macos-arm64.zip" % version())
    if os.path.exists(zip_path):
        os.remove(zip_path)
    # ditto는 심볼릭 링크·확장 속성을 지킨다. zip 명령으로 묶으면 프레임워크 링크가 풀려 서명이 깨진다.
    # 확장 속성·리소스 포크는 담지 않는다 — 담으면 `__MACOSX/`·`._파일` 찌꺼기가 생긴다. 서명은 번들 안(_CodeSignature)에 있어 상관없다.
    if subprocess.run(["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", stage, zip_path]).returncode != 0:
        return 1
    size = os.path.getsize(zip_path) / 1024 / 1024
    print("✅ %s (%.1fMB)" % (zip_path, size))
    if not args.no_dmg:
        dmg_path = os.path.join(OUT, "Madang-%s-macos-arm64.dmg" % version())
        dmg_ok = make_dmg(app_in, dmg_path, ident, cred if notarized else None)
        print("✅ %s (%.1fMB)%s" % (dmg_path, os.path.getsize(dmg_path) / 1024 / 1024,
                                    " — 서명·공증" if dmg_ok else " — 공증 전"))
    if notarized:
        print("   애플 공증을 받았다 — 받은 사람 맥에서 경고 없이 열린다")
    else:
        print("   공증 전이다 — 받은 사람은 처음 한 번 「그래도 열기」를 눌러야 한다(README)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
