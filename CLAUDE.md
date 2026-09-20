# Madang — Claude Code 에이전트 가이드

> a desk for your Claude Code sessions

여러 폴더에서 도는 클로드 코드 세션을 한 화면에서 보고 다루는 macOS 앱이다.
앱을 켜면 **대시보드 창**(할 일 리스트·보드 + 사무실 + 대화 칸)이 뜬다.
(코드에는 바탕화면 책상 위젯 모양도 남아 있지만 공개판은 `kWidgetMode = false`로 꺼 두었다.)

이 파일은 이 저장소에서 작업하는 에이전트가 먼저 읽는 규칙이다.

---

## 1. 한눈에

| 항목 | 값 |
|---|---|
| 프레임워크 | Flutter (macOS 데스크톱) — 앱 전체가 `lib/main.dart` 한 파일이다 |
| 훅 수신 | `127.0.0.1:9876` (클로드 코드 훅이 여기로 POST한다) |
| 할 일 페이지 | `http://127.0.0.1:9876/todo` — 앱 창 안의 대시보드도 이 주소를 연다 |
| 폰에서 보기 | `0.0.0.0:9878` + 열쇠(`todo_key.json`). 같은 와이파이·테일스케일 안에서만 쓴다 |
| 세션 실행 | tmux — `scripts/tmux_up.py` |
| 샌드박스 | 꺼져 있다(`art/` 폴더와 tmux 호출 때문) |

## 2. 설계 원칙 — 바꾸지 말 것

- **터미널을 앱 안으로 삼키지 않는다.** PTY도 터미널 에뮬레이터도 만들지 않는다.
  세션의 주인은 tmux이고, 앱은 `tmux` CLI를 부르는 얇은 껍데기다(`Tmux` 클래스).
- **상태는 훅으로만 판단한다.** `capture-pane`은 사람이 읽으라고 화면을 떠오는 용도다.
  예외는 훅이 아예 안 울리는 구간(압축·재시도·스피너)뿐이고, 그때도 `session.status`는
  건드리지 않고 그리는 자리(`shownStatus`)에서만 얹는다.
- **세션 이름 규칙은 두 곳에 있다.** `scripts/tmux_up.py`의 `session_name`과
  `main.dart`의 `Tmux.sessionName`이 같은 결과를 내야 한다. 테스트가 둘을 맞춰 본다.
- **승인 생략은 기본으로 꺼져 있다.** 켜는 것은 쓰는 사람이 정한다
  (`~/Library/Application Support/madang/yolo` 표식, 책상의 자물쇠 버튼, `cw yolo`).
- **동작은 Dart에 둔다.** 할 일 페이지의 HTML·JS는 보여 주고 누르는 것만 한다.

## 3. 처음 설정 — 받은 사람이 할 일

앱을 열면 ⚙ **「처음 설정」** 창(`FirstRun`)이 뜬다. 코드로 손댈 때 알아 둘 것:

1. **점검** — GET `/todo/app/setup`: tmux · git · claude · 훅 9개 · 등록 폴더. 하나라도 비면 대시보드를 켤 때 한 번 뜬다
2. **훅 연결** — POST `app/setup-hooks`(빼기는 `{"remove": true}`). `~/.claude/settings.json`에 **덧붙이기만** 하고 백업을 남긴다.
   넣는 줄은 `scripts/setup_hooks.py`의 `command()`와 **글자까지 같아야** 한다(테스트가 붙잡고 있다)
3. **폴더** — 「폴더 고르기」(`app/add-folder`) · 「새 폴더 만들기」(`app/new-folder`, 시작용 CLAUDE.md = `FirstRun.starterClaudeMd`) ·
   대화 칸 머리 「＋ 하위」(`app/sub-folder`). 폴더를 고르거나 만들면 할 일 API용 프로젝트 줄(`ProjectDb.ensureFolder`)도 같이 만든다 —
   없으면 세션의 할 일 요청이 「등록된 프로젝트 폴더가 아니다」로 거절된다
4. **숨길 폴더** — `blocked_paths.example.json`을 `blocked_paths.json`으로 복사해 적는다(훅 포트에는 인증이 없다)
5. **근무기록 이름**(선택) — `work_settings.json`에 `{"mainLabel": "…", "monthlyTargetHours": …}`

설정 파일은 모두 `.gitignore` 대상이다 — 절대경로·개인 기록이 들어간다.
배포용 zip은 공개본에서 `python3 scripts/release.py`로 만든다(아직 공증 전 — 받은 사람이 처음 한 번 「그래도 열기」).

## 4. 폴더 구조

```
lib/main.dart              앱 전체 (훅 서버 · 할 일 · 대시보드 페이지 · 위젯)
art/                       실행 중에 디스크에서 읽는 그림 (art/README.md)
macos/Runner/              네이티브 창 · 초점 되돌리기 · 한/영 처리
scripts/
  tmux_up.py               등록한 폴더마다 tmux 세션을 띄운다
  setup.py                 소스에서 준비물 확인 → 빌드 → 설치 → 열기
  setup_hooks.py           훅 연결(터미널판)
  release.py               배포용 zip (공개본에서만)
  statusline_limits.py     상태줄에서 남은 한도를 받아 앱에 보낸다
  install.py               빌드한 앱을 ~/Applications/Madang 으로 옮긴다
  dev_run.sh               확인용 판을 옆에 띄운다
test/logic_test.dart       순수 로직 테스트
test/fixtures/panes/       실제로 떠 온 터미널 화면(개인 흔적 지운 것)
```

## 5. 검증

```bash
flutter test                                   # 순수 로직
flutter build macos --release
scripts/dev_run.sh                             # 쓰는 앱을 끄지 않고 옆에(포트 9877) 확인용 판을 띄운다
```

- **쓰는 앱을 죽여 가며 확인하지 않는다.** 확인은 옆 인스턴스(`CLAUDE_WATCHER_PORT`,
  `CLAUDE_WATCHER_CONFIG_DIR`)로 한다. 창 자리·대화 기록도 따로 담긴다
- 설치본 교체는 `python3 scripts/install.py --update` — 데이터는 건드리지 않고 앱만 갈아 끼운다
- 화면 모양은 앱이 제 그림을 떠 내게 한다(`CLAUDE_WATCHER_SHOT` + `CLAUDE_WATCHER_SELFTEST`)
- 판 번호는 `pubspec.yaml`의 `version`과 `kVersion`을 함께 올린다 — 테스트가 둘을 맞춰 본다

## 6. 하지 말 것

- `~/.claude/settings.json`의 남의 훅을 덮어쓰거나 같은 훅을 두 번 넣기
- 훅 포트(9876)를 `0.0.0.0`으로 열기 — 인증이 없다. 밖으로 여는 것은 할 일 포트(9878)와 열쇠뿐이다
- 공유기에 포트 열기 — 집 밖에서는 테일스케일 같은 사설망으로 붙는다
- 샌드박스를 다시 켜기(`art/`·tmux가 막힌다)
- 터미널 에뮬레이터·PTY 붙이기
