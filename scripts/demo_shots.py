#!/usr/bin/env python3
"""시연용 가짜 데이터로 앱을 하나 더 띄우고 대시보드 스크린샷(1920×1080)을 뜬다.

    python3 scripts/demo_shots.py            공개본 앱(../madang)으로 뜬다
    python3 scripts/demo_shots.py --app <Madang.app 경로>
    python3 scripts/demo_shots.py --keep     다 뜬 뒤에도 앱을 켜 둔다(손으로 더 보거나 녹화할 때)

결과: build/shots/01_board.png · 02_list.png · 03_chat.png · 04_first_run.png · 05_meeting.png

**왜 있나** — 원티드 제출 폼(대표 이미지 1장 + 16:9 스크린샷 최대 5장)과 README 그림.
실제 할 일·거래처·대화가 찍히면 안 되므로(제출 유의사항) 모든 데이터를 여기서 새로 만든다.

- 쓰는 앱(9876)은 건드리지 않는다. 포트 9885, 설정은 `/tmp/madang-demo/.config`, 훅은 가짜 settings 파일에만 쓴다
- 세션은 진짜 claude가 아니라 **훅 신호를 흉내 내서** 만든다(상태·말풍선만 보인다, tmux 화면은 없다)
- 폴더 경로가 화면에 찍히므로 `/tmp/madang-demo` 아래에만 만든다 — 사용자 이름이 안 나온다
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 9885
DEMO = os.path.realpath("/tmp") + "/madang-demo"
CFG = DEMO + "/.config"
ROOT = DEMO + "/작업실"
OUT = os.path.join(HERE, "build/shots")
BASE = "http://127.0.0.1:%d" % PORT
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

FOLDERS = {
    "작업실": ROOT,
    "블로그": ROOT + "/블로그",
    "습관앱": ROOT + "/습관앱",
    "홈페이지": ROOT + "/홈페이지",
}
# 등록하지 않은 하위 폴더 — 사원(임시 세션)으로 앉는다
STAFF = ROOT + "/습관앱/디자인"


def call(path, body=None, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        text = r.read().decode() or "{}"
    try:
        return json.loads(text)
    except ValueError:
        return {"raw": text}


def hook(event, sid, cwd, **extra):
    call("/", dict(hook_event_name=event, session_id=sid, cwd=cwd, **extra))


def wait_port(up, seconds=30):
    for _ in range(seconds * 2):
        try:
            urllib.request.urlopen(BASE + "/todo/app/mode", timeout=1)
            if up:
                return True
        except Exception:
            if not up:
                return True
        time.sleep(0.5)
    return False


def prepare():
    if os.path.isdir(DEMO):
        shutil.rmtree(DEMO)
    for p in list(FOLDERS.values()) + [STAFF]:
        os.makedirs(p)
        with open(p + "/CLAUDE.md", "w", encoding="utf-8") as f:
            f.write("# %s\n\n시연용 폴더.\n" % os.path.basename(p))
    os.makedirs(CFG)
    with open(CFG + "/watched_projects.json", "w", encoding="utf-8") as f:
        json.dump({"projects": [{"path": p, "name": n} for n, p in FOLDERS.items()]}, f, ensure_ascii=False)
    # 훅이 연결된 것처럼 — 처음 설정 창이 안 뜨게. 줄 모양은 setup_hooks.py 것을 그대로 쓴다.
    sys.path.insert(0, os.path.join(HERE, "scripts"))
    import setup_hooks
    settings, _ = setup_hooks.plan({}, PORT, False)
    with open(CFG + "/claude_settings.json", "w", encoding="utf-8") as f:
        json.dump(settings, f)


def launch(app):
    exe = os.path.join(app, "Contents/MacOS/Madang")
    env = dict(os.environ,
               CLAUDE_WATCHER_PORT=str(PORT),
               CLAUDE_WATCHER_CONFIG_DIR=CFG,
               CLAUDE_WATCHER_PROJECTS=CFG + "/watched_projects.json",
               CLAUDE_WATCHER_CLAUDE_SETTINGS=CFG + "/claude_settings.json",
               CLAUDE_WATCHER_MODE="dashboard")
    proc = subprocess.Popen([exe], cwd=DEMO, env=env,
                            stdout=open(CFG + "/app.log", "w"), stderr=subprocess.STDOUT)
    if not wait_port(True):
        proc.kill()
        sys.exit("❌ 앱이 포트 %d를 안 연다 — %s/app.log" % (PORT, CFG))
    return proc


def seed():
    # 프로젝트 줄 — 이름·폴더·종류
    for name, path in FOLDERS.items():
        call("/todo/project/add", {"name": name})
    rows = json.load(open(CFG + "/projects.dev%d.json" % PORT, encoding="utf-8"))["projects"]
    for r in rows:
        call("/todo/project/edit", {"id": r["id"], "path": FOLDERS[r["name"]], "kind": "own",
                                     "favorite": r["name"] != "작업실"})

    def add(cwd, text, status, **kw):
        r = call("/todo/api/tasks/add", dict(cwd=cwd, text=text, **kw))
        tid = r["id"]
        if status == "running":
            call("/todo/api/tasks/start", {"cwd": cwd, "id": tid})
        elif status == "done":
            call("/todo/api/tasks/status", {"cwd": cwd, "id": tid, "status": "done", "ownerConfirmed": True})
        elif status == "revision":
            call("/todo/api/tasks/update", {"cwd": cwd, "id": tid, "revisionNote": "제목 글자를 한 단계 키워 주세요"})
            call("/todo/api/tasks/status", {"cwd": cwd, "id": tid, "status": "revision"})
        elif status != "waiting":
            call("/todo/api/tasks/status", {"cwd": cwd, "id": tid, "status": status})
        return tid

    B, H, W = FOLDERS["블로그"], FOLDERS["습관앱"], FOLDERS["홈페이지"]
    add(B, "여행 글 초안 — 사진 12장 배치", "running", priority="two", kind="content")
    add(B, "지난달 글 태그 정리", "sessionPlanned", body="태그를 5개 안쪽으로 줄이고 목록을 보여 줘")
    add(B, "댓글 알림 메일 문구 다듬기", "review")
    add(B, "블로그 첫 화면 소개 문단", "done")
    parent = add(H, "습관 기록 화면 새 디자인", "sessionPlanned", priority="one", due=time.strftime("%Y-%m-%d"))
    add(H, "잠금 화면 위젯 모양 시안", "revision", parentId=parent)
    add(H, "색상 토큰 정리", "done", parentId=parent)
    add(H, "알림 시간 설정이 저장 안 되는 문제", "running", priority="one", kind="bug")
    add(H, "앱스토어 설명 문구 초안", "today")
    add(W, "문의 폼 스팸 막기", "waiting", kind="dev")
    add(W, "회사 소개 페이지 사진 교체", "today")
    add(W, "푸터 링크 점검", "review")

    # 세션 — 훅 흉내. 상태가 골고루 보이게: 작업 중 · 승인 대기 · 완료 · 생각 중 · 사원
    hook("SessionStart", "demo-root", ROOT)
    hook("UserPromptSubmit", "demo-root", ROOT, prompt="오늘 할 일 정리해 줘")
    hook("Stop", "demo-root", ROOT, last_assistant_message="오늘 예정 2건, 확인이 필요한 것 2건입니다. 습관앱 디자인 묶음부터 보시면 됩니다.")

    hook("SessionStart", "demo-blog", B)
    hook("UserPromptSubmit", "demo-blog", B, prompt="여행 글 초안 이어서 써 줘")
    hook("PreToolUse", "demo-blog", B, tool_name="Edit", tool_input={"file_path": B + "/drafts/travel.md"})

    hook("SessionStart", "demo-habit", H)
    hook("UserPromptSubmit", "demo-habit", H, prompt="알림 시간이 저장 안 돼. 원인 찾아 줘")
    hook("PreToolUse", "demo-habit", H, tool_name="Bash", tool_input={"command": "flutter test"})
    hook("Notification", "demo-habit", H, notification_type="permission_prompt",
         message="Claude needs your permission to use Bash")

    hook("SessionStart", "demo-web", W)
    hook("UserPromptSubmit", "demo-web", W, prompt="푸터 링크 전부 열리는지 봐 줘")
    hook("Stop", "demo-web", W, last_assistant_message=(
        "푸터 링크 8개를 확인했습니다.\n\n| 링크 | 결과 |\n|---|---|\n| 회사 소개 | 정상 |\n| 개인정보처리방침 | 정상 |\n"
        "| 채용 | **404** — 주소가 바뀌었습니다 |\n\n채용 링크만 고치면 됩니다. 할 일에 「푸터 링크 점검」을 확인필요로 올려 두었습니다."))

    hook("SessionStart", "demo-design", STAFF)
    hook("UserPromptSubmit", "demo-design", STAFF, prompt="잠금 화면 위젯 시안 세 가지 만들어 줘")

    # 회의 — 사회자(작업실)가 쓰는 상태.json·회의록.md를 그대로 흉내 낸다. 대시보드 회의 화면(9/17)이 3초 안에 집어 든다.
    M = ROOT + "/.claude/회의록/20260917_다음주_우선순위"
    os.makedirs(M, exist_ok=True)
    B_, H_, W_ = FOLDERS["블로그"], FOLDERS["습관앱"], FOLDERS["홈페이지"]
    state = {"주제": "다음 주 우선순위 — 무엇부터 내보내나", "라운드": 2, "상태": "발언중",
             "갱신": "2026-09-17T13:40:00+09:00",
             "참석자": [
                 {"이름": "블로그", "경로": B_, "상태": "발언완료", "요약": "여행 글부터 — 사진 12장 이미 골랐다",
                  "발언": "여행 글 초안이 80% 왔다. 사진 12장 배치만 남아서 **이번 주 안에 발행**할 수 있다.\n\n댓글 알림 메일 문구는 발행 뒤에 다듬어도 늦지 않다."},
                 {"이름": "습관앱", "경로": H_, "상태": "발언완료", "요약": "알림 저장 버그가 먼저 — 리뷰가 걸려 있다",
                  "발언": "알림 시간 설정이 저장 안 되는 문제로 스토어 리뷰 별 2개가 두 건 들어왔다. 잠금 화면 위젯 시안보다 **이 버그 수정 배포가 우선**이다.\n\n- 원인은 로컬 저장 키 충돌로 좁혀졌다\n- 고치면 1.5.1로 바로 올린다"},
                 {"이름": "홈페이지", "경로": W_, "상태": "대기중", "요약": "", "발언": ""}],
             "사용자의견": ["블로그는 발행 뒤 반응 보고 다음 글 정하자."],
             "잠정결론": "R1: 습관앱 버그 수정 → 블로그 여행 글 발행 → 홈페이지 푸터 순. 홈페이지는 R2 발언을 기다린다.",
             "결론": ""}
    with open(M + "/상태.json", "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    with open(M + "/회의록.md", "w", encoding="utf-8") as f:
        f.write("# 다음 주 우선순위 — 무엇부터 내보내나\n\n- 시작: 2026-09-17 13:30 · 사회자: 작업실 · 참석: 블로그 · 습관앱 · 홈페이지\n\n"
                "## 1라운드\n\n### 블로그\n여행 글 초안이 80% 왔다.\n\n### 습관앱\n알림 저장 버그가 먼저다.\n\n### 홈페이지\n푸터 링크 점검은 30분이면 끝난다.\n\n"
                "### 사회자 정리\n습관앱 버그 → 블로그 발행 → 홈페이지 푸터.\n\n## 2라운드\n(진행 중)\n")


def shot(name, query, wait=7):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        os.remove(path)
    prof = CFG + "/chrome-" + name
    url = BASE + "/todo" + ("?" + urllib.parse.urlencode(query) if query else "")
    # 헤드리스 크롬은 다 찍고도 안 끝나는 일이 있다 — 파일이 생기면 내린다.
    proc = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                             "--user-data-dir=" + prof, "--window-size=1920,1080", "--force-device-scale-factor=1",
                             "--virtual-time-budget=%d" % (wait * 1000), "--screenshot=" + path, url],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(80):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            time.sleep(0.5)
            break
        time.sleep(0.5)
    proc.kill()
    print("  %s %s" % ("✓" if os.path.exists(path) else "✗", path))


def main():
    ap = argparse.ArgumentParser(description="시연 데이터로 스크린샷을 뜬다")
    ap.add_argument("--app", default=os.path.join(HERE, "../madang/build/macos/Build/Products/Release/Madang.app"))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    app = os.path.realpath(args.app)
    if not os.path.isdir(app):
        return print("❌ 앱이 없다: %s" % app) or 1
    if wait_port(True, seconds=1):
        return print("❌ 포트 %d가 이미 쓰이고 있다 — 먼저 내린다" % PORT) or 1

    print("시연 폴더: %s" % DEMO)
    prepare()
    proc = launch(app)
    try:
        seed()
        time.sleep(3)
        print("스크린샷 → %s" % OUT)
        shot("01_board.png", {"view": "board", "scope": "all", "chat": FOLDERS["홈페이지"]})
        shot("02_list.png", {"view": "list", "scope": "all"})
        shot("03_chat.png", {"view": "list", "scope": "all", "chat": FOLDERS["습관앱"]})
        shot("05_meeting.png", {"view": "meeting"}, wait=9)
    finally:
        if args.keep:
            print("앱을 켜 둔다 — 대시보드: %s/todo · 끄기: kill %d" % (BASE, proc.pid))
        else:
            proc.terminate()
    # 처음 설정 창 — 훅이 없는 설정으로 한 번 더 띄운다
    if not args.keep:
        wait_port(False)
        os.remove(CFG + "/claude_settings.json")
        proc = launch(app)
        try:
            shot("04_first_run.png", {"view": "list"})
        finally:
            proc.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
