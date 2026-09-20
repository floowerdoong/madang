import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:qr/qr.dart';

// 훅이 POST를 쏘는 포트. 바꾸려면 settings.json의 curl 주소도 같이 바꿀 것.
const int kDefaultPort = 9876;

/// 이 판이 들을 포트.
///
/// **고쳐서 확인할 때 쓰라고 열어 두었다.** 기본 포트로 도는 것은 동현동현이
/// 실제로 쓰는 위젯이다. 그걸 죽여 가며 확인하면 쓰던 사람이 계속 끊긴다.
/// `CLAUDE_WATCHER_PORT=9877` 로 옆에 하나 더 띄워 거기서 확인한다.
final int kPort =
    int.tryParse(Platform.environment['CLAUDE_WATCHER_PORT'] ?? '') ??
        kDefaultPort;

/// 기본 포트가 아니면 확인용으로 띄운 판이다.
///
/// 창 자리·설정 파일을 본 판과 나눠 쓰고, 타이틀에 표시를 달아
/// 어느 쪽을 보고 있는지 헷갈리지 않게 한다.
bool get kIsDevInstance => kPort != kDefaultPort;

/// 폰에서 여는 할 일 포트. **훅 포트와 나눠 둔다.**
///
/// ⚠️ **훅 포트를 밖으로 열지 않는다.** 그쪽은 인증이 없고, POST 하나로
/// 캐릭터 상태를 지어낼 수 있는 입구다(4-1절). 밖에서 볼 이유가 있는 것은
/// 할 일뿐이므로 그것만 떼어내 따로 연다.
final int kTodoPort = kPort + 2;

// 접힌 상태 크기.
const Size kCollapsedSize = Size(320, 240);

/// 지금 판. **`pubspec.yaml`의 `version:`과 같아야 한다** — 테스트가 둘을 맞춰 본다.
/// 릴리즈 앱은 pubspec을 들고 다니지 않아 코드에 적어 둔다. 창 제목과 ⚙ 메뉴에 보인다
/// (대표 요청 9/16 — 「지금 우리 버전이 파악되지 않는다」).
const String kVersion = '1.119.5';

/// 바탕화면 위젯 모양을 켜는가. **공개본은 `false`** — 공개판은 대시보드 창 하나로만 뜬다(대표 결정 2026-09-16).
/// 대표 저장소는 그대로 `true`다. 공개본 스냅숏이 `public_manifest.txt`의 글자 바꾸기로 이 줄만 뒤집는다 —
/// 줄 모양을 바꾸면 그 바꾸기가 헛돌아 공개본에 위젯이 남는다.
const bool kWidgetMode = false;

/// 머리의 출근·휴식·퇴근 버튼을 보이는가. **공개본은 `false`**(대표 결정 2026-09-16) — 받은 사람의 세션은 근무기록 규칙을 모른다.
/// `kWidgetMode`처럼 공개본 스냅숏이 글자 바꾸기로 이 줄만 뒤집는다.
const bool kWorkButtons = false;

/// 머리 버튼이 오늘 근무 상태를 읽는 곳. `main`이 넣는다.
WorkLog? kWorkLog;

/// 출근·휴식·퇴근 버튼 — 누르면 최상단(이사) 세션에 그 말을 보낸다(대표 요청 2026-09-16).
///
/// 기록은 버튼이 아니라 **이사 세션이** 한다 — 시각을 확인하고 근무기록 API에 적는 규칙·「일 시작」 루틴이 거기 있다.
/// 버튼은 대표가 치던 말을 대신 쳐 줄 뿐이다. 보일 버튼은 오늘 기록을 보고 고른다(5초 다시 그리기로 따라온다).
class ClockButtons {
  static const Map<String, String> say = {
    'start': '일 시작',
    'breakStart': '휴식 시작',
    'breakEnd': '휴식 끝',
    'end': '퇴근',
  };

  /// 그 날 기록으로 보일 동작들. 출근 전 → 출근 · 근무 중 → 휴식 시작·퇴근 · 휴식 중 → 휴식 끝 · 퇴근 뒤 → 없음.
  static List<String> actionsFor(WorkDay? today) {
    if (today == null || today.clockIn == null) return ['start'];
    if (today.clockOut != null) return const [];
    if (today.breakFrom != null) return ['breakEnd'];
    return ['breakStart', 'end'];
  }

  static String ymd(DateTime t) => t.toIso8601String().substring(0, 10);

  /// **지금 이어지고 있는 근무일.** 날짜가 넘어가도 퇴근을 안 했으면 어제 자리다.
  ///
  /// ⚠️ 오늘 날짜만 보던 때는 **00시를 넘기는 순간 「일 시작」이 떴다** — 일하는 중인데
  /// 출근 전으로 보였고, 그걸 누르면 어제 근무가 열린 채로 오늘 근무가 하나 더 생긴다
  /// (대표 제보 9/18). 어제가 열려 있으면(출근 있고 퇴근 없음) 그 날을 이어간다.
  /// 날짜 하나를 주면 그 날 기록을 돌려주는 함수를 받는다 — 테스트가 파일 없이 확인할 수 있게 갈라 두었다.
  static String openDate(WorkDay? Function(String) dayOf, DateTime now) {
    final today = ymd(now);
    final t = dayOf(today);
    if (t != null && t.clockIn != null) return today;
    final y = ymd(now.subtract(const Duration(days: 1)));
    final yd = dayOf(y);
    if (yd != null && yd.clockIn != null && yd.clockOut == null) return y;
    return today;
  }

  /// 지금 도는 위젯의 기록으로 [openDate]를 부른다.
  static String openDateNow(DateTime now) =>
      openDate((d) => kWorkLog?.of(d), now);

  static String html() {
    if (!kWorkButtons || kWorkLog == null) return '';
    final now = DateTime.now();
    final day = openDateNow(now);
    final carried = day != ymd(now);
    final acts = actionsFor(kWorkLog!.of(day));
    // 글자는 「일 시작 · 휴식 · 일 끝」(대표 결정 9/17) — 세션을 켜는 「출근시키기」와 헷갈리지 않게. 보내는 말은 루트 규칙 그대로다.
    const label = {'start': '일 시작', 'breakStart': '휴식', 'breakEnd': '휴식 끝', 'end': '일 끝'};
    if (acts.isEmpty) return '<span class="clock"><span class="off">오늘 일 끝</span></span>';
    // 자정을 넘겨 어제 근무를 이어가는 중이면 그 날짜를 적어 둔다 — 안 적으면 어느 날에 찍히는지 모른다.
    final note = carried
        ? '<span class="off" title="어제 퇴근을 안 했다 — 이 버튼은 그 날 기록에 찍힌다">${day.substring(5).replaceFirst('-', '/')} 근무 이어짐</span>'
        : '';
    return '<span class="clock">$note${[
      for (final a in acts)
        '<button type="button" class="clk${a == 'start' ? ' primary' : ''}" title="이사 세션에 「${say[a]}」을 보낸다 ($day 기록)" onclick="clockSay(\'$a\', this)">${label[a]}</button>'
    ].join()}</span>';
  }

  /// 최상단(이사) 세션. 등록한 폴더 중 가장 바깥 것 — 없으면 null.
  static AgentSession? director(SessionStore store) {
    for (final floor in store.floors) {
      for (final s in floor.sessions) {
        if (floor.tierOf(s) == kDirectorCharSet && !s.temporary) return s;
      }
    }
    return null;
  }
}

// 설정과 art/를 어디서 찾을지.
//
// ⚠️ **예전에는 만든 사람의 절대경로가 여기 박혀 있었다.** 릴리즈 .app을
// 파인더에서 띄우면 작업 디렉토리가 `/`라, 못 찾았을 때 마지막으로 볼 자리가
// 필요했기 때문이다. 그 값이 남의 기계에는 없는 경로라 **받아도 설정도 그림도
// 못 찾았다.** 오픈소스로 풀면서 실행 파일 위치에서 되짚는 방식으로 바꿨다
// (2026-09-09).

/// 빌드 트리 안에서 돌고 있다면 그 프로젝트 뿌리.
///
/// `<뿌리>/build/macos/Build/Products/<모드>/<앱>.app/Contents/MacOS/<실행파일>`
/// 이 모양이면 **여덟 칸**을 거슬러 올라간 곳이 뿌리다. 플러터가 만드는
/// 자리라 누구 기계에서든 같다.
///
/// ⚠️ **칸을 세지 말고 `pubspec.yaml`을 찾는다.** 일곱으로 적었다가 `build/`에서
/// 멈췄고, 그 바람에 남의 기계에서 art/를 통째로 못 찾았다(2026-09-09).
/// 몇 칸인지는 플러터 사정이라 바뀔 수 있지만 **뿌리에 pubspec.yaml이 있다는
/// 것은 안 바뀐다.** 그걸 만나면 멈춘다.
String? _buildTreeRoot() {
  try {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 12; i++) {
      if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
      final up = dir.parent;
      if (up.path == dir.path) break; // 뿌리에 닿았다
      dir = up;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// `.app` 바로 옆. **설치본은 이 모양이다.**
///
/// ```
/// ~/Applications/Madang/
/// ├── Madang.app   ← 실행 파일은 이 안쪽 깊이 있다
/// ├── art/
/// └── (설정 파일들)
/// ```
///
/// ⚠️ **이게 없으면 더블클릭으로 띄울 때 설정을 못 찾는다.** 파인더가 띄우면
/// 작업 디렉토리가 `/`이고, 설치본은 빌드 트리가 아니라 뿌리도 못 되짚는다.
/// 터미널에서 `cd` 해서 띄우면 우연히 맞으므로 **더블클릭으로 확인해야
/// 드러난다**(2026-09-09).
String? _besideApp() {
  try {
    // <어딘가>/<앱>.app/Contents/MacOS/<실행파일> → <어딘가>
    var dir = File(Platform.resolvedExecutable).parent; // MacOS
    for (var i = 0; i < 3; i++) {
      dir = dir.parent;
    }
    return dir.path;
  } catch (_) {
    return null;
  }
}

/// 설치해서 쓸 때 설정이 사는 자리.
///
/// 이름을 「마당」으로 바꾸면서 `madang`으로 옮겼다(2026-09-16). **옛 폴더(`claude-watcher`)가 아직 있으면
/// 그쪽을 쓴다** — 자물쇠 표식 같은 값이 이사 중에 조용히 사라지면 왜 바뀌었는지 알 수 없다.
String _supportDir() {
  final home = Platform.environment['HOME'] ?? '';
  final now = '$home/Library/Application Support/madang';
  final was = '$home/Library/Application Support/claude-watcher';
  if (!Directory(now).existsSync() && Directory(was).existsSync()) return was;
  return now;
}

/// 설정을 **찾을** 자리들. 앞에서부터 본다.
final List<String> kConfigRoots = () {
  final out = <String>[];
  void add(String? p) {
    if (p != null && p.isNotEmpty && !out.contains(p)) out.add(p);
  }

  add(Platform.environment['CLAUDE_WATCHER_CONFIG_DIR']);
  add(Directory.current.path);
  add(_buildTreeRoot());
  add(_besideApp());
  add(_supportDir());
  return out;
}();

/// 없는 파일을 **새로 만들** 자리.
///
/// 찾는 순서와 다르다. 작업 디렉토리는 파인더에서 띄우면 `/`라, 거기에
/// 만들려 들면 쓰지도 못하고 실패한다. 그래서 **정말 프로젝트 폴더일 때만**
/// 작업 디렉토리를 쓴다(`pubspec.yaml`이 있으면 그렇게 본다).
final String kConfigHome = () {
  final env = Platform.environment['CLAUDE_WATCHER_CONFIG_DIR'];
  if (env != null && env.isNotEmpty) return env;
  final cwd = Directory.current.path;
  if (File('$cwd/pubspec.yaml').existsSync()) return cwd;
  // 설치본이면 앱 옆에 만든다 — 앱·그림·설정이 한 몸이어야 통째로 옮길 수 있다.
  final beside = _besideApp();
  if (beside != null && Directory('$beside/art').existsSync()) return beside;
  return _buildTreeRoot() ?? _supportDir();
}();

// 펼친 상태 크기. 캐릭터를 누르면 같은 창이 이만큼 커진다. 새 창을 띄우지 않는다.
const Size kExpandedSize = Size(720, 520);

/// 펼쳤을 때 화면의 얼마를 차지할지.
///
/// 너비는 **절반**이다. 더 넓히면 읽는 데는 좋지만 창이 바탕화면을 덮어
/// 위젯이 아니라 앱처럼 느껴진다. 옆에 터미널이나 브라우저를 같이 두는
/// 화면이라 반쪽이 알맞다.
/// 높이는 넉넉히 둔다 — 메시지가 세로로 쌓이므로 줄 수가 곧 쓸모다.
const double kExpandRatioW = 0.5;
const double kExpandRatioH = 0.78;

/// 아무리 큰 화면이어도 이 이상은 넓히지 않는다. 한 줄이 너무 길면 눈이 못 따라간다.
const double kExpandMaxW = 1280.0;
const double kExpandMaxH = 1000.0;

// 책상 상판(캐릭터가 발을 딛는 면)의 높이. 창 아래쪽에서 잰다.
const double kDeskPlank = 26;
// 캐릭터를 상판 안쪽으로 얼마나 밀어 넣을지.
// 딱 상판 선에 맞추면 모서리에 걸터앉은 것처럼 보여서 살짝 겹쳐 준다.
const double kFootInset = 7;
// 책상 그림이 없을 때 쓰는 책상 영역 높이. 캐릭터 56 + 이름 + 상판이 들어간다.
const double kDeskAreaHeight = 128;

// 마지막 이벤트로부터 이만큼 지나면 대기로 되돌린다.
// SessionEnd가 오지 않는 강제 종료(터미널 창 닫기 등)를 위한 보조 장치다.
const Duration kStaleAfter = Duration(minutes: 10);

/// 완료 몸짓을 얼마나 붙잡고 있을지.
///
/// 끝난 티는 계속 나야 하지만 **몸짓까지 계속 남을 필요는 없다.** 몇 시간째
/// 만세를 하고 있으면 방금 끝난 것과 한참 전에 끝난 것이 똑같아 보인다.
/// 이 시간이 지나면 그림만 대기로 돌리고 **점은 초록으로 둔다.**
///
/// 5분을 기다려야 확인되는 것이라 그림으로 볼 때만 `CLAUDE_WATCHER_DONE_POSE`
/// (초)로 당길 수 있다. 안 주면 5분이다.
final Duration kDonePose = () {
  final raw = Platform.environment['CLAUDE_WATCHER_DONE_POSE'];
  final secs = raw == null ? null : int.tryParse(raw);
  return secs == null || secs <= 0
      ? const Duration(minutes: 5)
      : Duration(seconds: secs);
}();

const Color bgDark = Color(0xFF1a1a2e);
const Color bgMid = Color(0xFF16213e);
const Color borderCol = Color(0xFF4a4a6e);
const Color accent = Color(0xFF7b68ee);
const Color gold = Color(0xFFffd700);
const Color textPrimary = Color(0xFFe0e0e0);

/// 읽으라고 있는 잔글씨 — 앞말·선택지 설명.
///
/// ⚠️ **`textDim`으로 쓰지 않는다.** `#888`은 이 바탕(`#16213e`) 위에서 명암비가
/// 4.4밖에 안 나온다(작은 글씨 기준 4.5 미달). 10px로 그려 놓으니 **뭘 묻는지가
/// 안 읽혔다** — 동현동현이 지적한 자리다(2026-08-31). 이건 8.3이다.
/// `textDim`은 이제 **읽지 않아도 되는 것**(조작법·번호)에만 쓴다.
const Color textBody = Color(0xFFb8bdd0);
const Color textDim = Color(0xFF888888);
const Color success = Color(0xFF4caf50);
const Color bored = Color(0xFF7f8fa6); // 심심함 — 회청색
const Color danger = Color(0xFFe74c3c); // 에러 — 빨강

/// 한 세션이 들고 있을 대화 줄 수 상한. 도구 줄이 실시간으로 쌓이므로
/// 상한이 없으면 긴 턴 하나에 수백 줄이 붙는다.
const int kChatLimit = 300;

/// 계층 세 단계가 쓸 캐릭터 세트 이름 — `art/chars/<이름>/`.
///
/// 직급처럼 가른다. 이 셋만 **사람이 고르지 않아도** 자동으로 물린다.
///
/// | 세트 | 누구 |
/// |---|---|
/// | `director` (이사) | 최상위 등록 — 자기 위에 등록된 조상이 없다 |
/// | `manager` (팀장) | 하위로 등록한 프로젝트 |
/// | `staff` (사원) | 등록 안 한 폴더에서 띄운 임시 세션 |
///
/// ⚠️ **세 단계로 뭉갠다.** 등록을 더 깊이 해도 `manager`다. 단계가 늘면
/// 그림을 그만큼 더 그려야 하고 테마 한 벌이 무거워진다.
///
/// 그림이 없으면 기본 캐릭터로 떨어지므로 안 그린 동안은 아무 일도 안 난다.
const String kDirectorCharSet = 'director';
const String kManagerCharSet = 'manager';
const String kStaffCharSet = 'staff';

enum AgentStatus { idle, thinking, working, waiting, bored, done, error }

extension AgentStatusView on AgentStatus {
  Color get color {
    switch (this) {
      case AgentStatus.idle:
        return textDim;
      case AgentStatus.thinking:
        return accent;
      case AgentStatus.working:
        return accent;
      case AgentStatus.waiting:
        return gold;
      case AgentStatus.bored:
        return bored;
      case AgentStatus.done:
        return success;
      case AgentStatus.error:
        return danger;
    }
  }

  String get label {
    switch (this) {
      case AgentStatus.idle:
        return '대기';
      case AgentStatus.thinking:
        return '생각 중';
      case AgentStatus.working:
        return '작업 중';
      case AgentStatus.waiting:
        return '승인 대기';
      case AgentStatus.bored:
        return '심심함';
      case AgentStatus.done:
        return '완료';
      case AgentStatus.error:
        return '문제 발생';
    }
  }

  // art/char/ 아래에서 찾을 파일명. art/README.md의 표와 같은 값이어야 한다.
  String get artKey {
    switch (this) {
      case AgentStatus.idle:
        return 'idle';
      case AgentStatus.thinking:
        return 'thinking';
      case AgentStatus.working:
        return 'working';
      case AgentStatus.waiting:
        return 'waiting';
      case AgentStatus.bored:
        return 'bored';
      case AgentStatus.done:
        return 'done';
      case AgentStatus.error:
        return 'error';
    }
  }

  bool get pulses =>
      this == AgentStatus.thinking ||
      this == AgentStatus.working ||
      this == AgentStatus.waiting;

  /// 지금 손을 놀리고 있는 중인가. 진행 스트립을 그릴지 여기서 정한다.
  bool get busy =>
      this == AgentStatus.thinking || this == AgentStatus.working;
}

/// 화면에 그릴 상태. 훅이 준 것에 **화면 신호를 얹은 결과**다.
///
/// ⚠️ `session.status` 자체는 건드리지 않는다. 훅이 정한 값을 덮어쓰면
/// 다음 훅이 올 때까지 되돌릴 방법이 없어진다. 그리는 자리에서만 바꾼다.
extension ShownStatus on AgentSession {
  AgentStatus get shownStatus =>
      (signals.working && !status.busy) ? AgentStatus.working : status;

  /// **그림으로 그릴 상태.** 점 색(`shownStatus`)과 일부러 갈라 둔다.
  ///
  /// 완료는 결과를 보여주는 상태라 끝난 직후에는 그 몸짓이 남아 있어야 한다.
  /// 다만 `kDonePose`가 지나면 몸짓만 대기로 돌린다 — '끝났다'는 사실은
  /// 그대로고 '방금'이 아닐 뿐이라, 점은 초록으로 남는다.
  ///
  /// ⚠️ **완료 말고 다른 상태에는 손대지 않는다.** 승인 대기는 사람을
  /// 기다리느라 오래 서 있는 것이 정상이고, 거기서 몸짓을 빼면 무엇을
  /// 기다리는지 알 수 없어진다.
  AgentStatus get artStatus {
    if (status != AgentStatus.done) return status;
    final since = statusSince;
    if (since == null) return status;
    return DateTime.now().difference(since) > kDonePose
        ? AgentStatus.idle
        : status;
  }
}

/// 설정 파일이 어디 있는지 정한다. 릴리즈 .app은 작업 디렉토리가 프로젝트가 아니다.
String resolveConfigPath(String filename) {
  for (final root in kConfigRoots) {
    final path = '$root/$filename';
    if (File(path).existsSync()) return path;
  }
  // 아직 없는 파일이다. 만들 자리를 돌려주고, 그 폴더가 없으면 만들어 둔다.
  try {
    Directory(kConfigHome).createSync(recursive: true);
  } catch (_) {
    // 못 만들어도 경로는 돌려준다 — 쓰는 쪽이 각자 실패를 다룬다.
  }
  return '$kConfigHome/$filename';
}

/// 붙여 둔 모니터를 가리키는 값.
///
/// ⚠️ **id 하나로는 못 찾는다.** macOS의 `CGDirectDisplayID`는 같은 모니터라도
/// 뽑았다 꽂거나 재부팅하면 바뀌는 일이 있다. 그래서 이름과 크기도 같이 적어
/// 두고 **id → 이름 → 크기** 순으로 찾는다. 셋 다 어긋나면 못 찾은 것이다.
///
/// 크기까지 보는 이유는 같은 모델을 두 대 쓰면 이름이 겹치기 때문이다.
/// 그때는 어느 쪽이든 크기가 같은 것을 고르게 되는데, 어차피 같은 모니터라
/// 사람이 보기에 틀린 자리가 아니다.
class DisplayPin {
  const DisplayPin({required this.id, this.name, this.width, this.height});

  factory DisplayPin.of(Display d) => DisplayPin(
        id: d.id,
        name: (d.name?.isEmpty ?? true) ? null : d.name,
        width: d.size.width,
        height: d.size.height,
      );

  factory DisplayPin.fromJson(Map<String, dynamic> j) => DisplayPin(
        id: '${j['id'] ?? ''}',
        name: j['name'] as String?,
        width: (j['width'] as num?)?.toDouble(),
        height: (j['height'] as num?)?.toDouble(),
      );

  final String id;
  final String? name;
  final double? width;
  final double? height;

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };

  /// 사람에게 보여줄 이름. 이름이 없는 모니터도 있다.
  String get label => name ?? '모니터 $id';

  bool isSame(Display d) => d.id == id;

  /// 목록에서 이걸 가리키는 것을 찾는다. 없으면 null.
  Display? find(List<Display> displays) {
    for (final d in displays) {
      if (d.id == id) return d;
    }
    if (name != null) {
      for (final d in displays) {
        if (d.name == name) return d;
      }
    }
    if (width != null && height != null) {
      for (final d in displays) {
        if (d.size.width == width && d.size.height == height) return d;
      }
    }
    return null;
  }
}

/// 마지막 창 위치를 기억한다.
///
/// 크기는 저장하지 않는다. 펼침(720×520) 상태로 껐다고 해서 다음에 펼친 채로
/// 뜨면 곤란하다. 켤 때는 늘 접힌 상태에서 시작하고 자리만 되찾는다.
class WindowStateStore {
  /// 확인용 판은 자리를 따로 기억한다. 같이 쓰면 확인하느라 띄운 창이
  /// 본 판의 자리를 덮어써서, 쓰던 사람이 창을 도로 찾아 옮겨야 한다.
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'window_state.dev$kPort.json' : 'window_state.json');

  static Offset? load() {
    final file = File(_path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['x'] is num && decoded['y'] is num) {
        return Offset(
          (decoded['x'] as num).toDouble(),
          (decoded['y'] as num).toDouble(),
        );
      }
    } catch (e) {
      debugPrint('창 위치 읽기 실패: $e');
    }
    return null;
  }

  static void save(Offset position) {
    try {
      final out = <String, dynamic>{'x': position.dx, 'y': position.dy};
      // 고정해 둔 모니터는 자리를 저장할 때마다 같이 들고 간다.
      // 따로 파일을 두면 둘이 어긋났을 때 어느 쪽이 맞는지 알 수 없다.
      final pinned = loadPin();
      if (pinned != null) out['pin'] = pinned.toJson();
      File(_path).writeAsStringSync(jsonEncode(out));
    } catch (e) {
      debugPrint('창 위치 저장 실패: $e');
    }
  }

  /// 어느 모니터에 붙여 둘지. 안 정했으면 null.
  static DisplayPin? loadPin() {
    final file = File(_path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['pin'] is Map) {
        return DisplayPin.fromJson((decoded['pin'] as Map).cast<String, dynamic>());
      }
    } catch (e) {
      debugPrint('고정 모니터 읽기 실패: $e');
    }
    return null;
  }

  /// 고정할 모니터를 적어 둔다. `null`이면 고정을 푼다.
  ///
  /// ⚠️ **자리(x·y)는 건드리지 않는다.** 고정만 바꿨는데 자리까지 날아가면
  /// 다음에 켤 때 창이 엉뚱한 데서 뜬다.
  static void savePin(DisplayPin? pin) {
    try {
      final file = File(_path);
      final out = <String, dynamic>{};
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) out.addAll(decoded.cast<String, dynamic>());
      }
      if (pin == null) {
        out.remove('pin');
      } else {
        out['pin'] = pin.toJson();
      }
      file.writeAsStringSync(jsonEncode(out));
    } catch (e) {
      debugPrint('고정 모니터 저장 실패: $e');
    }
  }

  /// 저장된 자리가 지금 화면 안에 있는지 본다.
  ///
  /// 모니터를 빼면 예전 자리가 화면 밖이 되어 창이 안 보이게 된다.
  /// 창의 왼쪽 위 모서리 부근이 어느 디스플레이에든 걸쳐 있어야 통과다.
  static Future<bool> isOnScreen(Offset position, Size size) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return false;
      // 타이틀바가 없으므로 최소한 잡을 수 있는 만큼은 보여야 한다.
      final handle = Rect.fromLTWH(position.dx, position.dy, 80, 40);
      for (final d in displays) {
        final origin = d.visiblePosition ?? Offset.zero;
        final area = Rect.fromLTWH(
          origin.dx,
          origin.dy,
          (d.visibleSize ?? d.size).width,
          (d.visibleSize ?? d.size).height,
        );
        if (area.overlaps(handle)) return true;
      }
    } catch (e) {
      debugPrint('디스플레이 확인 실패: $e');
      return false;
    }
    return false;
  }
}

/// 아예 받지 않을 폴더들.
///
/// 훅은 전역이라 모든 프로젝트의 cwd와 마지막 응답 전문이 위젯으로 흘러온다.
/// 금고 같은 폴더는 화면에 이름조차 남기지 않는 편이 낫다 — 미등록 신호로도
/// 잡지 않는다.
class BlockList {
  BlockList(this.paths);

  final List<String> paths;

  /// 기본값은 **비어 있다.**
  ///
  /// ⚠️ 예전에는 만든 사람의 폴더 두 개가 절대경로로 박혀 있었다. 남의 기계에는
  /// 없는 경로라 아무 일도 안 하면서 그 사람 폴더 이름만 드러냈다. 차단할 폴더는
  /// 사람마다 다르므로 `blocked_paths.json`에서만 받는다 (2026-09-09).
  ///
  /// ⚠️ **파일이 있으면 그 내용이 전부다.** 파일에 적은 것 말고는 아무것도
  /// 차단되지 않는다 — 여기에 뭘 적어두고 파일에서 빠뜨리면 그 폴더는
  /// 뚫린 채로 돈다. 실제로 그렇게 새어 있었다(`98_가계부`, 2026-09-09 발견).
  /// 모양은 `blocked_paths.example.json`에 있다.
  static const List<String> defaults = [];

  factory BlockList.load() {
    final file = File(resolveConfigPath('blocked_paths.json'));
    if (!file.existsSync()) return BlockList(defaults);
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final list = decoded is Map ? decoded['blocked'] : decoded;
      if (list is List) {
        return BlockList(list
            .whereType<String>()
            .map(ProjectStore.normalize)
            .where((p) => p.isNotEmpty)
            .toList());
      }
    } catch (e) {
      debugPrint('차단 목록 읽기 실패: $e');
    }
    return BlockList(defaults);
  }

  bool blocks(String cwd) {
    final target = ProjectStore.normalize(cwd);
    return paths.any((p) {
      final base = ProjectStore.normalize(p);
      return target == base || target.startsWith('$base/');
    });
  }
}

/// 대화에 나온 경로를 파인더로 보여 줄 때 실제 경로로 푼다(대표 요청 9/15).
///
/// - `~/…`는 홈으로, 상대 경로(`lib/main.dart`)는 그 세션 폴더([cwd]) 기준으로 푼다
/// - 끝의 `:줄번호`(`main.dart:123`, `:12:5`)는 뗀다 — 세션이 `경로:줄` 모양으로 가리킨다
/// - 차단 폴더([BlockList]) 안이면 거절한다 — 금고 폴더는 화면에 이름조차 남기지 않는 규칙과 같다
/// - 없으면 거절한다. 파일이면 파인더에서 그 파일을 골라 보이고(`open -R`), 폴더면 연다
///
/// 여는 것은 파인더뿐이다 — 파일을 실행하거나 앱으로 열지 않는다.
({String? path, bool dir, String? error}) revealTarget(String raw, String cwd,
    {required String home, required BlockList block}) {
  var v = raw.trim();
  if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
    v = v.substring(1, v.length - 1);
  }
  v = v.replaceFirst(RegExp(r'(:\d+){1,2}$'), '');
  if (v.isEmpty) return (path: null, dir: false, error: '경로가 비었다');
  if (v == '~' || v.startsWith('~/')) {
    v = home + v.substring(1);
  } else if (!v.startsWith('/')) {
    if (cwd.isEmpty) return (path: null, dir: false, error: '어느 세션 기준인지 모른다');
    v = '$cwd/$v';
  }
  // `..`·`.`을 풀어 실제 자리로 — 차단 폴더를 `..`로 돌아 들어가지 못하게.
  final norm = Uri.file(v).normalizePath().toFilePath();
  final path = norm.length > 1 && norm.endsWith('/') ? norm.substring(0, norm.length - 1) : norm;
  if (block.blocks(path)) return (path: null, dir: false, error: '차단한 폴더라 열지 않는다');
  if (Directory(path).existsSync()) return (path: path, dir: true, error: null);
  if (File(path).existsSync()) return (path: path, dir: false, error: null);
  return (path: null, dir: false, error: '없는 경로다: $path');
}

/// 훅이 알려준 transcript 경로를 믿어도 되는지 본다.
///
/// 포트에 인증이 없어서 같은 기계의 아무 프로세스나 페이로드를 보낼 수 있다.
/// 경로를 그대로 열면 아무 파일이나 패널에 띄우게 만들 수 있으므로,
/// 클로드가 실제로 기록을 두는 곳 아래로만 허용한다.
bool isTranscriptPathAllowed(String path, {String? home}) {
  if (path.isEmpty || path.contains('..')) return false;
  if (!path.endsWith('.jsonl')) return false;
  final root = '${home ?? Platform.environment['HOME'] ?? ''}/.claude/projects/';
  if (root == '/.claude/projects/') return false;
  return path.startsWith(root);
}

/// 지켜볼 프로젝트 하나.
class WatchedProject {
  const WatchedProject({required this.path, required this.name, this.charSet});

  final String path;
  final String name;
  /// 이 프로젝트가 쓸 캐릭터 세트 이름(`art/chars/<이름>/`). 없으면 기본.
  final String? charSet;

  factory WatchedProject.fromJson(Map<String, dynamic> j) {
    // 예전에 NFD로 저장된 항목이 있을 수 있으므로 읽을 때 표기를 맞춘다.
    final path = ProjectStore.normalize(j['path'] as String);
    final name = j['name'] as String?;
    final set = j['char'] as String?;
    return WatchedProject(
      path: path,
      name: name == null
          ? _basename(path)
          : ProjectStore.composeHangul(name),
      charSet: (set == null || set.isEmpty)
          ? null
          : ProjectStore.composeHangul(set),
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        if (charSet != null) 'char': charSet,
      };

  static String _basename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return ProjectStore.composeHangul(parts.isEmpty ? path : parts.last);
  }
}

/// 등록된 프로젝트 목록. `watched_projects.json`에 저장한다.
///
/// **이 파일은 v1.0의 tmux 기동 스크립트가 읽을 입력이기도 하다.**
/// 스키마를 바꾸면 그쪽도 같이 고쳐야 한다.
class ProjectStore extends ChangeNotifier {
  final List<WatchedProject> projects = [];
  late String filePath;

  String _resolvePath() {
    final env = Platform.environment['CLAUDE_WATCHER_PROJECTS'];
    if (env != null && env.isNotEmpty) return env;
    // 다른 설정 파일과 같은 자리에서 찾는다(`resolveConfigPath`).
    return resolveConfigPath('watched_projects.json');
  }

  void load() => loadFrom(_resolvePath());

  /// 지정한 파일에서 읽는다. 테스트가 임시 파일을 물릴 수 있게 갈라 두었다.
  void loadFrom(String path) {
    filePath = path;
    projects.clear();
    final file = File(filePath);
    if (!file.existsSync()) {
      notifyListeners();
      return;
    }
    var rewritten = false;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final list = decoded is Map ? decoded['projects'] : decoded;
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic> && item['path'] is String) {
            final p = WatchedProject.fromJson(item);
            if (p.path != item['path']) rewritten = true;
            projects.add(p);
          }
        }
      }
    } catch (e) {
      debugPrint('프로젝트 목록 읽기 실패: $e');
    }
    // NFD로 저장돼 있던 항목을 고쳐 썼다면 파일도 정리해둔다.
    // v1의 tmux 스크립트가 같은 파일을 읽으므로 표기를 하나로 유지한다.
    if (rewritten) {
      debugPrint('프로젝트 경로 표기를 NFC로 정리했다');
      _save();
    }
    notifyListeners();
  }

  void _save() {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      const encoder = JsonEncoder.withIndent('  ');
      file.writeAsStringSync(
        encoder.convert({'projects': projects.map((p) => p.toJson()).toList()}),
      );
    } catch (e) {
      debugPrint('프로젝트 목록 저장 실패: $e');
    }
  }

  /// 한글 자모(NFD)를 완성형(NFC)으로 합친다.
  ///
  /// macOS 파일시스템과 `osascript`의 `choose folder`는 한글을 자모로 분리해
  /// 돌려주는데, 훅이 보내는 `cwd`는 완성형이다. 눈에는 같아 보여도 문자열
  /// 비교가 어긋나 등록한 프로젝트가 반응하지 않는다. 그래서 양쪽을 여기서 맞춘다.
  ///
  /// 한글만 다룬다. 라틴 문자의 결합 악센트는 이 경로들에 사실상 나오지 않는다.
  static String composeHangul(String s) {
    const lBase = 0x1100, vBase = 0x1161, tBase = 0x11A7;
    const sBase = 0xAC00, vCount = 21, tCount = 28;

    final out = <int>[];
    final runes = s.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final l = runes[i];
      if (l >= lBase && l <= 0x1112 && i + 1 < runes.length) {
        final v = runes[i + 1];
        if (v >= vBase && v <= 0x1175) {
          var code = sBase +
              ((l - lBase) * vCount + (v - vBase)) * tCount;
          i++;
          // 종성이 이어지면 같이 합친다
          if (i + 1 < runes.length) {
            final t = runes[i + 1];
            if (t > tBase && t <= 0x11C2) {
              code += t - tBase;
              i++;
            }
          }
          out.add(code);
          continue;
        }
      }
      out.add(l);
    }
    return String.fromCharCodes(out);
  }

  /// 끝의 `/`를 떼고 한글 표기를 맞춘다. 매칭이 이 표기에 의존한다.
  static String normalize(String path) {
    var p = composeHangul(path.trim());
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  bool add(String rawPath) {
    final path = normalize(rawPath);
    if (path.isEmpty) return false;
    if (projects.any((p) => p.path == path)) return false;
    projects.add(WatchedProject(path: path, name: WatchedProject._basename(path)));
    _save();
    notifyListeners();
    return true;
  }

  /// 이 폴더를 등록하면 삼켜버릴 하위 폴더들. 등록 전에 알려주려고 쓴다.
  ///
  /// 매칭이 접두어라서 상위 폴더를 등록하면 그 아래 모든 세션이 그 캐릭터로 잡힌다.
  /// 02_무위다라니처럼 큰 폴더를 등록하면 하위 프로젝트가 전부 흡수된다.
  List<String> wouldSwallow(String rawPath) {
    final path = normalize(rawPath);
    return projects
        .where((p) => p.path.startsWith('$path/'))
        .map((p) => p.name)
        .toList();
  }

  /// 이 폴더를 이미 삼키고 있는 상위 등록이 있는지.
  WatchedProject? swallowedBy(String rawPath) {
    final path = normalize(rawPath);
    for (final p in projects) {
      if (path.startsWith('${p.path}/')) return p;
    }
    return null;
  }

  /// 이 프로젝트가 쓸 캐릭터 세트를 정한다. null이면 기본으로 되돌린다.
  void setCharSet(String path, String? setName) {
    final i = projects.indexWhere((p) => p.path == path);
    if (i < 0) return;
    final p = projects[i];
    projects[i] =
        WatchedProject(path: p.path, name: p.name, charSet: setName);
    _save();
    notifyListeners();
  }

  void remove(String path) {
    projects.removeWhere((p) => p.path == path);
    _save();
    notifyListeners();
  }

  /// 훅의 cwd가 어느 프로젝트에 속하는지 찾는다.
  /// 하위 폴더에서 클로드를 열 수도 있으므로 접두어로 맞춘다.
  /// 겹치는 등록이 있으면 더 깊은 경로가 이긴다.
  WatchedProject? match(String cwd) {
    final target = normalize(cwd);
    WatchedProject? best;
    for (final p in projects) {
      if (target == p.path || target.startsWith('${p.path}/')) {
        if (best == null || p.path.length > best.path.length) best = p;
      }
    }
    return best;
  }
}

/// transcript(.jsonl)에서 마지막 어시스턴트 응답을 뽑아낸다.
///
/// 완료 시 메시지 탭에 올릴 응답의 기본 소스다. capture-pane은 보이는 화면만 주기 때문에
/// (클로드 코드가 alternate screen을 쓴다) 응답 전체를 온전히 얻으려면 이쪽뿐이다.
/// 자세한 근거는 `docs/tmux_검증_20260804/`에 있다.
/// 한 턴에서 뽑아낸 것. 응답 본문과 '무슨 일을 했는지'를 따로 들고 있는다.
class TurnReport {
  const TurnReport({this.text, this.toolCounts = const {}, this.files = const []});

  final String? text;
  /// 도구 이름 → 쓴 횟수
  final Map<String, int> toolCounts;
  /// 건드린 파일 (Edit/Write/Read 등에서 모은다)
  final List<String> files;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && toolCounts.isEmpty;

  /// "Bash 8 · Edit 12 · Read 3" 처럼 한 줄로 만든다.
  String? get toolLine {
    if (toolCounts.isEmpty) return null;
    final entries = toolCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.key} ${e.value}').join(' · ');
  }
}

/// 등록된 프로젝트의 transcript를 **훅 없이** 찾아낸다.
///
/// 훅이 알려주는 `transcript_path`만 믿으면, 위젯이 꺼져 있던 사이에 끝난
/// 턴을 영영 못 본다. 세션은 훅이 와야 생기고, 세션이 없으면 따라 읽기도
/// 돌지 않기 때문이다. 실제로 겪었다(2026-08-06) — 위젯을 갈아끼우는 25초
/// 사이에 다른 세션이 답을 끝냈는데, 그 답이 화면에 영영 안 떴다.
class TranscriptFinder {
  /// 클로드 코드가 프로젝트 경로를 폴더 이름으로 바꾸는 규칙.
  ///
  /// 영숫자가 아닌 것은 전부 `-`다. 한글도 한 글자에 `-` 하나다.
  /// `/Users/…/02_무위다라니` → `-Users-…-02------`
  /// 실측으로 확인했다(2026-08-06).
  static String dirName(String path) =>
      path.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '-');

  static String get _root =>
      '${Platform.environment['HOME'] ?? ''}/.claude/projects';

  /// 그 프로젝트에서 **가장 최근에 쓰인** transcript를 준다. 없으면 null.
  ///
  /// 한 폴더에 세션마다 파일이 쌓이므로 최신 것이 지금 돌고 있는 세션이다.
  static String? latest(String projectPath) {
    try {
      final dir = Directory('$_root/${dirName(projectPath)}');
      if (!dir.existsSync()) return null;
      String? best;
      DateTime? bestAt;
      for (final f in dir.listSync()) {
        if (f is! File || !f.path.endsWith('.jsonl')) continue;
        final at = f.statSync().modified;
        if (bestAt == null || at.isAfter(bestAt)) {
          bestAt = at;
          best = f.path;
        }
      }
      return best;
    } catch (e) {
      debugPrint('transcript 찾기 실패 $projectPath: $e');
      return null;
    }
  }
}

/// 응답 하나가 들고 간 **입력 토큰 합계** = 그 시점의 컨텍스트 크기.
///
/// 캐시에서 읽은 것도 컨텍스트를 차지하므로 다 더한다. 출력 토큰은 뺀다 —
/// 그건 다음 요청의 입력으로 넘어가며 이미 합계에 반영된다.
///
/// ⚠️ **비율(%)은 내지 않는다.** 모델 이름으로 한도를 알 수 없다.
/// 실측해 보니 `claude-opus-5` 인데 644k를 쓰고 있었다(2026-08-07) — 이름만
/// 보고 200k라 단정하면 틀린 숫자를 내걸게 된다. 숫자를 그대로 보여준다.
int? contextTokensOf(Object? usage) {
  if (usage is! Map) return null;
  int at(String key) {
    final v = usage[key];
    return v is int ? v : 0;
  }

  final total = at('input_tokens') +
      at('cache_creation_input_tokens') +
      at('cache_read_input_tokens');
  return total > 0 ? total : null;
}

/// `643241` → `643k`. 자리를 적게 먹으면서 크기 감이 온다.
String formatTokens(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

/// 훅이 준 `cwd`를 **transcript 경로로 바로잡는다.**
///
/// ⚠️ **훅의 cwd는 세션이 열린 폴더가 아니다.** Bash가 하위 폴더에서 돌면
/// `PreToolUse`의 cwd가 그 하위로 온다. 그게 위젯을 켠 뒤 **첫 훅**이면
/// `session_id`가 그 임시 캐릭터에 묶여서, 그 세션의 상태가 통째로 엉뚱한
/// 캐릭터로 간다. 실제로 겪었다(2026-08-10) — `02_무위다라니` 세션의 훅이
/// 전부 `.claude` 캐릭터로 가서, 대화는 (transcript 폴링 덕에) 보이는데
/// 점 세 개도 안 뜨고 작업 애니메이션도 안 돌았다.
///
/// transcript 파일이 놓인 폴더 이름은 **세션이 열린 폴더**를 인코딩한 것이라
/// 도구가 어디서 돌든 안 바뀐다. 그걸로 cwd의 조상 중 진짜를 골라낸다.
///
/// 못 고르면 cwd를 그대로 둔다 — 하위 폴더에서 **따로 띄운** 세션은 제
/// 캐릭터를 가져야 하고, 그때는 transcript 폴더도 그 하위를 가리킨다.
String resolveSessionCwd(String cwd, String? transcriptPath) {
  if (transcriptPath == null || transcriptPath.isEmpty) return cwd;
  final parts = transcriptPath.split('/');
  if (parts.length < 2) return cwd;
  final folder = parts[parts.length - 2];
  if (folder.isEmpty) return cwd;

  var path = ProjectStore.normalize(cwd);
  // 자기부터 위로 올라가며 transcript 폴더 이름과 맞는 조상을 찾는다.
  while (path.contains('/')) {
    if (TranscriptFinder.dirName(path) == folder) return path;
    path = path.substring(0, path.lastIndexOf('/'));
    if (path.isEmpty) break;
  }
  return cwd;
}

/// 클로드가 한 마디 한 것. transcript의 assistant text 블록 하나에 대응한다.
class Speech {
  const Speech({required this.uuid, required this.text});

  /// transcript 줄의 `uuid`. 같은 말을 두 번 올리지 않으려고 든다.
  final String uuid;
  final String text;
}

/// transcript를 증분으로 읽어낸 결과.
class SpeechBatch {
  const SpeechBatch(this.speeches, this.offset, {this.contextTokens, this.model});

  final List<Speech> speeches;

  /// 다음에 여기서부터 읽으면 된다 (파일 시작으로부터의 바이트).
  /// **완전한 줄이 끝나는 자리**라 반쯤 쓰인 줄을 다시 읽지 않는다.
  final int offset;

  /// 마지막 응답이 들고 간 입력 토큰 합계 = **지금 컨텍스트 크기**.
  /// 이번에 새로 본 것이 없으면 null(=그대로 둔다).
  final int? contextTokens;

  /// 마지막 응답을 쓴 모델(`claude-opus-5` 같은 값). 대화 칸 캐릭터 옆에 보인다(대표 요청 9/17).
  /// 이번에 새로 본 응답이 없으면 null(=그대로 둔다).
  final String? model;
}

class TranscriptReader {
  // 뒤에서부터 이만큼만 읽는다. 대화가 길어도 마지막 응답은 이 안에 들어온다.
  static const int _tailBytes = 512 * 1024;

  /// MCP 도구 이름은 `mcp__서버__도구` 꼴로 길다. 읽을 수 있게 줄인다.
  static String _shortToolName(String name) {
    if (!name.startsWith('mcp__')) return name;
    final parts = name.split('__');
    return parts.length >= 3 ? '${parts[1]}:${parts.last}' : name;
  }

  static TurnReport? lastTurn(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;

    String text;
    try {
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        final start = length > _tailBytes ? length - _tailBytes : 0;
        raf.setPositionSync(start);
        final bytes = raf.readSync(length - start);
        text = utf8.decode(bytes, allowMalformed: true);
        // 뒤에서 잘라 읽었으면 첫 줄은 잘린 조각이라 버린다.
        if (start > 0) {
          final nl = text.indexOf('\n');
          text = nl < 0 ? '' : text.substring(nl + 1);
        }
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      debugPrint('transcript 읽기 실패 $path: $e');
      return null;
    }

    final rows = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) rows.add(decoded);
      } catch (_) {
        // 잘린 줄 하나쯤은 그냥 넘긴다
      }
    }

    // 마지막 사람 발화 뒤에 나온 것만 본다.
    // 도구 결과도 role=user로 들어오므로, 사람이 친 것만 경계로 삼는다.
    final chunks = <String>[];
    final toolCounts = <String, int>{};
    final files = <String>[];

    for (var i = rows.length - 1; i >= 0; i--) {
      final row = rows[i];
      final type = row['type'];
      final message = row['message'];
      if (message is! Map) continue;

      if (type == 'user' && _isHumanTurn(message['content'])) break;
      if (type != 'assistant') continue;

      final part = _textOf(message['content']);
      if (part != null && part.trim().isNotEmpty) chunks.add(part.trim());
      _collectTools(message['content'], toolCounts, files);
    }

    return TurnReport(
      text: chunks.isEmpty ? null : chunks.reversed.join('\n\n'),
      toolCounts: toolCounts,
      files: files.reversed.toList(),
    );
  }

  /// [offset] 이후에 새로 쌓인 어시스턴트 발화를 순서대로 뽑아낸다.
  ///
  /// **transcript는 턴이 끝나기를 기다리지 않는다.** 클로드가 도구를 부르기
  /// 직전에 한 말이 그 자리에서 한 줄로 박힌다(2026-08-06 실측). 그래서
  /// 훅이 올 때마다 이걸로 따라 읽으면 터미널에서 보이는 그대로 —
  /// `말 → 도구 → 말 → 도구` — 를 메시지 탭에 옮길 수 있다.
  /// `Stop`의 `last_assistant_message`만 쓰면 턴의 **마지막 한 마디**밖에 안 남는다.
  ///
  /// 파일 전체를 다시 읽지 않고 바이트 [offset]부터만 읽는다. 대화가 10MB를
  /// 넘어가도 훅 한 번에 읽는 양은 방금 늘어난 만큼뿐이다.
  static SpeechBatch? since(String path, int offset) {
    final file = File(path);
    if (!file.existsSync()) return null;

    try {
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        // 처음 보는 파일이거나(0) 파일이 갈려 짧아졌으면 꼬리만 본다.
        // 그대로 처음부터 읽으면 지난 대화가 통째로 쏟아진다.
        final fresh = offset <= 0 || offset > length;
        final start =
            fresh ? (length > _tailBytes ? length - _tailBytes : 0) : offset;
        if (start >= length) return SpeechBatch(const [], length);

        raf.setPositionSync(start);
        final bytes = raf.readSync(length - start);

        // ⚠️ **마지막 개행까지만 삼킨다.** jsonl 한 줄이 쓰이는 중일 수 있는데,
        // 반쯤 쓰인 줄을 소비해 버리면 그 말은 영영 못 읽는다.
        var end = bytes.length;
        while (end > 0 && bytes[end - 1] != 0x0A) {
          end--;
        }
        if (end == 0) return SpeechBatch(const [], start);

        var text = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
        // 꼬리부터 잘라 읽었으면 첫 줄은 잘린 조각이라 버린다.
        if (fresh && start > 0) {
          final nl = text.indexOf('\n');
          text = nl < 0 ? '' : text.substring(nl + 1);
        }

        final rows = <Map<String, dynamic>>[];
        for (final line in const LineSplitter().convert(text)) {
          if (line.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map<String, dynamic>) rows.add(decoded);
          } catch (_) {
            // 깨진 줄 하나쯤은 넘긴다
          }
        }

        // 처음 읽는 것이라면 마지막 사람 발화 뒤에 나온 것만 올린다.
        // 앱을 켜자마자 지난 턴들이 말풍선으로 쏟아지면 대화가 아니라 로그가 된다.
        var from = 0;
        if (fresh) {
          for (var i = rows.length - 1; i >= 0; i--) {
            final message = rows[i]['message'];
            if (rows[i]['type'] == 'user' &&
                message is Map &&
                _isHumanTurn(message['content'])) {
              from = i + 1;
              break;
            }
          }
        }

        final out = <Speech>[];
        int? tokens;
        String? model;
        // 처음 읽을 때는 말풍선과 달리 모델은 지난 턴 것도 줍는다 — 켜자마자 캐릭터 옆이 비지 않게.
        if (fresh) {
          for (final row in rows) {
            final message = row['message'];
            if (row['type'] != 'assistant' || row['isSidechain'] == true || message is! Map) continue;
            final m = message['model'];
            if (m is String && m.startsWith('claude')) model = m;
          }
        }
        for (var i = from; i < rows.length; i++) {
          final row = rows[i];
          if (row['type'] != 'assistant') continue;
          // 서브에이전트가 제 안에서 한 말은 이 대화가 아니다.
          if (row['isSidechain'] == true) continue;
          final message = row['message'];
          if (message is! Map) continue;
          // 컨텍스트 크기는 **말이 없는 줄에도** 들어 있다(도구만 쓴 응답).
          // 그래서 uuid·본문을 보기 전에 먼저 챙긴다.
          tokens = contextTokensOf(message['usage']) ?? tokens;
          // 오류 안내 같은 가짜 응답은 `<synthetic>`으로 온다 — 모델이 바뀐 것이 아니다.
          final m = message['model'];
          if (m is String && m.startsWith('claude')) model = m;
          final uuid = row['uuid'];
          if (uuid is! String || uuid.isEmpty) continue;
          final body = _textOf(message['content'])?.trim();
          if (body == null || body.isEmpty) continue;
          out.add(Speech(uuid: uuid, text: body));
        }

        return SpeechBatch(out, start + end, contextTokens: tokens, model: model);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      debugPrint('transcript 증분 읽기 실패 $path: $e');
      return null;
    }
  }

  /// 무슨 도구를 몇 번 썼고 어떤 파일을 건드렸는지 모은다.
  ///
  /// 응답 본문만으로는 "무슨 일을 했는지"가 남지 않는다. 도구를 열 번 쓰고
  /// 마지막에 한 줄만 말하는 턴이 흔해서, 그 한 줄만 보면 내용이 비어 보인다.
  static void _collectTools(
      dynamic content, Map<String, int> counts, List<String> files) {
    if (content is! List) return;
    for (final block in content) {
      if (block is! Map || block['type'] != 'tool_use') continue;
      final name = block['name'];
      if (name is! String) continue;
      final short = _shortToolName(name);
      counts[short] = (counts[short] ?? 0) + 1;

      final input = block['input'];
      if (input is Map) {
        final path = input['file_path'] ?? input['notebook_path'];
        if (path is String && path.isNotEmpty && !files.contains(path)) {
          files.add(path);
        }
      }
    }
  }

  /// 사람이 직접 친 발화인지. 도구 결과는 아니다.
  static bool _isHumanTurn(dynamic content) {
    if (content is String) return true;
    if (content is List) {
      return !content.any((c) => c is Map && c['type'] == 'tool_result');
    }
    return false;
  }

  /// text 블록만 이어 붙인다. thinking과 tool_use는 사람이 읽을 본문이 아니다.
  static String? _textOf(dynamic content) {
    if (content is String) return content;
    if (content is! List) return null;
    final parts = <String>[];
    for (final block in content) {
      if (block is Map && block['type'] == 'text' && block['text'] is String) {
        parts.add(block['text'] as String);
      }
    }
    return parts.isEmpty ? null : parts.join('\n');
  }
}

/// 도구 호출 하나를 한 줄로 줄인다 — `Bash · flutter test`.
///
/// 도구 이름만으로는 무슨 일인지 모른다. `Edit`이 열 번 찍히는 것보다
/// 무슨 파일을 고쳤는지가 보여야 쓸모가 있다.
String toolSummary(String tool, Object? input) {
  if (input is! Map) return tool;
  String? pick(String key) {
    final v = input[key];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  // 경로는 파일 이름만 남긴다. 절대경로를 다 적으면 한 줄을 통째로 먹는다.
  String? base(String? path) =>
      path?.split('/').where((e) => e.isNotEmpty).lastOrNull;

  final detail = switch (tool) {
    'Bash' => pick('command'),
    'Read' || 'Edit' || 'Write' || 'NotebookEdit' => base(pick('file_path')),
    'Grep' || 'Glob' => pick('pattern'),
    'Task' || 'Agent' => pick('description'),
    'WebFetch' => pick('url'),
    'WebSearch' => pick('query'),
    _ => null,
  };
  if (detail == null) return tool;
  // 첫 줄만, 그리고 너무 길면 자른다. 말풍선이 아니라 한 줄짜리 표시다.
  var one = detail.split('\n').first.trim();
  if (one.length > 60) one = '${one.substring(0, 60)}…';
  return one.isEmpty ? tool : '$tool · $one';
}

/// 입력창에 `/`를 쳤을 때 내걸 슬래시 명령.
class SlashCommand {
  const SlashCommand(this.name, this.hint);
  final String name;
  final String hint;
}

/// **자주 쓰는 것만** 내건다.
///
/// 클로드 코드의 슬래시 명령은 수십 개다. 전부 늘어놓으면 고르는 데
/// 터미널보다 오래 걸려서 내건 보람이 없다. 여기 없는 것도 그냥 쳐서
/// 보내면 그대로 동작한다 — 목록은 거들 뿐이다.
const List<SlashCommand> kSlashCommands = [
  SlashCommand('/clear', '대화를 비운다'),
  SlashCommand('/compact', '지금까지를 요약해 컨텍스트를 줄인다'),
  SlashCommand('/context', '컨텍스트를 얼마나 쓰고 있는지 본다'),
  SlashCommand('/model', '모델을 고른다'),
  SlashCommand('/effort', '얼마나 깊이 생각할지 고른다'),
  SlashCommand('/resume', '지난 대화를 이어서 연다'),
  SlashCommand('/rewind', '앞선 턴으로 되돌린다'),
  SlashCommand('/agents', '서브에이전트를 관리한다'),
];

/// 이 맥에 깔린 **슬래시 명령**을 찾아 온다 — 내 명령(`~/.claude/commands`)과 플러그인 명령.
///
/// ⚠️ 붙박이 여덟 개만 내걸던 때는, 플러그인으로 깔아 둔 것(`/ponytail-review` 같은)이 목록에 없어
/// 대표가 `>ponytail-review`처럼 다른 모양으로 쳤다가 아무 반응도 못 봤다(제보 9/16).
/// **부르는 모양은 하나다 — 슬래시(`/`)로 시작한다.** 그것을 목록이 직접 보여 준다.
///
/// 찾는 자리
/// - `~/.claude/commands/*.md` · `*.toml` — 사람이 만든 명령
/// - `~/.claude/plugins/cache/<장터>/<플러그인>/<판>/commands/*` — 플러그인이 들고 온 명령
///
/// 설명은 toml의 `description`, md의 앞머리(`description:`) 또는 첫 줄에서 뽑는다. 못 찾으면 어디서 왔는지만 적는다.
List<SlashCommand> discoverSlashCommands() {
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return const [];
  final found = <String, SlashCommand>{};
  String? describe(File f) {
    try {
      final head = f.readAsLinesSync().take(12);
      for (final line in head) {
        final t = line.trim();
        final m = RegExp(r'^description\s*[:=]\s*(.+)$').firstMatch(t);
        if (m != null) return m[1]!.replaceAll(RegExp(r'^["\x27]|["\x27],?$'), '').trim();
      }
    } catch (_) {}
    return null;
  }

  void scan(Directory dir, String from) {
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.md') && !name.endsWith('.toml')) continue;
      final stem = name.substring(0, name.lastIndexOf('.'));
      if (stem.isEmpty || stem.startsWith('.') || stem.toUpperCase() == 'README') continue;
      final hint = describe(f) ?? from;
      found.putIfAbsent('/$stem', () => SlashCommand('/$stem', hint.length > 60 ? '${hint.substring(0, 60)}…' : hint));
    }
  }

  scan(Directory('$home/.claude/commands'), '내 명령');
  final cache = Directory('$home/.claude/plugins/cache');
  if (cache.existsSync()) {
    for (final market in cache.listSync().whereType<Directory>()) {
      for (final plugin in market.listSync().whereType<Directory>()) {
        for (final ver in plugin.listSync().whereType<Directory>()) {
          scan(Directory('${ver.path}/commands'), '플러그인 ${plugin.uri.pathSegments[plugin.uri.pathSegments.length - 2]}');
        }
      }
    }
  }
  final list = found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return list;
}

/// 붙박이 + 이 맥에 깔린 것. 30초마다 다시 훑지 않고 **켤 때 한 번** 본다(파일이 늘어나는 일은 드물다).
List<SlashCommand> _slashAll = kSlashCommands;
List<SlashCommand> get slashCommands => _slashAll;
void loadSlashCommands() {
  try {
    final more = discoverSlashCommands();
    final seen = {for (final c in kSlashCommands) c.name};
    _slashAll = [...kSlashCommands, ...more.where((c) => !seen.contains(c.name))];
    debugPrint('슬래시 명령 ${_slashAll.length}개 (붙박이 ${kSlashCommands.length} + 깔린 것 ${_slashAll.length - kSlashCommands.length})');
  } catch (e) {
    debugPrint('슬래시 명령 훑기 실패: $e');
  }
}

/// 지금 친 글자로 목록을 추린다. `/`만 쳤으면 전부 준다.
List<SlashCommand> matchSlash(String text) {
  final t = text.trim();
  if (!t.startsWith('/')) return const [];
  // 공백이 들어갔으면 이미 인자를 쓰는 중이다. 그때 목록이 뜨면 방해만 된다.
  if (t.contains(' ')) return const [];
  return [
    for (final c in slashCommands)
      if (c.name.startsWith(t)) c
  ];
}

/// 입력창 끝에 쓰다 만 `@…`이 있으면 그 토큰을 준다.
///
/// 커서 앞이 아니라 **글 끝**을 본다. 붙여넣기나 중간 편집까지 따라가면
/// 목록이 엉뚱한 자리에서 튀어나온다 — `@`를 치고 이어서 쓰는 흔한 경우만
/// 받는 편이 예측하기 쉽다.
/// 끌어다 놓은 파일을 입력창에 박을 `@토큰`으로 바꾼다.
///
/// **절대경로를 통째로 박으면 한 줄을 다 먹는다.** 그 세션 폴더 아래면
/// 상대경로로 줄인다 — `@lib/main.dart`처럼 짧고, 클로드 코드가 cwd 기준으로
/// 읽으므로 그대로 통한다.
///
/// ⚠️ **한글 경로는 표기를 맞춰야 한다.** macOS가 주는 경로는 자모가 분리된
/// NFD인데 등록 경로는 완성형(NFC)이라, 그냥 비교하면 같은 폴더인데도
/// 남남으로 잡혀 절대경로가 박힌다.
String dropToken(String filePath, String sessionPath) {
  final file = ProjectStore.normalize(filePath);
  final root = ProjectStore.normalize(sessionPath);
  // 세션 폴더 **아래**일 때만 줄인다. 폴더 자기 자신이거나 밖이면 절대경로다 —
  // 어설프게 `..`로 거슬러 올라가면 읽기만 더 어렵다.
  if (file.length > root.length + 1 && file.startsWith('$root/')) {
    return '@${file.substring(root.length + 1)}';
  }
  return '@$file';
}

/// 클립보드에 있는 그림을 파일로 떠온다. 없으면 `null`.
///
/// **네이티브 코드를 안 붙인다.** Flutter의 `Clipboard`는 글자만 읽으므로
/// 그림을 읽으려면 플랫폼 채널이 필요한데, `osascript` 한 줄이면 되는 일에
/// Swift를 끼워 넣으면 확인할 곳만 늘어난다. 여기는 얇은 껍데기다.
///
/// ⚠️ **세션이 열린 폴더(남의 저장소)에 떨구지 않는다.** 그 폴더는 동현동현의
/// 작업물이 있는 곳이고, 붙여넣을 때마다 PNG가 하나씩 늘면 깃이 그걸 다
/// 잡는다. 다른 설정 파일과 같은 자리(`resolveConfigPath`)에 모아두고
/// gitignore에 걸어 둔다. 설정 파일을 옮길 때 같이 딸려가는 것이 덤이다.
class ClipboardImage {
  /// 붙여넣은 그림을 모아두는 곳.
  static String get dirPath => resolveConfigPath(
      kIsDevInstance ? 'pasted.dev$kPort' : 'pasted');

  /// 파일 이름. 겹치지 않게 시각을 쓴다.
  static String nameFor(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}.png';
  }

  /// 클립보드를 PNG로 떠서 파일 경로를 돌려준다. 그림이 없으면 `null`.
  static Future<String?> save() async {
    final dir = Directory(dirPath);
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      debugPrint('붙여넣기 폴더를 못 만들었다: $e');
      return null;
    }
    final path = '$dirPath/${nameFor(DateTime.now())}';
    try {
      // ⚠️ 그림이 없으면 osascript가 오류로 끝난다. 그게 정상 흐름이다 —
      // 글자를 붙여넣는 평소 경우라 조용히 넘긴다.
      final r = await Process.run('osascript', [
        '-e', 'set p to POSIX file "$path"',
        '-e', 'set d to (the clipboard as «class PNGf»)',
        '-e', 'set f to open for access p with write permission',
        '-e', 'set eof f to 0',
        '-e', 'write d to f',
        '-e', 'close access f',
      ]);
      if (r.exitCode != 0) return null;
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) {
        // 빈 파일이 남으면 폴더만 더럽힌다.
        try {
          file.deleteSync();
        } catch (_) {}
        return null;
      }
      unawaited(sweep());
      return path;
    } catch (e) {
      debugPrint('클립보드 그림 읽기 실패: $e');
      return null;
    }
  }

  /// 오래된 것을 치운다. 붙여넣을 때마다 하나씩 늘어나므로 그냥 두면 쌓인다.
  ///
  /// 이레는 남긴다 — 어제 붙여넣은 그림을 오늘 다시 짚는 일이 있다.
  static Future<void> sweep({Duration keep = const Duration(days: 7)}) async {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now().subtract(keep);
      for (final f in dir.listSync()) {
        // 이 폴더는 붙여넣기·대시보드 올리기만 쓴다 — 그림이 아닌 것도 같이 치운다.
        if (f is! File) continue;
        if (f.statSync().modified.isBefore(cutoff)) f.deleteSync();
      }
    } catch (e) {
      debugPrint('붙여넣은 그림 치우기 실패: $e');
    }
  }
}

String? atToken(String text) {
  final at = text.lastIndexOf('@');
  if (at < 0) return null;
  final token = text.substring(at + 1);
  // 공백이 들어갔으면 파일 이름은 끝난 것이다.
  if (token.contains(' ') || token.contains('\n')) return null;
  return token;
}

/// 친 글자로 파일을 추린다.
///
/// **파일 이름에 걸린 것이 먼저다.** 경로 어딘가에 걸린 것보다 찾던 것일
/// 확률이 높다. `main`을 쳤을 때 `lib/main.dart`가 `main_test/foo.txt`보다
/// 위에 와야 한다.
List<String> matchFiles(List<String> files, String token, {int max = 8}) {
  final t = token.toLowerCase();
  if (t.isEmpty) return files.take(max).toList();
  final byName = <String>[];
  final byPath = <String>[];
  for (final f in files) {
    final base = f.split('/').last.toLowerCase();
    if (base.contains(t)) {
      byName.add(f);
    } else if (f.toLowerCase().contains(t)) {
      byPath.add(f);
    }
    if (byName.length >= max) break;
  }
  return [...byName, ...byPath].take(max).toList();
}

/// 세션 폴더의 파일 목록. `@`로 집어 넣을 때 쓴다.
class FileIndex {
  static final Map<String, List<String>> _cache = {};
  static final Map<String, DateTime> _at = {};
  /// 파일이 늘거나 줄어도 이만큼 지나면 다시 훑는다.
  static const Duration _ttl = Duration(seconds: 30);

  /// 훑어서 상대경로 목록을 준다. 실측으로 둘 다 20ms 안쪽이었다(2026-08-06).
  ///
  /// git 저장소면 `git ls-files`가 낫다 — 빠르고 `.gitignore`를 이미 반영해서
  /// `build/`나 `node_modules` 같은 것이 안 섞인다. 저장소가 아니면 `find`로
  /// 훑되 **깊이를 4로 묶고 숨김 폴더를 뺀다.** 제한이 없으면 큰 폴더에서
  /// 목록이 수만 개가 되어 고를 수 없게 된다.
  static Future<List<String>> list(String dir) async {
    final cached = _cache[dir];
    final at = _at[dir];
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    var out = <String>[];
    try {
      // ⚠️ `core.quotepath=false`가 없으면 한글 경로가 `"docs/tmux_\352\262…"`처럼 따옴표·8진수로 나와
      // 한글로 쳐서는 하나도 안 걸렸다(대표 QA 9/15 — 대시보드 `@`가 안 뜬다). 자모가 풀린 이름도 모아 쓴다.
      final git = await Process.run('git', ['-c', 'core.quotepath=false', '-C', dir, 'ls-files'],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      if (git.exitCode == 0) {
        out = const LineSplitter()
            .convert(git.stdout as String)
            .where((e) => e.trim().isNotEmpty)
            .map(ProjectStore.composeHangul)
            .toList();
      }
    } catch (_) {
      // git이 없을 수도 있다. 아래로 넘어간다.
    }
    if (out.isEmpty) {
      try {
        final found = await Process.run('find', [
          dir, '-maxdepth', '4', '-type', 'f', '-not', '-path', '*/.*',
        ],
          stdoutEncoding: utf8, stderrEncoding: utf8);
        if (found.exitCode == 0) {
          final prefix = dir.endsWith('/') ? dir : '$dir/';
          out = const LineSplitter()
              .convert(found.stdout as String)
              .where((e) => e.trim().isNotEmpty)
              .map((e) => e.startsWith(prefix) ? e.substring(prefix.length) : e)
              .map(ProjectStore.composeHangul)
              .toList();
        }
      } catch (e) {
        debugPrint('파일 훑기 실패 $dir: $e');
      }
    }
    out.sort();
    _cache[dir] = out;
    _at[dir] = DateTime.now();
    return out;
  }
}

/// 메시지 한 줄이 어떤 종류인가.
enum ChatKind {
  /// 내가 보낸 말.
  mine,

  /// 그 세션의 클로드가 한 말.
  reply,

  /// 도구를 하나 썼다. 턴이 끝나기 전에도 쌓여 진행이 보인다.
  tool,

  /// **선택창에서 고른 답.** 내가 친 말과 같은 자리에 서지만 모양이 다르다 —
  /// 둘이 똑같이 보이면 나중에 대화를 되짚을 때 무엇이 내 말이고 무엇이 고른 것인지 못 가른다(UI 리뷰 9/18).
  chose,
}

/// 메시지 탭에 쌓이는 대화 한 줄.
class ChatEntry {
  ChatEntry({required this.kind, required this.text, this.turn, DateTime? at})
      : at = at ?? DateTime.now();

  final ChatKind kind;
  final String text;

  /// 내가 보낸 것인지. **고른 답도 내 쪽이다** — 오른쪽에 선다.
  bool get mine => kind == ChatKind.mine || kind == ChatKind.chose;

  /// 그 턴에 무슨 도구를 썼는지 (상대 쪽에만 붙는다).
  final TurnReport? turn;
  final DateTime at;

  /// 디스크에 남길 모양.
  ///
  /// `turn`(도구 요약)은 남기지 않는다. 파일만 커지고, 다시 띄웠을 때
  /// 말풍선 위 꼬리표가 없어도 대화를 읽는 데 지장이 없다.
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'text': text,
        'at': at.toIso8601String(),
      };

  static ChatEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.isEmpty) return null;
    final kind = ChatKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (kind == null) return null;
    return ChatEntry(
      kind: kind,
      text: text,
      at: DateTime.tryParse(raw['at'] as String? ?? ''),
    );
  }
}

/// 세션마다 주고받은 것을 디스크에 남긴다.
///
/// 대화가 메모리에만 있으면 앱을 껐다 켤 때마다 통째로 사라진다.
/// 위젯은 오래 띄워 두는 물건이라 그럴 일이 드물 것 같지만, 고치고 다시
/// 띄우는 날에는 하루에도 몇 번씩 날아간다.
///
/// **세션 키(cwdPath)별로 나눠 담는다.** 한 파일에 전부 담으면 세션 하나가
/// 길어질 때 다른 세션까지 같이 무거워진다.
/// 진행상태의 큰 분류. **넷이다** — 노션 status 타입은 셋(To-do·In progress·
/// Complete)으로 고정이라 원하는 대로 못 나눴던 것을 여기서 나눈다(2026-09-14).
enum TaskGroup {
  todo('시작 전'),
  inProgress('진행중'),
  paused('일시정지'),
  complete('완료');

  const TaskGroup(this.label);
  final String label;
}

/// 진행상태. **대표가 큰 분류 / 작은 분류로 다시 짰다(2026-09-14).**
///
/// | 큰 분류 | 작은 분류 | 뜻 |
/// |---|---|---|
/// | 시작 전 | 백로그 · 오늘예정 · 세션예정 | 적어만 둠 · 대표가 오늘 할 일 · 세션에 넘길 일 |
/// | 진행중 | 진행중 · 확인필요 · 수정요청 | 하는 중 · **대표 차례** · **세션 차례** |
/// | 일시정지 | 일시정지 | 멈춰 둠 |
/// | 완료 | 완료 · 대기 | 끝 · 끝났지만 결과 확인이 남았거나 외부 때문에 다음이 막힘 |
///
/// ⚠️ **대기는 끝난 것이 아니다**([isClosed]가 거짓). 완료 칸 옆에 두지만 목록
/// 아래로 내리지 않고 완료 날짜도 안 찍는다 — 내리면 잊힌다.
///
/// 노션에는 이 구분이 없다. 노션에서 온 값은 [_legacy]로 옮겨 읽고, 노션에
/// 쓸 때(노션이사 6/6)는 가장 가까운 값으로 보낸다 — 세션예정→클로드코드작업,
/// 대기→일시 중지.
///
/// 식별자(`name`)는 저장 파일에 들어간다. 옛 파일을 계속 읽으려고 `waiting`
/// (예전 `대기`·`시작 전`)은 이름을 바꾸지 않고 `백로그`에 둔다.
enum TaskStatus {
  waiting('백로그', TaskGroup.todo, 'default'),
  today('오늘예정', TaskGroup.todo, 'yellow'),
  sessionPlanned('세션예정', TaskGroup.todo, 'purple'),
  running('진행중', TaskGroup.inProgress, 'blue'),
  review('확인필요', TaskGroup.inProgress, 'pink'),
  revision('수정요청', TaskGroup.inProgress, 'orange'),
  paused('일시정지', TaskGroup.paused, 'gray'),
  done('완료', TaskGroup.complete, 'green'),
  blocked('대기', TaskGroup.complete, 'brown');

  const TaskStatus(this.label, this.group, this.color);
  final String label;
  final TaskGroup group;

  /// 노션 색 이름. 할 일 페이지가 같은 색으로 칠한다(`c-orange`).
  final String color;

  /// 끝난 것으로 볼지. 목록에서 아래로 내리고 개수에서 뺀다.
  /// **완료만이다** — 같은 묶음의 대기는 아직 살아 있다.
  bool get isClosed => this == TaskStatus.done;

  /// 옛 판·노션에서 오는 값. 파일과 노션에 남아 있다.
  static const Map<String, TaskStatus> _legacy = {
    '시작 전': TaskStatus.waiting,
    'held': TaskStatus.paused,
    '일시 중지': TaskStatus.paused,
    'promptPending': TaskStatus.waiting,
    '프롬프트작업전': TaskStatus.waiting,
    'claudeWork': TaskStatus.sessionPlanned,
    '클로드코드작업': TaskStatus.sessionPlanned,
    'designWork': TaskStatus.running,
    '디자인작업': TaskStatus.running,
    'designFeedback': TaskStatus.revision,
    '디자인 피드백 수정': TaskStatus.revision,
    'designReview': TaskStatus.review,
    '디자인 검토중': TaskStatus.review,
  };

  static TaskStatus parse(Object? raw) {
    if (raw is! String) return TaskStatus.waiting;
    for (final s in TaskStatus.values) {
      if (s.name == raw || s.label == raw) return s;
    }
    return _legacy[raw] ?? TaskStatus.waiting;
  }
}

/// 대표가 바꾼 것을 세션에 한 번씩 알린다 — `UserPromptSubmit` 훅의 답으로 끼워 넣는다.
///
/// 세션마다 어디까지 알렸는지(커서)를 들고, **바뀐 게 있을 때만** 한 줄씩 준다.
/// 처음 보는 세션은 지금부터 센다 — 켜기 전의 일은 그 세션이 API로 읽으면 된다.
/// 범위는 세션 API와 같다([ApiScope]) — 남의 프로젝트 소식은 안 준다.
/// 메모리에만 둔다. 위젯을 다시 켜면 못 알린 것은 버려진다(세션이 다시 읽으면 된다).
class OwnerNotices {
  final List<(int, DateTime, TodoItem, String)> _items = [];
  final Map<String, int> _cursor = {};
  int _seq = 0;

  void add(TodoItem task, String text) {
    _items.add((++_seq, DateTime.now(), task, text));
    if (_items.length > 300) _items.removeRange(0, _items.length - 300);
  }

  /// 훅이 올 때마다 부른다. 처음 보는 세션이면 지금 위치에 커서를 둔다.
  void see(String sessionId) {
    if (sessionId.isNotEmpty) _cursor.putIfAbsent(sessionId, () => _seq);
  }

  /// 그 세션에 아직 안 알린 것. 없으면 빈 글자다.
  String takeFor(String sessionId, String cwd, List<ProjectRow> projects) {
    if (sessionId.isEmpty) return '';
    final from = _cursor[sessionId] ?? _seq;
    _cursor[sessionId] = _seq;
    final scope = ApiScope.of(cwd, projects);
    if (scope == null) return '';
    final mine = _items.where((e) => e.$1 > from && scope.allows(e.$3)).toList();
    if (mine.isEmpty) return '';
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final lines = [for (final e in mine.take(8)) '- ${hm(e.$2)} ${e.$4}'];
    if (mine.length > 8) lines.add('- … 외 ${mine.length - 8}건');
    return '[Madang] 대표가 할 일 페이지에서 바꾼 것 — 이 태스크들의 상태는 이 값을 따른다:\n'
        '${lines.join('\n')}\n';
  }
}

final OwnerNotices kOwnerNotices = OwnerNotices();

/// 사무실 꾸밈 — 세션 별명과 층 순서(대표 요청 9/18). `office_layout.json`에 둔다.
///
/// - **별명은 화면에 보이는 이름만 바꾼다.** 폴더·tmux 세션 이름·그림 폴더(`art/chars/<폴더>`)는
///   그대로다 — tmux 이름 규칙은 `tmux_up.py`와 짝이라 건드리면 위젯이 엉뚱한 세션을 본다(2절).
/// - **세션이 제 이름을 알아듣게** `UserPromptSubmit` 답에 한 번 끼워 준다. session_id마다
///   마지막으로 알린 이름을 들고 있어서, 새로 켠 세션도 첫 말에서 이름을 받는다.
/// - 층 순서: 이사 층은 **언제나 맨 위**다. 여기 적힌 것은 그 아래 팀 층의 차례뿐이다.
class OfficeLayout {
  OfficeLayout._(this._file, this.names, this.order);

  final File _file;
  /// 세션 폴더(cwdPath) → 별명.
  final Map<String, String> names;
  /// 팀 층(칸 주인 경로)의 위→아래 차례. 없는 것은 원래 순서대로 뒤에 붙는다.
  final List<String> order;
  /// session_id → 마지막으로 알린 이름(지웠으면 빈 글자).
  final Map<String, String> _told = {};

  /// 테스트용 — 파일을 직접 물린다. 진짜 설정 자리를 건드리지 않는다.
  factory OfficeLayout.at(String path) => OfficeLayout._(File(path), {}, []);

  static OfficeLayout load() {
    final f = File(resolveConfigPath(
        kIsDevInstance ? 'office_layout.dev$kPort.json' : 'office_layout.json'));
    final names = <String, String>{};
    final order = <String>[];
    try {
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) {
          final n = j['names'];
          if (n is Map) {
            n.forEach((k, v) {
              if (k is String && v is String && v.trim().isNotEmpty) {
                names[ProjectStore.composeHangul(k)] = v.trim();
              }
            });
          }
          final o = j['order'];
          if (o is List) order.addAll(o.whereType<String>().map(ProjectStore.composeHangul));
        }
      }
    } catch (e) {
      debugPrint('사무실 꾸밈 읽기 실패: $e');
    }
    return OfficeLayout._(f, names, order);
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(const JsonEncoder.withIndent('  ')
          .convert({'names': names, 'order': order}));
    } catch (e) {
      debugPrint('사무실 꾸밈 저장 실패: $e');
    }
  }

  String? nameOf(String cwdPath) => names[ProjectStore.composeHangul(cwdPath)];

  /// 빈 글자면 별명을 지운다. 30자까지.
  String? rename(String cwdPath, String name) {
    final key = ProjectStore.composeHangul(cwdPath);
    final v = ProjectStore.composeHangul(name.trim());
    if (v.length > 30) return '이름은 30자까지다';
    if (v.isEmpty) {
      names.remove(key);
    } else {
      names[key] = v;
    }
    _save();
    return null;
  }

  /// 팀 층들을 대표가 정한 차례로. 이사 층은 호출하는 쪽이 맨 위에 둔다.
  List<Floor> arrange(List<Floor> floors) {
    int rank(Floor f) {
      final i = order.indexOf(ProjectStore.composeHangul(f.rootPath));
      return i < 0 ? order.length + floors.indexOf(f) : i;
    }
    final teams = floors.where((f) => !f.top).toList()
      ..sort((a, b) => rank(a).compareTo(rank(b)));
    return [...floors.where((f) => f.top), ...teams];
  }

  /// 팀 층 하나를 한 칸 위(-1)·아래(+1)로. 지금 보이는 층 목록을 기준으로 차례를 다시 적는다.
  String? move(List<Floor> floors, String rootPath, int dir) {
    final teams = arrange(floors).where((f) => !f.top)
        .map((f) => ProjectStore.composeHangul(f.rootPath)).toList();
    final key = ProjectStore.composeHangul(rootPath);
    final i = teams.indexOf(key);
    if (i < 0) return '그 층이 없다 — 이사 층은 맨 위에 고정이다';
    final j = i + dir;
    if (j < 0 || j >= teams.length) return null;
    teams[i] = teams[j];
    teams[j] = key;
    // 지금 안 보이는(세션 없는) 층의 기억은 뒤에 남겨 둔다.
    order
      ..removeWhere(teams.contains)
      ..insertAll(0, teams);
    _save();
    return null;
  }

  /// 이 세션에 아직 안 알린 이름 소식. 없으면 빈 글자.
  String noticeFor(String sessionId, String cwdPath, String folderName) {
    if (sessionId.isEmpty || cwdPath.isEmpty) return '';
    final now = nameOf(cwdPath) ?? '';
    final before = _told[sessionId];
    _told[sessionId] = now;
    if (now.isEmpty) {
      if (before == null || before.isEmpty) return '';
      return '[Madang] 대표가 이 세션의 별명을 지웠다. 이제 폴더 이름 「$folderName」으로 부른다.\n';
    }
    if (before == now) return '';
    return '[Madang] 이 세션(폴더 「$folderName」)의 이름은 「$now」이다. '
        '대표가 대화에서 「$now」라고 부르면 바로 이 세션을 말하는 것이다. 자기를 소개할 때도 이 이름을 쓴다.\n';
  }
}

final OfficeLayout kOffice = OfficeLayout.load();

/// 세션이 멈추면서 남긴 메모. 시계가 멈춰 구간이 생길 때 그 줄에 붙는다.
final Map<String, String> kPendingMemo = {};

/// 담당이 대표라는 표시. 세션이 담당이면 그 세션의 키(`cwdPath`)가 들어간다.
const String kOwnerAssignee = 'owner';

/// 우선순위. **노션의 네 단계를 그대로 옮겼다** — 타임기록·🔥·🔥🔥·🔥🔥🔥.
///
/// 노션에서 새 페이지를 만들면 `🔥`가 들어간다. 그래서 기본값도 [one]이다.
enum TaskPriority {
  timeLog('타임기록', 'gray'),
  one('🔥', 'purple'),
  two('🔥🔥', 'pink'),
  three('🔥🔥🔥', 'red');

  const TaskPriority(this.label, this.color);
  final String label;
  final String color;

  /// 카드에 붙일 표시. **기본값(🔥)과 타임기록에는 안 붙인다** — 전부에
  /// 불이 붙어 있으면 불이 아무 뜻도 없다.
  String get mark => index >= TaskPriority.two.index ? label : '';

  /// 옛 판(두 단계 시절)의 값. `urgent`는 가장 높은 단계로 올린다.
  static TaskPriority parse(Object? raw) {
    if (raw == 'urgent') return TaskPriority.three;
    for (final p in TaskPriority.values) {
      if (p.name == raw || p.label == raw) return p;
    }
    return TaskPriority.one;
  }
}

/// 유형. **노션의 선택지 8개를 그대로 옮겼다.** 비워 둘 수 있다.
enum TaskKind {
  work('업무', 'orange'),
  content('콘텐츠', 'brown'),
  workTime('업무타임', 'pink'),
  planning('기획', 'blue'),
  design('디자인', 'purple'),
  dev('개발', 'green'),
  common('공통', 'gray'),
  marketing('마케팅', 'yellow');

  const TaskKind(this.label, this.color);
  final String label;
  final String color;

  static TaskKind? parse(Object? raw) {
    for (final k in TaskKind.values) {
      if (k.name == raw || k.label == raw) return k;
    }
    return null;
  }
}

/// 날짜만 남긴다. 시각까지 두면 마감일이 아니라 알람이 된다.
DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

/// 마감일을 사람이 읽는 모양으로. 카드 한 줄에 들어가야 하므로 짧게 쓴다.
String formatDue(DateTime due, DateTime now) {
  final days = dateOnly(due).difference(dateOnly(now)).inDays;
  if (days == 0) return '오늘';
  if (days == 1) return '내일';
  if (days == -1) return '어제';
  if (days < 0) return '${-days}일 지남';
  if (days <= 7) return '$days일 뒤';
  return '${due.month}/${due.day}';
}

List<String> _ids(Object? raw) =>
    raw is List ? raw.whereType<String>().where((s) => s.isNotEmpty).toList() : const [];

/// 할 일 한 줄. **노션 업적모음 DB의 한 행과 칸이 1:1이다.**
///
/// | 노션 | 여기 |
/// |---|---|
/// | 이름 | [text] |
/// | 진행사항 · 우선순위 · 유형 | [status] · [priority] · [kind] |
/// | 하위프로젝트 | [project](책상 캐릭터 키) + [subprojectIds](노션 페이지 ID) |
/// | 거래처 · 세션 | [clientIds] · [sessionIds] (노션 페이지 ID) |
/// | 마감일 · 완료 날짜 | [due] · [doneDate] |
/// | 시작시간 · 최근 중지 시간 · 누적 시간(분) | [startedAt] · [stoppedAt] · [spentSec] |
/// | 프롬프트 · 작업 내용 · 수정사항 | [body] · [content] · [revisionNote] |
/// | 생성 일시 | [at] |
///
/// 롤업(첫 착수·마지막 작업·작업 횟수·총 시간·걸린 기간·거래처(자동))은
/// **값을 담지 않는다.** 세션 기록 DB가 생기면(노션이사 4/6) 거기서 계산한다.
/// 버튼(▶️·⏸️·✅)은 칸이 아니라 [Todos]의 동작이다.
///
/// 관계 칸은 프로젝트·회사·세션 DB가 워쳐에 생기기 전까지(3/6·4/6) **노션
/// 페이지 ID를 그대로 담아 둔다.** 옮겨온 뒤 이어 붙일 근거다.
///
/// ⚠️ **프로젝트가 필드다.** 예전에는 담긴 자리(맵의 키)가 프로젝트였는데,
/// 그러면 프로젝트를 옮길 수도 상태·시간으로 정렬할 수도 없다.
class TodoItem {
  TodoItem({
    required this.text,
    required this.project,
    this.status = TaskStatus.waiting,
    this.priority = TaskPriority.one,
    this.kind,
    this.body = '',
    this.content = '',
    this.revisionNote = '',
    this.due,
    this.doneDate,
    this.spentSec = 0,
    this.startedAt,
    this.stoppedAt,
    this.subprojectIds = const [],
    this.clientIds = const [],
    this.sessionIds = const [],
    this.notionId,
    this.assignee,
    this.projectId,
    this.statusAt,
    this.queuedAt,
    this.parentId,
    this.held = false,
    this.rounds = const [],
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// 작업명.
  final String text;

  /// 어느 프로젝트 것인가. 책상 캐릭터와 같은 키(`cwdPath`)다.
  final String project;

  final TaskStatus status;
  final TaskPriority priority;
  final TaskKind? kind;

  /// 시킬 내용. **`시키기`가 보내는 것이 이것이다.** 노션의 `프롬프트` 칸.
  final String body;

  /// 노션의 `작업 내용` 칸.
  final String content;

  /// 노션의 `수정사항` 칸.
  final String revisionNote;

  /// 마감일. 날짜만 남긴다.
  final DateTime? due;

  /// 완료 날짜. **완료로 옮길 때만 찍힌다** — 직접 넣는 길은 없다.
  /// 만들 때 넣으면 미완료인데 끝난 것처럼 보인다(루트 CLAUDE.md 6번-7).
  final DateTime? doneDate;

  /// 여태 쓴 시간(초). **재는 중인 몫은 여기 없다.** 노션에는 분으로 적는다.
  final int spentSec;

  /// 시작시간. **멈춰도 지우지 않는다** — 노션과 같다.
  final DateTime? startedAt;

  /// 최근 중지 시간. [startedAt]보다 뒤면 그 구간은 이미 누적에 들어갔다.
  final DateTime? stoppedAt;

  final List<String> subprojectIds;
  final List<String> clientIds;
  final List<String> sessionIds;

  /// 노션에서 옮겨왔거나 노션에도 쓴 태스크면 그 페이지 ID. 이중 쓰기의 짝이다.
  final String? notionId;

  /// 담당. [kOwnerAssignee]면 대표, 아니면 워쳐 세션의 키(`cwdPath`). 비어 있을 수 있다.
  ///
  /// 하위프로젝트(어느 일인가)와 따로 둔다 — 같은 프로젝트 일도 대표가 할 때와
  /// 세션이 할 때가 있다. 노션에는 없는 칸이다.
  final String? assignee;

  /// 프로젝트 목록(`ProjectDb`)의 ID. [project](폴더)와 따로 둔다 — 폴더 없는
  /// 외주 프로젝트의 할 일은 폴더가 비고 이 칸으로만 프로젝트에 붙는다.
  final String? projectId;

  /// 진행사항을 마지막으로 옮긴 시각. 「어제 못 한 오늘예정」을 가르는 근거다.
  /// 이 칸이 생기기 전(2026-09-14)의 할 일은 비어 있고, 그때는 적은 시각으로 친다.
  final DateTime? statusAt;

  /// 「시키기」 줄에 선 시각. 비어 있으면 줄에 없다. **파일에 남는다** — 위젯을 다시
  /// 켜도 줄이 사라지지 않는다([SendQueue]).
  final DateTime? queuedAt;

  /// 상위 태스크의 ID(적은 시각). 비어 있으면 맨 위 태스크다. **한 단계뿐이다** —
  /// 하위의 하위는 만들지 않는다([TaskTree.parentRefusal]). 노션에서 제목 번호(1/6~6/6)로
  /// 버티던 묶음을 대신한다(대표 결정 9/15).
  final String? parentId;

  /// 세션이 API(`tasks/start`)로 스스로 시작한 시계인가. **그러면 턴 끝(`Stop`)에 멈추지 않는다.**
  /// 대표와 여러 번 주고받는 기획은 첫 답에서 턴이 끝나 시계가 3분에 멈췄다(오타쿠 로그, 9/15).
  /// 이 시계는 세션이 `tasks/stop`을 부르거나, 다른 태스크를 시작하거나, 세션이 끝날 때 멈춘다.
  /// 「시키기」·화면의 ▶️로 돈 시계는 예전처럼 턴 끝에 멈춘다. 멈추면 지운다.
  final bool held;

  /// 지난 회차(오래된 것부터). 수정요청을 받아 다시 시작하는 순간 그때까지의 작업 내용과 수정사항이
  /// 한 회차로 묶여 여기로 가고, [content]·[revisionNote]는 새 회차로 비워진다([TodoStore.nextRound]).
  /// 수정을 오갈 때마다 작업 내용 한 칸에 계속 쌓여 읽기 어려웠다(대표 요청 9/15). 지금 회차 = 길이 + 1.
  final List<TaskRound> rounds;

  /// 적은 시각(생성 일시). **이것이 열쇠다** — 글자는 겹쳐도 시각은 안 겹친다.
  final DateTime at;

  bool get done => status.isClosed;

  /// 재는 중인가. **노션의 규칙 그대로다** — 시작시간이 있고, 최근 중지 시간이
  /// 없거나 그보다 앞이면 돌고 있다.
  ///
  /// ⚠️ **진행중일 때만 돈다.** 노션에서 옮겨온 태스크 중에 시작시간만 있고
  /// 중지가 안 찍힌 채 확인필요로 넘어간 것이 있었다(2026-09-14). 그대로 두면
  /// 사흘 전부터 도는 것으로 보이고, 그 세션의 다음 `Stop`이 사흘치를 누적에 박는다.
  bool get ticking =>
      status == TaskStatus.running &&
      startedAt != null &&
      (stoppedAt == null || startedAt!.isAfter(stoppedAt!));

  bool get urgent => priority.index >= TaskPriority.two.index;

  /// 마감일이 지났나. **끝난 것은 지났다고 하지 않는다** — 이미 한 일이다.
  bool overdue(DateTime now) =>
      !done && due != null && dateOnly(due!).isBefore(dateOnly(now));

  /// 시킬 말. 본문이 있으면 본문, 없으면 작업명이다.
  ///
  /// ⚠️ 예전에는 늘 작업명만 보냈다. 그러면 본문에 아무리 자세히 적어도
  /// 터미널에는 제목 한 줄만 가서, 적어둔 것이 쓸모가 없었다.
  ///
  /// 수정요청이면 수정사항을 뒤에 붙인다 — 수정요청 카드를 시키면서 무엇을 고칠지를
  /// 안 보내면 세션이 같은 일을 한 번 더 한다.
  String get command {
    final base = body.trim().isEmpty ? text : body.trim();
    final note = revisionNote.trim();
    return status == TaskStatus.revision && note.isNotEmpty
        ? '$base\n\n[수정요청]\n$note'
        : base;
  }

  /// 「시키기」가 세션에 **실제로 보내는 말.** 맨 앞에 `[태스크 <id>] 「제목」`을 붙인다 —
  /// 세션이 어느 태스크인지 목록을 훑어 찾지 않고 `GET tasks?id=`로 바로 읽게 한다(대표 요청 9/15).
  /// 프롬프트가 비었으면 제목이 이미 표시에 있으니 되풀이하지 않는다.
  String get dispatch {
    final tag = '[태스크 ${Todos.idOf(this)}] 「$text」';
    final b = body.trim();
    final note = revisionNote.trim();
    final rev = status == TaskStatus.revision && note.isNotEmpty ? '\n\n[수정요청]\n$note' : '';
    return b.isEmpty ? '$tag$rev' : '$tag\n$b$rev';
  }

  /// 지금까지 쓴 시간. 재는 중이면 그 몫까지 더해서 준다.
  int spentAt(DateTime now) =>
      spentSec + (ticking ? now.difference(startedAt!).inSeconds : 0);

  TodoItem copyWith({
    String? text,
    String? project,
    TaskStatus? status,
    TaskPriority? priority,
    TaskKind? kind,
    bool clearKind = false,
    String? body,
    String? content,
    String? revisionNote,
    DateTime? due,
    bool clearDue = false,
    DateTime? doneDate,
    bool clearDoneDate = false,
    int? spentSec,
    DateTime? startedAt,
    DateTime? stoppedAt,
    List<String>? subprojectIds,
    List<String>? clientIds,
    List<String>? sessionIds,
    String? notionId,
    String? assignee,
    bool clearAssignee = false,
    String? projectId,
    DateTime? statusAt,
    DateTime? queuedAt,
    bool clearQueued = false,
    String? parentId,
    bool clearParent = false,
    bool? held,
    List<TaskRound>? rounds,
  }) =>
      TodoItem(
        text: text ?? this.text,
        project: project ?? this.project,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        kind: clearKind ? null : (kind ?? this.kind),
        body: body ?? this.body,
        content: content ?? this.content,
        revisionNote: revisionNote ?? this.revisionNote,
        due: clearDue ? null : (due ?? this.due),
        doneDate: clearDoneDate ? null : (doneDate ?? this.doneDate),
        spentSec: spentSec ?? this.spentSec,
        startedAt: startedAt ?? this.startedAt,
        stoppedAt: stoppedAt ?? this.stoppedAt,
        subprojectIds: subprojectIds ?? this.subprojectIds,
        clientIds: clientIds ?? this.clientIds,
        sessionIds: sessionIds ?? this.sessionIds,
        notionId: notionId ?? this.notionId,
        assignee: clearAssignee ? null : (assignee ?? this.assignee),
        projectId: projectId ?? this.projectId,
        statusAt: statusAt ?? this.statusAt,
        queuedAt: clearQueued ? null : (queuedAt ?? this.queuedAt),
        parentId: clearParent ? null : (parentId ?? this.parentId),
        held: held ?? this.held,
        rounds: rounds ?? this.rounds,
        at: at,
      );

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  Map<String, dynamic> toJson() => {
        'text': text,
        'project': project,
        'status': status.name,
        'priority': priority.name,
        if (kind != null) 'kind': kind!.name,
        if (body.isNotEmpty) 'body': body,
        if (content.isNotEmpty) 'content': content,
        if (revisionNote.isNotEmpty) 'revisionNote': revisionNote,
        if (due != null) 'due': _day(due!),
        if (doneDate != null) 'doneDate': _day(doneDate!),
        if (spentSec > 0) 'spentSec': spentSec,
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (stoppedAt != null) 'stoppedAt': stoppedAt!.toIso8601String(),
        if (subprojectIds.isNotEmpty) 'subprojectIds': subprojectIds,
        if (clientIds.isNotEmpty) 'clientIds': clientIds,
        if (sessionIds.isNotEmpty) 'sessionIds': sessionIds,
        if (notionId != null) 'notionId': notionId,
        if (assignee != null) 'assignee': assignee,
        if (projectId != null) 'projectId': projectId,
        if (statusAt != null) 'statusAt': statusAt!.toIso8601String(),
        if (queuedAt != null) 'queuedAt': queuedAt!.toIso8601String(),
        if (parentId != null) 'parentId': parentId,
        if (held) 'held': true,
        if (rounds.isNotEmpty) 'rounds': [for (final r in rounds) r.toJson()],
        'at': at.toIso8601String(),
      };

  /// [project]는 v1 파일을 읽을 때 맵의 키에서 온다. v2부터는 필드로 들어 있다.
  static TodoItem? fromJson(Object? raw, {String? project}) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final owner = (raw['project'] as String?) ?? project ?? '';
    final pid = raw['projectId'] as String?;
    // ⚠️ 폴더도 프로젝트 ID도 없으면 어디 일인지 모른다. 폴더 없는 프로젝트는 ID로 붙는다.
    if (owner.isEmpty && (pid == null || pid.isEmpty)) return null;
    DateTime? time(String key) => DateTime.tryParse(raw[key] as String? ?? '');
    return TodoItem(
      text: text,
      project: owner,
      // v1에는 상태가 없고 done 하나뿐이었다. 체크해 둔 것은 완료로 올린다.
      status: raw.containsKey('status')
          ? TaskStatus.parse(raw['status'])
          : (raw['done'] == true ? TaskStatus.done : TaskStatus.waiting),
      priority: TaskPriority.parse(raw['priority']),
      kind: TaskKind.parse(raw['kind']),
      body: raw['body'] as String? ?? '',
      content: raw['content'] as String? ?? '',
      revisionNote: raw['revisionNote'] as String? ?? '',
      due: time('due'),
      doneDate: time('doneDate'),
      spentSec: (raw['spentSec'] as num?)?.toInt() ?? 0,
      startedAt: time('startedAt'),
      stoppedAt: time('stoppedAt'),
      subprojectIds: _ids(raw['subprojectIds']),
      clientIds: _ids(raw['clientIds']),
      sessionIds: _ids(raw['sessionIds']),
      notionId: raw['notionId'] as String?,
      assignee: (raw['assignee'] as String?)?.isEmpty ?? true ? null : raw['assignee'] as String,
      projectId: (pid == null || pid.isEmpty) ? null : pid,
      statusAt: time('statusAt'),
      queuedAt: time('queuedAt'),
      parentId: (raw['parentId'] as String?)?.isEmpty ?? true ? null : raw['parentId'] as String,
      held: raw['held'] == true,
      rounds: raw['rounds'] is List
          ? (raw['rounds'] as List).map(TaskRound.fromJson).whereType<TaskRound>().toList()
          : const [],
      at: time('at'),
    );
  }
}

/// 지난 회차 하나 — 그 회차의 작업 내용과, 그것을 보고 대표가 적은 수정사항.
class TaskRound {
  const TaskRound({required this.content, required this.note, required this.at});

  final String content;
  final String note;

  /// 회차가 닫힌 시각(수정요청을 받아 다시 시작한 때).
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'content': content,
        'revisionNote': note,
        'at': at.toIso8601String(),
      };

  static TaskRound? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    if (at == null) return null;
    return TaskRound(
        content: raw['content'] as String? ?? '', note: raw['revisionNote'] as String? ?? '', at: at);
  }
}

/// 하위 태스크의 규칙. **한 단계뿐이다**(상위 → 하위) — 여러 단계는 트리 관리가 일이 된다.
///
/// - 진행률은 하위 완료 수로 센다. 상위에 따로 적지 않는다
/// - 시계는 하위에서 돈다. 상위는 제 몫 + 하위 합계를 **보여 주기만** 한다(두 번 세지 않게)
/// - 칸(리스트·보드)에는 하위 카드가 올라가고, 하위가 남은 상위는 칸에서 빠진다 — 같은 일이
///   두 장 깔리지 않게. 하위가 다 끝나면 상위가 제 차례로 돌아와 대표가 완료한다
/// - 완료는 여전히 대표 말이다. 하위가 남은 상위를 완료하면 막지 않고 「남은 하위 N개」를 알린다
///
/// 화면·API와 떼어 둬야 테스트로 굳힐 수 있다.
class TaskTree {
  static List<TodoItem> childrenOf(List<TodoItem> all, String parentId) =>
      all.where((t) => t.parentId == parentId).toList()..sort((a, b) => a.at.compareTo(b.at));

  static bool hasChildren(List<TodoItem> all, TodoItem t) {
    final id = Todos.idOf(t);
    return all.any((x) => x.parentId == id);
  }

  /// 끝난 하위 수와 전체 하위 수.
  static ({int done, int total}) progress(List<TodoItem> kids) =>
      (done: kids.where((k) => k.done).length, total: kids.length);

  /// 남은(안 끝난) 하위 수.
  static int left(List<TodoItem> all, TodoItem parent) =>
      childrenOf(all, Todos.idOf(parent)).where((k) => !k.done).length;

  /// 상위가 보일 시간 — 제 몫 + 하위 합계. 하위가 되기 전에 쟀던 시간도 버리지 않는다.
  static int spentAt(TodoItem parent, List<TodoItem> kids, DateTime now) =>
      kids.fold(parent.spentAt(now), (sum, k) => sum + k.spentAt(now));

  /// 하위 중 가장 늦은 마감. 마감 없는 하위만 있으면 null.
  static DateTime? lastDue(List<TodoItem> kids) {
    DateTime? out;
    for (final k in kids) {
      if (k.due != null && (out == null || k.due!.isAfter(out))) out = k.due;
    }
    return out;
  }

  /// 칸에서 뺄 상위인가 — 안 끝난 하위가 하나라도 있으면 그 하위들이 대신 칸에 선다.
  static bool hiddenOnBoard(List<TodoItem> all, TodoItem t) =>
      t.parentId == null && left(all, t) > 0;

  /// [childId]를 [parentId] 아래에 둘 수 없는 이유. 둘 수 있으면 null.
  /// [childId]가 비어 있으면 새로 만들 하위다.
  static String? parentRefusal(List<TodoItem> all, String childId, String parentId) {
    if (parentId == childId) return '자기 자신을 상위로 둘 수 없다';
    final parent = all.where((t) => Todos.idOf(t) == parentId).firstOrNull;
    if (parent == null) return '상위 태스크가 없다';
    if (parent.parentId != null) return '하위의 하위는 만들지 않는다 — 한 단계뿐이다';
    if (childId.isNotEmpty) {
      final child = all.where((t) => Todos.idOf(t) == childId).firstOrNull;
      if (child == null) return '그 할 일이 없다';
      if (all.any((t) => t.parentId == childId)) return '하위가 있는 태스크는 하위가 될 수 없다';
      final same = child.projectId != null && parent.projectId != null
          ? child.projectId == parent.projectId
          : child.project == parent.project;
      if (!same) return '상위와 같은 프로젝트의 할 일만 하위로 둔다';
    }
    return null;
  }

  /// **마지막 하위가 끝난 순간 상위를 확인필요로 올린다.** 완료는 여전히 대표 몫이다.
  ///
  /// ⚠️ 없던 때는 하위가 다 끝나면 상위가 **자기 진행사항 칸으로** 돌아왔다 — 일시정지 상위는 대기·멈춤에
  /// 섰고(대표 제보 9/15), 세션예정 상위는 세션 차례에 「시키기」가 붙어 끝난 일을 다시 시킬 수 있었다.
  /// [before]는 바뀌기 전 모습(열쇠 → 태스크)이다. **이번에 완료로 넘어온 하위**가 있을 때만 움직인다 —
  /// 대표가 확인필요 상위를 다른 칸으로 옮겨 둔 것을 매번 되돌리지 않게.
  static List<TodoItem> rollUp(List<TodoItem> tasks, Map<String, TodoItem> before, DateTime now) {
    final parents = <String>{
      for (final t in tasks)
        if (t.parentId != null && t.done && !(before[Todos.idOf(t)]?.done ?? true)) t.parentId!,
    };
    if (parents.isEmpty) return tasks;
    return [
      for (final t in tasks)
        parents.contains(Todos.idOf(t)) && !t.done && t.parentId == null &&
                t.status != TaskStatus.review && left(tasks, t) == 0
            ? TodoStore.withStatus(TodoStore.stopped(t, now), TaskStatus.review, now)
            : t,
    ];
  }

  /// 상위를 지웠을 때 — 하위는 지우지 않고 맨 위 태스크로 푼다. 적어 둔 일이 딸려 사라지면 안 된다.
  static List<TodoItem> orphaned(List<TodoItem> all, String removedId) => [
        for (final t in all) t.parentId == removedId ? t.copyWith(clearParent: true) : t,
      ];
}

/// 업무 지시서 — 시킬 말을 「무엇을 · 완료 기준 · 하지 말 것」 세 칸으로 나눠 쓴다(대표 결정 9/15, 시안 A).
///
/// **저장은 프롬프트(`body`) 한 칸 그대로다.** 세 칸을 머리말(`완료 기준:` · `하지 말 것:`)로 합쳐 넣는다 —
/// API·CSV·시키기·노션 되돌리기가 전부 body 하나를 보므로 칸을 늘리면 그쪽이 다 흔들린다.
/// 머리말이 없는 옛 프롬프트는 통째로 「무엇을」에 들어간다.
///
/// ⚠️ 페이지 스크립트(`briefCompose`)가 같은 모양으로 합친다 — 한쪽만 고치면 저장한 것이 다르게 읽힌다.
class TaskBrief {
  const TaskBrief({this.what = '', this.done = '', this.dont = ''});
  final String what, done, dont;

  static const doneHead = '완료 기준:';
  static const dontHead = '하지 말 것:';

  static TaskBrief parse(String body) {
    final parts = {'what': <String>[], 'done': <String>[], 'dont': <String>[]};
    var at = 'what';
    for (final line in const LineSplitter().convert(body)) {
      final t = line.trim();
      if (t == doneHead) {
        at = 'done';
      } else if (t == dontHead) {
        at = 'dont';
      } else {
        parts[at]!.add(line);
      }
    }
    String join(String k) => parts[k]!.join('\n').trim();
    return TaskBrief(what: join('what'), done: join('done'), dont: join('dont'));
  }

  String compose() {
    final out = StringBuffer(what.trim());
    void add(String head, String v) {
      if (v.trim().isEmpty) return;
      if (out.isNotEmpty) out.write('\n\n');
      out.write('$head\n${v.trim()}');
    }
    add(doneHead, done);
    add(dontHead, dont);
    return out.toString();
  }
}

/// 소요시간을 사람이 읽는 모양으로. 한 칸에 들어가야 하므로 짧게 쓴다.
String formatSpent(int sec) {
  if (sec < 60) return sec <= 0 ? '–' : '$sec초';
  final min = sec ~/ 60;
  if (min < 60) return '$min분';
  final h = min ~/ 60;
  final rest = min % 60;
  return rest == 0 ? '$h시간' : '$h시간 $rest분';
}

/// 프로젝트마다 적어둔 할 일을 디스크에 남긴다.
///
/// **노션을 부르지 않는다.** 로컬 JSON 하나로 돌아가므로 남에게 줘도 그대로
/// 동작하고 토큰이 필요 없다.
///
/// ⚠️ 자리는 `resolveConfigPath`가 정한다 — 다른 설정 파일과 한 몸이라,
/// 나중에 `Application Support`로 옮길 때 같이 딸려간다.
class TodoStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'tasks.dev$kPort.json' : 'tasks.json');

  /// 지금 저장 모양의 판. 올릴 때 옛 파일을 알아보는 표지다.
  ///
  /// v3(2026-09-14)은 노션 업적모음의 칸을 모두 담는다. v2 파일은 없는 칸이
  /// 기본값으로 떨어질 뿐 그대로 읽힌다 — 모양은 같은 리스트다.
  static const int version = 3;

  /// 저장할 모양으로 만든다. 파일 쓰기와 나눠 둬야 테스트로 굳힐 수 있다.
  static Map<String, dynamic> encode(List<TodoItem> tasks) => {
        'version': version,
        'tasks': tasks.map((t) => t.toJson()).toList(),
      };

  /// **안 끝난 것 → 우선순위 높은 것 → 마감일 가까운 것 → 먼저 적은 것.**
  ///
  /// 끝난 것을 지우지 않고 아래로 내리는 이유는, 오늘 뭘 했는지가 남아야
  /// 하기 때문이다. 지우고 싶으면 손으로 지운다.
  ///
  /// ⚠️ **마감일 없는 것을 위로 올리지 않는다.** 날짜를 안 적은 것이 급한
  /// 것보다 앞에 서면 적어둔 마감일이 뜻을 잃는다.
  static List<TodoItem> sorted(List<TodoItem> items) {
    final out = [...items];
    out.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.priority != b.priority) {
        return b.priority.index.compareTo(a.priority.index);
      }
      if ((a.due == null) != (b.due == null)) return a.due == null ? 1 : -1;
      if (a.due != null && b.due != null && a.due != b.due) {
        return a.due!.compareTo(b.due!);
      }
      return a.at.compareTo(b.at);
    });
    return out;
  }

  /// 파일 내용을 항목으로 푼다. **v1(맵)도 읽는다.**
  ///
  /// v1은 `{프로젝트: [할 일]}`이라 프로젝트가 담긴 자리였다. 그 키를 항목의
  /// `project` 필드로 옮겨 담으면 그대로 v2가 된다.
  static List<TodoItem> decode(Object? raw) {
    if (raw is! Map) return [];
    final rows = raw['tasks'];
    if (rows is List) {
      return rows.map((r) => TodoItem.fromJson(r)).whereType<TodoItem>().toList();
    }
    // v1 — 키가 프로젝트다.
    final out = <TodoItem>[];
    for (final e in raw.entries) {
      final key = e.key;
      final list = e.value;
      if (key is! String || list is! List) continue;
      out.addAll(list
          .map((r) => TodoItem.fromJson(r, project: key))
          .whereType<TodoItem>());
    }
    return out;
  }

  /// 옛 판인가. 그렇다면 갈아엎기 전에 한 벌 남긴다.
  static bool isLegacy(Object? raw) => raw is Map && raw['tasks'] is! List;

  // ── 시계 ────────────────────────────────────────────────
  //
  // 순수 함수로 빼 둔 이유는 테스트하기 위해서다. `Todos`는 손대는 족족
  // 디스크에 쓰므로 거기서 확인하려면 파일을 만들어야 한다.

  /// 시계를 멈추고 그동안 쓴 만큼을 누적에 더한다.
  ///
  /// **노션의 ⏸️와 같다** — 시작시간은 두고 최근 중지 시간을 찍는다. 그래야
  /// 다음에 정산하는 쪽이 "이 구간은 이미 더했다"를 안다(루트 CLAUDE.md 6번-8).
  static TodoItem stopped(TodoItem t, DateTime now) => t.ticking
      ? t.copyWith(spentSec: t.spentAt(now), stoppedAt: now, held: false)
      : t;

  /// 상태를 옮긴다. **완료 날짜는 상태를 따라간다** — 완료로 들어갈 때 오늘을
  /// 찍고, 완료에서 나오면 지운다. 시계는 여기서 건드리지 않는다.
  static TodoItem withStatus(TodoItem t, TaskStatus status, DateTime now) {
    final moved = assigned(t.copyWith(status: status));
    if (status.isClosed == t.done) return moved;
    return status.isClosed
        ? moved.copyWith(doneDate: dateOnly(now))
        : moved.copyWith(clearDoneDate: true);
  }

  /// 대표가 바꾼 것을 한 줄로. 알릴 거리가 없으면 `null`.
  ///
  /// **시계만 바뀐 것(시작·중지·누적)은 알리지 않는다** — 세션이 판단을 바꿀 일이 아니다.
  static String? describeOwnerChange(TodoItem? before, TodoItem? after) {
    String q(String s) => '「${s.length > 30 ? '${s.substring(0, 30)}…' : s}」';
    if (before == null && after == null) return null;
    if (before == null) return '${q(after!.text)} 새로 적음 (${after.status.label})';
    if (after == null) return '${q(before.text)} 지움';
    final parts = <String>[
      if (before.text != after.text) '제목 → ${q(after.text)}',
      if (before.status != after.status) '${before.status.label} → ${after.status.label}',
      if (before.revisionNote != after.revisionNote && after.revisionNote.trim().isNotEmpty)
        '수정사항 적힘',
      if (before.body != after.body) '프롬프트 바뀜',
      if (before.content != after.content) '작업 내용 바뀜',
      if (before.assignee != after.assignee)
        '담당 → ${after.assignee == null ? '없음' : after.assignee == kOwnerAssignee ? '대표' : after.assignee!.split('/').last}',
      if (before.due != after.due)
        '마감 → ${after.due == null ? '없음' : after.due!.toIso8601String().substring(0, 10)}',
      if (before.priority != after.priority) '우선순위 → ${after.priority.label}',
      if (before.projectId != after.projectId) '프로젝트 옮김',
      if (before.parentId != after.parentId) after.parentId == null ? '상위에서 뗌' : '상위 태스크 바뀜',
    ];
    return parts.isEmpty ? null : '${q(before.text)} ${parts.join(' · ')}';
  }

  /// 진행중에서 끝내면 바로 완료인가 — **담당이 대표인 것만** 그렇다(A안, 대표 결정 9/16).
  ///
  /// 대표가 직접 한 일은 확인해 줄 사람이 자기 자신이라, 「끝냄 → 확인필요 → 완료」로 두 번 누르는 것이
  /// 헛걸음이었다. 세션에게 시킨 일은 예전대로 확인필요를 거친다 — 대표가 보고 판단할 거리가 남는다.
  /// ⚠️ 담당이 비어 있으면 대표로 치지 않는다. 그런 태스크는 「시키기」가 프로젝트 세션으로 보낸다(sendTargetOf).
  static bool finishesSelf(TodoItem t) => t.assignee == kOwnerAssignee;

  /// 「시키기」가 보낼 세션. **담당 세션이 먼저고**, 담당이 비었거나 대표면
  /// 프로젝트 폴더의 세션이다. 폴더도 없으면 빈 글자 — 보낼 데가 없다.
  static String sendTargetOf(TodoItem t) {
    final a = t.assignee;
    if (a != null && a != kOwnerAssignee) return a;
    return t.project;
  }

  /// 「시키기」를 막을 이유. 막지 않으면 `null`.
  ///
  /// ⚠️ **승인 대기면 보내지 않는다.** 선택지가 떠 있는 입력창에 붙여넣고
  /// 엔터를 치면 선택지가 눌린다 — 사람이 고를 것을 위젯이 대신 고르게 된다.
  static String? sendRefusal(TodoItem t, AgentStatus? targetStatus) {
    if (t.assignee == kOwnerAssignee) return '대표 담당이라 세션에 보내지 않는다';
    if (sendTargetOf(t).isEmpty) return '폴더 없는 프로젝트라 보낼 세션이 없다';
    if (targetStatus == AgentStatus.waiting) {
      return '그 세션이 승인 대기 중이라 보내지 않았다 — 먼저 고르고 다시 시킨다';
    }
    return null;
  }

  /// 그 세션 앞에 선 줄 — 먼저 선 순서다. 세션 키는 한글 표기를 맞춰 비교한다.
  static List<TodoItem> queueFor(List<TodoItem> tasks, String target) {
    final want = ProjectStore.composeHangul(target);
    return tasks
        .where((t) => t.queuedAt != null && !t.done &&
            ProjectStore.composeHangul(sendTargetOf(t)) == want)
        .toList()
      ..sort((a, b) => a.queuedAt!.compareTo(b.queuedAt!));
  }

  /// 지금 보내도 되는 세션 상태인가. **일하는 중·생각 중·승인 대기면 기다린다.**
  /// 승인 대기에 붙여넣으면 선택지가 눌리고, 일하는 중에 보내면 두 일이 한 턴에 섞여
  /// 상태·시간이 한 칸씩 어긋난다(2026-09-14 대표 질문으로 확인).
  static bool readyToSend(AgentStatus status) => switch (status) {
        AgentStatus.thinking || AgentStatus.working || AgentStatus.waiting => false,
        _ => true,
      };

  /// 담당이 비어 있으면 상태가 정해 준다 — 오늘예정은 대표, 세션예정은 그
  /// 프로젝트의 세션. **이미 적힌 담당은 건드리지 않는다.**
  static TodoItem assigned(TodoItem t) {
    if (t.assignee != null) return t;
    return switch (t.status) {
      TaskStatus.today => t.copyWith(assignee: kOwnerAssignee),
      // 폴더 없는 프로젝트면 세션을 정할 수 없다 — 비워 둔다.
      TaskStatus.sessionPlanned when t.project.isNotEmpty =>
        t.copyWith(assignee: t.project),
      _ => t,
    };
  }

  /// [index]번째를 재기 시작한다.
  ///
  /// ⚠️ **한 세션에서 재는 것은 하나뿐이다.** 훅은 세션 단위이지 태스크
  /// 단위가 아니라, 같은 세션에 진행중이 둘이면 그 세션의 `Stop` 하나로
  /// 둘 다 멈춰야 하는데 그러면 시간이 어느 쪽 것인지 알 수 없다.
  /// 그래서 앞엣것을 멈춰 확인필요로 넘긴다.
  ///
  /// [held]면 세션이 API로 스스로 시작한 것이라 턴 끝에 멈추지 않는다([TodoItem.held]).
  static List<TodoItem> started(
      List<TodoItem> tasks, int index, DateTime now, {bool held = false}) {
    if (index < 0 || index >= tasks.length) return tasks;
    final target = tasks[index];
    final out = [...tasks];
    for (var i = 0; i < out.length; i++) {
      if (i == index || out[i].project != target.project || !out[i].ticking) {
        continue;
      }
      out[i] = stopped(out[i], now).copyWith(status: TaskStatus.review);
    }
    // 이미 재는 중이면 시작 시각을 건드리지 않는다. 다시 누를 때마다
    // 0으로 돌아가면 그때까지 잰 것이 날아간다.
    out[index] = withStatus(nextRound(target, now), TaskStatus.running, now)
        .copyWith(startedAt: target.ticking ? null : now, held: held);
    return out;
  }

  /// 수정사항이 적힌 채 다시 시작하면 한 회차를 닫는다 — 작업 내용·수정사항을 [TodoItem.rounds]에 넣고
  /// 두 칸을 비운다. 이미 재는 중이면(두 번 시작) 건드리지 않는다.
  ///
  /// ⚠️ 「시키기」는 보낼 말([TodoItem.dispatch])을 만든 **뒤에** 시작하므로 수정사항은 세션에 이미 갔다.
  /// 기존 태스크의 긴 작업 내용은 자르지 않고 통째로 1회차가 된다.
  static TodoItem nextRound(TodoItem t, DateTime now) {
    if (t.ticking || t.revisionNote.trim().isEmpty) return t;
    return t.copyWith(
      rounds: [...t.rounds, TaskRound(content: t.content, note: t.revisionNote, at: now)],
      content: '',
      revisionNote: '',
    );
  }

  /// 그 세션의 턴이 끝났다(`Stop` 훅). 재던 것을 확인필요로 넘긴다.
  ///
  /// 시킨 일이 끝났다는 뜻이지 다 됐다는 뜻은 아니다 — 사람이 보고 완료로
  /// 옮기거나 다시 시킨다.
  ///
  /// ⚠️ 세션이 API로 시작한 시계([TodoItem.held])는 턴 끝에 두고, 세션이 끝났을 때([gone])만 멈춘다.
  static List<TodoItem> ended(
      List<TodoItem> tasks, String project, DateTime now, {bool gone = false}) {
    final out = [...tasks];
    for (var i = 0; i < out.length; i++) {
      if (out[i].project != project || !out[i].ticking) continue;
      if (out[i].held && !gone) continue;
      out[i] = stopped(out[i], now).copyWith(status: TaskStatus.review);
    }
    return out;
  }

  static List<TodoItem> load() {
    final file = File(_path);
    if (!file.existsSync()) return [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      // ⚠️ v1을 v2로 올리기 전에 원본을 남긴다. 옮기다 잘못돼도 되돌릴 곳이 있다.
      if (isLegacy(decoded)) {
        try {
          file.copySync('$_path.bak-v1');
          debugPrint('할 일 v1 → v2 · 원본을 $_path.bak-v1에 남겼다');
        } catch (e) {
          debugPrint('v1 백업 실패: $e');
        }
      }
      return decode(decoded);
    } catch (e) {
      // 파일이 깨져도 앱은 떠야 한다. 못 읽은 것은 버리고 넘어간다.
      debugPrint('할 일 불러오기 실패: $e');
      return [];
    }
  }

  /// ⚠️ **노션을 대체하면 이 파일 하나가 사업 전체 일감이다.** gitignore
  /// 대상이라 날아가면 되돌릴 곳이 없다. 그래서 두 겹으로 남긴다 —
  /// 직전본 한 벌(`.bak`)과 하루 한 번 날짜 스냅샷.
  static void save(List<TodoItem> tasks) {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        file.copySync('$_path.bak');
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final snapshot = File('$_path.$day.bak');
        if (!snapshot.existsSync()) file.copySync(snapshot.path);
      }
      file.writeAsStringSync(jsonEncode(encode(tasks)));
    } catch (e) {
      debugPrint('할 일 저장 실패: $e');
    }
  }
}

/// 리스트·보드의 칸. **진행사항이 아니라 지금 공을 쥔 쪽으로 나눈다**(2026-09-14 대표 확정).
///
/// 12칸 보드에서는 77장이 한 화면에 깔려 무엇이 내 차례인지 안 보였다. 리스트와 보드가
/// 같은 기준을 써야 두 화면을 오갈 때 헷갈리지 않는다.
enum BallLane {
  me('내 차례', '대표', 'pink'),
  session('세션 차례', '세션', 'purple'),
  running('진행중', '돌고 있음', 'blue'),
  hold('대기 · 멈춤', '누구도 아님', 'gray');

  const BallLane(this.label, this.who, this.color);
  final String label;
  final String who;
  final String color;
}

/// 보는 범위 — 오늘 · 이번 주 · 전체. **백로그를 얼마나 끌어올리나**만 정한다.
/// 살아 있는 카드(백로그가 아닌 것)는 범위와 상관없이 늘 보인다 — 숨으면 잊힌다.
enum TodoScope {
  today('오늘'),
  week('이번 주'),
  all('전체');

  const TodoScope(this.label);
  final String label;

  static TodoScope parse(Object? raw) =>
      TodoScope.values.where((x) => x.name == raw).firstOrNull ?? TodoScope.today;
}

/// 리스트·보드가 쓰는 판정. 화면과 떼어 둬야 테스트로 굳힐 수 있다.
class TodoBoard {
  /// 칸 안의 정렬 — 확인필요 → 수정요청 → 오늘예정 → 세션예정 → 진행중 → 대기 → 일시정지.
  static const List<TaskStatus> order = [
    TaskStatus.review, TaskStatus.revision, TaskStatus.today,
    TaskStatus.sessionPlanned, TaskStatus.running, TaskStatus.blocked,
    TaskStatus.paused, TaskStatus.waiting,
  ];

  /// 그 카드의 칸. 끝난 것은 `null`이다.
  ///
  /// ⚠️ **수정요청은 담당이 대표여도 세션 차례다** — 대표가 보고 공을 세션에 돌려준 상태다.
  /// ⚠️ **대기(blocked)는 대표 몫이 아니다** — 외부 때문에 막힌 것이라 누구의 공도 아니다
  /// (대표 결정, 2026-09-14. 리스트 시안은 내 차례로 셌는데 보드에 맞췄다).
  static BallLane? laneOf(TodoItem t) => switch (t.status) {
        TaskStatus.done => null,
        TaskStatus.running => BallLane.running,
        TaskStatus.paused || TaskStatus.blocked => BallLane.hold,
        TaskStatus.revision => BallLane.session,
        TaskStatus.review => BallLane.me,
        _ when t.assignee == kOwnerAssignee => BallLane.me,
        _ => BallLane.session,
      };

  /// 이번 주의 마지막 날(일요일).
  static DateTime weekEnd(DateTime now) =>
      dateOnly(now).add(Duration(days: DateTime.sunday - now.weekday));

  /// 이번 주의 첫날(월요일).
  static DateTime weekStart(DateTime now) =>
      dateOnly(now).subtract(Duration(days: now.weekday - DateTime.monday));

  /// 차례 칸에 올라오나. 백로그는 **마감이 범위 안에 든 것만** 올라오고 나머지는 서랍에 있다.
  static bool onBoard(TodoItem t, TodoScope scope, DateTime now) {
    if (t.done) return false;
    if (t.status != TaskStatus.waiting) return true;
    if (t.due == null) return false;
    return switch (scope) {
      TodoScope.all => true,
      TodoScope.week => !dateOnly(t.due!).isAfter(weekEnd(now)),
      TodoScope.today => !dateOnly(t.due!).isAfter(dateOnly(now)),
    };
  }

  /// 어제(또는 그 전에) 오늘예정으로 옮겨 두고 아직 오늘예정인 것.
  /// 옮긴 시각이 없던 옛 할 일은 적은 시각으로 친다.
  static bool staleToday(TodoItem t, DateTime now) =>
      t.status == TaskStatus.today &&
      dateOnly(t.statusAt ?? t.at).isBefore(dateOnly(now));

  /// 칸 안의 정렬 — 상태 → **지난 마감** → **불(중요도)** → 마감이 이른 것 → 적은 순.
  ///
  /// 불을 넣은 것은 대표 요청이다(9/16) — 🔥🔥🔥을 붙여도 칸 아래에 그대로 있으면 표시한 뜻이 없다.
  /// 마감이 지난 것을 불보다 앞에 두는 이유는, 이미 늦은 것은 중요도와 상관없이 오늘 손을 봐야 해서다.
  /// 「타임기록」은 중요도가 아니라 갈래라 맨 뒤로 보낸다.
  static int compare(TodoItem a, TodoItem b) {
    final s = order.indexOf(a.status).compareTo(order.indexOf(b.status));
    if (s != 0) return s;
    final now = DateTime.now();
    final od = a.overdue(now) != b.overdue(now);
    if (od) return a.overdue(now) ? -1 : 1;
    final p = priorityRank(b.priority).compareTo(priorityRank(a.priority));
    if (p != 0) return p;
    if ((a.due == null) != (b.due == null)) return a.due == null ? 1 : -1;
    if (a.due != null && a.due != b.due) return a.due!.compareTo(b.due!);
    return a.at.compareTo(b.at);
  }

  /// 불이 셀수록 큰 값. 타임기록은 중요도가 아니므로 가장 작다.
  static int priorityRank(TaskPriority p) =>
      p == TaskPriority.timeLog ? -1 : p.index;
}

/// 지금 들고 있는 할 일. **위젯과 브라우저가 같은 것을 본다.**
///
/// 예전에는 패널 위젯이 제 안에 들고 있었는데, 그러면 HTTP 서버가 볼 수 없다.
/// 여기로 꺼내 두면 브라우저에서 고친 것이 위젯에 바로 뜨고 그 반대도 된다.
///
/// ⚠️ **동작을 여기에 둔다.** 나중에 네이티브 창으로 옮기더라도 이 부분은
/// 그대로 쓴다 — 버려지는 건 HTML 한 장뿐이게 하려는 것이다.
/// 되돌리기 한 걸음 — 화면에서 한 일 하나를 되돌릴 만큼만 담는다.
///
/// 대표 결정(2026-09-16): **칸 이동·완료·지우기**만 담는다. 시키기(세션에 실제로 간 말)·시계·
/// 글자 고치기는 담지 않는다 — 앞엣것은 되돌릴 수 없고, 글자는 글칸이 스스로 ⌘Z를 한다.
class UndoStep {
  UndoStep({required this.label, required this.id, required this.before, required this.after});

  /// 사람 말로 적은 한 일 — 토스트에 그대로 뜬다(예: 「‘끝냄’ 처리」).
  final String label;
  final String id;

  /// 하기 전 모습. 지운 것이면 통째로 들어 있고, 그 밖에는 바뀌기 전 값이다.
  final Map<String, dynamic>? before;

  /// 하고 난 모습. 다시 실행에 쓴다. 지운 것이면 null이다.
  final Map<String, dynamic>? after;
}

/// 되돌리기·다시 실행 한 벌. 페이지가 새로 떠도 살아 있게 서버에 둔다.
///
/// ⚠️ **한 걸음만 깊이 파지 않는다.** 여러 걸음을 쌓으면 그 사이 세션·폰에서 바뀐 것과 엉켜
/// 「무엇이 되돌아갔는지」를 사람이 못 따라간다. 스무 걸음까지 담되 되돌린 것은 곧바로 다시 실행 쪽으로 옮긴다.
class UndoStack {
  static const int kMax = 20;
  final List<UndoStep> _done = [];
  final List<UndoStep> _undone = [];

  bool get canUndo => _done.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;
  String get nextLabel => _done.isEmpty ? '' : _done.last.label;

  void push(UndoStep step) {
    _done.add(step);
    if (_done.length > kMax) _done.removeAt(0);
    _undone.clear();
  }

  UndoStep? popUndo() {
    if (_done.isEmpty) return null;
    final step = _done.removeLast();
    _undone.add(step);
    return step;
  }

  UndoStep? popRedo() {
    if (_undone.isEmpty) return null;
    final step = _undone.removeLast();
    _done.add(step);
    return step;
  }
}

/// 이 앱이 든 되돌리기 한 벌.
final UndoStack kUndo = UndoStack();

class Todos extends ChangeNotifier {
  Todos() {
    _snapshot = {for (final t in _tasks) idOf(t): t};
  }

  final List<TodoItem> _tasks = TodoStore.load();

  /// 시계가 멈출 때마다 한 구간씩 받는다(세션 기록). 버튼·훅·API 어느 길로
  /// 멈춰도 여기 한 곳에서 잡는다 — 길마다 따로 적으면 하나는 꼭 빠진다.
  void Function(TodoItem before, TodoItem after)? onInterval;
  Map<String, TodoItem> _snapshot = {};

  /// 대표가 보드·폰·위젯에서 바꾼 것. 세션에게 알릴 거리다([OwnerNotices]).
  /// ⚠️ 세션이 API로 바꾼 것·훅이 시계를 멈춘 것·시키기는 **알리지 않는다** —
  /// 그 세션이 이미 아는 일이라 알리면 소음이다. 그런 길은 [quietly]로 감싼다.
  void Function(TodoItem? before, TodoItem? after)? onOwnerChange;
  bool _quiet = false;

  void quietly(void Function() f) {
    final was = _quiet;
    _quiet = true;
    try {
      f();
    } finally {
      _quiet = was;
    }
  }

  List<TodoItem> get all => List.unmodifiable(_tasks);

  /// 그 프로젝트의 할 일. 안 끝난 것이 위다.
  List<TodoItem> of(String cwdPath) =>
      TodoStore.sorted(_tasks.where((t) => t.project == cwdPath).toList());

  /// 안 끝난 것의 개수. 배지에 쓴다.
  int get remaining => _tasks.where((t) => !t.done).length;

  /// 할 일 하나를 가리키는 값. **적은 시각을 쓴다** — 글자는 같을 수 있어도
  /// 시각은 안 겹친다. 브라우저에서 어느 줄을 눌렀는지 알아내는 데 쓴다.
  static String idOf(TodoItem t) => t.at.toIso8601String();

  TodoItem? byId(String id) => _tasks.where((t) => idOf(t) == id).firstOrNull;

  int _indexOf(String id) => _tasks.indexWhere((t) => idOf(t) == id);

  /// 지금 그 세션에서 시간을 재고 있는 태스크.
  TodoItem? tickingIn(String cwdPath) =>
      _tasks.where((t) => t.project == cwdPath && t.ticking).firstOrNull;

  /// 새로 적는다. 적은 것의 ID를 돌려준다(못 적으면 null) — 「새 할 일」 창이 적자마자 시킬 때 쓴다.
  String? add(String cwdPath, String text,
      {TaskStatus status = TaskStatus.waiting, String? projectId, String body = ''}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (cwdPath.isEmpty && (projectId == null || projectId.isEmpty)) return null;
    var t = TodoStore.assigned(TodoItem(
        text: trimmed, project: cwdPath, status: status, projectId: projectId, body: body.trim()));
    while (byId(idOf(t)) != null) {
      t = TodoItem.fromJson({...t.toJson(), 'at': t.at.add(const Duration(milliseconds: 1)).toIso8601String()})!;
    }
    _tasks.add(t);
    _save();
    return idOf(t);
  }

  /// 상위 아래에 하위를 적는다. **프로젝트·담당·차례를 상위에서 물려받는다.**
  ///
  /// 차례(칸)를 따르게 한 것은 대표 요청이다(9/16) — 오늘예정 상위 밑에 적었는데 백로그로 떨어지면
  /// 적자마자 찾아 옮겨야 했다. 상위가 어느 칸에 있든 하위가 같은 칸에서 시작한다:
  /// 내 차례(오늘예정·확인필요) → 오늘예정, 세션 차례(세션예정·수정요청) → 세션예정,
  /// 진행중 → 담당이 세션이면 세션예정, 아니면 오늘예정, 멈춤·완료 → 백로그.
  /// ⚠️ 진행중을 그대로 물려주지 않는다 — 하위에 시계가 저절로 돌면 시간이 두 곳에서 잡힌다.
  static TaskStatus childStatusOf(TodoItem parent) {
    if (parent.done) return TaskStatus.waiting;
    return switch (TodoBoard.laneOf(parent)) {
      BallLane.me => TaskStatus.today,
      BallLane.session => TaskStatus.sessionPlanned,
      BallLane.running => parent.assignee != null && parent.assignee != kOwnerAssignee
          ? TaskStatus.sessionPlanned
          : TaskStatus.today,
      _ => TaskStatus.waiting,
    };
  }

  String? addChild(String parentId, String text, {String body = ''}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '이름이 비었다';
    final refusal = TaskTree.parentRefusal(_tasks, '', parentId);
    if (refusal != null) return refusal;
    final parent = byId(parentId)!;
    final status = childStatusOf(parent);
    var t = TodoStore.assigned(TodoItem(
        text: trimmed, project: parent.project, projectId: parent.projectId,
        status: status, assignee: parent.assignee, parentId: parentId, body: body.trim()));
    while (byId(idOf(t)) != null) {
      t = TodoItem.fromJson({...t.toJson(), 'at': t.at.add(const Duration(milliseconds: 1)).toIso8601String()})!;
    }
    _tasks.add(t);
    _save();
    return null;
  }

  /// 상위를 붙이거나(`parentId`) 뗀다(빈 글자). 못 붙이면 이유를 돌려준다.
  String? setParent(String id, String parentId) {
    final i = _indexOf(id);
    if (i < 0) return '그 할 일이 없다';
    if (parentId.isEmpty) {
      if (_tasks[i].parentId == null) return null;
      _tasks[i] = _tasks[i].copyWith(clearParent: true);
      _save();
      return null;
    }
    final refusal = TaskTree.parentRefusal(_tasks, id, parentId);
    if (refusal != null) return refusal;
    _tasks[i] = _tasks[i].copyWith(parentId: parentId);
    _save();
    return null;
  }

  /// 프로젝트를 옮긴다. 폴더도 같이 따라간다(폴더 없는 프로젝트면 비운다).
  void moveTo(String id, ProjectRow row) {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    _tasks[i] = TodoItem.fromJson({
      ...t.toJson(),
      'project': row.path ?? '',
      'projectId': row.id,
    })!;
    _save();
  }

  /// 옛 파일·노션에서 온 할 일을 통째로 넣는다. **같은 노션 ID가 이미 있으면 건너뛴다.**
  int importAll(List<TodoItem> items) {
    final have = {for (final t in _tasks) if (t.notionId != null) t.notionId};
    var n = 0;
    for (final t in items) {
      if (t.notionId != null && have.contains(t.notionId)) continue;
      _tasks.add(t);
      n++;
    }
    if (n > 0) _save();
    return n;
  }

  /// 체크는 완료와 대기를 오간다. 되돌리기 쉬우니 겨누기를 두지 않는다.
  void toggle(String id) {
    final i = _indexOf(id);
    if (i < 0) return;
    setStatus(id, _tasks[i].done ? TaskStatus.waiting : TaskStatus.done);
  }

  /// 상태를 옮긴다. **시계는 상태를 따라간다** — 진행중이 아니면 멈춘다.
  void setStatus(String id, TaskStatus status) {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    if (status == TaskStatus.running) {
      _startTimer(i);
      return;
    }
    final now = DateTime.now();
    _tasks[i] = TodoStore.withStatus(TodoStore.stopped(t, now), status, now);
    _save();
  }

  // ── 버튼 ────────────────────────────────────────────────
  //
  // 노션 업적모음의 ▶️ · ⏸️ · ✅. 훅이 시간을 저절로 재지만, 시키지 않고
  // 사람이 직접 하는 일(디자인·통화)은 손으로 재야 해서 그대로 둔다.

  /// ▶️ — 진행중으로 옮기고 시계를 돌린다.
  void play(String id) => setStatus(id, TaskStatus.running);

  /// ⏸️ — 시계를 멈추고 일시 중지로 옮긴다.
  void pause(String id) => setStatus(id, TaskStatus.paused);

  /// ✅ — 시계를 멈추고 완료로 옮긴다. 완료 날짜가 찍힌다.
  void check(String id) => setStatus(id, TaskStatus.done);

  void edit(String id,
      {String? text,
      String? body,
      String? content,
      String? revisionNote,
      String? project,
      TaskPriority? priority,
      TaskKind? kind,
      bool clearKind = false,
      String? assignee,
      bool clearAssignee = false,
      DateTime? due,
      bool clearDue = false}) {
    final i = _indexOf(id);
    if (i < 0) return;
    final title = text?.trim();
    if (title != null && title.isEmpty) return;
    _tasks[i] = _tasks[i].copyWith(
        text: title,
        body: body,
        content: content,
        revisionNote: revisionNote,
        project: project,
        priority: priority,
        kind: kind,
        clearKind: clearKind,
        assignee: assignee,
        clearAssignee: clearAssignee,
        due: due,
        clearDue: clearDue);
    _save();
  }

  void remove(String id) {
    final i = _indexOf(id);
    if (i < 0) return;
    _tasks.removeAt(i);
    // 상위를 지우면 하위는 맨 위 태스크로 풀린다 — 딸려 사라지지 않는다.
    _replaceAll(TaskTree.orphaned(_tasks, id));
  }

  /// 되돌리기가 쓰는 길 — 적어 둔 모습 그대로 되돌려 놓는다([UndoStack]).
  ///
  /// 있으면 갈아 끼우고, 지워졌으면 도로 세운다. ⚠️ 이 길로는 알림을 내지 않는다(대표가 방금 한 일을
  /// 되돌린 것이라 세션에 알릴 소식이 아니다) — 부르는 쪽에서 [quietly]로 감싼다.
  bool restore(Map<String, dynamic> raw) {
    final item = TodoItem.fromJson(raw);
    if (item == null) return false;
    final i = _indexOf(idOf(item));
    if (i < 0) {
      _tasks.add(item);
    } else {
      _tasks[i] = item;
    }
    _replaceAll(List<TodoItem>.from(_tasks));
    return true;
  }

  /// 줄에 세운다(이미 서 있으면 그 자리를 지킨다).
  void enqueue(String id) {
    final i = _indexOf(id);
    if (i < 0 || _tasks[i].queuedAt != null) return;
    quietly(() {
      _tasks[i] = _tasks[i].copyWith(queuedAt: DateTime.now());
      _save();
    });
  }

  /// 줄에서 뺀다.
  void unqueue(String id) {
    final i = _indexOf(id);
    if (i < 0 || _tasks[i].queuedAt == null) return;
    quietly(() {
      _tasks[i] = _tasks[i].copyWith(clearQueued: true);
      _save();
    });
  }

  /// 「오늘 다시」 — 진행사항은 그대로 두고 옮긴 시각만 지금으로 한다.
  void touchStatus(List<String> ids) {
    final stamp = DateTime.now();
    var hit = false;
    for (final id in ids) {
      final i = _indexOf(id);
      if (i < 0) continue;
      _tasks[i] = _tasks[i].copyWith(statusAt: stamp);
      hit = true;
    }
    if (hit) _save();
  }

  // ── 소요시간 ────────────────────────────────────────────
  //
  // 노션은 ▶️/⏸️를 손으로 눌러야 했다. 여기는 훅이 있으니 자동으로 잰다.
  // 규칙은 `TodoStore`에 순수 함수로 있다 — 여기는 담고 저장만 한다.

  void _startTimer(int i) {
    _replaceAll(TodoStore.started(_tasks, i, DateTime.now()));
  }

  /// `시키기`를 누른 순간. 그 태스크가 진행중이 되고 시계가 돈다.
  void startFor(String id) {
    final i = _indexOf(id);
    // 시키기 — 받는 세션이 곧 그 말을 받으므로 따로 알리지 않는다.
    if (i >= 0) quietly(() => _startTimer(i));
  }

  /// 그 세션의 턴이 끝났다(`Stop` 훅). **재던 것을 확인필요로 넘긴다.**
  ///
  /// [gone]이면 세션이 끝난 것이라 API로 시작한 시계([TodoItem.held])까지 멈춘다.
  void stopFor(String cwdPath, {bool gone = false}) {
    // ⚠️ 멈출 것이 없으면 저장하지 않는다. Stop은 턴마다 오므로, 그때마다
    // 파일을 쓰면 할 일과 상관없이 디스크를 두드린다.
    if (!_tasks.any((t) => t.project == cwdPath && t.ticking && (gone || !t.held))) return;
    quietly(() => _replaceAll(TodoStore.ended(_tasks, cwdPath, DateTime.now(), gone: gone)));
  }

  /// 세션이 API(`tasks/start`)로 스스로 시작한다. 턴 끝에 멈추지 않는다([TodoItem.held]).
  void startHeld(String id) {
    final i = _indexOf(id);
    if (i < 0) return;
    _replaceAll(TodoStore.started(_tasks, i, DateTime.now(), held: true));
  }

  void _replaceAll(List<TodoItem> next) {
    _tasks
      ..clear()
      ..addAll(next);
    _save();
  }

  void _save() {
    // 마지막 하위가 끝났으면 상위를 확인필요로 — 길(버튼·보드·API·세션)이 어디든 여기 한 곳에서 잡는다.
    final rolled = TaskTree.rollUp(_tasks, _snapshot, DateTime.now());
    if (!identical(rolled, _tasks)) {
      _tasks
        ..clear()
        ..addAll(rolled);
    }
    // 진행사항이 바뀐 것에 옮긴 시각을 찍는다. 길(버튼·훅·API)마다 따로 찍으면 하나는 빠진다.
    final stamp = DateTime.now();
    for (var i = 0; i < _tasks.length; i++) {
      final prev = _snapshot[idOf(_tasks[i])];
      if (prev != null && prev.status != _tasks[i].status) {
        // 진행사항을 옮기면 줄에서 빠진다 — 손으로 옮긴 것을 줄이 나중에 다시 시키면 안 된다.
        _tasks[i] = _tasks[i].copyWith(statusAt: stamp, clearQueued: true);
      }
    }
    final now = {for (final t in _tasks) idOf(t): t};
    for (final t in _tasks) {
      final prev = _snapshot[idOf(t)];
      if (prev != null && prev.ticking && !t.ticking && t.stoppedAt != null) {
        onInterval?.call(prev, t);
      }
      if (!_quiet && onOwnerChange != null) onOwnerChange!(prev, t);
    }
    if (!_quiet && onOwnerChange != null) {
      for (final e in _snapshot.entries) {
        if (!now.containsKey(e.key)) onOwnerChange!(e.value, null);
      }
    }
    _snapshot = now;
    TodoStore.save(_tasks);
    notifyListeners();
  }

  // ── 세션 API가 쓰는 길 ──

  /// 준 칸만 바꾼다. 완료로 옮기는 것은 [setStatus]로만 한다.
  void apiUpdate(String id,
      {String? text,
      String? body,
      String? content,
      String? revisionNote,
      TaskPriority? priority,
      TaskKind? kind,
      String? assignee,
      DateTime? due,
      bool clearDue = false}) {
    final i = _indexOf(id);
    if (i < 0) return;
    final title = text?.trim();
    _tasks[i] = _tasks[i].copyWith(
        text: (title == null || title.isEmpty) ? null : title,
        body: body,
        content: content,
        revisionNote: revisionNote,
        priority: priority,
        kind: kind,
        assignee: assignee,
        due: due,
        clearDue: clearDue);
    _save();
  }

  /// 새 할 일을 만들고 그 ID를 돌려준다.
  String? apiAdd(TodoItem item) {
    if (item.text.trim().isEmpty) return null;
    var t = TodoStore.assigned(item);
    // 열쇠(적은 시각)가 겹치면 1밀리초씩 민다.
    while (byId(idOf(t)) != null) {
      t = TodoItem.fromJson({...t.toJson(), 'at': t.at.add(const Duration(milliseconds: 1)).toIso8601String()})!;
    }
    _tasks.add(t);
    _save();
    return idOf(t);
  }
}

/// 세션 기록 한 줄 — 시계가 돈 한 구간. **노션 세션 기록 DB를 대신한다.**
///
/// `누적 시간(분)` 하나로는 날짜별로 안 쪼개져서 노션에 따로 두었던 것이다
/// (루트 CLAUDE.md 6번-9). 날짜별 시간과 무위다라니(시간) 계산의 근거다.
class SessionRecord {
  SessionRecord({
    required this.id,
    required this.start,
    required this.end,
    this.taskId,
    this.taskText = '',
    this.projectId,
    this.method = '워쳐',
    this.memo = '',
    this.notionId,
  });

  final String id;
  final DateTime start;
  final DateTime end;

  /// 할 일의 ID(적은 시각). 태스크 없는 구간이면 비어 있다.
  final String? taskId;
  final String taskText;
  final String? projectId;

  /// 어떻게 남았나 — 워쳐(시계가 멈춤) · 노션(옮겨옴) · 수동.
  final String method;
  final String memo;
  final String? notionId;

  int get minutes => end.difference(start).inMinutes;

  /// 날짜는 시작한 날로 친다.
  String get date => start.toIso8601String().substring(0, 10);

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        if (taskId != null) 'taskId': taskId,
        if (taskText.isNotEmpty) 'taskText': taskText,
        if (projectId != null) 'projectId': projectId,
        'method': method,
        if (memo.isNotEmpty) 'memo': memo,
        if (notionId != null) 'notionId': notionId,
        'minutes': minutes,
        'date': date,
      };

  static SessionRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = DateTime.tryParse(raw['start'] as String? ?? '');
    final end = DateTime.tryParse(raw['end'] as String? ?? '');
    final id = raw['id'] as String?;
    if (start == null || end == null || id == null) return null;
    return SessionRecord(
      id: id, start: start, end: end,
      taskId: raw['taskId'] as String?,
      taskText: raw['taskText'] as String? ?? '',
      projectId: raw['projectId'] as String?,
      method: raw['method'] as String? ?? '워쳐',
      memo: raw['memo'] as String? ?? '',
      notionId: raw['notionId'] as String?,
    );
  }
}

/// 세션 기록의 디스크와 계산.
class SessionLogStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'sessions.dev$kPort.json' : 'sessions.json');

  static Map<String, dynamic> encode(List<SessionRecord> rows) =>
      {'version': 1, 'sessions': rows.map((r) => r.toJson()).toList()};

  static List<SessionRecord> decode(Object? raw) {
    if (raw is! Map || raw['sessions'] is! List) return [];
    final seen = <String>{};
    return [
      for (final r in (raw['sessions'] as List).map(SessionRecord.fromJson))
        if (r != null && seen.add(r.id)) r,
    ];
  }

  /// 멈춘 시계 하나를 구간으로. 0분이면 남기지 않는다 — 누르다 만 것까지 쌓으면 기록이 부스러기가 된다.
  static SessionRecord? fromStop(TodoItem before, TodoItem after) {
    final start = before.startedAt, end = after.stoppedAt;
    if (start == null || end == null || !end.isAfter(start)) return null;
    if (end.difference(start).inSeconds < 60) return null;
    return SessionRecord(
      id: 's${start.microsecondsSinceEpoch}',
      start: start, end: end,
      taskId: Todos.idOf(after), taskText: after.text, projectId: after.projectId);
  }

  /// 그 날짜의 분을 프로젝트 종류별로 — **무위다라니(시간) = 실근무 − 개인**의 근거.
  static Map<String, int> minutesByKind(
      List<SessionRecord> rows, String date, ProjectRow? Function(String id) projectOf) {
    final out = {for (final k in ProjectKind.values) k.name: 0, 'unknown': 0};
    for (final r in rows.where((r) => r.date == date)) {
      final kind = r.projectId == null ? null : projectOf(r.projectId!)?.kind;
      out[kind?.name ?? 'unknown'] = out[kind?.name ?? 'unknown']! + r.minutes;
    }
    return out;
  }

  static List<SessionRecord> load() {
    final f = File(_path);
    if (!f.existsSync()) return [];
    try {
      return decode(jsonDecode(f.readAsStringSync()));
    } catch (e) {
      debugPrint('세션 기록 불러오기 실패: $e');
      return [];
    }
  }

  static void save(List<SessionRecord> rows) {
    try {
      final f = File(_path);
      if (f.existsSync()) f.copySync('$_path.bak');
      f.writeAsStringSync(jsonEncode(encode(rows)));
    } catch (e) {
      debugPrint('세션 기록 저장 실패: $e');
    }
  }
}

class SessionLog extends ChangeNotifier {
  final List<SessionRecord> _rows = SessionLogStore.load();
  List<SessionRecord> get all => List.unmodifiable(_rows);

  void add(SessionRecord r) {
    if (_rows.any((x) => x.id == r.id)) return;
    _rows.add(r);
    SessionLogStore.save(_rows);
    notifyListeners();
  }

  int importAll(List<SessionRecord> rows) {
    final have = {for (final r in _rows) r.id};
    final fresh = rows.where((r) => have.add(r.id)).toList();
    if (fresh.isEmpty) return 0;
    _rows.addAll(fresh);
    SessionLogStore.save(_rows);
    notifyListeners();
    return fresh.length;
  }
}

/// 세션 API의 범위 — **부른 세션의 폴더로 정한다.**
///
/// ⚠️ 규칙 문장에만 맡기면 샌다(2026-08-31 사고 두 건). API가 막는다:
/// - 모든 프로젝트 폴더를 품는 **맨 위 폴더**(루트)에서 부르면 전부 본다
/// - 그 밖에서는 가장 깊게 맞는 프로젝트 **하나**만 본다
/// - 맨 위 폴더 말고는 맞는 프로젝트가 없으면 거절한다 — 루트로 새지 않게
class ApiScope {
  const ApiScope({required this.all, this.project});
  final bool all;
  final ProjectRow? project;

  bool allows(TodoItem t) =>
      all || (project != null && (t.projectId == project!.id ||
          (t.projectId == null && t.project.isNotEmpty && t.project == project!.path)));

  // ⚠️ macOS 경로는 한글이 풀어진 모양(NFD)으로 올 때가 있다. 맞춰서 비교한다.
  static String _norm(String p) {
    final c = ProjectStore.composeHangul(p);
    return c.endsWith('/') && c.length > 1 ? c.substring(0, c.length - 1) : c;
  }

  /// 모든 폴더 있는 프로젝트의 조상인 프로젝트. 없으면 `null`.
  static ProjectRow? rootOf(List<ProjectRow> rows) {
    final withPath = rows.where((r) => r.path != null).toList();
    for (final r in withPath) {
      final base = _norm(r.path!);
      if (withPath.length > 1 &&
          withPath.every((x) => x == r || _norm(x.path!).startsWith('$base/'))) {
        return r;
      }
    }
    return null;
  }

  static ApiScope? of(String cwd, List<ProjectRow> rows) {
    final c = _norm(cwd.trim());
    if (c.isEmpty) return null;
    final root = rootOf(rows);
    if (root != null && _norm(root.path!) == c) return const ApiScope(all: true);
    ProjectRow? best;
    for (final r in rows.where((r) => r.path != null && r != root)) {
      final base = _norm(r.path!);
      if (c == base || c.startsWith('$base/')) {
        if (best == null || base.length > _norm(best.path!).length) best = r;
      }
    }
    return best == null ? null : ApiScope(all: false, project: best);
  }
}

/// 「시키기」 줄. **일하는 세션에 또 시키면 바로 보내지 않고 줄에 세운다**(2026-09-14 대표 결정).
///
/// 바로 보내면 앞 태스크가 일찍 확인필요로 가고, 앞 턴이 끝나는 `Stop`이 뒤 태스크를
/// 확인필요로 넘겨 상태·시간이 한 칸씩 어긋났다. 줄에 세워 두고:
/// - 시키면 늘 줄에 넣고 곧바로 [pump] — 세션이 보낼 수 있는 상태면 줄 맨 앞을 보낸다
/// - 보낸 뒤에는 그 세션의 `Stop`이 올 때까지 다음을 보내지 않는다([_inFlight])
/// - `Stop`이 오면 시계 정산 뒤 잠깐 있다가 다음을 보낸다
/// 위젯과 브라우저가 **같은 줄을 쓴다** — 어느 쪽에서 시켜도 순서가 하나다.
class SendQueue {
  SendQueue(this.store, this.todos) {
    // 위젯을 다시 켰거나 Stop을 놓쳐도 줄이 서 버리지 않게 가끔 한 번씩 밀어 준다.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => pumpAll());
  }

  final SessionStore store;
  final Todos todos;
  Timer? _timer;

  /// 보냈고 그 턴의 `Stop`을 기다리는 세션 → 보낸 시각. 30분이 지나면 놓친 것으로 본다.
  final Map<String, DateTime> _inFlight = {};

  /// 보냈을 때 알릴 곳(위젯이 그 세션 패널을 펴는 데 쓴다).
  void Function(AgentSession session, TodoItem item)? onSent;

  static String _key(String p) => ProjectStore.composeHangul(p);

  AgentSession? _session(String target) =>
      store.sessions.where((s) => _key(s.cwdPath) == _key(target)).firstOrNull;

  /// 시키기. 거절할 이유가 있으면 그 문장, 아니면 `null`(보냈거나 줄에 섰다).
  Future<String?> submit(String id) async {
    final item = todos.byId(id);
    if (item == null) return '그 할 일이 없다';
    final refusal = TodoStore.sendRefusal(item, null);
    if (refusal != null) return refusal;
    final target = TodoStore.sendTargetOf(item);
    if (_session(target) == null) return '그 캐릭터가 지금 없다';
    todos.enqueue(id);
    return pump(target);
  }

  /// 그 세션이 보낼 수 있으면 줄 맨 앞을 보낸다. 보내다 실패하면 그 문장을 준다.
  Future<String?> pump(String target) async {
    final key = _key(target);
    final since = _inFlight[key];
    if (since != null && DateTime.now().difference(since) < const Duration(minutes: 30)) return null;
    final session = _session(target);
    if (session == null || session.ended || !TodoStore.readyToSend(session.status)) return null;
    final line = TodoStore.queueFor(todos.all, target);
    if (line.isEmpty) return null;
    final head = line.first;
    final id = Todos.idOf(head);
    _inFlight[key] = DateTime.now();
    final error = await sendToSession(store, target, head.dispatch);
    if (error != null) {
      // 못 보냈으면 줄에서 빼고 알린다 — 줄에 남겨 두면 10초마다 같은 실패를 되풀이한다.
      _inFlight.remove(key);
      todos.unqueue(id);
      return error;
    }
    todos.unqueue(id);
    todos.startFor(id);
    onSent?.call(session, head);
    return null;
  }

  /// 그 세션의 턴이 끝났다. 시계 정산(`stopFor`)이 끝난 뒤 불린다.
  void turnEnded(String cwdPath) {
    _inFlight.remove(_key(cwdPath));
    // Stop 직후에는 세션 상태가 아직 바뀌는 중이다. 잠깐 두고 보낸다.
    Timer(const Duration(milliseconds: 1500), () => pump(cwdPath));
  }

  void pumpAll() {
    final targets = {
      for (final t in todos.all)
        if (t.queuedAt != null && !t.done) _key(TodoStore.sendTargetOf(t)),
    };
    for (final t in targets) {
      unawaited(pump(t));
    }
  }

  void dispose() => _timer?.cancel();
}

/// 줄에 선 태스크를 가리키는 전역. 서버와 위젯이 같은 줄을 쓰도록 `main`에서 한 번 만든다.
SendQueue? kSendQueue;

/// 대시보드가 쓰는 그림 저장소. 서버가 캐릭터 얼굴·모자를 PNG로 내줄 때 쓴다(`main`에서 한 번 넣는다).
ArtStore? kArtStore;

/// 그림 한 장을 PNG로 — 같은 이미지는 한 번만 굽는다.
final Expando<Uint8List> _pngCache = Expando('png');
Future<Uint8List?> pngOf(ui.Image image) async {
  final hit = _pngCache[image];
  if (hit != null) return hit;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) return null;
  return _pngCache[image] = data.buffer.asUint8List();
}

/// 대화 칸의 읽기. 사무실 목록(`/todo/chat/sessions`)과 한 세션의 대화(`/todo/chat/log`).
///
/// ⚠️ 대화에는 세션이 읽은 파일 내용·도구 인자가 들어간다. 폰 입구(9878)에서는 열쇠가
/// 있어야만 여기까지 온다 — 할 일 페이지와 같은 문이다.
Map<String, dynamic> chatApi(SessionStore store, Todos todos, String path, Map<String, String> q) {
  String state(AgentSession s) => s.ended ? 'ended' : s.status.name;
  switch (path) {
    case '/todo/chat/sessions':
      final now = DateTime.now();
      // 책상과 같은 칸(팀) 순서 — 이사 칸이 먼저, 칸 안에서는 팀장 → 사원.
      // 그 아래 팀 칸의 차례는 대표가 ▲▼로 정한 것을 따른다([OfficeLayout.arrange], 9/18).
      final floors = kOffice.arrange(store.floors);
      return {
        'ok': true,
        'sessions': [
          for (final floor in floors)
            for (final s in floor.sessions)
              () {
                final tier = floor.tierOf(s);
                final frames = kArtStore?.framesOf(s.folderName, s.artStatus, setName: s.project.charSet ?? tier);
                final f0 = (frames == null || frames.isEmpty) ? null : frames.first;
                final hat = kArtStore?.hatOf(tier, s.artStatus.artKey);
                final running = todos.tickingIn(s.cwdPath);
                final line = TodoStore.queueFor(todos.all, s.cwdPath);
                final key = Uri.encodeQueryComponent(s.cwdPath);
                return {
                  'path': s.cwdPath,
                  'name': s.name,
                  // 별명을 지었으면 `name`은 별명이다. 폴더 이름도 같이 줘서 이름 바꾸기 창이 본이름을 보일 수 있게 한다(9/18).
                  'folder': s.folderName,
                  'state': state(s),
                  if (store.tmuxLive(s.cwdPath) != null) 'live': store.tmuxLive(s.cwdPath),
                  'label': s.ended ? '끝남' : s.status.label,
                  if (s.agent != 'claude') 'agent': s.agent,
                  'tier': tier,
                  'team': floor.rootPath,
                  // 층 이름 — 그 칸 주인(팀장·이사) 세션에 붙인 별명을 따른다.
                  'teamName': kOffice.nameOf(floor.rootPath) ?? floor.name,
                  'top': floor.top,
                  if (running != null)
                    'run': '${running.text} · ${running.startedAt == null ? '' : '${now.difference(running.startedAt!).inMinutes}분째'}',
                  'queue': line.length,
                  if (line.isNotEmpty) 'queueText': [for (var i = 0; i < line.length; i++) '${i + 1}. ${line[i].text}'].join(' · '),
                  if (f0 != null) ...{
                    'sprite': '/todo/art/sprite?path=$key&st=${s.artStatus.artKey}&v=${identityHashCode(f0.image)}',
                    'frames': (f0.image.width / f0.src.width).round(),
                    if (f0.contentTop != null) 'head': f0.contentTop,
                    // 발밑 투명 여백 — 이만큼 내려야 발이 책상 윗선에 붙는다(9/18).
                    // 그림마다 다르므로 코드가 한 값으로 고정하면 어떤 캐릭터는 뜨고 어떤 캐릭터는 박힌다.
                    'foot': f0.bottomPadding,
                    if (f0.headCenterX != null) 'headX': f0.headCenterX,
                    // 애니메이션 — 위젯 책상과 같은 규칙(`_frameIndex`): 한 칸 180ms, 반복 구간 앞은 한 번만 지난다.
                    // 칸마다 시트 속 자리와 머리 위치가 달라서(몸이 눌렸다 펴진다) 칸별로 준다.
                    'cells': [
                      for (final f in frames!)
                        [f.src.left / f.src.width, f.contentTop, f.headCenterX],
                    ],
                    'loop': kArtStore!.loopRangeOf(s.artStatus.artKey, frames.length),
                    if (s.statusSince != null) 'since': s.statusSince!.toIso8601String(),
                  },
                  if (hat != null) ...{
                    'hat': '/todo/art/hat?tier=$tier&st=${s.artStatus.artKey}&v=${identityHashCode(hat.image)}',
                    'hatBottom': hat.contentBottom ?? hat.src.height,
                  },
                };
              }(),
        ],
      };
    case '/todo/chat/log':
      final want = ProjectStore.composeHangul(q['path'] ?? '');
      final s = store.sessions
          .where((x) => ProjectStore.composeHangul(x.cwdPath) == want)
          .firstOrNull;
      if (s == null) return {'ok': false, 'error': '그 세션이 지금 없다'};
      final limit = int.tryParse(q['limit'] ?? '') ?? 120;
      final rows = s.chat.length > limit ? s.chat.sublist(s.chat.length - limit) : s.chat;
      return {
        'ok': true,
        'name': s.name,
        'state': state(s),
        'label': s.ended ? '끝남' : s.status.label,
        'tool': s.tool,
        'entries': [
          for (final e in rows)
            {
              'kind': e.kind.name,
              'text': e.text,
              'at': e.at.toIso8601String(),
              if (e.turn?.toolLine != null) 'tools': e.turn!.toolLine,
            },
        ],
      };
  }
  return {'ok': false, 'error': '없는 주소다'};
}

AgentSession? _sessionAt(SessionStore store, String path) {
  final want = ProjectStore.composeHangul(path);
  return store.sessions.where((x) => ProjectStore.composeHangul(x.cwdPath) == want).firstOrNull;
}

/// 대화 칸의 **지금 화면** — 위젯 메시지 탭의 선택 카드·일하는 중 말풍선·헤더 칩·원본 탭 자리.
///
/// 대화 칸이 열려 있는 동안만 1.5초마다 불린다(위젯도 펼쳐 있을 때만 화면을 뜬다).
///
/// ⚠️ **상태는 여전히 훅이 정한다.** 화면은 「무엇을 고르라는지」「무엇을 하는 중인지」만
/// 채운다 — 위젯과 같은 선이다(설계 원칙 2절). 카드를 띄울지는 훅의 승인 대기이거나
/// 화면이 묻고 있을 때(`awaitingChoice`)다.
Future<Map<String, dynamic>> chatPaneApi(SessionStore store, Map<String, String> q) async {
  final s = _sessionAt(store, q['path'] ?? '');
  if (s == null) return {'ok': false, 'error': '그 세션이 지금 없다'};
  final name = Tmux.sessionName(s.cwdPath);
  final alive = Tmux.binary != null && await Tmux.hasSession(name);
  final text = alive ? await Tmux.capturePane(name) : null;
  // 대화 칸은 1.5초마다 화면을 뜬다 — 취소한 승인 대기는 여기서 바로 풀린다(30초 청소를 기다리지 않는다).
  if (alive) store.clearStaleWaiting(s, text);
  final sig = alive ? PaneView.signals(text) : s.signals;
  final busy = !s.ended && (s.status.busy || sig.working);
  final done = s.toolDoneAt;
  final writing = done != null && DateTime.now().difference(done) > const Duration(milliseconds: 700);
  final asking = alive && (PaneView.awaitingChoice(text) || s.status == AgentStatus.waiting);
  final choice = asking ? PaneChoice.parse(text) : null;
  final slider = asking && choice == null ? PaneSlider.parse(text) : null;
  final tokens = s.contextTokens;
  final tail = PaneView.activity(text, max: 6)
      .where((l) => !RegExp(r"^[^\w\s]\s+[A-Za-z][\w'-]*…").hasMatch(l))
      .toList();
  return {
    'ok': true,
    'session': name,
    'alive': alive,
    'tmux': Tmux.binary != null,
    'busy': busy,
    if (s.model != null) 'model': s.model,
    'waiting': s.status == AgentStatus.waiting,
    if (s.tool != null) 'tool': s.tool,
    if (busy) ...{
      'label': sig.label ?? (writing ? '답을 쓰는 중' : (s.tool != null ? '${s.shownStatus.label} · ${s.tool}' : s.shownStatus.label)),
      if (s.statusSince != null) 'since': s.statusSince!.toIso8601String(),
      // 스피너 줄(`✽ Canoodling… (7s · ↓ 1.2k tokens)`)은 빼고 준다 — 경과 시간은 말풍선 머리에 이미 있다.
      'activity': tail.length > 2 ? tail.sublist(tail.length - 2) : tail,
    },
    'chips': [
      if (tokens != null) formatTokens(tokens),
      if (sig.shells > 0) '셸 ${sig.shells}',
      // ⚠️ 1은 늘 떠 있다. 2 이상만 뜻이 있다.
      if (sig.agents > 1) '에이전트 ${sig.agents}',
      if (PaneView.mode(text) case final m?) m,
    ],
    if (choice != null)
      'choice': {
        'question': choice.question,
        'lead': choice.lead,
        'hint': choice.hint,
        'multi': choice.multi,
        'next': choice.isNext,
        if (choice.tabs.isNotEmpty) 'tabs': [for (final t in choice.tabs) t.toJson()],
        if (choice.tabAt != null) 'tabAt': choice.tabAt,
        'canSubmit': choice.toSubmit != null,
        if (choice.cursor != null) 'cursor': choice.cursor,
        if (choice.preview.isNotEmpty) 'preview': choice.preview,
        'options': [
          for (final o in choice.options)
            {'n': o.number, 'text': o.text, if (o.detail != null) 'detail': o.detail, if (o.checked != null) 'checked': o.checked},
        ],
      },
    if (slider != null)
      'slider': {'title': slider.title, 'hint': slider.hint, 'options': slider.options, 'current': slider.current},
    // 읽어내지 못한 창 — 화면 꼬리만 보여 준다. 고르는 것은 원본에서.
    if (asking && choice == null && slider == null) 'screen': PaneView.activity(text, max: 5),
    if (q['raw'] == '1' && text != null) 'raw': text,
  };
}

/// 대화 칸에 끌어다 놓거나 붙여넣은 파일을 받아 둔다. 입력창에 박을 `@경로`를 돌려준다.
///
/// 브라우저는 파일의 **원래 경로를 알려 주지 않는다.** 그래서 위젯처럼 `@상대경로`를
/// 박을 수 없고, 내용을 받아 붙여넣기 그림과 같은 자리(`pasted/`)에 두고 그 경로를 준다.
/// ⚠️ 세션 폴더(남의 저장소)에는 떨구지 않는다 — [ClipboardImage]와 같은 이유다.
String? saveUpload(String name, List<int> bytes) {
  const maxBytes = 20 * 1024 * 1024;
  if (bytes.isEmpty || bytes.length > maxBytes) return null;
  final dir = Directory(ClipboardImage.dirPath);
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 이름은 글자·숫자·점·밑줄·하이픈만 남긴다 — 경로(`../`)가 섞여 들어오지 못하게.
    var safe = ProjectStore.composeHangul(name).replaceAll(RegExp(r'[^\w.\-가-힣]'), '_');
    safe = safe.replaceAll(RegExp(r'^\.+'), '');
    if (safe.isEmpty) safe = 'file';
    if (safe.length > 80) safe = safe.substring(safe.length - 80);
    final stamp = ClipboardImage.nameFor(DateTime.now()).replaceAll('.png', '');
    final file = File('${dir.path}/${stamp}_$safe');
    file.writeAsBytesSync(bytes);
    unawaited(ClipboardImage.sweep());
    return file.path;
  } catch (e) {
    debugPrint('올린 파일 저장 실패: $e');
    return null;
  }
}

/// 적어둔 할 일을 그 프로젝트의 클로드에게 보낸다.
///
/// **위젯에서 누르든 브라우저에서 누르든 같은 길을 탄다.** 그래야 어느 쪽에서
/// 시켰든 내가 보낸 말로 대화에 남는다.
Future<String?> sendToSession(
    SessionStore store, String cwdPath, String text) async {
  // ⚠️ 한글 경로는 풀어진 모양(NFD)으로 저장돼 있을 수 있다 — 맞춰서 찾는다.
  final want = ProjectStore.composeHangul(cwdPath);
  final session = store.sessions
      .where((s) => ProjectStore.composeHangul(s.cwdPath) == want)
      .firstOrNull;
  if (session == null) return '그 캐릭터가 지금 없다';
  if (Tmux.binary == null) return 'tmux가 없다';
  final name = Tmux.sessionName(session.cwdPath);
  if (!await Tmux.hasSession(name)) return '세션이 없다 ($name)';
  // ⚠️ 승인 대기 창에 붙여넣고 엔터를 치면 선택지가 눌린다. 그래서 보내지 않는다.
  // **다만 훅 상태만 믿지 않는다** — 대표가 그 창을 취소하면 훅이 안 울려 승인 대기에 굳고,
  // 그러면 다음 말을 영영 못 친다(대표 제보 9/18). 화면을 떠서 선택창이 아직 있을 때만 막는다.
  if (session.status == AgentStatus.waiting) {
    final pane = await Tmux.capturePane(name);
    if (!store.clearStaleWaiting(session, pane, notify: true)) {
      return '그 세션이 승인 대기 중이라 보내지 않았다 — 먼저 고르고 다시 시킨다';
    }
  }
  if (!await Tmux.sendLine(name, text)) {
    return '세션이 받지 못했다 — 터미널 입력창에 그대로 남아 있다. 그 세션이 바쁜지 보고 다시 보낸다 ($name)';
  }
  store.appendMine(session, text);
  return null;
}

/// 밖에서 들어올 때 쓰는 열쇠.
///
/// 한 번 만들어 파일에 두고 계속 쓴다. 켤 때마다 새로 만들면 폰에 해둔
/// 북마크가 매번 죽는다. gitignore 대상이다.
///
/// ⚠️ **이건 자물쇠일 뿐 금고가 아니다.** 평문 HTTP라 같은 망에 있는 누군가가
/// 작정하고 들여다보면 열쇠가 보인다. 집 와이파이와 테일스케일 안에서 쓰는
/// 것을 전제로 한 것이고, 카페 와이파이에서 그냥 열지 않는다.
class TodoKey {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'todo_key.dev$kPort.json' : 'todo_key.json');

  static String? _cached;

  static String get value => _cached ??= _loadOrCreate();

  static String _loadOrCreate() {
    final file = File(_path);
    try {
      if (file.existsSync()) {
        final got = jsonDecode(file.readAsStringSync())['key'];
        if (got is String && got.length >= 16) return got;
      }
    } catch (e) {
      debugPrint('열쇠 읽기 실패: $e');
    }
    final made = generateKey();
    try {
      file.writeAsStringSync(jsonEncode({'key': made}));
    } catch (e) {
      // 못 써도 이번 판은 돌아야 한다. 다음에 켜면 열쇠가 바뀔 뿐이다.
      debugPrint('열쇠 저장 실패: $e');
    }
    return made;
  }

  /// ⚠️ `Random()`이 아니라 `Random.secure()`다. 밖으로 열리는 자물쇠라
  /// 짐작할 수 있는 값이면 없는 것과 같다.
  static String generateKey() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// 요청이 열쇠를 들고 왔나. 주소에 실려 오거나 쿠키로 온다.
  ///
  /// 처음 한 번만 주소에 실어 보내고, 그 뒤로는 쿠키로 다닌다 — 폰에 해둔
  /// 북마크에 긴 열쇠가 안 붙어 있어도 열린다.
  static bool allows(Uri uri, List<Cookie> cookies) {
    if (uri.queryParameters['k'] == value) return true;
    return cookies.any((c) => c.name == cookieName && c.value == value);
  }

  static const String cookieName = 'cw_key';
}

/// 프로젝트의 종류. **사람이 프로젝트마다 한 번 적는다** — 거래처로 추론하지 않는다.
///
/// 「개인」이면 본업 시간에서 뺀다. 외주처럼 보여도 매출이 아니면 개인이다(대표 결정, 2026-09-14).
enum ProjectKind {
  own('자사', 'blue'),
  client('외주', 'orange'),
  personal('개인', 'gray');

  const ProjectKind(this.label, this.color);
  final String label;
  final String color;

  static ProjectKind parse(Object? raw) {
    for (final k in ProjectKind.values) {
      if (k.name == raw || k.label == raw) return k;
    }
    return ProjectKind.own;
  }
}

/// 프로젝트의 상태. 할 일의 진행사항과 **다른 목록이다** — 프로젝트는 넷이면 된다.
enum ProjectState {
  active('진행', 'blue'),
  waiting('대기', 'yellow'),
  onHold('보류', 'pink'),
  closed('종료', 'default');

  const ProjectState(this.label, this.color);
  final String label;
  final String color;

  static ProjectState parse(Object? raw) {
    for (final st in ProjectState.values) {
      if (st.name == raw || st.label == raw) return st;
    }
    return ProjectState.active;
  }
}

/// 프로젝트 한 줄. **노션이사 3/6 — 계층 없는 평평한 목록이다.**
///
/// 노션 프로젝트 DB는 상위/하위 계층에 거래처(회사) DB가 따로 붙어 있었는데,
/// 대표·이사 합의(2026-09-14)로 **칸 다섯**만 남겼다 — 이름 · 거래처 · 종류 ·
/// 폴더 · 상태. 거래처는 DB가 아니라 글자다. 정산 조건·단가는 여기 두지 않는다.
///
/// 폴더가 있으면 그 폴더가 곧 이 프로젝트다 — 캐릭터 목록(`ProjectStore`)과
/// 할 일의 프로젝트를 이 줄에 잇는 것은 다음 단계에서 한다.
class ProjectRow {
  ProjectRow({
    required this.id,
    required this.name,
    this.client = '',
    this.kind = ProjectKind.own,
    this.path,
    this.state = ProjectState.active,
    this.notionId,
    this.favorite = false,
    this.note = ProjectNote.empty,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// 이름이 바뀌어도 그대로인 열쇠. 할 일이 이것으로 프로젝트를 가리키게 된다.
  final String id;
  final String name;

  /// 거래처 이름(글자). 개인 일이면 비운다.
  final String client;
  final ProjectKind kind;

  /// 폴더 절대경로. 폴더 없는 옛 외주 프로젝트는 `null`이다.
  final String? path;
  final ProjectState state;

  /// 노션에서 옮겨왔으면 그 페이지 ID.
  final String? notionId;

  /// ⭐ 즐겨찾기. 할 일 리스트·보드의 기본 범위가 이것이다(2026-09-14 대표 확정).
  /// 이 파일에 두므로 폰에서 바꿔도 같은 값이고, 세션도 `GET /todo/api/projects`로 읽는다.
  final bool favorite;

  /// 사람이 쓰는 기록 — 소개·결정 사항·보류·링크(프로젝트 기록 페이지, 2026-09-15).
  final ProjectNote note;
  final DateTime at;

  /// 새 ID. 적은 시각을 쓴다 — 한 사람이 같은 밀리초에 둘을 만들 일은 없다.
  static String newId(DateTime t) => 'p${t.millisecondsSinceEpoch}';

  ProjectRow copyWith({
    String? name,
    String? client,
    ProjectKind? kind,
    String? path,
    bool clearPath = false,
    ProjectState? state,
    bool? favorite,
    ProjectNote? note,
  }) =>
      ProjectRow(
        id: id,
        name: name ?? this.name,
        client: client ?? this.client,
        kind: kind ?? this.kind,
        path: clearPath ? null : (path ?? this.path),
        state: state ?? this.state,
        notionId: notionId,
        favorite: favorite ?? this.favorite,
        note: note ?? this.note,
        at: at,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (client.isNotEmpty) 'client': client,
        'kind': kind.name,
        if (path != null) 'path': path,
        'state': state.name,
        if (notionId != null) 'notionId': notionId,
        if (favorite) 'favorite': true,
        if (!note.isEmpty) 'note': note.toJson(),
        'at': at.toIso8601String(),
      };

  static ProjectRow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      return null;
    }
    final path = raw['path'] as String?;
    return ProjectRow(
      id: id,
      name: name,
      client: raw['client'] as String? ?? '',
      kind: ProjectKind.parse(raw['kind']),
      path: (path == null || path.isEmpty) ? null : path,
      state: ProjectState.parse(raw['state']),
      notionId: raw['notionId'] as String?,
      favorite: raw['favorite'] == true,
      note: ProjectNote.fromJson(raw['note']),
      at: DateTime.tryParse(raw['at'] as String? ?? ''),
    );
  }
}

/// 기록 한 줄 — 결정 사항·보류 이유(날짜·무엇·근거)나 링크(이름·주소).
class NoteEntry {
  const NoteEntry({this.date = '', required this.text, this.why = ''});
  final String date; // YYYY-MM-DD
  final String text; // 결정·보류면 한 줄, 링크면 이름
  final String why; // 결정·보류면 근거, 링크면 주소

  Map<String, dynamic> toJson() => {
        if (date.isNotEmpty) 'date': date,
        'text': text,
        if (why.isNotEmpty) 'why': why,
      };

  /// 받은 날짜 칸을 고른다. 비었으면 [today], 틀리면 null(거절).
  /// 결정 기록은 「언제 정했나」로 찾는다 — 노션에서 옮긴 34줄이 전부 이관 날짜로 찍혀 찾을 수 없었다(9/15).
  /// 그래서 실제 날짜를 받되, 없는 날(2월 30일)·앞으로의 날은 받지 않는다.
  static String? dateOf(Object? raw, String today) {
    final v = (raw as String? ?? '').trim();
    if (v.isEmpty) return today;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
    if (m == null) return null;
    final d = DateTime.tryParse(v);
    if (d == null || d.month != int.parse(m.group(2)!) || d.day != int.parse(m.group(3)!)) return null;
    return v.compareTo(today) > 0 ? null : v;
  }

  static NoteEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = (raw['text'] as String? ?? '').trim();
    if (text.isEmpty) return null;
    return NoteEntry(date: raw['date'] as String? ?? '', text: text, why: raw['why'] as String? ?? '');
  }
}

/// 프로젝트 기록 — **사람이 쓰는 칸만 담는다.** 현황·문서 목록은 열 때마다 계산한다(낡지 않게).
///
/// 노션 프로젝트 페이지의 본문이 워쳐로 옮기며 빠졌다(2026-09-14). 태스크에 안 남는
/// 「왜 이렇게 했나」가 갈 곳이다. 거래처 이름·금액이 적힐 수 있다 — projects.json은 gitignore다.
class ProjectNote {
  const ProjectNote({this.intro = '', this.decisions = const [], this.holds = const [], this.links = const []});
  final String intro;
  final List<NoteEntry> decisions;
  final List<NoteEntry> holds;
  final List<NoteEntry> links;

  static const empty = ProjectNote();
  static const kinds = ['decisions', 'holds', 'links'];

  bool get isEmpty => intro.trim().isEmpty && decisions.isEmpty && holds.isEmpty && links.isEmpty;

  List<NoteEntry> listOf(String kind) => switch (kind) {
        'decisions' => decisions,
        'holds' => holds,
        'links' => links,
        _ => const [],
      };

  ProjectNote copyWith({String? intro, List<NoteEntry>? decisions, List<NoteEntry>? holds, List<NoteEntry>? links}) =>
      ProjectNote(
        intro: intro ?? this.intro,
        decisions: decisions ?? this.decisions,
        holds: holds ?? this.holds,
        links: links ?? this.links,
      );

  /// 한 줄 덧붙이기. **결정·보류는 날짜가 새 것이 위로** 온다 — 최근 결정이 먼저 읽혀야 한다.
  /// 지난 날짜로 적으면 그 날짜 자리에 끼운다(같은 날이면 먼저 있던 것보다 위). 날짜 없는 줄은 맨 밑이다.
  /// ⚠️ 저장 순서가 곧 보이는 순서다 — 지우기가 줄 번호(index)로 가리키므로 그리기에서 따로 정렬하지 않는다.
  ProjectNote added(String kind, NoteEntry e) => switch (kind) {
        'decisions' => copyWith(decisions: _placed(decisions, e)),
        'holds' => copyWith(holds: _placed(holds, e)),
        'links' => copyWith(links: [...links, e]),
        _ => this,
      };

  static List<NoteEntry> _placed(List<NoteEntry> list, NoteEntry e) {
    if (e.date.isEmpty) return [...list, e];
    final at = list.indexWhere((x) => x.date.isEmpty || x.date.compareTo(e.date) <= 0);
    return at < 0 ? [...list, e] : ([...list]..insert(at, e));
  }

  /// 한 줄 고치기 — 빼고 다시 끼운다(날짜가 바뀌면 자리도 바뀐다). 줄 번호가 틀리면 그대로 둔다.
  ProjectNote editedAt(String kind, int index, NoteEntry Function(NoteEntry) change) {
    final list = listOf(kind);
    if (kind == 'links' || index < 0 || index >= list.length) return this;
    return removedAt(kind, index).added(kind, change(list[index]));
  }

  ProjectNote removedAt(String kind, int index) {
    List<NoteEntry> drop(List<NoteEntry> l) =>
        index < 0 || index >= l.length ? l : ([...l]..removeAt(index));
    return switch (kind) {
      'decisions' => copyWith(decisions: drop(decisions)),
      'holds' => copyWith(holds: drop(holds)),
      'links' => copyWith(links: drop(links)),
      _ => this,
    };
  }

  Map<String, dynamic> toJson() => {
        if (intro.trim().isNotEmpty) 'intro': intro,
        if (decisions.isNotEmpty) 'decisions': [for (final e in decisions) e.toJson()],
        if (holds.isNotEmpty) 'holds': [for (final e in holds) e.toJson()],
        if (links.isNotEmpty) 'links': [for (final e in links) e.toJson()],
      };

  static ProjectNote fromJson(Object? raw) {
    if (raw is! Map) return empty;
    List<NoteEntry> list(String k) =>
        [for (final x in (raw[k] as List? ?? const [])) if (NoteEntry.fromJson(x) case final e?) e];
    return ProjectNote(intro: raw['intro'] as String? ?? '', decisions: list('decisions'), holds: list('holds'), links: list('links'));
  }
}

/// 프로젝트 폴더의 문서 한 건 — **파일 이름만** 본다(`YYYYMMDD_구분_내용.확장자`). 내용은 열지 않는다.
class ProjectDoc {
  const ProjectDoc({required this.date, required this.kind, required this.title, required this.path});
  final String date; // YYYY-MM-DD
  final String kind;
  final String title;
  final String path; // 절대경로

  Map<String, dynamic> toJson() => {'date': date, 'kind': kind, 'title': title, 'path': path};
}

/// 프로젝트 폴더에서 날짜형 문서를 모은다.
///
/// 지키는 선(계획서 2026-09-15): 이름만 읽는다 · 깊이 2 · 숨김·빌드 폴더 제외 · 보안 폴더
/// (95_·99_사업·98_가계부)와 이름에 계약·인감·주민·통장·사업자등록증이 든 파일은 목록에서도 뺀다 ·
/// 다른 프로젝트로 등록된 하위 폴더는 그 프로젝트 몫이라 뺀다(루트가 전부를 끌어오지 않게).
class ProjectDocs {
  static final RegExp _name = RegExp(r'^(\d{4})(\d{2})(\d{2})_([^_]+)_(.+)\.[A-Za-z0-9]+$');
  static const _skipDirs = {'build', 'node_modules', 'Pods', 'ios', 'android', 'macos', 'windows', 'linux', 'web'};
  static const _forbiddenWords = ['계약', '인감', '주민', '통장', '사업자등록증'];
  static bool _forbiddenDir(String seg) =>
      seg.startsWith('.') || _skipDirs.contains(seg) || seg.startsWith('95_') ||
      seg.startsWith('99_사업') || seg.startsWith('98_가계부');

  /// 파일 이름 하나를 문서로. 규칙에 안 맞거나 금지어가 있으면 `null`.
  static ProjectDoc? parse(String path) {
    final name = ProjectStore.composeHangul(path.split('/').last);
    if (_forbiddenWords.any(name.contains)) return null;
    final m = _name.firstMatch(name);
    if (m == null) return null;
    final mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return ProjectDoc(
        date: '${m.group(1)}-${m.group(2)}-${m.group(3)}',
        kind: m.group(4)!,
        title: m.group(5)!.replaceAll('_', ' '),
        path: ProjectStore.composeHangul(path));
  }

  static final Map<String, (DateTime, List<ProjectDoc>)> _cache = {};

  /// 새 것이 위. 30초 동안은 다시 훑지 않는다.
  static List<ProjectDoc> scan(String root, {Iterable<String> otherProjects = const []}) {
    final key = ProjectStore.composeHangul(root);
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 30)) return hit.$2;
    final others = {for (final o in otherProjects) ProjectStore.composeHangul(o)}..remove(key);
    final out = <ProjectDoc>[];
    void walk(Directory dir, int depth) {
      List<FileSystemEntity> kids;
      try {
        kids = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in kids) {
        final seg = ProjectStore.composeHangul(e.path.split('/').last);
        if (e is Directory) {
          if (depth >= 2 || _forbiddenDir(seg) || others.contains(ProjectStore.composeHangul(e.path))) continue;
          walk(e, depth + 1);
        } else if (e is File) {
          final doc = parse(e.path);
          if (doc != null) out.add(doc);
        }
      }
    }
    final dir = Directory(root);
    if (dir.existsSync()) walk(dir, 1);
    out.sort((a, b) => b.date.compareTo(a.date) != 0 ? b.date.compareTo(a.date) : a.title.compareTo(b.title));
    _cache[key] = (DateTime.now(), out);
    return out;
  }
}

/// 프로젝트 목록을 디스크에 남긴다. 할 일(`TodoStore`)과 같은 방식이다.
///
/// ⚠️ **거래처 이름이 들어 있다.** gitignore 대상이고, 공개 저장소에 넣지 않는다
/// (2026-09-09에 저장소 이력에서 거래처 이름을 도려낸 적이 있다).
class ProjectDbStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'projects.dev$kPort.json' : 'projects.json');

  static const int version = 1;

  static Map<String, dynamic> encode(List<ProjectRow> rows) => {
        'version': version,
        'projects': rows.map((r) => r.toJson()).toList(),
      };

  static List<ProjectRow> decode(Object? raw) {
    if (raw is! Map || raw['projects'] is! List) return [];
    final seen = <String>{};
    final out = <ProjectRow>[];
    for (final r in raw['projects'] as List) {
      final row = ProjectRow.fromJson(r);
      // 같은 ID가 둘이면 앞엣것만 둔다 — 고칠 때 어느 줄인지 모르게 된다.
      if (row != null && seen.add(row.id)) out.add(row);
    }
    return out;
  }

  /// **상태 순서(진행→대기→보류→종료) → 종류 → 이름.** 끝난 것이 아래로 간다.
  static List<ProjectRow> sorted(List<ProjectRow> rows) {
    final out = [...rows];
    out.sort((a, b) {
      if (a.state != b.state) return a.state.index.compareTo(b.state.index);
      if (a.kind != b.kind) return a.kind.index.compareTo(b.kind.index);
      return a.name.compareTo(b.name);
    });
    return out;
  }

  static List<ProjectRow> load() {
    final file = File(_path);
    if (!file.existsSync()) return [];
    try {
      return decode(jsonDecode(file.readAsStringSync()));
    } catch (e) {
      debugPrint('프로젝트 불러오기 실패: $e');
      return [];
    }
  }

  /// 할 일처럼 두 겹으로 남긴다 — 직전본과 하루 한 번 날짜 스냅샷.
  static void save(List<ProjectRow> rows) {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        file.copySync('$_path.bak');
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final snapshot = File('$_path.$day.bak');
        if (!snapshot.existsSync()) file.copySync(snapshot.path);
      }
      file.writeAsStringSync(jsonEncode(encode(rows)));
    } catch (e) {
      debugPrint('프로젝트 저장 실패: $e');
    }
  }
}

/// 지금 들고 있는 프로젝트 목록. 할 일 페이지가 이것을 보고 고친다.
class ProjectDb extends ChangeNotifier {
  final List<ProjectRow> _rows = ProjectDbStore.load();

  List<ProjectRow> get all => List.unmodifiable(_rows);

  ProjectRow? byId(String id) => _rows.where((r) => r.id == id).firstOrNull;

  void add(String name, {ProjectState state = ProjectState.active}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final now = DateTime.now();
    var id = ProjectRow.newId(now);
    // 연달아 만들어 밀리초가 겹쳐도 열쇠는 안 겹치게 한다.
    while (byId(id) != null) {
      id = '${id}x';
    }
    _rows.add(ProjectRow(id: id, name: trimmed, state: state, at: now));
    _save();
  }

  void edit(String id,
      {String? name,
      String? client,
      ProjectKind? kind,
      String? path,
      bool clearPath = false,
      ProjectState? state,
      bool? favorite}) {
    final i = _rows.indexWhere((r) => r.id == id);
    if (i < 0) return;
    final title = name?.trim();
    if (title != null && title.isEmpty) return;
    _rows[i] = _rows[i].copyWith(
        name: title,
        client: client?.trim(),
        kind: kind,
        path: path?.trim(),
        clearPath: clearPath,
        state: state,
        favorite: favorite);
    _save();
  }

  /// 이 폴더를 가리키는 프로젝트 줄을 보장한다 — 없으면 폴더 이름으로 새로 만든다.
  ///
  /// 할 일 API는 `projects.json`에 폴더가 있어야 세션을 받아 준다(`ApiScope`). 처음 설정에서 폴더를
  /// 등록할 때 이것을 같이 부르지 않으면, 캐릭터는 뜨는데 세션이 할 일을 쓰려 하면 「등록된 프로젝트
  /// 폴더가 아니다」로 거절당한다.
  void ensureFolder(String rawPath) {
    final path = ProjectStore.normalize(rawPath);
    if (path.isEmpty || _rows.any((r) => r.path != null && ProjectStore.normalize(r.path!) == path)) return;
    final now = DateTime.now();
    var id = ProjectRow.newId(now);
    while (byId(id) != null) {
      id = '${id}x';
    }
    _rows.add(ProjectRow(id: id, name: path.split('/').last, path: path, at: now));
    _save();
  }

  /// 기록을 통째로 바꾼다. 페이지의 한 줄 추가·지우기가 이 길을 쓴다.
  void setNote(String id, ProjectNote Function(ProjectNote) change) {
    final i = _rows.indexWhere((r) => r.id == id);
    if (i < 0) return;
    _rows[i] = _rows[i].copyWith(note: change(_rows[i].note));
    _save();
  }

  void remove(String id) {
    final before = _rows.length;
    _rows.removeWhere((r) => r.id == id);
    if (_rows.length != before) _save();
  }

  void _save() {
    ProjectDbStore.save(_rows);
    notifyListeners();
  }
}

/// 근무일의 상태. 노션 근무기록의 `상태`와 같다.
enum WorkState {
  working('근무중', 'blue'),
  onBreak('휴게중', 'yellow'),
  done('완료', 'green');

  const WorkState(this.label, this.color);
  final String label;
  final String color;

  static WorkState parse(Object? raw) {
    for (final st in WorkState.values) {
      if (st.name == raw || st.label == raw) return st;
    }
    // 노션에 한때 「휴게」라는 옵션도 있었다.
    return raw == '휴게' ? WorkState.onBreak : WorkState.working;
  }
}

/// 근무강도. 월 130시간 가용 가정을 검증하는 데이터라 가벼운 날도 빠뜨리지 않는다.
enum WorkIntensity {
  focus('집중', 'purple'),
  light('가볍게', 'gray');

  const WorkIntensity(this.label, this.color);
  final String label;
  final String color;

  static WorkIntensity? parse(Object? raw) {
    for (final w in WorkIntensity.values) {
      if (w.name == raw || w.label == raw) return w;
    }
    // ⚠️ 노션 옵션에 오타 「가벼게」가 섞여 있었다(9/12 행). 하나로 합친다.
    return raw == '가벼게' ? WorkIntensity.light : null;
  }
}

/// 근무일 하루. **노션 근무기록 DB 한 행이다**(노션이사, 2026-09-14).
///
/// 날짜가 열쇠다 — 하루 한 행. 시각은 `HH:MM` 글자로 둔다(노션과 같다).
/// ⚠️ **시각은 부르는 쪽이 `date`로 확인한 값만 넣는다.** 서버가 지금 시각을
/// 끼워 넣지 않는다 — 추정한 시각이 기록에 섞이면 되돌릴 근거가 없다.
///
/// ⚠️ 타임라인에 외주 금액·거래처·개인 일정이 섞인다. `worklog.json`은 gitignore다.
class WorkDay {
  WorkDay({
    required this.date,
    this.clockIn,
    this.clockOut,
    this.breakMin = 0,
    this.breakFrom,
    this.state = WorkState.working,
    this.timeline = '',
    this.intensity,
    this.actualHours,
    this.muwidaraniHours,
    this.notionId,
  });

  /// `YYYY-MM-DD`.
  final String date;
  final String? clockIn;
  final String? clockOut;

  /// 쌓인 휴게(분).
  final int breakMin;

  /// 휴게중이면 그 시작 시각. 끝낼 때 이것과의 차이를 [breakMin]에 더한다.
  final String? breakFrom;
  final WorkState state;

  /// 「/」로 이어 붙인 서술.
  final String timeline;
  final WorkIntensity? intensity;

  /// 실근무(시간, 소수 1자리). 퇴근할 때 계산해 둔다. 노션에서 온 값은 그대로 둔다.
  final double? actualHours;

  /// 무위다라니(시간). 세션 기록이 생기면 실근무 − 개인 프로젝트 시간으로 채운다.
  final double? muwidaraniHours;
  final String? notionId;

  /// 노션 제목 모양 — 「2026-09-14 (월)」.
  String get title {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    const w = ['월', '화', '수', '목', '금', '토', '일'];
    return '$date (${w[d.weekday - 1]})';
  }

  WorkDay copyWith({
    String? clockIn,
    String? clockOut,
    int? breakMin,
    String? breakFrom,
    bool clearBreakFrom = false,
    WorkState? state,
    String? timeline,
    WorkIntensity? intensity,
    double? actualHours,
    double? muwidaraniHours,
  }) =>
      WorkDay(
        date: date,
        clockIn: clockIn ?? this.clockIn,
        clockOut: clockOut ?? this.clockOut,
        breakMin: breakMin ?? this.breakMin,
        breakFrom: clearBreakFrom ? null : (breakFrom ?? this.breakFrom),
        state: state ?? this.state,
        timeline: timeline ?? this.timeline,
        intensity: intensity ?? this.intensity,
        actualHours: actualHours ?? this.actualHours,
        muwidaraniHours: muwidaraniHours ?? this.muwidaraniHours,
        notionId: notionId,
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        'title': title,
        if (clockIn != null) 'clockIn': clockIn,
        if (clockOut != null) 'clockOut': clockOut,
        'breakMin': breakMin,
        if (breakFrom != null) 'breakFrom': breakFrom,
        'state': state.name,
        if (timeline.isNotEmpty) 'timeline': timeline,
        if (intensity != null) 'intensity': intensity!.name,
        if (actualHours != null) 'actualHours': actualHours,
        if (muwidaraniHours != null) 'muwidaraniHours': muwidaraniHours,
        if (notionId != null) 'notionId': notionId,
      };

  static WorkDay? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final date = raw['date'];
    if (date is! String || DateTime.tryParse(date) == null) return null;
    return WorkDay(
      date: date,
      clockIn: raw['clockIn'] as String?,
      clockOut: raw['clockOut'] as String?,
      breakMin: (raw['breakMin'] as num?)?.toInt() ?? 0,
      breakFrom: raw['breakFrom'] as String?,
      state: WorkState.parse(raw['state']),
      timeline: raw['timeline'] as String? ?? '',
      intensity: WorkIntensity.parse(raw['intensity']),
      actualHours: (raw['actualHours'] as num?)?.toDouble(),
      muwidaraniHours: (raw['muwidaraniHours'] as num?)?.toDouble(),
      notionId: raw['notionId'] as String?,
    );
  }
}

/// 근무기록의 규칙과 디스크. 규칙은 순수 함수라 테스트로 굳힌다.
class WorkLogStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'worklog.dev$kPort.json' : 'worklog.json');

  static const int version = 1;

  /// `HH:MM`을 분으로. 모양이 틀리면 `null`.
  static int? minutesOf(String? hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm?.trim() ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return h * 60 + mi;
  }

  /// **실근무 = 퇴근 − 출근 − 휴게**, 시간 단위 소수 1자리. 자정을 넘기면 하루를 더한다.
  static double? actualHoursOf(String? clockIn, String? clockOut, int breakMin) {
    final a = minutesOf(clockIn), b = minutesOf(clockOut);
    if (a == null || b == null) return null;
    var span = b - a;
    if (span < 0) span += 24 * 60;
    final worked = span - breakMin;
    return (worked < 0 ? 0 : worked / 60 * 10).round() / 10;
  }

  // ── 대표의 말이 트리거다 ── 일 시작 · 점심/저녁 시작 · 끝 · 퇴근

  /// 「일 시작」. 행을 만들고 출근을 찍는다.
  static (WorkDay?, String?) start(WorkDay? today, String date, String time) {
    if (minutesOf(time) == null) return (null, '시각은 HH:MM이다');
    if (today?.clockIn != null) return (null, '이미 출근이 찍혀 있다 (${today!.clockIn})');
    return (WorkDay(date: date, clockIn: time, state: WorkState.working), null);
  }

  /// 「점심·저녁 시작」. 휴게중으로 두고 시작 시각을 기억한다.
  static (WorkDay?, String?) breakStart(WorkDay? d, String time, {String? note}) {
    if (d == null) return (null, '그 날짜 행이 없다 — 출근부터');
    if (minutesOf(time) == null) return (null, '시각은 HH:MM이다');
    if (d.state == WorkState.onBreak) return (null, '이미 휴게중이다 (${d.breakFrom})');
    if (d.state == WorkState.done) return (null, '이미 퇴근했다');
    return (
      d.copyWith(state: WorkState.onBreak, breakFrom: time,
          timeline: appendTimeline(d.timeline, note == null ? null : '$time $note')),
      null
    );
  }

  /// 「점심·저녁 끝」. 휴게를 누적하고 근무중으로 되돌린다.
  static (WorkDay?, String?) breakEnd(WorkDay? d, String time, {String? note}) {
    if (d == null) return (null, '그 날짜 행이 없다');
    final to = minutesOf(time), from = minutesOf(d.breakFrom);
    if (to == null) return (null, '시각은 HH:MM이다');
    if (d.state != WorkState.onBreak || from == null) return (null, '휴게중이 아니다');
    var span = to - from;
    if (span < 0) span += 24 * 60;
    return (
      d.copyWith(state: WorkState.working, breakMin: d.breakMin + span, clearBreakFrom: true,
          timeline: appendTimeline(d.timeline, note == null ? null : '$time $note')),
      null
    );
  }

  /// 「퇴근」. 퇴근을 찍고 실근무를 계산한다. 휴게중이었으면 거절한다 — 휴게를 먼저 끝낸다.
  static (WorkDay?, String?) end(WorkDay? d, String time) {
    if (d == null) return (null, '그 날짜 행이 없다');
    if (minutesOf(time) == null) return (null, '시각은 HH:MM이다');
    if (d.state == WorkState.onBreak) return (null, '휴게중이다 — 휴게 끝을 먼저 찍는다');
    if (d.clockIn == null) return (null, '출근이 없다');
    return (
      d.copyWith(clockOut: time, state: WorkState.done,
          actualHours: actualHoursOf(d.clockIn, time, d.breakMin)),
      null
    );
  }

  /// 타임라인은 「 / 」로 이어 붙인다.
  static String appendTimeline(String timeline, String? text) {
    final t = text?.trim() ?? '';
    if (t.isEmpty) return timeline;
    return timeline.trim().isEmpty ? t : '${timeline.trim()} / $t';
  }

  static Map<String, dynamic> encode(List<WorkDay> days) => {
        'version': version,
        'days': days.map((d) => d.toJson()).toList(),
      };

  static List<WorkDay> decode(Object? raw) {
    if (raw is! Map || raw['days'] is! List) return [];
    final byDate = <String, WorkDay>{};
    for (final r in raw['days'] as List) {
      final d = WorkDay.fromJson(r);
      // 하루 한 행이다. 같은 날짜가 둘이면 앞엣것만 둔다.
      if (d != null) byDate.putIfAbsent(d.date, () => d);
    }
    return byDate.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  static List<WorkDay> load() {
    final file = File(_path);
    if (!file.existsSync()) return [];
    try {
      return decode(jsonDecode(file.readAsStringSync()));
    } catch (e) {
      debugPrint('근무기록 불러오기 실패: $e');
      return [];
    }
  }

  static void save(List<WorkDay> days) {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        file.copySync('$_path.bak');
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final snapshot = File('$_path.$day.bak');
        if (!snapshot.existsSync()) file.copySync(snapshot.path);
      }
      file.writeAsStringSync(jsonEncode(encode(days)));
    } catch (e) {
      debugPrint('근무기록 저장 실패: $e');
    }
  }
}

/// 지금 들고 있는 근무기록. 날짜 최신이 앞이다.
class WorkLog extends ChangeNotifier {
  final List<WorkDay> _days = WorkLogStore.load();

  List<WorkDay> get all => List.unmodifiable(_days);

  WorkDay? of(String date) => _days.where((d) => d.date == date).firstOrNull;

  /// 규칙 함수의 결과를 담는다. 에러면 아무것도 안 바꾸고 에러를 돌려준다.
  String? apply(String date, (WorkDay?, String?) result) {
    final (next, error) = result;
    if (error != null || next == null) return error ?? '바뀐 것이 없다';
    _days.removeWhere((d) => d.date == date);
    _days.add(next);
    _days.sort((a, b) => b.date.compareTo(a.date));
    WorkLogStore.save(_days);
    notifyListeners();
    return null;
  }
}

/// 앱을 켤 때의 모양 — `dashboard`(앱 창 안에 대시보드) 또는 `widget`(바탕화면의 작은 책상).
///
/// 대표 결정(2026-09-15): 앱을 켜면 브라우저 없이 앱 창 안에 대시보드가 뜬다. 훅·서버·폰 접속은
/// 어느 모양이든 똑같이 돈다 — 바뀌는 것은 창 하나다. ⚙ 설정에서 바꾸고 **다음에 켤 때** 적용된다.
/// 확인용 판(포트가 다른 옆 인스턴스)은 기본이 위젯이다 — 빌드할 때마다 큰 창이 뜨면 대표 화면을 가린다.
/// `CLAUDE_WATCHER_MODE`가 있으면 그것이 이긴다.
class LaunchModeStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'launch_mode.dev$kPort.json' : 'launch_mode.json');

  static Map<String, dynamic> _read() {
    try {
      final f = File(_path);
      if (!f.existsSync()) return {};
      final d = jsonDecode(f.readAsStringSync());
      return d is Map<String, dynamic> ? d : {};
    } catch (_) {
      return {};
    }
  }

  static String load() {
    if (!kWidgetMode) return 'dashboard';
    final env = Platform.environment['CLAUDE_WATCHER_MODE'];
    if (env == 'dashboard' || env == 'widget') return env!;
    final m = _read()['mode'];
    if (m == 'dashboard' || m == 'widget') return m as String;
    return kIsDevInstance ? 'widget' : 'dashboard';
  }

  static void save(String mode) => _write({..._read(), 'mode': mode});

  /// 대시보드 창의 자리와 크기. 화면 밖이면 버린다(쓰는 쪽에서 확인).
  static Rect? loadFrame() {
    final f = _read()['frame'];
    if (f is! List || f.length != 4) return null;
    final v = [for (final x in f) (x as num).toDouble()];
    return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
  }

  static void saveFrame(Rect r) => _write({..._read(), 'frame': [r.left, r.top, r.width, r.height]});

  static void _write(Map<String, dynamic> d) {
    try {
      File(_path).writeAsStringSync(jsonEncode(d));
    } catch (e) {
      debugPrint('켜는 모양 저장 실패: $e');
    }
  }
}

/// 할 일 패널을 펴 두었는지만 따로 기억한다.
///
/// 창 자리처럼 **확인용 판과 갈라 둔다.** 같이 쓰면 확인하려고 띄운 판이
/// 본 판의 상태를 덮어쓴다.
class TodoOpenStore {
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'todo_open.dev$kPort.json' : 'todo_open.json');

  static bool load() {
    try {
      final f = File(_path);
      if (!f.existsSync()) return false;
      return jsonDecode(f.readAsStringSync())['open'] == true;
    } catch (_) {
      return false;
    }
  }

  static void save(bool open) {
    try {
      File(_path).writeAsStringSync(jsonEncode({'open': open}));
    } catch (e) {
      debugPrint('할 일 패널 상태 저장 실패: $e');
    }
  }
}

class ChatStore {
  /// ⚠️ **확인용 판은 대화도 따로 담는다.** 저장은 지금 살아 있는 세션을
  /// 통째로 다시 쓰는 방식이라, 같은 파일을 쓰면 확인하려고 띄운 판이
  /// 본 판에 쌓인 대화를 덮어써서 날려 버린다. 창 자리를 갈라놓은 것과 같은 이유다.
  static String get _path => resolveConfigPath(
      kIsDevInstance ? 'chat_log.dev$kPort.json' : 'chat_log.json');

  /// 저장을 몰아서 한다. 도구 줄은 초당 여러 번 붙으므로 그때마다 쓰면
  /// 디스크를 쉬지 않고 두드린다.
  static Timer? _debounce;

  /// 미룬 저장이 처음 생긴 시각.
  ///
  /// 몰아 쓰기만 하면 **끝나지 않는 턴에서 영영 안 써진다.** 도구 줄이
  /// 3초 안에 계속 붙으면 타이머가 매번 처음으로 돌아가기 때문이다.
  /// 그래서 처음 미룬 지 [_maxWait]가 지나면 그 자리에서 쓴다.
  static DateTime? _pendingSince;
  static const Duration _maxWait = Duration(seconds: 15);

  static Map<String, List<ChatEntry>> load() {
    final file = File(_path);
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return {};
      final out = <String, List<ChatEntry>>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final rows = entry.value;
        if (key is! String || rows is! List) continue;
        final list = rows.map(ChatEntry.fromJson).whereType<ChatEntry>().toList();
        if (list.isNotEmpty) out[key] = list;
      }
      debugPrint('대화 불러옴: ${out.length}개 세션 · '
          '${out.values.fold<int>(0, (a, b) => a + b.length)}줄');
      return out;
    } catch (e) {
      // 깨진 파일 때문에 앱이 안 뜨면 안 된다. 비우고 새로 쌓는다.
      debugPrint('대화 불러오기 실패 — 비우고 시작한다: $e');
      return {};
    }
  }

  static void scheduleSave(Iterable<AgentSession> sessions,
      [Map<String, List<ChatEntry>> pending = const {}]) {
    final since = _pendingSince ??= DateTime.now();
    if (DateTime.now().difference(since) >= _maxWait) {
      saveNow(sessions, pending);
      return;
    }
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(seconds: 3), () => saveNow(sessions, pending));
  }

  /// 저장할 모양으로 만든다. 파일 쓰기와 나눠 둬야 테스트로 굳힐 수 있다.
  static Map<String, dynamic> encode(Iterable<AgentSession> sessions,
      Map<String, List<ChatEntry>> pending) {
    final data = <String, dynamic>{};
    // 안 깨어난 것을 먼저 깐다. 살아 있는 세션이 같은 키를 덮어쓰는 게 맞다.
    for (final entry in pending.entries) {
      if (entry.value.isEmpty) continue;
      data[entry.key] = entry.value.map((e) => e.toJson()).toList();
    }
    for (final s in sessions) {
      if (s.chat.isEmpty) continue;
      final prior = pending[s.cwdPath];
      if (prior == null || prior.isEmpty) {
        data[s.cwdPath] = s.chat.map((e) => e.toJson()).toList();
        continue;
      }
      // ⚠️ **복원되지 않은 대화가 같은 키에 남아 있다.** 그냥 덮어쓰면
      // 디스크에 있던 것이 통째로 사라진다. 실제로 당했다(2026-08-06) —
      // 77줄이 2줄로 줄어 있었다. 복원이 왜 실패했든, 저장이 그걸 지우는
      // 일만은 없어야 한다. 앞에 두고 겹치지 않는 것만 이어 붙인다.
      final seen = {for (final e in prior) _dedupKey(e)};
      data[s.cwdPath] = [
        ...prior,
        ...s.chat.where((e) => !seen.contains(_dedupKey(e))),
      ].map((e) => e.toJson()).toList();
    }
    return data;
  }

  static String _dedupKey(ChatEntry e) =>
      '${e.kind.name} ${e.at.toIso8601String()} ${e.text}';

  /// [pending]은 디스크에서 읽어 왔지만 **아직 세션이 깨어나지 않아** 메모리에
  /// 얹히지 못한 대화다. 이걸 같이 쓰지 않으면 저장 한 번에 통째로 지워진다.
  static void saveNow(Iterable<AgentSession> sessions,
      [Map<String, List<ChatEntry>> pending = const {}]) {
    _debounce?.cancel();
    _debounce = null;
    _pendingSince = null;
    try {
      File(_path).writeAsStringSync(jsonEncode(encode(sessions, pending)));
    } catch (e) {
      debugPrint('대화 저장 실패: $e');
    }
  }
}

class AgentSession {
  AgentSession({required this.project, String? cwd})
      : cwdPath = cwd ?? project.path,
        // 등록 폴더 자체가 아니면 그 아래에서 발견된 임시 세션이다.
        temporary = cwd != null && cwd != project.path;

  final WatchedProject project;
  /// 이 캐릭터가 대표하는 실제 폴더. 등록된 것은 project.path와 같다.
  final String cwdPath;
  /// 등록되지 않은 하위 폴더에서 발견된 세션인지.
  /// 끝나면 사라진다 — 죽은 세션이 쌓이지 않게 하려는 것이다.
  final bool temporary;
  AgentStatus status = AgentStatus.idle;
  String? tool;
  /// 완료 시 뽑아둔 마지막 응답. 펼침 패널(⑤)이 여기서 읽는다.
  /// capture-pane 결과와 절대 섞지 않는다 — 소스가 다르면 필드도 다르다.
  String? report;
  /// 훅이 알려준 transcript 경로. 나중에 다시 읽을 수 있게 들고 있는다.
  String? transcriptPath;
  /// 어느 에이전트의 세션인가 — `claude`(기본) · `codex`. 코덱스 훅은 transcript가 `~/.codex/sessions/` 아래라 그걸로 가른다(9/17 코덱스 최소 연동).
  String agent = 'claude';
  /// 지금 컨텍스트 크기(입력 토큰 합계). transcript에서 읽으므로 **접혀
  /// 있어도 갱신된다** — 화면을 떠오지 않아도 된다.
  int? contextTokens;
  /// 마지막 응답을 쓴 모델. transcript에서 읽는다 — `/model`로 바꾼 뒤 새 답이 나와야 바뀐다.
  String? model;
  /// 화면에서 주운 신호. 펼쳐 있으면 1.2초마다, 접혀 있으면 30초 청소
  /// 주기에 갱신된다. 접었다고 압축 중인 것이 안 보이면 곤란해서다.
  PaneSignals signals = const PaneSignals();
  /// 마지막 도구가 끝난 시각(`PostToolUse`). 다음 도구가 시작되면 비운다.
  ///
  /// 이게 있고 조금 지났으면 **답을 쓰는 중**이다. 도구 실행 중과 답 쓰는
  /// 중은 둘 다 `working`이라 훅 상태만으로는 갈리지 않는다.
  DateTime? toolDoneAt;
  /// transcript를 어디까지 읽었는지(바이트). 0이면 아직 한 번도 안 읽었다.
  int transcriptOffset = 0;
  /// 이미 말풍선으로 올린 발화의 uuid. 파일이 갈려 꼬리를 다시 읽을 때
  /// 같은 말이 두 번 올라가는 걸 막는다.
  final Set<String> spokenUuids = {};
  /// 마지막 턴에 무슨 도구를 몇 번 썼고 어떤 파일을 건드렸는지.
  TurnReport? turn;
  /// 주고받은 것들. 메시지 탭이 이걸 대화처럼 보여준다.
  final List<ChatEntry> chat = [];
  /// 세션이 끝났는지(SessionEnd 또는 오래 조용함). 대기와 구분해서 흐리게 그린다.
  bool ended = false;
  /// 마지막 이벤트가 실제로 온 폴더. 등록 폴더보다 깊을 수 있다.
  /// 상위 폴더를 등록해 두면 하위 폴더의 세션도 이 캐릭터로 잡히기 때문에,
  /// 어디서 온 신호인지 보여줘야 헷갈리지 않는다.
  String? lastCwd;
  // 아직 아무 이벤트도 받지 못한 상태를 구분한다. 경과시간을 안 띄우려고 쓴다.
  DateTime? updatedAt;
  // 상태가 **바뀐** 시점. 애니메이션 재생 위치를 여기서 잰다.
  // updatedAt은 같은 상태에서도 이벤트마다 갱신되므로 애니메이션 기준으로 쓸 수 없다.
  DateTime? statusSince;

  /// 폴더에서 온 본이름. 그림 폴더(`art/projects/<이름>`)와 tmux 세션이 이것을 쓴다.
  String get folderName => temporary
      ? ProjectStore.composeHangul(
          cwdPath.split('/').where((e) => e.isNotEmpty).last)
      : project.name;

  /// 화면에 보이는 이름. 대표가 별명을 지어 줬으면 그쪽이다(9/18).
  ///
  /// ⚠️ **별명으로 그림·tmux를 찾지 않는다.** 그림 찾기는 [folderName]으로 한다 —
  /// 이름을 바꿨다고 캐릭터가 기본 그림으로 떨어지면 안 된다.
  String get name => kOffice.nameOf(cwdPath) ?? folderName;

  /// 계층에서 몇 칸 아래인가. 층 안에서 정렬할 때 쓴다.
  int get depth => '/'.allMatches(cwdPath).length;
}

/// 책상 한 층. 등록된 상위 폴더 하나와 그 아래 세션들이 여기 선다.
class Floor {
  const Floor({
    required this.name,
    required this.sessions,
    required this.rootPath,
    required this.top,
    required this.depths,
  });

  final String name;
  final List<AgentSession> sessions;

  /// 이 칸의 주인이 되는 등록의 경로. 칸 하나 = 등록 하나다.
  final String rootPath;

  /// **자기 위에 등록된 조상이 없는가.** 그러면 이 칸의 주인이 이사다.
  ///
  /// ⚠️ `rootPath`와 헷갈리면 안 된다. 모든 칸이 자기 `rootPath`를 가지므로
  /// 그것만 보면 **전부 최상위로** 잡힌다. 실제로 그렇게 짰다가 일곱이 다
  /// 이사가 됐다(2026-08-07).
  final bool top;

  /// 등록 경로 → 깊이(0 이사 · 1 팀장 · 2 이상 사원).
  final Map<String, int> depths;

  /// 그 세션이 어느 계층인가.
  ///
  /// 등록 안 된 하위 폴더 세션은 언제나 사원이다. 등록된 것은 **경로 깊이**를
  /// 따른다 — `otaku_log/titles`처럼 등록했어도 팀장 아래면 사원이다.
  String tierOf(AgentSession s) {
    if (s.temporary) return kStaffCharSet;
    final d = depths[s.project.path] ?? 1;
    if (d == 0) return kDirectorCharSet;
    if (d == 1) return kManagerCharSet;
    return kStaffCharSet;
  }
}

class SessionStore extends ChangeNotifier {
  SessionStore(this._projects) {
    _projects.addListener(_syncWithProjects);
    _syncWithProjects();
    // 강제 종료된 세션을 대기로 되돌리는 청소 타이머.
    _sweeper = Timer.periodic(const Duration(seconds: 30), (_) {
      _sweepStale();
      _adoptOrphanTranscripts();
    });
    // 켜자마자 한 번 한다. 30초를 기다리면 그 사이 끝난 턴을 놓친 채로 뜬다.
    _adoptOrphanTranscripts();
    // ⚠️ **훅만으로는 말을 다 못 건진다.** 클로드가 한 마디 하고 도구를
    // 부르지 않으면 훅이 아예 울리지 않는다. 백그라운드 셸이 도는 동안에는
    // `Stop`도 한참 뒤에 오므로, 그 사이 한 말이 영영 안 뜬다.
    // 실제로 겪었다(2026-08-06) — transcript에는 있는데 화면에 없었다.
    //
    // 증분이라 값이 싸다. 파일이 안 자랐으면 길이만 재고 바로 나온다.
    _speechPump =
        Timer.periodic(const Duration(seconds: 2), (_) => _pumpAllSpeech());
  }

  final ProjectStore _projects;

  /// 턴이 끝났을 때 알린다. **할 일의 시계를 여기서 멈춘다.**
  ///
  /// ⚠️ `Todos`를 여기서 직접 부르지 않는다. 세션은 훅을 다루는 곳이고
  /// 할 일은 그 위에 얹힌 것이라, 거꾸로 매달면 테스트에서 세션 하나 만들
  /// 때마다 할 일 파일까지 딸려온다.
  void Function(String cwdPath)? onTurnEnd;

  /// 세션이 끝났을 때(`SessionEnd` 훅 · tmux에서 사라짐). 세션이 API로 시작한 시계는 여기서 멈춘다.
  void Function(String cwdPath)? onSessionGone;

  /// tmux에서 살아 있는 걸 본 세션. 여기 있다가 사라져야 「끝났다」로 친다([onSessionGone]).
  final Set<String> _wasLive = {};

  /// 훅이 준 session_id로 그 세션을 찾는다. 이름 소식을 어느 세션에 줄지 고를 때 쓴다.
  AgentSession? byId(String sessionId) => _bySessionId[sessionId];

  final Map<String, AgentSession> _byPath = {};
  /// 켤 때 디스크에서 읽어 둔 대화. 세션이 처음 설 때 한 번씩 꺼내 쓴다.
  final Map<String, List<ChatEntry>> _saved = ChatStore.load();
  /// 훅이 준 session_id → 그 세션. 한 세션의 신호가 폴더에 따라 갈라지는 것을 막는다.
  final Map<String, AgentSession> _bySessionId = {};
  /// 아예 받지 않을 폴더들. 앱을 켤 때 한 번 읽는다.
  final BlockList _blocked = BlockList.load();
  Timer? _sweeper;
  Timer? _speechPump;

  // 등록 순서를 그대로 쓴다. 상태가 바뀔 때마다 캐릭터 자리가 튀면 안 된다.
  // 등록된 것 뒤에 그 아래에서 발견된 임시 세션을 붙인다.
  List<AgentSession> get sessions {
    final out = <AgentSession>[];
    for (final p in _projects.projects) {
      final own = _byPath[p.path];
      if (own != null) out.add(own);
      final kids = _byPath.values
          .where((s) => s.temporary && s.project.path == p.path)
          .toList()
        ..sort((a, b) => a.cwdPath.compareTo(b.cwdPath));
      out.addAll(kids);
    }
    return out;
  }

  /// 파티션 목록. **칸 하나 = 한 집안.**
  ///
  /// 집안의 대표는 '자기 위에 등록된 조상이 없는' 등록이다. 그 아래에 있는 것은
  /// 따로 등록했든 하위 폴더에서 발견된 임시 세션이든 **같은 칸에 앉는다.**
  ///
  /// 어떤 폴더를 등록하고 그 안의 하위 폴더를 또 등록해도 둘은 한 칸이다.
  /// 갈라 놓고 싶으면 위쪽 등록을 해제하면 된다 — 그러면 각자 대표가 된다.
  ///
  /// 칸 순서와 칸 안의 순서 모두 등록 순서를 따른다. 자리가 튀지 않게 하려는 것이다.
  List<Floor> get floors {
    final projects = _projects.projects;

    /// 나를 품는 등록 중 **가장 가까운 것**(직속 부모). 없으면 null.
    WatchedProject? parentOf(WatchedProject p) {
      WatchedProject? best;
      for (final q in projects) {
        if (q.path == p.path) continue;
        if (!p.path.startsWith('${q.path}/')) continue;
        if (best == null || q.path.length > best.path.length) best = q;
      }
      return best;
    }

    /// 등록 깊이. 0 = 이사, 1 = 팀장, 2 이상 = 사원.
    int depthOf(WatchedProject p) {
      var d = 0;
      var cur = p;
      for (var parent = parentOf(cur); parent != null; parent = parentOf(cur)) {
        d++;
        cur = parent;
        if (d > 8) break; // 등록이 꼬여도 여기서 멈춘다
      }
      return d;
    }

    /// 이 프로젝트가 앉을 **칸의 주인**.
    ///
    /// ⚠️ 칸은 **팀장 단위**다. 사원(깊이 2 이상)은 등록했더라도 자기 칸을
    /// 갖지 않고 위의 팀장 칸에 앉는다. `otaku_log/titles`를 등록해도
    /// `otaku_log`와 한 칸이어야 한다 — QA에서 갈라져서 잡혔다(2026-08-07).
    WatchedProject boothOf(WatchedProject p) {
      var cur = p;
      while (depthOf(cur) >= 2) {
        final parent = parentOf(cur);
        if (parent == null) break;
        cur = parent;
      }
      return cur;
    }

    // 이사를 맨 앞으로. 등록 순서대로 두면 상위가 한가운데 섞여 안 보인다.
    // ⚠️ 상태로 정렬하는 것과는 다르다 — 계층은 고정이라 자리가 안 튄다.
    final booths = [
      for (final p in projects)
        if (boothOf(p).path == p.path) p
    ];
    final ordered = [
      ...booths.where((p) => depthOf(p) == 0),
      ...booths.where((p) => depthOf(p) != 0),
    ];

    final out = <Floor>[];
    for (final booth in ordered) {
      final members = <AgentSession>[];
      // 칸 주인 → 그 아래 등록(등록 순서) → 각자의 임시 세션
      for (final q in projects) {
        if (q.path != booth.path && boothOf(q).path != booth.path) continue;
        final own = _byPath[q.path];
        if (own != null) members.add(own);
        members.addAll(
          _byPath.values
              .where((s) => s.temporary && s.project.path == q.path)
              .toList()
            ..sort((a, b) => a.cwdPath.compareTo(b.cwdPath)),
        );
      }
      if (members.isNotEmpty) {
        out.add(Floor(
          name: booth.name,
          sessions: members,
          rootPath: booth.path,
          top: depthOf(booth) == 0,
          depths: {
            for (final p in projects) p.path: depthOf(p),
          },
        ));
      }
    }
    return out;
  }

  void _syncWithProjects() {
    final paths = _projects.projects.map((p) => p.path).toSet();
    // 등록이 풀린 프로젝트와 그 아래 임시 세션을 함께 걷어낸다.
    _byPath.removeWhere((path, s) =>
        s.temporary ? !paths.contains(s.project.path) : !paths.contains(path));
    for (final p in _projects.projects) {
      _byPath.putIfAbsent(p.path, () => AgentSession(project: p));
    }
    notifyListeners();
  }

  /// 살아 있는 tmux 세션 이름들. 없으면 null(= tmux를 못 쓰는 상황).
  Set<String>? _liveSessions;

  /// 그 폴더의 tmux 세션이 켜져 있나 — null은 모른다(tmux 없음·아직 안 훑음). 회의 시작 창의 출근/퇴근 구분에 쓴다.
  bool? tmuxLive(String cwd) => _liveSessions?.contains(Tmux.sessionName(cwd));

  Future<void> _sweepStale() async {
    // 먼저 tmux에게 직접 물어본다. 시간 재기보다 이쪽이 정확하다.
    // 한 번의 list-sessions로 전부 받는다 — 프로젝트마다 프로세스를 띄우면 낭비다.
    _liveSessions = await Tmux.liveSessions();
    await _refreshSignals();

    final now = DateTime.now();
    var changed = false;
    final gone = <String>[];
    for (final s in _byPath.values.toList()) {
      // 임시 세션은 자기 폴더 이름으로 tmux를 찾는다.
      final live = _liveSessions?.contains(Tmux.sessionName(s.cwdPath));

      if (live == true) {
        _wasLive.add(s.cwdPath);
        // 세션이 살아 있으면 오래 조용해도 끊긴 게 아니다.
        if (s.ended) {
          s.ended = false;
          changed = true;
        }
        continue;
      }
      if (live == false) {
        // tmux가 아는데 그 세션이 없다 = 끝났다.
        // ⚠️ tmux 밖에서 도는 세션도 여기로 온다(늘 「없다」). 살아 있는 걸 본 적이 있는 세션이
        // 사라졌을 때만 끝난 것으로 친다 — 아니면 tmux 밖 세션의 시계가 새로 고칠 때마다 멈춘다.
        if (_wasLive.remove(s.cwdPath)) onSessionGone?.call(s.cwdPath);
        if (s.temporary) {
          gone.add(s.cwdPath);
          changed = true;
          continue;
        }
        if (!s.ended || s.status != AgentStatus.idle) {
          s.status = AgentStatus.idle;
          s.statusSince = now;
          s.tool = null;
          s.ended = true;
          changed = true;
          // 흐려진 이유가 로그에 남아야 한다. 안 보이면 '왜 흐리지'를 못 푼다.
          debugPrint('세션 끝남: ${s.name} — tmux에 세션이 없다');
        }
        continue;
      }

      // tmux를 못 쓰는 경우에만 예전 방식(마지막 이벤트로부터 경과)으로 떨어진다.
      if (s.status == AgentStatus.idle || s.updatedAt == null) continue;
      if (now.difference(s.updatedAt!) > kStaleAfter) {
        if (s.temporary) {
          gone.add(s.cwdPath);
        } else {
          s.status = AgentStatus.idle;
          s.statusSince = now;
          s.tool = null;
          s.ended = true;
        }
        changed = true;
        debugPrint('세션 조용함: ${s.name} — '
            '${kStaleAfter.inMinutes}분 넘게 신호가 없다 (tmux를 못 물어봄)');
      }
    }
    for (final key in gone) {
      _byPath.remove(key);
    }
    if (changed) notifyListeners();
  }

  /// 등록되지 않은 폴더에서 온 이벤트. 등록을 권하려고 들고만 있는다.
  final Set<String> unwatched = {};

  void handleEvent(Map<String, dynamic> payload) {
    final raw = payload['cwd'] as String?;
    if (raw == null || raw.isEmpty) return;
    // ⚠️ **훅의 cwd를 그대로 믿지 않는다.** 도구가 하위 폴더에서 돌면 그
    // 하위가 오는데, 그게 첫 훅이면 세션이 통째로 엉뚱한 캐릭터에 묶인다.
    final tpath = payload['transcript_path'] as String?;
    final safeTranscript =
        (tpath != null && tpath.isNotEmpty && isTranscriptPathAllowed(tpath))
            ? tpath
            : null;
    // 코덱스 훅 — 이벤트·칸 이름이 클로드 코드와 같다(0.154.0 실측 9/17). 기록 파일은 모양이 달라 읽지 않는다
    // (허용 목록 밖이라 safeTranscript가 null → cwd 바로잡기·말 따라 읽기를 건너뛴다). 말풍선은 Stop의 last_assistant_message로만 오른다.
    final fromCodex = tpath != null && tpath.contains('/.codex/sessions/') && !tpath.contains('..');
    final cwd = resolveSessionCwd(raw, safeTranscript);
    if (cwd != raw) {
      debugPrint('cwd 바로잡음: $raw → $cwd (transcript 기준)');
    }

    // 금고 폴더는 여기서 끝낸다. 미등록 신호로도 남기지 않는다 —
    // 그 폴더에서 뭔가 돌고 있다는 사실 자체를 화면에 띄우지 않으려는 것이다.
    if (_blocked.blocks(cwd)) {
      debugPrint('차단된 폴더에서 온 이벤트 — 무시');
      return;
    }

    final event = payload['hook_event_name'] as String? ?? '';
    const known = {
      'SessionStart',
      'UserPromptSubmit',
      'PreToolUse',
      'PostToolUse',
      'Notification',
      'Stop',
      'SessionEnd',
      'PostToolUseFailure',
      'StopFailure',
      // 코덱스 훅(9/17) — 승인 창·끊기
      'PermissionRequest',
      'Interrupt',
    };
    if (!known.contains(event)) {
      debugPrint('알 수 없는 이벤트: $event');
      return;
    }

    final project = _projects.match(cwd);
    if (project == null) {
      // 등록되지 않은 폴더는 캐릭터를 만들지 않는다. 이게 죽은 세션이 쌓이는 걸 막는다.
      if (unwatched.add(ProjectStore.normalize(cwd))) notifyListeners();
      return;
    }

    // 등록 폴더보다 깊은 곳에서 온 신호는 그 층에 임시 캐릭터로 세운다.
    // 상위 하나로 뭉치면 어디서 도는 세션인지 알 수 없다.
    //
    // ⚠️ 단, **cwd만 보고 가르면 한 세션이 둘로 쪼개진다.** Bash 도구가
    // 하위 폴더에서 돌면 PreToolUse의 cwd가 그 하위 폴더로 오는데, Stop은
    // 세션 폴더로 온다. 그러면 도구 줄은 임시 캐릭터에, 응답은 본 캐릭터에
    // 각각 쌓여 어느 쪽을 열어도 반쪽만 보인다. 실제로 겪은 일이다.
    //
    // 그래서 `session_id`를 먼저 본다. 같은 세션이면 어느 폴더에서 온
    // 신호든 같은 캐릭터로 간다. 하위 폴더에서 **따로 띄운** 세션은
    // session_id가 다르므로 예전대로 제 캐릭터를 가진다.
    final normalized = ProjectStore.normalize(cwd);
    final sid = payload['session_id'] as String?;
    var session = (sid != null && sid.isNotEmpty) ? _bySessionId[sid] : null;
    if (session == null) {
      final key = normalized == project.path ? project.path : normalized;
      session = _byPath.putIfAbsent(
        key,
        () => AgentSession(
          project: project,
          cwd: normalized == project.path ? null : normalized,
        ),
      );
      if (sid != null && sid.isNotEmpty) _bySessionId[sid] = session;
      _restoreChat(session);
      debugPrint('세션 추가: ${session.name}'
          '${session.temporary ? " (임시 — ${session.cwdPath})" : ""}');
    }

    // 훅이 주는 transcript 경로는 **어느 이벤트에서든 챙긴다.**
    // 예전에는 Stop 때만 챙겨서, 턴이 끝나기 전(선택창이 떠 있는 동안)에는
    // 읽을 길이 없었다.
    if (fromCodex) session.agent = 'codex';
    if (safeTranscript != null) {
      // 다른 파일로 갈렸으면 읽은 자리를 처음으로 되돌린다.
      if (session.transcriptPath != safeTranscript) {
        session.transcriptOffset = 0;
      }
      session.transcriptPath = safeTranscript;
    }

    // ⚠️ **상태를 바꾸기 전에, 도구 줄을 붙이기 전에 부른다.**
    // 클로드는 `말 → 도구` 순으로 움직인다. 도구 줄을 먼저 붙이면 방금 한
    // 말이 그 아래로 들어가 순서가 뒤집힌다.
    _pumpSpeech(session);

    final AgentStatus next;
    switch (event) {
      case 'SessionStart':
        next = AgentStatus.idle;
        session.tool = null;
        session.ended = false;
        break;
      case 'SessionEnd':
        // 세션이 끝난 것과 살아 있는데 조용한 것은 다르다. 흐리게 그려 구분한다.
        next = AgentStatus.idle;
        session.tool = null;
        session.ended = true;
        onSessionGone?.call(session.cwdPath);
        break;
      case 'UserPromptSubmit':
        next = AgentStatus.thinking;
        session.tool = null;
        session.toolDoneAt = null;
        // 터미널에서 친 말도 대화에 남긴다. 이게 없으면 물음은 없고 대답만
        // 쌓여서, 위젯만 보면 무엇을 시켰는지 모른 채 답만 읽게 된다.
        _appendMineFromHook(session, payload);
        break;
      case 'PreToolUse':
        next = AgentStatus.working;
        session.tool = payload['tool_name'] as String?;
        // 무슨 도구를 썼는지 대화에도 남긴다. 턴이 끝나기 전에 보이는
        // 유일한 내용이라, 이게 없으면 작업 중 메시지 탭이 비어 있다.
        if (session.tool != null) {
          _appendTool(session, session.tool!, payload['tool_input']);
        }
        // 새 도구가 돌기 시작했다. 답을 쓰던 중이 아니다.
        session.toolDoneAt = null;
        break;
      case 'PostToolUse':
        next = AgentStatus.working;
        session.tool = payload['tool_name'] as String?;
        // 도구가 끝났다. 여기서부터 다음 도구가 오기 전까지는 **답을 쓰는
        // 중**이다. 그 구간에도 터미널 스피너(`Newspapering…`)는 계속 도는데,
        // 위젯은 `작업 중 · Bash`로 굳어 있어 멈춘 것처럼 보였다.
        session.toolDoneAt = DateTime.now();
        break;
      case 'Notification':
        // Notification은 여덟 가지 상황에서 온다. 전부 '승인 대기'로 뭉개면
        // 그냥 놀고 있는 것도 골드로 깜빡인다. notification_type으로 갈라낸다.
        final kind = payload['notification_type'] as String?;
        switch (kind) {
          case 'idle_prompt':
            // ⚠️ **사람이 봐야 하는 상태를 덮어쓰지 않는다.**
            //
            // 클로드 코드는 사용자가 답을 안 하고 있으면 이걸 보낸다. 그런데
            // 턴이 끝난 직후가 바로 그 상황이라, 완료 애니메이션이 한 번
            // 돌다 말고 심심함으로 떨어졌다. `bored`는 아트가 없어
            // base.png 한 장으로 떨어지므로 그림이 통째로 얼어붙는다 —
            // 결과를 보여주는 그 순간이 정확히 사라진 것이다(2026-09-08 재현).
            //
            // 완료·승인 대기·문제 발생은 **사람이 아직 봐야 할 것**이다.
            // 심심함은 아무 일도 없을 때의 상태이므로 그 셋을 밀어낼 수 없다.
            // 완료는 다음 `UserPromptSubmit`이 자연히 걷어간다.
            if (session.status == AgentStatus.done ||
                session.status == AgentStatus.waiting ||
                session.status == AgentStatus.error) {
              return;
            }
            next = AgentStatus.bored;
            break;
          case 'agent_completed':
            next = AgentStatus.done;
            break;
          case 'auth_success':
          case 'elicitation_complete':
          case 'elicitation_response':
            // 상태를 바꿀 일이 아니다. 그냥 흘려보낸다.
            return;
          default:
            // permission_prompt · agent_needs_input · elicitation_dialog,
            // 그리고 이 필드를 안 주는 옛 버전까지 여기로 온다.
            next = AgentStatus.waiting;
        }
        session.tool = null;
        break;
      // 코덱스는 승인 창을 Notification이 아니라 PermissionRequest로 알린다. 답(출력)은 주지 않는다 — 고르는 것은 사람이다.
      case 'PermissionRequest':
        next = AgentStatus.waiting;
        session.tool = payload['tool_name'] as String?;
        break;
      // 코덱스에서 사용자가 턴을 끊었다(Esc). Stop이 안 올 수 있어 여기서 시계를 정산하고 쉼으로 돌린다.
      case 'Interrupt':
        next = AgentStatus.idle;
        session.tool = null;
        session.toolDoneAt = null;
        onTurnEnd?.call(session.cwdPath);
        break;
      case 'PostToolUseFailure':
      case 'StopFailure':
        // 무언가 실패했다. 다음 이벤트가 오면 자연히 풀리므로 해제 로직은 두지 않는다.
        next = AgentStatus.error;
        session.tool = payload['tool_name'] as String?;
        break;
      case 'Stop':
        next = AgentStatus.done;
        session.tool = null;
        session.toolDoneAt = null;
        _readReport(session, payload);
        _notifyMac(session.name, session.cwdPath);
        // 시킨 일이 끝났다. 재던 시계를 멈추고 확인필요로 넘긴다.
        // ⚠️ 노션은 ⏸️를 손으로 눌러야 했는데, 그 자리를 훅이 대신한다.
        onTurnEnd?.call(session.cwdPath);
        break;
      default:
        return;
    }

    final now = DateTime.now();
    session.lastCwd = ProjectStore.normalize(cwd);
    // SessionEnd 말고 어떤 이벤트든 왔다면 세션이 살아 있다는 뜻이다.
    if (event != 'SessionEnd') session.ended = false;
    // 같은 상태가 이어지면 애니메이션을 처음으로 되돌리지 않는다.
    // 도구를 연달아 쓸 때마다 인트로 프레임이 다시 튀는 걸 막는다.
    if (session.statusSince == null || session.status != next) {
      session.statusSince = now;
    }
    if (session.temporary && next == AgentStatus.idle && session.ended) {
      // 하위에서 잠깐 떠 있던 세션이 끝났다. 자리를 비운다.
      _byPath.remove(session.cwdPath);
      debugPrint('임시 세션 정리: ${session.name}');
      notifyListeners();
      return;
    }
    session.status = next;
    session.updatedAt = now;
    final deeper = session.lastCwd != null &&
            session.lastCwd!.startsWith('${project.path}/')
        ? ' (하위: ${session.lastCwd!.substring(project.path.length + 1)})'
        : '';
    debugPrint('훅 수신: $event ← ${project.name}$deeper → ${next.label}'
        '${session.tool != null ? " · ${session.tool}" : ""}');
    notifyListeners();
  }

  void clearUnwatched() {
    if (unwatched.isEmpty) return;
    unwatched.clear();
    notifyListeners();
  }

  // 마지막 응답이 파일에 적히기 전에 Stop이 오는 일이 있다. 그때 다시 볼 간격.
  static const List<Duration> _reportRetries = [
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
    Duration(milliseconds: 3000),
  ];

  /// 접혀 있어도 화면 신호를 챙긴다.
  ///
  /// 펼친 세션만 화면을 떠오면, 접어둔 사이에 압축이 도는 것을 못 본다.
  /// 캐릭터가 멈춘 것처럼 보이는데 실제로는 몇 분씩 일하는 중이다.
  /// 실측으로 여섯 세션을 한 바퀴 도는 데 29ms였다(2026-08-07) — 30초
  /// 주기라면 부담이 없다.
  Future<void> _refreshSignals() async {
    for (final session in _byPath.values.toList()) {
      if (session.ended) continue;
      final name = Tmux.sessionName(session.cwdPath);
      if (_liveSessions != null && !_liveSessions!.contains(name)) continue;
      final pane = await Tmux.capturePane(name);
      if (pane == null) continue;
      session.signals = PaneView.signals(pane);
      clearStaleWaiting(session, pane, notify: true);
    }
  }

  /// 취소된 승인 대기를 푼다. 풀었으면 `true`.
  ///
  /// ⚠️ **선택창에서 취소하면 훅이 안 울린다.** `Notification`으로 승인 대기가 된 뒤
  /// 대표가 esc로 물리면 그 뒤로 아무 훅도 안 와서 위젯이 **승인 대기에 굳는다.**
  /// 그러면 「보내기」가 거절되어(`sendRefusal`) 다음 말을 아예 못 친다 —
  /// 대표가 「선택을 취소하니까 다음 명령을 못 친다」고 제보했다(2026-09-18).
  ///
  /// 화면에 **입력창이 살아 있으면 그 창은 닫힌 것이다.** 2절의 「화면으로 상태를
  /// 판정하지 않는다」에 대한 두 번째 예외이고, 범위는 **승인 대기를 푸는 것 하나**다 —
  /// 승인 대기로 **만드는** 것은 여전히 훅만 한다.
  bool clearStaleWaiting(AgentSession session, String? pane, {bool notify = false}) {
    if (session.status != AgentStatus.waiting) return false;
    if (pane == null || PaneView.awaitingChoice(pane)) return false;
    session.status = AgentStatus.idle;
    session.statusSince = DateTime.now();
    session.tool = null;
    debugPrint('승인 대기 풀림: ${session.name} — 화면에 입력창이 돌아왔다(취소한 듯)');
    if (notify) notifyListeners();
    return true;
  }

  /// 지켜보는 세션 전부의 transcript를 따라 읽는다.
  ///
  /// 훅이 울릴 때만 읽으면 **말하고 도구를 안 부른 경우**를 통째로 놓친다.
  /// 그 말은 다음 훅(대개 `Stop`)까지 안 뜨는데, 백그라운드 셸이 도는 턴에서는
  /// 그게 몇 분씩 걸린다.
  void _pumpAllSpeech() {
    for (final session in _byPath.values.toList()) {
      if (session.transcriptPath == null) continue;
      _pumpSpeech(session);
    }
  }

  /// 훅이 한 번도 오지 않은 등록 프로젝트의 transcript를 찾아 붙인다.
  ///
  /// **세션은 훅이 와야 생기고, 세션이 없으면 따라 읽기도 안 돈다.** 그래서
  /// 위젯이 꺼져 있던 사이에 끝난 턴은 영영 안 떴다. 실제로 겪었다
  /// (2026-08-06) — 갈아끼우는 25초 사이에 다른 세션이 답을 끝냈는데
  /// 그 답이 화면에 안 나타났다.
  ///
  /// 파일을 뒤지는 일이라 2초 폴링이 아니라 **30초 청소 주기**에 얹는다.
  /// 놓친 답이 30초 안에 뜨면 충분하다.
  void _adoptOrphanTranscripts() {
    for (final session in _byPath.values.toList()) {
      // 훅이 이미 알려줬으면 그쪽이 정확하다. 지금 도는 세션의 것이다.
      if (session.transcriptPath != null) continue;
      // ⚠️ **'세션이 없으면'으로 가르면 안 된다.** `_syncWithProjects`가
      // 등록된 프로젝트마다 세션을 **미리** 만들어 두기 때문에 그 조건은
      // 늘 거짓이고, 이 기능이 통째로 안 돈다. 실제로 그렇게 짰다가
      // 한 번도 안 도는 채로 넘어갔다(2026-08-06).
      // 가를 것은 **transcript 경로를 아직 모르는가**다.
      final path = TranscriptFinder.latest(session.cwdPath);
      if (path == null || !isTranscriptPathAllowed(path)) continue;
      // 훅을 기다리지 않고 여기서 복원까지 해 둔다.
      _restoreChat(session);
      session.transcriptPath = path;
      debugPrint('훅 없이 transcript를 붙였다: ${session.name}');
    }
  }

  /// transcript에 새로 쌓인 말을 말풍선으로 옮긴다.
  ///
  /// **메시지 탭이 턴의 마지막 한 마디만 보여주던 것을 이걸로 푼다.**
  /// `Stop`의 `last_assistant_message`는 말 그대로 *마지막* 한 마디뿐이라,
  /// 도구를 부르기 전에 한 말들이 전부 사라졌다. 남는 건 얇은 도구 줄뿐이라
  /// 무엇을 하고 있는지는 보여도 무엇을 말했는지는 안 보였다.
  ///
  /// transcript는 실시간으로 쌓이므로 훅이 올 때마다 따라 읽으면 된다.
  void _pumpSpeech(AgentSession session) {
    final path = session.transcriptPath;
    if (path == null) return;

    final batch = TranscriptReader.since(path, session.transcriptOffset);
    if (batch == null) return;
    session.transcriptOffset = batch.offset;
    // 컨텍스트 크기는 말이 없는 응답에도 실려 온다. 말보다 먼저 챙긴다.
    if (batch.contextTokens != null) {
      session.contextTokens = batch.contextTokens;
    }
    if (batch.model != null) session.model = batch.model;
    if (batch.speeches.isEmpty) return;

    var added = 0;
    for (final speech in batch.speeches) {
      if (!session.spokenUuids.add(speech.uuid)) continue;
      _appendReply(session, speech.text, null);
      added++;
    }
    // uuid를 무한정 쌓지 않는다. 대화 자체가 kChatLimit에서 잘리므로
    // 그보다 오래된 것을 기억해 봐야 쓸 데가 없다.
    if (session.spokenUuids.length > kChatLimit) {
      final keep = session.spokenUuids.skip(
          session.spokenUuids.length - kChatLimit).toList();
      session.spokenUuids
        ..clear()
        ..addAll(keep);
    }
    if (added > 0) {
      debugPrint('말 $added줄 올림 (${session.name})');
      notifyListeners();
    }
  }

  /// 완료 시 메시지 탭에 올릴 응답을 챙긴다.
  ///
  /// 본문은 훅이 직접 주는 `last_assistant_message`를 쓴다. 공식 문서가
  /// transcript 대신 이걸 쓰라고 안내하며, 파일 기록이 늦어 메시지가 비는 문제도 없다.
  /// transcript는 '무슨 일을 했는지'(도구·파일)를 세는 데만 쓴다.
  void _readReport(AgentSession session, Map<String, dynamic> payload) {
    final direct = payload['last_assistant_message'] as String?;
    session.report = (direct != null && direct.trim().isNotEmpty)
        ? direct.trim()
        : null;
    if (session.report != null) {
      debugPrint('응답 확보 (${session.name}) '
          '${session.report!.length}자 · 훅이 직접 줌');
      _appendReply(session, session.report!, null);
    }

    final path = payload['transcript_path'] as String?;
    if (path == null || path.isEmpty) {
      if (session.report == null) {
        debugPrint('응답 없음 (${session.name}) — 훅에 본문도 transcript도 없다: '
            '${payload.keys.toList()}');
      }
      return;
    }
    if (!isTranscriptPathAllowed(path)) {
      // 조용히 넘기지 않는다. 막았다는 사실이 보여야 원인을 찾을 수 있다.
      debugPrint('허용되지 않은 transcript 경로라 읽지 않는다: $path');
      session.transcriptPath = null;
      return;
    }
    session.transcriptPath = path;
    _tryReadReport(session, 0);
  }

  void _tryReadReport(AgentSession session, int attempt) {
    final path = session.transcriptPath;
    if (path == null) return;
    // 그 사이 등록이 풀렸으면 그만둔다.
    if (!_byPath.containsValue(session)) return;

    final turn = TranscriptReader.lastTurn(path);
    if (turn != null && !turn.isEmpty) {
      session.report ??= turn.text;
      session.turn = turn;
      // ⚠️ **본문은 여기서 붙이지 않는다.** `_pumpSpeech`가 transcript를 줄
      // 단위로 따라 읽어 이미 올려 두었다. `turn.text`는 그 줄들을 통째로
      // 이어 붙인 것이라, 여기서 또 붙이면 방금 올라간 말들이 한 덩어리로
      // 한 번 더 쌓인다.
      //
      // 도구 요약만 마지막 응답 줄에 얹는다. 이건 transcript에서만 얻는다.
      final i = session.chat.lastIndexWhere((e) => e.kind == ChatKind.reply);
      if (i >= 0 && session.chat[i].turn == null) {
        session.chat[i] =
            ChatEntry(kind: ChatKind.reply, text: session.chat[i].text, turn: turn);
      }
      debugPrint('응답 확보 (${session.name}) '
          '${turn.text?.length ?? 0}자 · 도구 [${turn.toolLine ?? "없음"}]'
          '${turn.files.isNotEmpty ? " · 파일 ${turn.files.length}개" : ""}'
          '${attempt > 0 ? " · 재시도 $attempt회" : ""}');
      notifyListeners();
      return;
    }
    if (attempt >= _reportRetries.length) {
      debugPrint('응답 없음 (${session.name}) — transcript에서 응답을 못 찾음');
      return;
    }
    Timer(_reportRetries[attempt], () => _tryReadReport(session, attempt + 1));
  }

  /// 상대 말풍선을 붙인다. 같은 말이 잇달아 오면(재시도) 덧붙이지 않는다.
  void _appendReply(AgentSession session, String text, TurnReport? turn) {
    for (var i = session.chat.length - 1; i >= 0; i--) {
      final e = session.chat[i];
      // 내 말까지가 이번 턴이다. 도구 줄은 지나쳐 계속 거슬러 올라간다.
      if (e.mine) break;
      if (e.kind == ChatKind.tool) continue;
      if (e.text == text) {
        if (turn != null && e.turn == null) {
          session.chat[i] = ChatEntry(kind: ChatKind.reply, text: text, turn: turn);
        }
        return;
      }
    }
    session.chat.add(ChatEntry(kind: ChatKind.reply, text: text, turn: turn));
    _save();
  }

  /// 도구를 하나 썼다고 대화에 남긴다.
  ///
  /// 말풍선은 턴이 끝나야 오르므로, 그 사이 무슨 일이 되고 있는지 알 수 없다.
  /// 도구 줄이 실시간으로 쌓이면 진행이 대화 안에서 그대로 보인다.
  void _appendTool(AgentSession session, String tool, Object? input) {
    final text = toolSummary(tool, input);
    // 같은 도구를 같은 인자로 잇달아 부르면(재시도) 한 줄만 남긴다.
    final last = session.chat.lastOrNull;
    if (last != null && last.kind == ChatKind.tool && last.text == text) return;
    session.chat.add(ChatEntry(kind: ChatKind.tool, text: text));
    // 한 턴에 도구를 수백 번 쓰면 목록이 무거워진다. 오래된 것부터 덜어낸다.
    if (session.chat.length > kChatLimit) {
      session.chat.removeRange(0, session.chat.length - kChatLimit);
    }
    _save();
  }

  /// 사람이 친 말을 대화에 남긴다 — **터미널에서 쳤든 위젯에서 보냈든.**
  ///
  /// 소스는 훅의 `prompt`다. transcript에도 사람 발화가 있지만 거기엔
  /// `[Image: …]` 처럼 시스템이 만든 user 줄이 섞인다. 훅은 사람이 실제로
  /// 친 것만 주므로 걸러낼 것이 없다.
  ///
  /// ⚠️ **위젯에서 보내면 두 번 들어온다.** `appendMine`이 먼저 넣고, 곧바로
  /// `UserPromptSubmit` 훅이 같은 내용을 들고 온다. 그대로 두면 내 말이
  /// 나란히 두 번 뜬다.
  void _appendMineFromHook(AgentSession session, Map<String, dynamic> payload) {
    final raw = payload['prompt'];
    if (raw is! String) {
      // 조용히 넘기지 않는다. 필드 이름이 바뀌면 이 로그로만 알 수 있다.
      debugPrint('UserPromptSubmit에 prompt가 없다: ${payload.keys.toList()}');
      return;
    }
    final text = raw.trim();
    if (text.isEmpty) return;

    // 가장 마지막 내 말만 본다. 같은 말을 한참 뒤에 또 치는 것은 진짜 두 번이다.
    for (var i = session.chat.length - 1; i >= 0; i--) {
      if (!session.chat[i].mine) continue;
      final last = session.chat[i];
      if (last.text.trim() == text &&
          DateTime.now().difference(last.at) < const Duration(seconds: 10)) {
        return;
      }
      break;
    }

    session.chat.add(ChatEntry(kind: ChatKind.mine, text: text));
    if (session.chat.length > kChatLimit) {
      session.chat.removeRange(0, session.chat.length - kChatLimit);
    }
    _save();
  }

  /// 내가 보낸 말을 대화에 남긴다.
  void appendMine(AgentSession session, String text, {bool chose = false}) {
    session.chat.add(ChatEntry(
        kind: chose ? ChatKind.chose : ChatKind.mine, text: text));
    _save();
    notifyListeners();
  }

  /// 디스크에 남아 있던 대화를 세션에 얹는다. 한 번만 한다.
  void _restoreChat(AgentSession session) {
    if (session.chat.isNotEmpty) return;
    final old = _saved.remove(session.cwdPath);
    if (old == null || old.isEmpty) {
      // 조용히 넘기면 대화가 왜 짧아졌는지 나중에 못 찾는다.
      // 들고 있던 키를 같이 찍어야 경로가 어긋난 것인지 알 수 있다.
      if (_saved.isNotEmpty) {
        debugPrint('대화 복원 못 함: ${session.name} · 찾은 키 [${session.cwdPath}] · '
            '남은 키 ${_saved.keys.toList()}');
      }
      return;
    }
    session.chat.addAll(old);
    debugPrint('대화 복원: ${session.name} ${old.length}줄');
  }

  /// ⚠️ **아직 안 깨어난 세션의 대화도 같이 넘긴다.**
  /// 세션은 훅이 와야 생긴다. 먼저 깨어난 세션 하나 때문에 저장이 돌면,
  /// 아직 조용한 세션들의 대화가 파일에서 통째로 지워진다. 실제로 당했다
  /// (2026-08-06) — 위젯을 갈아끼웠더니 75줄·44줄이 2줄로 줄어 있었다.
  void _save() => ChatStore.scheduleSave(_byPath.values, _saved);

  /// 지금 당장 디스크에 쓴다. 아직 안 깨어난 대화도 같이 챙긴다.
  void saveChatNow() => ChatStore.saveNow(_byPath.values, _saved);

  /// 답이 끝났다는 macOS 알림. 앱이 직접 보낸다(UNUserNotificationCenter, Madang 이름·아이콘) — 누르면 그 세션의 대화가 열린다.
  /// ⚠️ 예전엔 osascript `display notification`이라 보내는 앱이 「스크립트 편집기」로 찍히고 눌러도 아무 데도 안 갔다(대표 제보 9/17).
  /// 권한을 거부했으면 조용히 안 보낸다 — 예전 osascript로 떨어지지 않는다(대표 결정 9/17: 거부는 「알림 끄기」다).
  void _notifyMac(String name, String path) {
    if (!Platform.isMacOS) return;
    unawaited(() async {
      try {
        await kNotify.invokeMethod<bool>('post', {'title': name, 'body': '답이 끝났다 — 눌러서 대화 열기', 'path': path});
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    _sweeper?.cancel();
    _speechPump?.cancel();
    // 몰아서 저장하므로 내려가기 전에 한 번 확실히 쓴다.
    saveChatNow();
    _projects.removeListener(_syncWithProjects);
    super.dispose();
  }
}

/// 글 한 조각. 링크면 [url]이 있고, 아니면 그냥 글자다.
class TextPiece {
  const TextPiece(this.text, [this.url]);

  final String text;

  /// 눌렀을 때 열 주소. null이면 링크가 아니다.
  final String? url;

  bool get isLink => url != null;

  @override
  bool operator ==(Object other) =>
      other is TextPiece && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);

  @override
  String toString() => url == null ? '"$text"' : '"$text"→$url';
}

/// 글에서 링크를 가려낸다.
///
/// 두 모양을 다 읽는다.
/// - 마크다운 `[보이는 글](주소)` — 보이는 글만 남기고 주소는 뒤에 숨긴다
/// - 그냥 박힌 `https://...`
///
/// **`http`·`https`만 링크로 본다.** `open` 명령은 무엇이든 여는지라
/// `file://`이나 낯선 스킴을 그대로 넘기면 눌렀을 때 무슨 일이 날지 모른다.
List<TextPiece> parseLinks(String text) {
  // 마크다운 링크가 먼저다. 그래야 괄호 안 주소를 두 번 잡지 않는다.
  final pattern = RegExp(
    r'\[([^\]\n]+)\]\((https?://[^\s)]+)\)'
    r'|(https?://[^\s<>"' "'" r'`]+)',
  );
  final out = <TextPiece>[];
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) out.add(TextPiece(text.substring(last, m.start)));
    if (m.group(2) != null) {
      out.add(TextPiece(m.group(1)!, m.group(2)!));
    } else {
      var url = m.group(3)!;
      // `**주소**에서`처럼 굵게 닫는 별표 뒤에 글자가 바로 붙으면 꼬리 떼기로는 못 뗀다 — 별표 둘에서 끊는다
      // (대표 QA 9/15, 대시보드). 주소 한가운데 별표 **하나**는 진짜 경로일 수 있어 둘일 때만 끊는다.
      var rest = '';
      final stars = url.indexOf('**');
      if (stars > 0) {
        rest = url.substring(stars);
        url = url.substring(0, stars);
      }
      // 문장 끝 부호까지 주소로 삼으면 열리지 않는다. 뒤에서 떼어 낸다.
      //
      // ⚠️ **별표도 여기 들어간다.** 채팅에 `**주소**`로 굵게 쓰면 뒤의 별표가
      // 주소에 붙어 엉뚱한 데로 갔다(2026-09-09 대표 제보). 주소 한가운데의
      // 별표는 진짜 경로일 수 있으니 **꼬리에 붙은 것만** 뗀다.
      var tail = '';
      while (url.isNotEmpty && '.,;:!?*)]}>"\''.contains(url[url.length - 1])) {
        tail = url[url.length - 1] + tail;
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) {
        out.add(TextPiece(m.group(3)!));
      } else {
        out.add(TextPiece(url, url));
        if (tail.isNotEmpty || rest.isNotEmpty) out.add(TextPiece(tail + rest));
      }
    }
    last = m.end;
  }
  if (last < text.length) out.add(TextPiece(text.substring(last)));
  return out.isEmpty ? [TextPiece(text)] : out;
}

/// 주소를 기본 브라우저로 연다.
///
/// 눌러서 여는 것은 밖으로 나가는 일이라, 여는 것은 **사람이 누를 때만**이다.
/// 스킴은 다시 한 번 확인한다 — 파서를 거치지 않고 불릴 수도 있다.
Future<bool> openUrl(String url) async {
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    debugPrint('열지 않는다 (http/https가 아니다): $url');
    return false;
  }
  try {
    final r = await Process.run('open', [url]);
    if (r.exitCode != 0) debugPrint('링크 열기 실패: ${r.stderr}');
    return r.exitCode == 0;
  } catch (e) {
    debugPrint('링크 열기 실패: $e');
    return false;
  }
}

/// 마크다운 표를 행·열로 가른다. 구분선(`|---|`)은 뼈대일 뿐이라 버린다.
///
/// 순수 함수로 빼 둔 이유는 테스트하기 위해서다. 화면으로 확인하려면
/// 창을 띄우고 눈으로 봐야 하는데, 그 방법으로는 회귀를 못 막는다.
List<List<String>> parseMarkdownTable(List<String> lines) {
  bool isDivider(String line) =>
      RegExp(r'^[\s|:\-]+$').hasMatch(line) && line.contains('-');

  List<String> cells(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  return lines
      .where((l) => l.trim().isNotEmpty && !isDivider(l))
      .map(cells)
      .toList();
}

/// 스프라이트 한 칸. 시트에서 잘라낼 위치를 들고 있는다.
class SpriteFrame {
  const SpriteFrame(this.image, this.src,
      {this.contentBottom, this.contentTop, this.headCenterX});

  final ui.Image image;
  final Rect src;

  /// **이 프레임에서** 그림이 처음 시작되는 y(칸 위쪽 기준). 모자를 머리 위에 얹는 자리다.
  /// 여백과 달리 프레임마다 잰다 — 캐릭터가 눌렸다 펴질 때 머리 높이가 1~2px 바뀐다.
  final double? contentTop;

  /// 머리 윗줄의 가로 가운데(칸 왼쪽 기준). 몸이 좌우로 기울어도 모자가 머리를 따라간다.
  final double? headCenterX;

  /// 시트 안에서 그림이 실제로 끝나는 y (아래 투명 여백을 뺀 값).
  /// 이걸 상판에 맞춰야 발이 바닥에 붙는다. 못 재면 null.
  final double? contentBottom;

  /// 아래 투명 여백의 높이. 그릴 때 이만큼 더 내린다.
  double get bottomPadding =>
      contentBottom == null ? 0 : (src.bottom - contentBottom!);
}

/// art/ 폴더를 통째로 메모리에 올려두는 저장소.
///
/// 앱을 다시 빌드하지 않고 그림만 갈아끼울 수 있게, 번들 에셋이 아니라
/// 디스크에서 직접 읽는다. `↺` 버튼이 [reload]를 부른다.
class ArtStore extends ChangeNotifier {
  String? dirPath;
  String? error;

  Uint8List? desk;
  final Map<String, List<SpriteFrame>> charFrames = {};
  final Map<String, Map<String, List<SpriteFrame>>> projectFrames = {};
  /// 캐릭터 세트: 세트 이름 → 상태별 프레임. `art/chars/<이름>/`에서 읽는다.
  final Map<String, Map<String, List<SpriteFrame>>> charSets = {};

  /// 계층 모자: `director` · `manager` · `staff`(+ `_<상태>`) → 한 장. `art/hats/`에서 읽는다.
  ///
  /// 계층을 캐릭터 세트 대신 **모자로 가른다**(2026-09-15 대표 결정). 세트는 상태마다
  /// 네 칸씩 그려야 하지만 모자는 한 장이면 된다. 모자는 시트로 자르지 않는다 — 64×32는
  /// 가로가 세로의 두 배라 시트 규칙이면 두 칸으로 잘린다.
  final Map<String, SpriteFrame> hats = {};

  /// 그 계층·상태의 모자. `<계층>_<상태>.png` → `<계층>.png` 순이고, 없으면 `null`(모자 없음).
  SpriteFrame? hatOf(String tier, String artKey) => hats['${tier}_$artKey'] ?? hats[tier];

  /// 고를 수 있는 세트 이름들. 맨 앞의 '기본'은 `art/char/`를 가리킨다.
  List<String> get setNames => ['기본', ...charSets.keys];
  // 상태별 반복 구간. [시작, 끝] 0-based 양끝 포함. anim.json에서 읽는다.
  final Map<String, List<int>> loopRanges = {};
  // reload 때 정리해야 할 디코딩된 이미지들
  final List<ui.Image> _decoded = [];

  // 상태별 파일이 없을 때 대신 쓰는 한 장. 캐릭터를 하나만 그렸을 때를 위한 것이다.
  static const String kBaseKey = 'base';

  /// 그림 없는 상태가 떨어지는 자리. [pickFrames] 참조.
  static const String kIdleKey = 'idle';

  int get loadedStateCount =>
      charFrames.keys.where((k) => k != kBaseKey).length;
  bool get hasBase => charFrames.containsKey(kBaseKey);
  bool get hasAnyArt => desk != null || charFrames.isNotEmpty;

  Directory? _resolveDir() {
    final env = Platform.environment['CLAUDE_WATCHER_ART_DIR'];
    final candidates = <String>[
      if (env != null && env.isNotEmpty) env,
      for (final root in kConfigRoots) '$root/art',
      // 앱 안에 넣어 둔 그림 — DMG로 받아 응용 프로그램 폴더에 앱 하나만 옮겨도 캐릭터가 뜨게(9/17).
      // 옆에 art/를 둔 설치본·저장소가 먼저다(대표가 그린 새 그림을 앱을 다시 만들지 않고 바로 본다).
      '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/art',
    ];
    for (final path in candidates) {
      final dir = Directory(path);
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  /// PNG 하나를 프레임 목록으로 만든다.
  ///
  /// 가로가 세로의 정수배면 **가로로 이어붙인 스프라이트 시트**로 보고 잘라낸다.
  /// (예: 256×64 → 64×64 네 프레임). 아니면 한 장짜리로 본다.
  Future<List<SpriteFrame>> _decodeSheet(File file) async {
    try {
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final image = (await codec.getNextFrame()).image;
      _decoded.add(image);

      final w = image.width, h = image.height;
      final count = (h > 0 && w > h && w % h == 0) ? w ~/ h : 1;
      final fw = w / count;

      // 아래 투명 여백을 한 번만 잰다.
      //
      // 프레임마다 따로 재면, 위아래로 들썩이는 애니메이션이 매 프레임 바닥에
      // 붙어버려서 제자리걸음처럼 보인다. 시트 전체 기준으로 재야 움직임이 산다.
      final bottom = await _contentBottom(image);
      final heads = await _heads(image, count);

      return [
        for (var i = 0; i < count; i++)
          SpriteFrame(
            image,
            Rect.fromLTWH(i * fw, 0, fw, h.toDouble()),
            contentBottom: bottom,
            contentTop: heads?[i]?.$1,
            headCenterX: heads?[i]?.$2,
          ),
      ];
    } catch (e) {
      debugPrint('이미지 디코딩 실패 ${file.path}: $e');
      return const [];
    }
  }

  /// 프레임마다 머리 자리(윗줄 y, 윗줄 가로 가운데).
  static Future<List<(double, double)?>?> _heads(ui.Image image, int count) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return headsOf(data.buffer.asUint8List(), image.width, image.height, count);
    } catch (e) {
      debugPrint('머리 자리 측정 실패: $e');
      return null;
    }
  }

  /// [_heads]의 계산만 떼어 둔 것 — 테스트로 굳힌다. RGBA 바이트를 받는다.
  ///
  /// ⚠️ **가장 위의 불투명 점이 머리가 아니다.** 생각 중의 생각 방울·승인 대기의 물방울이
  /// 머리 위에 떨어져 떠 있어서, 그걸 머리로 잡으면 모자가 방울 위로 뜬다(2026-09-15 대표 확인).
  /// 그래서 프레임에서 **가장 큰 덩어리(몸통)**만 보고 그 윗줄을 머리로 친다. 가로 자리는 그
  /// 윗줄의 가운데다 — 승인 대기는 몸이 좌우로 기운다.
  static List<(double, double)?> headsOf(Uint8List bytes, int w, int h, int count) {
    final fw = w ~/ count;
    final out = <(double, double)?>[];
    for (var i = 0; i < count; i++) {
      final x0 = i * fw;
      final seen = Uint8List(fw * h);
      var bestSize = 0, bestTop = 0;
      List<int> bestXsAtTop = const [];
      bool solid(int x, int y) => bytes[(y * w + x0 + x) * 4 + 3] > 8;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < fw; x++) {
          if (seen[y * fw + x] == 1 || !solid(x, y)) continue;
          // 한 덩어리를 4방향으로 따라간다.
          final stack = <int>[y * fw + x];
          seen[y * fw + x] = 1;
          var size = 0, top = y;
          final topXs = <int>[];
          while (stack.isNotEmpty) {
            final p = stack.removeLast();
            final px = p % fw, py = p ~/ fw;
            size++;
            if (py < top) {
              top = py;
              topXs.clear();
            }
            if (py == top) topXs.add(px);
            for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
              final nx = px + dx, ny = py + dy;
              if (nx < 0 || ny < 0 || nx >= fw || ny >= h) continue;
              final q = ny * fw + nx;
              if (seen[q] == 1 || !solid(nx, ny)) continue;
              seen[q] = 1;
              stack.add(q);
            }
          }
          if (size > bestSize) {
            bestSize = size;
            bestTop = top;
            bestXsAtTop = topXs;
          }
        }
      }
      if (bestSize == 0) {
        out.add(null);
      } else {
        final xs = [...bestXsAtTop]..sort();
        out.add((bestTop.toDouble(), (xs.first + xs.last + 1) / 2));
      }
    }
    return out;
  }

  /// 그림이 실제로 끝나는 y를 찾는다. 아래에서 위로 올라오며 첫 불투명 줄을 만나면 그곳이다.
  ///
  /// 그림 쪽에 "여백을 딱 맞춰 그려라"라고 요구하는 대신 여기서 흡수한다.
  static Future<double?> _contentBottom(ui.Image image) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final bytes = data.buffer.asUint8List();
      final w = image.width, h = image.height;
      for (var y = h - 1; y >= 0; y--) {
        final row = y * w * 4;
        for (var x = 0; x < w; x++) {
          if (bytes[row + x * 4 + 3] > 8) return (y + 1).toDouble();
        }
      }
      return null; // 전부 투명하면 손대지 않는다
    } catch (e) {
      debugPrint('여백 측정 실패: $e');
      return null;
    }
  }

  /// 한 상태에 해당하는 파일들을 고른다. 찾는 순서는 이렇다.
  ///
  /// 1. `<state>/` 폴더 — 그 안의 png를 이름순으로 전부
  /// 2. `<state>.png` — 정확히 일치하는 한 장
  /// 3. `*_<state>.png` — 접두어가 붙은 것들 (예: `char_001_working.png`)
  List<File> _filesFor(String baseDir, String stateKey) {
    final frameDir = Directory('$baseDir/$stateKey');
    if (frameDir.existsSync()) {
      final files = frameDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.png'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isNotEmpty) return files;
    }

    final exact = File('$baseDir/$stateKey.png');
    if (exact.existsSync()) return [exact];

    final dir = Directory(baseDir);
    if (!dir.existsSync()) return const [];
    final prefixed = dir.listSync().whereType<File>().where((f) {
      final name = f.path.split('/').last.toLowerCase();
      if (!name.endsWith('.png')) return false;
      return name.substring(0, name.length - 4).endsWith('_$stateKey');
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return prefixed;
  }

  Future<List<SpriteFrame>> _framesFor(String baseDir, String stateKey) async {
    final frames = <SpriteFrame>[];
    for (final file in _filesFor(baseDir, stateKey)) {
      frames.addAll(await _decodeSheet(file));
    }
    return frames;
  }

  static const List<String> _allKeys = [
    'idle',
    'thinking',
    'working',
    'waiting',
    'bored',
    'done',
    'error',
    kBaseKey,
  ];

  Future<void> reload() async {
    desk = null;
    charFrames.clear();
    projectFrames.clear();
    charSets.clear();
    hats.clear();
    loopRanges.clear();
    for (final img in _decoded) {
      img.dispose();
    }
    _decoded.clear();
    error = null;

    final dir = _resolveDir();
    if (dir == null) {
      dirPath = null;
      error = 'art/ 폴더를 찾지 못했다';
      // ⚠️ **조용히 넘기지 않는다.** 로그가 없어서 '왜 캐릭터가 회색 네모지'를
      // 못 풀었다(2026-09-09). 어디를 뒤졌는지까지 남긴다.
      debugPrint('아트 폴더를 못 찾았다. 뒤진 곳: ${kConfigRoots.join(", ")}');
      notifyListeners();
      return;
    }
    dirPath = dir.path;

    try {
      _loadAnimConfig(dir.path);

      final deskFile = File('${dir.path}/desk/background.png');
      if (deskFile.existsSync()) desk = deskFile.readAsBytesSync();

      for (final key in _allKeys) {
        final frames = await _framesFor('${dir.path}/char', key);
        if (frames.isNotEmpty) charFrames[key] = frames;
      }

      // 세트 폴더. 두 번째 캐릭터부터는 여기에 넣는다.
      final setsDir = Directory('${dir.path}/chars');
      if (setsDir.existsSync()) {
        for (final entry in setsDir.listSync().whereType<Directory>()) {
          final setName =
              ProjectStore.composeHangul(entry.path.split('/').last);
          final byState = <String, List<SpriteFrame>>{};
          for (final key in _allKeys) {
            final frames = await _framesFor(entry.path, key);
            if (frames.isNotEmpty) byState[key] = frames;
          }
          if (byState.isNotEmpty) charSets[setName] = byState;
        }
      }

      final hatsDir = Directory('${dir.path}/hats');
      if (hatsDir.existsSync()) {
        for (final f in hatsDir.listSync().whereType<File>()) {
          final name = f.path.split('/').last;
          if (!name.toLowerCase().endsWith('.png')) continue;
          try {
            final codec = await ui.instantiateImageCodec(await f.readAsBytes());
            final image = (await codec.getNextFrame()).image;
            _decoded.add(image);
            hats[name.substring(0, name.length - 4).toLowerCase()] = SpriteFrame(
                image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
                contentBottom: await _contentBottom(image));
          } catch (e) {
            debugPrint('모자 읽기 실패 ${f.path}: $e');
          }
        }
      }

      final projectsDir = Directory('${dir.path}/projects');
      if (projectsDir.existsSync()) {
        for (final entry in projectsDir.listSync().whereType<Directory>()) {
          // 파일시스템은 한글을 자모로 돌려준다. 프로젝트 이름과 맞추려면 합쳐야 한다.
          final projectName =
              ProjectStore.composeHangul(entry.path.split('/').last);
          final byState = <String, List<SpriteFrame>>{};
          for (final key in _allKeys) {
            final frames = await _framesFor(entry.path, key);
            if (frames.isNotEmpty) byState[key] = frames;
          }
          if (byState.isNotEmpty) projectFrames[projectName] = byState;
        }
      }
    } catch (e) {
      error = '읽는 중 오류: $e';
    }

    final counts = charFrames.entries.map((e) {
      final r = loopRangeOf(e.key, e.value.length);
      final loop = (r[0] == 0 && r[1] == e.value.length - 1)
          ? ''
          : '(반복 ${r[0] + 1}-${r[1] + 1})';
      return '${e.key}:${e.value.length}f$loop';
    }).join(' ');
    debugPrint('아트 로드: $dirPath | $counts'
        '${charSets.isEmpty ? "" : " | 세트 ${charSets.keys.toList()}"}'
        '${hats.isEmpty ? "" : " | 모자 ${hats.keys.toList()}"} | '
        '배경 ${desk != null ? "있음" : "없음"} | '
        '프로젝트 전용 ${projectFrames.keys.toList()}');
    notifyListeners();
  }

  /// `art/anim.json`을 읽는다. 없으면 전 프레임을 반복한다.
  ///
  /// ```json
  /// { "working": "2-4" }
  /// ```
  /// 1-based 양끝 포함. 구간 앞의 프레임은 상태에 들어올 때 한 번만 재생하는
  /// 인트로가 되고, 구간 뒤의 프레임은 쓰지 않는다.
  void _loadAnimConfig(String dirPath) {
    final file = File('$dirPath/anim.json');
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        // "2-4" 또는 {"loop": "2-4"} 둘 다 받는다.
        final raw = value is Map ? value['loop'] : value;
        if (raw is! String) return;
        final parts = raw.split('-');
        final start = int.tryParse(parts.first.trim());
        final end = parts.length > 1 ? int.tryParse(parts[1].trim()) : start;
        if (start == null || end == null || start < 1 || end < start) {
          debugPrint('anim.json 구간을 못 읽음: $key = $raw');
          return;
        }
        loopRanges['$key'] = [start - 1, end - 1];
      });
    } catch (e) {
      debugPrint('anim.json 읽기 실패: $e');
    }
  }

  /// 해당 상태의 반복 구간을 프레임 수에 맞춰 잘라 돌려준다.
  List<int> loopRangeOf(String stateKey, int frameCount) {
    final r = loopRanges[stateKey];
    if (r == null || frameCount == 0) return [0, frameCount - 1];
    final start = r[0].clamp(0, frameCount - 1);
    final end = r[1].clamp(start, frameCount - 1);
    return [start, end];
  }

  /// 어느 칸을 쓸지 고른다. **그림이 없을 때 무엇으로 떨어지는지가 전부다.**
  ///
  /// 좁은 것부터 넓은 것 순으로 보고(프로젝트 전용 → 세트 → 기본),
  /// 각 단계 안에서는 `상태 → 대기 → base` 순으로 본다.
  ///
  /// ⚠️ **base가 아니라 대기로 먼저 떨어진다.** base는 한 장뿐이라 거기로
  /// 가면 그림이 통째로 얼어붙는다 — 심심함이 실제로 그랬다(2026-09-08).
  /// 대기는 네 장이라 움직이고, 뜻도 어긋나지 않는다: 그림이 없는 상태란
  /// 대개 '아무것도 안 하는 중'이다. 상태를 새로 늘려도 같은 함정에 다시
  /// 빠지지 않게 여기서 한 번에 막는다.
  ///
  /// 단계를 먼저 훑고 그 안에서 떨어지므로, 세트에 한 장만 넣어도 그
  /// 프로젝트만 다른 캐릭터가 되는 성질은 그대로다.
  static T? pickFrames<T>(List<Map<String, T>?> tiers, String artKey) {
    for (final tier in tiers) {
      if (tier == null) continue;
      final hit = tier[artKey] ?? tier[kIdleKey] ?? tier[kBaseKey];
      if (hit != null) return hit;
    }
    return null;
  }

  /// 좁은 것부터 넓은 것 순으로 찾는다. 고르는 규칙은 [pickFrames]에 있다.
  List<SpriteFrame>? framesOf(String projectName, AgentStatus status,
          {String? setName}) =>
      pickFrames<List<SpriteFrame>>([
        projectFrames[projectName],
        setName == null ? null : charSets[setName],
        charFrames,
      ], status.artKey);
}

/// HTML에 그대로 박으면 안 되는 글자를 막는다.
///
/// ⚠️ 할 일 본문은 사람이 친 것이라 `<`나 `&`가 들어올 수 있다. 안 막으면
/// 화면이 깨지고, 남의 글이 섞이는 경로가 생긴다.
String htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// 할 일 페이지 한 장.
///
/// **얇게 둔다.** 판단은 전부 Dart(`Todos`)에 있고 여기는 보여주고 누르는
/// 것만 한다 — 나중에 네이티브 창으로 옮기면 버려질 부분이라서다.
/// 테마를 페이지가 그려지기 전에 입힌다 — 늦게 입히면 밝은 화면이 한 번 번쩍인다.
/// 고른 테마는 이 브라우저에만 남는다(폰과 맥이 따로 기억한다).
const String kThemeBoot = '<script>try{var t=localStorage.getItem("cw_theme");'
    'if(t)document.documentElement.dataset.theme=t}catch(e){}</script>';

/// 할 일 페이지와 프로젝트 페이지가 같이 쓰는 모양. 보기가 늘어도 한 벌이다.
const String kTodoCss = r'''
@import url('https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/variable/pretendardvariable-dynamic-subset.min.css');
@import url('https://fonts.googleapis.com/css2?family=Nanum+Gothic+Coding&display=swap');
/* 톤 A — 소프트 파스텔 라이트(기본) · 다크는 [data-theme=dark] (2026-09-14, 핀터레스트 「클로드 와쳐」)
   ⚠️ 색은 여기 변수로만 쓴다. 아래 규칙에 색을 박으면 다크 모드에서 그 칸만 튄다.
   글자 크기는 세 단계다 — 22(제목) · 14(본문) · 12(속성·꼬리표) */
:root{
  --bg:#f7f3ee;
  --bg-img:none;
  --panel:#ffffff;--card:#ffffff;--hover:rgba(70,50,30,.05);
  --lane-glass:rgba(255,255,255,.52);--lane-edge:rgba(255,255,255,.75);
  --line:rgba(70,50,30,.08);--line2:rgba(70,50,30,.14);
  --fg:#2b2724;--dim:#6b655e;--faint:#6f695f;
  --accent:#5b5bd6;--accent-fg:#ffffff;--accent-soft:rgba(91,91,214,.12);--red:#e5484d;
  --shadow-card:0 1px 2px rgba(70,50,30,.05),0 6px 18px rgba(70,50,30,.06);
  --shadow-pop:0 28px 70px rgba(70,50,30,.20);
  --scrim:rgba(60,45,35,.28);--scheme:light;
}
:root[data-theme="dark"]{
  /* 다크는 흑연 톤이다 — 색을 빼고 회색 단계(바탕 → 칸 → 카드)로만 층을 나눈다 */
  --bg:#262626;
  --bg-img:none;
  --panel:#333333;--card:#404040;--hover:rgba(255,255,255,.06);
  --lane-glass:#303030;--lane-edge:transparent;
  --line:rgba(255,255,255,.06);--line2:rgba(255,255,255,.16);
  --fg:#ededed;--dim:#b3b3b3;--faint:#8f8f8f;
  --accent:#d9d9d9;--accent-fg:#262626;--accent-soft:rgba(255,255,255,.12);--red:#ff7a7a;
  --shadow-card:0 0 0 transparent;--shadow-pop:0 28px 70px rgba(0,0,0,.55);
  --scrim:rgba(0,0,0,.5);--scheme:dark;
}
/* 선택지 색 — 꼬리표 바탕(--pb)·글자(--pf)·카드 물감(--ct) 한 벌. 이름은 노션 색 이름 그대로 */
.c-default,.l-default{--pf:#5f5a52;--pb:#eeebe6;--ct:#ffffff}
.c-gray,.l-gray{--pf:#66625c;--pb:#ebe9e5;--ct:#f6f5f3}
.c-brown,.l-brown{--pf:#8a5a3f;--pb:#f5e4d8;--ct:#fbf2eb}
.c-orange,.l-orange{--pf:#b05510;--pb:#ffe2c7;--ct:#fff3e6}
.c-yellow,.l-yellow{--pf:#8f6400;--pb:#ffefbd;--ct:#fff9e3}
.c-green,.l-green{--pf:#2b7a4f;--pb:#d6f1e1;--ct:#edf9f2}
.c-blue,.l-blue{--pf:#2f5db3;--pb:#d9e6ff;--ct:#eef4ff}
.c-purple,.l-purple{--pf:#6a3db0;--pb:#e9ddfc;--ct:#f5eefe}
.c-pink,.l-pink{--pf:#ad3674;--pb:#fcdded;--ct:#fdeff6}
.c-red,.l-red{--pf:#b53d2d;--pb:#fcdcd7;--ct:#fdefed}
/* 다크 카드는 모두 같은 회색이다. 색은 꼬리표의 점과 글자에만 남긴다 */
:root[data-theme="dark"] :is(.c-default,.l-default){--pf:#d0d0d0;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-gray,.l-gray){--pf:#d0d0d0;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-brown,.l-brown){--pf:#dcbfae;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-orange,.l-orange){--pf:#f0c09a;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-yellow,.l-yellow){--pf:#e8d49a;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-green,.l-green){--pf:#aad6b9;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-blue,.l-blue){--pf:#b3c8ee;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-purple,.l-purple){--pf:#cbb8ec;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-pink,.l-pink){--pf:#eab8d0;--pb:rgba(255,255,255,.08);--ct:#404040}
:root[data-theme="dark"] :is(.c-red,.l-red){--pf:#f0b0a8;--pb:rgba(255,255,255,.08);--ct:#404040}
*{box-sizing:border-box}
html{background:var(--bg)}
body{margin:0;padding:28px 32px;background:var(--bg-img) fixed,var(--bg);color:var(--fg);min-height:100vh;
  font:14px/1.55 "Pretendard Variable",Pretendard,-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;
  -webkit-font-smoothing:antialiased}
button{background:none;border:0;color:var(--dim);cursor:pointer;font:inherit;padding:0}
.faint{color:var(--faint)}
/* 머리 — 제목 · 새로 적기 · 보기 바꾸기 */
/* 머리 줄은 **모든 페이지에서 같은 폭**이다 — 리스트·보드·근무기록·프로젝트·사용량 어디서나
   리스트/보드/근무기록 버튼이 같은 자리에 선다(대표 수정요청 9/16 「페이지마다 버튼 위치가 달라진다」).
   ⚠️ 화면 끝이 아니라 **정해진 폭**에서 끝나야 한다 — 화면 끝에 붙이면 사무실·대화 칸을 접고 펼 때마다
   버튼이 옮겨 다닌다(대표 요청 9/15). 보드 내용(1500)보다 조금 좁지만, 자리가 안 흔들리는 쪽을 택한다. */
.top{display:flex;align-items:center;gap:12px;margin:0 0 22px;flex-wrap:wrap;max-width:1400px;min-height:58px}
/* 상단 머리·프로젝트 탭 줄은 스크롤해도 붙어 있다(대표 요청 9/17). 머리는 맨 위, 탭 줄은 머리 높이만큼 아래(--top-h, 스크립트가 잰다) */
.top{position:sticky;top:0;z-index:15;background:var(--bg-img) fixed,var(--bg);margin-top:-28px;padding-top:28px;padding-bottom:10px;margin-bottom:12px}
.ptabsrow{position:sticky;top:var(--top-h,58px);z-index:14;background:var(--bg-img) fixed,var(--bg);padding-bottom:6px}
/* ⚠️ **머리 높이를 고정한다.** 할 일 화면에만 남은 한도 원 그래프(56px)가 있어 그 줄만 키가 커졌고,
   근무기록으로 옮기면 버튼 모음이 위로 몇 px 튀었다(대표 수정요청 9/16 「y값이 쪼금씩 바뀜」).
   가장 큰 조각(도넛) 높이를 모든 페이지가 미리 비워 둔다 — 도넛이 없어도 자리는 같다. */
.top h1{font-size:22px;margin:0;font-weight:800;letter-spacing:-.3px}
.top h1 b{color:var(--faint);font-weight:600;font-size:14px;margin-left:6px}
.newbtn{color:var(--accent-fg);background:var(--accent);border-radius:999px;padding:6px 14px;font-size:14px;font-weight:600;
  box-shadow:var(--shadow-card)}
.newbtn:hover{filter:brightness(1.07)}
form.add{display:none;gap:8px;align-items:center;flex:1;min-width:320px;max-width:720px}
form.add.open{display:flex}
form.add select{background:var(--card);border:1px solid var(--line2);color:var(--fg);
  border-radius:10px;font:inherit;font-size:12px;padding:6px 8px;outline:none}
form.add input{flex:1;background:var(--card);border:1px solid var(--line2);border-radius:10px;
  color:var(--fg);font:inherit;padding:6px 12px;outline:none}
form.add input:focus{border-color:var(--accent)}
.views{margin-left:auto;font-size:14px;font-weight:600;display:inline-flex;gap:2px;align-items:center;
  background:var(--lane-glass);border:1px solid var(--lane-edge);border-radius:999px;padding:3px;
  -webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.csv{font-size:12px;color:var(--dim);text-decoration:none;border:1px solid var(--line2);
  border-radius:999px;padding:3px 10px;background:var(--card)}
.csv:hover{color:var(--fg)}
.views a{color:var(--dim);text-decoration:none;border-radius:999px;padding:5px 12px}
.views a:hover{color:var(--fg)}
.views a.on{color:var(--fg);background:var(--card);box-shadow:var(--shadow-card)}
.theme-btn{width:30px;height:30px;border-radius:50%;font-size:15px;color:var(--dim);margin-left:2px}
.theme-btn:hover{background:var(--hover);color:var(--fg)}
/* 꼬리표 */
.ktxt{font-size:12px;font-weight:600;color:var(--pf)}
.pill{display:inline-flex;align-items:center;gap:5px;height:22px;padding:0 9px;
  border-radius:999px;background:var(--pb);color:var(--pf);font-size:12px;
  line-height:22px;white-space:nowrap;font-weight:600}
.dot{width:6px;height:6px;border-radius:50%;background:var(--pf);flex:none;display:inline-block}
.kd{display:inline-flex;align-items:center;gap:5px;font-size:12px;color:var(--dim);white-space:nowrap}
.fire{font-size:12px;letter-spacing:-2px;white-space:nowrap}
.fire.soft{opacity:.45}
.tl{font-size:12px;color:var(--faint);white-space:nowrap}
.due{font-size:12px;color:var(--dim);white-space:nowrap}
.due.late{color:var(--red);font-weight:700}
.cs{font-size:12px;color:var(--dim);white-space:nowrap}
.cs.on{color:var(--accent);font-weight:700}
.memo{color:var(--faint);font-style:normal;margin-left:6px}
.proj{font-size:14px;color:var(--fg)}
/* 꼬리표 위에 겹친 고르는 칸 — 안 보이지만 누르면 목록이 뜬다 */
.pick{position:relative;display:inline-flex;align-items:center;min-height:26px;
  padding:2px 4px;margin:-2px -4px;border-radius:8px;cursor:pointer}
.pick:hover{background:var(--hover)}
.pick select{position:absolute;inset:0;width:100%;height:100%;opacity:0;cursor:pointer}
/* 아이콘 버튼 */
.ic{display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;
  border-radius:8px;color:var(--dim);font-size:14px;line-height:1}
.ic svg{width:14px;height:14px}
.ic:hover{background:var(--hover);color:var(--fg)}
.ic.del:hover{color:var(--red)}
.go{border:1px solid var(--line2);color:var(--fg);border-radius:999px;background:var(--card);
  padding:3px 12px;font-size:12px;font-weight:600}
.go:hover{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.go[disabled]{opacity:.4;cursor:default}
.txtbtn{font-size:14px;color:var(--dim)}
.txtbtn.del:hover{color:var(--red)}
/* 표 — 흰 판 위에 올린다 */
table{width:100%;max-width:1400px;border-collapse:separate;border-spacing:0;background:var(--panel);
  border-radius:20px;box-shadow:var(--shadow-card);overflow:hidden}
th{font-size:12px;color:var(--faint);text-align:left;font-weight:600;
  padding:12px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:6px 12px;border-bottom:1px solid var(--line);vertical-align:middle;height:44px}
tr:last-child td{border-bottom:0}
tr.row:hover{background:var(--hover)}
tr.done .txt{color:var(--faint);text-decoration:line-through}
.txt{cursor:pointer;word-break:break-word;min-width:260px;font-weight:600}
.chk{width:28px}
.chk button{color:var(--faint);font-size:14px}
.meta{white-space:nowrap}
.act{width:170px;text-align:right;white-space:nowrap}
.hov{display:inline-flex;align-items:center;gap:2px;opacity:0;transition:opacity .12s}
tr.row:hover .hov,tr.row:focus-within .hov{opacity:1}
.hov .go{margin:0 4px}
.empty{color:var(--dim);padding:20px 12px}
/* 상세창 — 노션의 페이지 자리 */
#back{display:none;position:fixed;inset:0;background:var(--scrim);
  -webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px)}
#back.on{display:block}
.sheet{display:none;position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);
  width:min(720px,94vw);max-height:90vh;overflow-y:auto;background:var(--panel);
  border:1px solid var(--line);border-radius:24px;padding:30px 34px 0;
  box-shadow:var(--shadow-pop)}
.sheet.on{display:block}
.sh{display:flex;gap:10px;align-items:flex-start;margin-bottom:16px}
.sh .title{flex:1;background:none;border:0;color:var(--fg);font:inherit;resize:none;
  font-size:22px;font-weight:800;line-height:1.35;outline:none;padding:2px 6px;margin:-2px -6px;
  letter-spacing:-.3px;border-radius:10px;overflow:hidden;min-height:0;width:auto}
.sh .title:hover{background:var(--hover)}
.sh .title:focus{background:var(--hover)}
.props{display:grid;grid-template-columns:104px 1fr;gap:0 12px;align-items:center}
.props>label{font-size:14px;color:var(--faint);padding:0;line-height:36px}
.props>span{min-height:36px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:14px}
.props .pick input[type=date]{position:absolute;inset:0;opacity:0;cursor:pointer;width:100%;color-scheme:var(--scheme)}
.props.fold-empty>.emp{display:none}
.props .more-emp{display:none;grid-column:1/-1;justify-self:start;font-size:12px;color:var(--faint);padding:2px 0}
.props.fold-empty .more-emp{display:inline-flex}
.props .clear{color:var(--faint);display:inline-flex;opacity:0}
.props .clear svg{width:12px;height:12px}
.props>span:hover .clear{opacity:1}
.sbtns{display:inline-flex;gap:6px;margin-left:6px}
.sb{display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 11px;border-radius:999px;
  border:1px solid var(--line2);font-size:12px;font-weight:600;color:var(--dim);background:var(--card)}
.sb svg{width:11px;height:11px}
.sb:hover{color:var(--fg);background:var(--hover)}
.meta-line{font-size:12px;color:var(--faint);margin:12px 0 18px;padding:10px 14px;border-radius:14px;
  background:var(--hover);display:flex;flex-wrap:wrap;gap:4px 0;line-height:1.6}
.meta-line em{font-style:normal;margin:0 8px;opacity:.6}
.meta-line b{font-weight:700;color:var(--dim)}
.meta-line b.on{color:var(--accent)}
.help{font-style:normal;display:inline-flex;align-items:center;justify-content:center;
  width:16px;height:16px;border-radius:50%;border:1px solid var(--line2);font-size:12px;
  color:var(--faint);margin-left:4px;cursor:help}
.btns{display:inline-flex;gap:2px}
.sec{margin:0 0 16px}
/* 창이 모니터 반쪽보다 좁으면 대화만 — 옆에 가이드(브라우저)를 띄워 놓고 쓰라는 모양(대표 결정 9/16) */
/* ⚠️ 숨길 것을 하나씩 적으면 새 칸이 생길 때마다 빠진다 — 보드 보기의 `.board4`와 백로그 서랍(`details.fold`)이
   그대로 남아 창을 반 아래로 줄여도 대화만 안 남았다(대표 3차 제보 9/16). **남길 것만 적고 나머지는 다 숨긴다.** */
/* ⚠️ 열려 있는 작은 창(#submenu)은 남긴다 — 퇴근·＋하위·✎이름 메뉴가 이 화면에서만 안 보였다(9/18). */
.only-chat body>*:not(.duo):not(.sheet):not(#back):not(#err):not(#submenu):not(script):not(style){display:none !important}
.only-chat .duo{left:0;top:0;right:0;bottom:0;border-radius:0;border:0}
.only-chat .dock{flex:1}
.only-chat .dock-grip{display:none}
/* 남은 한도 원 그래프 — 머리에 작게, 사용량 페이지에 크게(대표 요청 9/16) */
/* 토스트 — 되돌린 뒤 무엇이 되돌아갔는지 알린다(대표 결정 9/16) */
#toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%) translateY(12px);z-index:60;
  display:flex;align-items:center;gap:12px;max-width:min(92vw,560px);
  background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:12px;
  box-shadow:0 10px 30px rgba(0,0,0,.18);padding:10px 14px;font-size:13px;font-weight:600;
  opacity:0;pointer-events:none;transition:opacity .16s,transform .16s}
#toast.on{opacity:1;transform:translateX(-50%) translateY(0);pointer-events:auto}
#toast button{border:0;background:var(--hover);color:var(--fg);font:inherit;font-weight:800;
  border-radius:999px;padding:4px 12px;cursor:pointer}
#toast button:hover{background:var(--line2)}
/* 근무기록 한 장 — 리스트·보드와 **같은 문서에서 갈아 끼우려고** 공통 CSS로 옮겼다(대표 제보 9/16 깜빡임).
   ⚠️ `details`·`.num` 같은 흔한 이름이라 반드시 `.wrk` 안으로 좁힌다 — 안 그러면 다른 화면의 접기까지 바뀐다 */
.wrk .months{display:flex;gap:4px;flex-wrap:wrap;margin:0 0 14px}
.wrk .months a{color:var(--dim);text-decoration:none;border-radius:6px;padding:3px 10px;font-size:12px}
.wrk .months a.on{color:var(--fg);background:var(--card)}
.wrk .stats{display:flex;gap:28px;flex-wrap:wrap;margin:0 0 18px}
/* 리뷰3 M2(9/17): 단위가 작은 회색이라 첫눈에 뜻이 안 잡혔다 — 단위는 숫자 옆에, 설명은 읽히는 회색으로 */
.wrk .stat b{display:block;font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}
.wrk .stat b small{font-size:13px;font-weight:600;color:var(--dim);margin-left:2px}
.wrk .stat span{font-size:12px;color:var(--dim)}
.wrk .num{text-align:right}
.wrk td.tl{max-width:420px}
/* 리뷰3 M2: 접힌 타임라인이 잘린 글자뿐이라 펼 수 있는지 몰랐다 — ▸ 표시와 손 모양, 펴면 줄바꿈 */
td.tl summary{list-style:none;cursor:pointer;color:var(--dim)}
td.tl summary::before{content:'▸ ';color:var(--faint)}
td.tl details[open] summary::before{content:'▾ '}
td.tl details[open] summary{white-space:normal}
td.tl details>div{white-space:normal;line-height:1.6;padding:4px 0 2px 14px;color:var(--dim)}
td.tl summary::-webkit-details-marker{display:none}
.wrk details summary{cursor:pointer;color:var(--dim);font-size:12px;list-style:none}
.wrk details summary::-webkit-details-marker{display:none}
.wrk details[open] summary{color:var(--fg)}
.wrk details div{margin-top:6px;font-size:12px;line-height:1.7;color:var(--fg)}
/* 「직접 적기」를 기다리는 줄 — 적을 자리를 바로 내준다 */
.wait-note.type-note{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.wait-note.type-note .txtbtn{margin-left:auto;font-weight:800;color:var(--accent)}
/* ⚙ 메뉴의 단축키 안내 */
.menu .mi-keys{padding:8px 12px;border-bottom:1px solid var(--line);font-size:12px;color:var(--dim);line-height:1.6}
.menu .mi-keys b{display:inline-block;min-width:16px;text-align:center;font-weight:800;color:var(--fg);
  background:var(--hover);border:1px solid var(--line2);border-radius:5px;padding:0 4px;margin:0 1px}
.menu .mi-keys small{display:block;color:var(--faint);font-size:11px;margin-top:3px}
.donuts{display:flex;align-items:center;gap:10px;text-decoration:none;color:inherit}
.donut{position:relative;display:flex;flex-direction:column;align-items:center;gap:1px;width:52px}
.donut svg{width:34px;height:34px;transform:rotate(-90deg)}
.donut circle{fill:none;stroke-width:4;stroke-linecap:round}
.donut circle.bg{stroke:var(--line2)}
/* 리뷰3 H3(9/17): 머리의 작은 원은 「+ 새로」 옆에서 같은 보라로 경쟁했다 — 평소엔 회색, 70%부터만 색이 든다. 큰 원(사용량 페이지)은 보라 그대로 */
.donut circle.fg{stroke:var(--dim)}
.donuts.big .donut circle.fg{stroke:var(--accent)}
.donut.warm circle.fg{stroke:#e8a317}
.donut.hot circle.fg{stroke:var(--red)}
.donut>b{position:absolute;top:8px;left:0;right:0;text-align:center;font-size:11px;font-weight:800;font-variant-numeric:tabular-nums}
.donut>b i{font-style:normal;font-size:8px;font-weight:700;color:var(--faint)}
.donut .dl{font-size:10px;font-weight:700;color:var(--dim);line-height:1.1}
.donut .dt{font-size:9.5px;color:var(--faint);line-height:1.1;white-space:nowrap}
.donuts .dstale{align-self:flex-start;font-size:10px;font-weight:700;color:#9a6412;background:var(--hover);border-radius:999px;padding:1px 6px}
.donuts:hover .dl{color:var(--fg)}
.top .donuts{margin-left:auto}
.top .donuts+.views{margin-left:14px}
.donuts.big{gap:22px;margin:2px 0 2px}
.donuts.big .donut{width:104px}
.donuts.big .donut svg{width:76px;height:76px}
.donuts.big .donut circle{stroke-width:7}
.donuts.big .donut>b{top:26px;font-size:18px}
.donuts.big .donut>b i{font-size:11px}
.donuts.big .donut .dl{font-size:13px;margin-top:4px}
.donuts.big .donut .dt{font-size:11.5px}
@media (max-width:1100px){.top .donuts{display:none}}
/* 작업 내용 회차 */
.sec-h .rnd{font-style:normal;font-size:12px;font-weight:700;color:var(--accent);background:var(--accent-soft);border-radius:999px;padding:1px 8px;margin-left:6px}
.rnote{margin:0 0 12px;padding:10px 14px;border-radius:12px;background:var(--hover);font-size:13px;color:var(--dim)}
.rnote b{color:var(--dim);font-weight:700}
.rnote p{margin:4px 0 0;white-space:pre-wrap;color:var(--fg);font-size:14px;line-height:1.55}
details.rounds{margin:-6px 0 16px}
details.rounds>summary{list-style:none;cursor:pointer;font-size:13px;font-weight:700;color:var(--dim);padding:6px 2px}
details.rounds>summary::-webkit-details-marker,details.round>summary::-webkit-details-marker{display:none}
details.rounds>summary::before,details.round>summary::before{content:'▸ ';color:var(--faint)}
details.rounds[open]>summary::before,details.round[open]>summary::before{content:'▾ '}
details.round{margin:4px 0 0 12px;border-left:2px solid var(--line2);padding-left:10px}
details.round>summary{list-style:none;cursor:pointer;display:flex;gap:8px;align-items:baseline;font-size:13px;color:var(--dim);padding:4px 0;min-width:0}
details.round>summary b{color:var(--fg)}
details.round>summary span{color:var(--faint);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
details.round .rc{margin:6px 0;white-space:pre-wrap;font:inherit;font-size:13px;line-height:1.55;color:var(--fg);max-height:320px;overflow:auto}
details.round .rn{font-size:13px;color:var(--dim);margin:0 0 8px}
details.round .rn p{margin:2px 0 0;white-space:pre-wrap;color:var(--fg)}
.sec-h{display:flex;align-items:baseline;gap:8px;font-size:14px;font-weight:700;color:var(--dim);margin:0 0 6px}
.sec-h i{font-style:normal;font-weight:400;font-size:12px;color:var(--faint)}
.sec.folded{display:flex;align-items:center;gap:10px;margin:0 0 6px}
.sec.folded .sec-h,.sec.folded textarea{display:none}
.add-sec{font-size:14px;color:var(--faint);padding:4px 0}
.add-sec:hover{color:var(--accent)}
.sheet textarea:not(.title){width:100%;min-height:72px;max-height:52vh;background:var(--bg);
  border:1px solid var(--line);border-radius:14px;color:var(--fg);
  font:inherit;font-size:14px;line-height:1.7;padding:12px 14px;outline:none;resize:vertical}
.sheet textarea.big{min-height:150px}
.sheet textarea:not(.title):focus{border-color:var(--accent)}
.sf{position:sticky;bottom:0;display:flex;justify-content:space-between;align-items:center;
  margin:8px -34px 0;padding:14px 34px;background:var(--panel);border-top:1px solid var(--line)}
.sf .go{padding:7px 18px;font-size:14px}
.go.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.go.primary:hover{filter:brightness(1.07)}
.txtbtn.del{color:var(--faint)}
/* 보드 — 반투명 칸 위에 칸 색으로 칠한 카드(weihu) */
.board{display:flex;gap:12px;align-items:flex-start;overflow-x:auto;padding-bottom:14px}
.col{flex:0 0 256px;background:var(--lane-glass);border:1px solid var(--lane-edge);border-radius:22px;
  padding:12px 10px 8px;-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px)}
.col.hot{border-color:var(--accent)}
/* 큰 분류가 바뀌는 칸 앞은 조금 더 띄운다 */
.col[data-gap]{margin-left:16px}
.col h3{margin:0 0 10px;font-size:12px;font-weight:600;color:var(--dim);
  padding:0 4px;display:flex;flex-wrap:wrap;align-items:center;gap:6px}
.col h3 small{flex-basis:100%;font-size:12px;font-weight:700;color:var(--faint);height:18px;line-height:18px;
  letter-spacing:.2px}
.col h3 em{font-style:normal;color:var(--faint);font-weight:700}
/* 「· 수정 2」는 어느 폭에서도 줄을 안 바꾼다 — 갈라지면 세로로 깨져 보인다(대표 제보 9/16) */
.col h3 .rvc{white-space:nowrap;flex:none}
.card{position:relative;background:var(--ct,var(--card));border-radius:16px;padding:12px 14px 10px;
  margin-bottom:8px;cursor:grab;box-shadow:var(--shadow-card);border:1px solid var(--line)}
/* UI/UX 리뷰 3회차(9/17) H1: 칸(.col.l-*) 색을 카드까지 물려주면 라이트에서 판 전체가 색이 된다 — 카드는 흰 바탕, 색은 칸 배경과 상태 알약이 말한다 */
.col .card{background:var(--card)}
.card:hover{filter:brightness(.985);box-shadow:var(--shadow-card),0 0 0 1px var(--line2)}
.card.alarm{box-shadow:inset 4px 0 0 var(--red),var(--shadow-card)}
.card.drag{opacity:.4}
.ct{font-size:14px;font-weight:700;line-height:1.45;word-break:break-word;cursor:pointer;color:var(--fg);
  display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden}
/* 리스트 줄은 두 줄까지 — 채팅처럼 길게 적힌 제목이 화면을 다 먹지 않게(대표 9/16). 전체는 카드를 열면 보인다 */
.lrow .ct{-webkit-line-clamp:2}
.cp{display:flex;flex-wrap:wrap;align-items:center;gap:4px 10px;margin-top:8px}
.cp:empty{display:none}
.pj{margin-top:6px;font-size:12px;color:var(--faint);display:flex;gap:8px;align-items:center}
.cp .pj{margin:0 0 0 auto;display:inline-flex}
.cp .pj img,.cp .who img{height:14px;width:auto;vertical-align:-2px}
.cp .who{font-size:12px;line-height:1}
.who{font-size:12px;color:var(--dim);white-space:nowrap}
.who.me{color:var(--fg);font-weight:700}
.cf{position:absolute;bottom:6px;right:8px;display:flex;align-items:center;gap:1px;
  background:var(--panel);border-radius:999px;padding:2px 4px;box-shadow:var(--shadow-card);border:1px solid var(--line);
  opacity:0;pointer-events:none;transition:opacity .12s}
.card:hover .cf{opacity:1;pointer-events:auto}
.cf .go{margin:0 2px;padding:2px 10px}
form.new{margin-top:2px}
form.new input{width:100%;background:none;border:0;border-radius:12px;color:var(--fg);
  font:inherit;font-size:14px;padding:7px 10px;outline:none}
form.new input::placeholder{color:var(--faint)}
form.new input:hover{background:var(--hover)}
form.new input:focus{background:var(--card)}
/* ── 회의 화면 (9/17) ── 원탁은 타원 위 자리, 회의록은 카드 */
.mtg{max-width:960px}
.mtg-head h2{font-size:20px;font-weight:800;margin:4px 0 6px}
.mtg-meta{display:flex;gap:10px;align-items:center;font-size:12px;margin-bottom:14px}
.mtg-stage{display:flex;flex-wrap:wrap;justify-content:center;align-items:flex-end;gap:10px 18px;margin:8px 0 22px;padding:22px 16px 14px;border-radius:24px;background:var(--panel);border:1px solid var(--line);box-shadow:var(--shadow-card)}
.mtg-seat{width:150px;display:flex;flex-direction:column;align-items:center;text-align:center}
.mtg-px{width:56px;height:56px;border-radius:14px;background:var(--card) no-repeat 0 0/auto 100%;border:1px solid var(--line2);image-rendering:pixelated;display:flex;align-items:center;justify-content:center;font-size:20px;font-weight:800;color:var(--dim)}
.mtg-px.real{background-color:transparent;border-color:transparent;color:transparent}
.mtg-px.sm{width:34px;height:34px;border-radius:10px;font-size:14px;flex:none}
.mtg-nmrow{display:flex;align-items:center;justify-content:center;gap:5px;margin-top:5px}
.mtg-nm{font-size:12px;font-weight:700}
.mtg-seat.s-green .dot{background:#3aa66a}.mtg-seat.s-gray .dot{background:var(--faint)}.mtg-seat.s-red .dot{background:var(--red)}
/* 머리 위 말풍선 — 아래로 꼬리 */
.mtg-bub{position:relative;margin:0 0 12px;min-height:38px;max-width:150px;font-size:12px;line-height:1.4;color:var(--fg);background:var(--card);border:1px solid var(--line2);border-radius:14px;padding:7px 10px;box-shadow:var(--shadow-card);display:flex;align-items:center}
.mtg-bub::after{content:'';position:absolute;left:50%;bottom:-7px;width:12px;height:12px;background:var(--card);border-right:1px solid var(--line2);border-bottom:1px solid var(--line2);transform:translateX(-50%) rotate(45deg)}
.mtg-bub.think{color:var(--faint);letter-spacing:2px;justify-content:center;min-width:48px}
/* 발언 전문 — 대화 칸처럼 아바타 + 말풍선 */
.mtg-msg{display:flex;gap:10px;align-items:flex-start;margin-bottom:10px}
.mtg-bubble{max-width:min(88%,760px);background:var(--card);border:1px solid var(--line2);border-radius:16px;border-top-left-radius:6px;padding:8px 14px 6px;box-shadow:var(--shadow-card)}
.mtg-bubble>b{display:block;font-size:12px;margin-bottom:4px}
.mtg-bubble .ch-text{font-size:14px;line-height:1.6}
.mtg-bubble.empty{background:var(--hover);border-style:dashed;box-shadow:none}
.mtg-log{display:flex;flex-direction:column;gap:12px}
.mtg-card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:12px 16px;box-shadow:var(--shadow-card)}
.mtg-card>b{display:block;font-size:12px;color:var(--dim);margin-bottom:6px}
.mtg-card.done{border-color:var(--accent);background:var(--accent-soft)}
.mtg-card.done>b{color:var(--accent)}
.mtg-card ul{margin:0;padding-left:18px;font-size:14px;line-height:1.6}
.mtg-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px}
.mtg-acts{display:flex;gap:8px;align-items:center;flex:none;padding-top:6px}
.mtg-acts .go.primary{padding:9px 20px;font-size:14px;font-weight:700}
.mtg-card.now{border-color:var(--yellow,#e0b04a);box-shadow:0 0 0 1px color-mix(in srgb,var(--yellow,#e0b04a) 40%,transparent)}
.mtg-card.now>b{color:var(--fg);font-size:13px}
.mtg-card.wait{background:transparent;border-style:dashed;box-shadow:none}
.mtg-card.wait>b{color:var(--fg);font-size:13px;margin:0}
.mtg-card.wait p{margin:4px 0 0;font-size:13px}
.mtg-ask{margin-top:14px;padding-top:14px;border-top:1px solid var(--line)}
.mtg-ask textarea{width:100%;box-sizing:border-box;min-height:72px;font:inherit;font-size:14px;padding:10px 12px;border-radius:12px;border:1px solid var(--line2);background:var(--bg);color:var(--fg);resize:vertical}
.mtg-ask textarea:focus{outline:none;border-color:var(--accent)}
.mtg-ask .row{display:flex;justify-content:flex-end;gap:8px;margin-top:10px}
.mtg-ask p{margin:0;font-size:13px}
.mtg-doc{margin-top:12px;border-top:1px solid var(--line);padding-top:10px}
.mtg-doc summary{display:flex;align-items:center;gap:6px;cursor:pointer;font-size:13px;list-style:none}
.mtg-doc summary::-webkit-details-marker{display:none}
.mtg-doc summary .txtbtn{margin-left:auto}
.mtg-doc summary.mtg-drag{cursor:grab;border-radius:10px;padding:6px 8px;margin:-6px -8px}
.mtg-doc summary.mtg-drag:hover{background:var(--hover)}
.mtg-doc summary.drag{opacity:.5}
.mtg-doc .ch-text{margin-top:10px;padding:12px 14px;border-radius:12px;background:var(--bg);font-size:13px}
.mtg-round{margin-top:4px}
.mtg-round summary,.mtg-full>summary{cursor:pointer;font-size:13px;font-weight:700;color:var(--dim);padding:6px 0;margin:0}
.mtg-round .mtg-msg{margin-top:8px}
.agpick{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;margin:0 0 12px;padding:10px 12px;border-radius:12px;background:var(--hover)}
.agpick>b{font-size:13px}.agpick>span{font-size:12px}
.agpick>div{display:flex;gap:6px;margin-left:auto}
.agchip{font:inherit;font-size:13px;padding:5px 12px;border-radius:999px;border:1px solid var(--line2);background:var(--card);color:var(--fg);cursor:pointer}
.agchip.on{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 16%,var(--card));font-weight:700}
.agent-tag{display:inline-block;margin-left:5px;padding:0 5px;border-radius:5px;font-size:9.5px;font-weight:700;line-height:15px;vertical-align:1px;background:#10a37f22;color:#10a37f;border:1px solid #10a37f55}
.mtg-role{font-size:10px;font-weight:700;padding:1px 6px;border-radius:6px;background:var(--accent-soft);color:var(--fg);margin-left:4px}
.mtg-msg.boss .mtg-bubble{border-color:var(--accent)}
.mtg-past{margin-top:28px;padding-top:18px;border-top:1px solid var(--line)}
.mtg-fold{padding:0}
.mtg-fold>summary{cursor:pointer;padding:12px 16px;font-size:13px;font-weight:700;color:var(--dim)}
.mtg-fold>.ch-text,.mtg-fold>b,.mtg-fold>ul{margin-left:16px;margin-right:16px}
.mtg-fold>ul{margin-bottom:14px}
.mtg-fold>b{display:block;font-size:12px;color:var(--dim);margin-top:10px;margin-bottom:4px}
.mtg-seat{width:170px}
.mtg-bub{max-width:170px;min-width:0}
.mtg-bub>span{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;overflow-wrap:anywhere;word-break:keep-all;max-height:2.8em}
.mtg-stage,.mtg-log,.mtg-card{min-width:0;max-width:100%}
.mtg-card{overflow:hidden}
.mtg-px{width:64px;height:64px}
.mtg-card>b{font-size:13px;color:var(--fg)}
.mtg-card.done>b{color:var(--fg)}
.mtg-past h3{font-size:13px;color:var(--dim);margin:0 0 8px}
.mtg-prow{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:12px;color:var(--fg);text-decoration:none;font-size:14px}
.mtg-prow:hover{background:var(--hover)}
.mtg-prow .dt{width:40px;flex:none;color:var(--faint);font-size:12px}
.mtg-prow b{font-weight:600;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mtg-prow .who{margin-left:auto;font-size:12px;white-space:nowrap}
.mtg-says h3{font-size:12px;color:var(--dim);margin:8px 0 6px 4px}
.mtg-say{background:var(--card);border:1px solid var(--line2);border-radius:14px;padding:8px 14px;margin-bottom:8px}
.mtg-say summary{cursor:pointer;font-size:14px;list-style:none}
.mtg-say summary::-webkit-details-marker{display:none}
.mtg-say .ch-text{font-size:14px;line-height:1.6;margin-top:6px}
.mtg-full{margin-top:6px}
.mtg-full summary{cursor:pointer;font-size:12px;color:var(--dim);padding:6px 4px}
.mtg-full .ch-text{background:var(--panel);border-radius:14px;padding:12px 16px;font-size:13px;line-height:1.65}
.mtg-foot{font-size:11px;margin-top:14px}
.mtg-empty{max-width:560px}
.mtgstart .brief select{font:inherit;font-size:14px;padding:6px 10px;border-radius:10px;border:1px solid var(--line2);background:var(--card);color:var(--fg)}
.mtgstart .bwarn{margin:10px 0 0}
.mtgstart{width:min(640px,calc(100vw - 32px))}
.mtgstart .sh{justify-content:space-between;align-items:center}
.mtgstart .ms{margin:0 0 20px}
.mtgstart .ms h4{margin:0 0 10px;font-size:13px;font-weight:700;color:var(--dim);display:flex;align-items:baseline;gap:8px}
.mtgstart .ms h4 em{font-style:normal;font-weight:600;color:var(--accent)}
.mtgstart .ms h5{margin:14px 0 8px;font-size:12px;font-weight:600;color:var(--faint)}
.mtgstart .ms h5 span{font-weight:400;margin-left:6px}
.mtgstart .ms textarea{width:100%;min-height:64px}
.mtgstart .sf .go.primary{margin-left:auto}
.mtg-pick{display:flex;flex-wrap:wrap;gap:6px}
.mtg-pick .mp{position:relative;display:inline-flex;align-items:center;gap:6px;height:36px;padding:0 12px 0 4px;border-radius:10px;border:1px solid var(--line2);background:var(--card);color:var(--fg);font:inherit;font-size:13px;cursor:pointer}
.mtg-pick .mp b{font-weight:600}
.mtg-pick .mp small{color:var(--faint);font-size:11px}
.mtg-pick .mp .ck{display:none;font-style:normal;font-size:11px;font-weight:800;width:16px;height:16px;border-radius:50%;background:var(--accent);color:var(--accent-fg);align-items:center;justify-content:center;margin-left:2px}
.mtg-pick .mp:hover{border-color:var(--fg)}
.mtg-pick .mp.on{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,var(--card))}
.mtg-pick .mp.on .ck{display:inline-flex}
.mtg-pick .mp.off{background:transparent;border-style:dashed;color:var(--faint)}
.mtg-pick .mp.off .px{opacity:.5;filter:grayscale(1)}
.mtg-pick .mp.boss{cursor:default;background:transparent}
.mtg-pick .mp.boss:hover{border-color:var(--line2)}
.mtg-pick p{margin:0;font-size:13px}
.mtg-confirm{position:fixed;inset:0;z-index:60;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center}
.mtg-confirm .card{background:var(--panel);color:var(--fg);border-radius:16px;padding:20px 22px;min-width:300px;max-width:420px;box-shadow:0 12px 40px rgba(0,0,0,.3)}
.mtg-confirm h4{margin:0 0 8px;font-size:16px}
.mtg-confirm p{margin:0 0 8px}
.mtg-confirm .row{display:flex;justify-content:flex-end;gap:8px;margin-top:14px}
/* 리스트·보드 머리의 회의 표시 — 회의가 돌 때만 */
.mtg-badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:700;color:var(--fg);background:var(--accent-soft);border:1px solid var(--accent);border-radius:999px;padding:4px 10px;text-decoration:none}
.mtg-badge i{width:7px;height:7px;border-radius:50%;background:var(--accent);animation:mtgblink 1.4s infinite}
/* 사무실 맨 아래 회의실 버튼 */
.office .mtg-room{display:flex;align-items:center;gap:10px;margin:0 8px 10px;padding:8px 12px;border-radius:14px;background:var(--card);border:1px solid var(--line2);color:var(--fg);text-decoration:none;box-shadow:var(--shadow-card)}
.office .mtg-room:hover{border-color:var(--accent)}
.office .mtg-room .dot{width:8px;height:8px;background:var(--faint);flex:none}
.office .mtg-room.live .dot{background:#3aa66a;animation:mtgblink 1.4s infinite}
.office .mtg-room .txt{display:flex;flex-direction:column;line-height:1.25;min-width:0}
.office .mtg-room b{font-size:13px;font-weight:800}
.office .mtg-room small{font-size:11px;color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.office-folded .mtg-room{justify-content:center;padding:8px 0;margin:0 6px 8px}
.office-folded .mtg-room .txt{display:none}
@keyframes mtgblink{50%{opacity:.25}}
/* ── 리스트 · 4칸 보드 (2026-09-14 대표 확정) ── */
.seg{display:inline-flex;align-items:center;gap:2px;background:var(--lane-glass);border:1px solid var(--lane-edge);
  border-radius:999px;padding:3px;-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.seg a{color:var(--dim);text-decoration:none;border-radius:999px;padding:4px 12px;font-size:14px;font-weight:600}
.seg a:hover{color:var(--fg)}
.seg a.on{color:var(--fg);background:var(--card);box-shadow:var(--shadow-card)}
.views .seg{background:var(--hover);border:0;padding:2px;margin-right:4px;-webkit-backdrop-filter:none;backdrop-filter:none}
html.in-app *{-webkit-backdrop-filter:none!important;backdrop-filter:none!important}
/* 리스트 본문과 프로젝트 판 — **판을 오른쪽에 띄우고 목록은 그 아래로 흘러 끝까지 쓴다**
   (대표 요청 9/16 「전체로 끝부분에 맞추기」). 두 칸(그리드)으로 두면 판이 끝난 아래에도
   오른쪽이 늘 비어 있어서, 접힌 줄(세션 차례·대기·백로그)이 화면 절반에서 끊겼다. */
.grid2{display:block;max-width:1400px}
.grid2>aside{float:right;width:360px;margin:0 0 20px 24px}
.grid2::after{content:'';display:block;clear:both}
/* ⚠️ 칸 하나가 판 옆과 판 아래에 **걸쳐서** 반은 좁고 반은 넓게 끊겼다(대표 제보 9/16 스크린샷).
   칸마다 제 영역을 갖게 해(flow-root) **칸 통째로** 판 옆에 서거나 판 아래로 내려가게 한다 */
.grid2>main>section,.grid2>main>details,.grid2>main>div,.grid2>main>nav{display:flow-root}
.blk{margin:0 0 22px}
.blk h2{font-size:12px;font-weight:700;color:var(--dim);margin:0 0 8px 4px;display:flex;align-items:center;gap:8px;letter-spacing:.02em}
.blk h2 em{font-style:normal;color:var(--faint);font-weight:600}
.hint{margin-left:auto;font-weight:400;color:var(--faint);letter-spacing:0}
.banner{display:flex;gap:12px;align-items:center;flex-wrap:wrap;background:var(--c-banner,var(--panel));
  border-radius:18px;padding:12px 16px;margin:0 0 22px;box-shadow:var(--shadow-card);border:1px solid var(--line);
  border-left:4px solid #e8b43a}
.banner .ba{margin-left:auto;display:flex;gap:6px}
/* 리스트 — 줄 하나가 곧 카드 한 장이다(대표 수정요청 9/16). 묶음만 상자였을 때는 하위 없는 태스크가
   태스크로 안 보였다. 묶음(.lgrp)과 홑 줄이 같은 테두리·모서리를 쓴다. */
.list{background:none;border:0;box-shadow:none;border-radius:0;padding:4px 0}
.lrow{cursor:pointer}
.list>.lrow{background:var(--card);border:1px solid var(--line2);border-radius:14px;margin:8px 10px}
.lrow{position:relative;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;align-items:center;
  padding:10px 16px}
.lrow:hover{background:var(--hover)}
.list>.lrow:hover{border-color:var(--dim)}
.lrow.alarm{box-shadow:inset 3px 0 0 var(--red)}
.lrow .ct{font-weight:600}
.lrow .cp{margin-top:4px}
.la{display:flex;gap:6px;align-items:center}
.pjn{font-size:12px;color:var(--faint)}
.list .empty{padding:14px 16px;font-size:12px;color:var(--faint)}
details.fold{margin:0 0 12px}
/* 리스트 본문은 판 아래로 내려가도 **판 자리(360 + 사이 24)를 비워 둔다** — 판 옆 카드와 판 아래 카드·접힌 줄의 오른쪽 끝이
   어긋났다(대표 제보 9/17 스크린샷 세 장: 세션 차례·대기·백로그, 내 차례 · 오늘 할 일). 9/16 「끝까지」 결정을 이번 제보로 뒤집는다.
   판이 위로 올라가는 좁은 화면에서는 끝까지 쓴다. 접힌 줄은 줄 카드(.list>.lrow)와 같은 좌우 10px 안쪽 */
.grid2>main{margin-right:384px}
@media (max-width:920px){.grid2>main{margin-right:0}}
.main-narrow .grid2>main{margin-right:0}
.grid2>main>details.fold{margin:0 10px 12px}
details.fold>summary{list-style:none;cursor:pointer;display:flex;align-items:center;gap:6px;flex-wrap:wrap;
  background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:11px 16px;color:var(--dim);
  box-shadow:var(--shadow-card)}
details.fold>summary::-webkit-details-marker{display:none}
details.fold>summary::after{content:'›';margin-left:auto;transition:transform .15s;font-size:16px}
details.fold[open]>summary::after{transform:rotate(90deg)}
details.fold>summary:hover{color:var(--fg)}
details.fold>summary b{color:var(--fg)}
details.fold[open]>summary{border-radius:18px 18px 0 0;box-shadow:none}
details.fold>.list{border-radius:0 0 18px 18px;border-top:0}
.rvc{color:var(--pf);font-weight:700;font-size:12px}
.col .rvc,.fold .rvc{--pf:#d0457f}
:root[data-theme="dark"] .col .rvc,:root[data-theme="dark"] .fold .rvc{--pf:#eea4c8}
.board4{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;align-items:start;max-width:1500px}
/* 칸이 좁아지면(1920에서 대화 칸을 연 상태) 네 칸을 지키되 카드를 촘촘하게 — 240px 칸에 예전 크기를 그대로 두니
   제목이 석 줄로 접히고 꼬리표가 두 줄로 넘쳐 답답했다(대표 제보 9/16). 글씨·여백·꼬리표를 한 단 줄인다. */
.main-narrow-ish .board4{gap:8px}
.main-narrow-ish .board4 .card{padding:9px 10px 7px}
.main-narrow-ish .board4 .ct{font-size:13px;line-height:1.4;-webkit-line-clamp:2}
.main-narrow-ish .board4 .cp{gap:3px 6px;margin-top:6px}
.main-narrow-ish .board4 .pill{font-size:10.5px;padding:0 6px}
.main-narrow-ish .board4 .cp .spent,.main-narrow-ish .board4 .cp .due{font-size:11px}
.main-narrow-ish .board4 .pj{margin-top:4px;font-size:11px}
.main-narrow-ish .board4 .col h3{font-size:11.5px;gap:4px}
/* 좁은 칸에서는 머리 줄을 접지 않는다 — 「수정 2」가 세로로 깨져 보였다(대표 제보 9/16) */
.main-narrow-ish .board4 .col h3 .rvc{flex:none;white-space:nowrap}
.main-narrow-ish .board4 .col h3 .sendall{flex-basis:100%;margin:2px 0 0;text-align:center;font-size:11px}
.main-narrow-ish .board4 .gh .gn{font-size:12px}
.main-narrow-ish .board4 .gsum{font-size:11px}
.board4 .col{flex:none;min-width:0}
.board4 .col h3{flex-wrap:nowrap;font-size:12px}
.lwho{margin-left:auto;font-weight:400;color:var(--faint);white-space:nowrap}
.board4 .col .empty{padding:10px 6px;font-size:12px;color:var(--faint)}
/* ⚠️ details.fold{margin:0 0 12px}가 더 구체적이라 여백이 0이 되어 가장 긴 칸 밑에 서랍이 붙어 겹쳐 보였다(대표 제보 9/15) */
details.fold.drawer{margin-top:18px;max-width:1500px}
.ptabsrow{display:flex;align-items:center;gap:10px;max-width:1500px}
/* 리스트는 오른쪽에 프로젝트 판(360px)이 있으므로 그만큼 뺀 폭으로 — 판 위로 넘어가지 않게 */
.ptabsrow.list-row{max-width:1400px;padding-right:384px}
@media (max-width:920px){.ptabsrow.list-row{padding-right:0}}
.ptabsrow .ptabs{flex:1;min-width:0}
.ptabsrow .find{margin-bottom:10px}
/* 리뷰3 L1(9/17): 옆으로 스크롤이라 마지막 탭이 「홈…」으로 잘렸다 — 넘치면 다음 줄로 감는다 */
.ptabs{display:flex;gap:4px 4px;align-items:center;flex-wrap:wrap;padding:2px 2px 12px}
.whobar{display:flex;align-items:center;gap:10px;margin:0 0 10px;padding:8px 14px;border-radius:14px;background:var(--accent-soft);font-size:14px;max-width:1500px}
.whobar b{font-weight:800}
.whobar em{font-style:normal;color:var(--faint);font-weight:700;margin-left:4px}
.whobar .txtbtn{margin-left:auto;font-weight:700}
.whobar.find-bar{background:var(--hover)}
/* 찾기 칸 — 머리에 둔다(대표 요청 9/16) */
.find{position:relative;display:inline-flex;align-items:center;margin-left:auto;flex:none}
.find input{width:150px;font:inherit;font-size:13px;color:var(--fg);background:var(--card);border:1px solid var(--line2);
  border-radius:999px;padding:5px 26px 5px 12px;outline:none;transition:width .15s}
.find input::placeholder{color:var(--faint)}
.find input:focus{width:230px;border-color:var(--accent)}
.find input::-webkit-search-decoration,.find input::-webkit-search-cancel-button{display:none}
.find .x{position:absolute;right:6px;border:0;background:none;color:var(--faint);font-size:12px;cursor:pointer;padding:2px}
.find .x:hover{color:var(--fg)}
@media (max-width:900px){.find input{width:110px}.find input:focus{width:150px}}
.ptabs a{text-decoration:none;color:inherit}
.pt{flex:none;display:inline-flex;align-items:center;gap:2px;padding:5px 12px;border-radius:999px;color:var(--dim);
  white-space:nowrap;font-size:14px;font-weight:600;border:1px solid transparent}
span.pt{padding-left:6px}
.pt em{font-style:normal;color:var(--faint);font-weight:500;margin-left:3px}
.pt:hover{background:var(--hover);color:var(--fg)}
.pt.on{background:var(--card);color:var(--fg);box-shadow:var(--shadow-card);border-color:var(--line)}
.pt.off{color:var(--faint)}
.ptabs .sep{flex:none;width:1px;height:18px;background:var(--line2);margin:0 6px}
.star{width:22px;height:22px;border-radius:50%;font-size:14px;line-height:22px;color:var(--faint);flex:none}
.star.on{color:#e8a317}
.star:hover{background:var(--hover);color:#e8a317}
.bnote{font-size:12px;color:var(--faint);margin:0 4px 12px}
.ppanel{background:var(--panel);border-radius:18px;box-shadow:var(--shadow-card);border:1px solid var(--line);overflow:hidden}
.prow{display:grid;grid-template-columns:24px minmax(0,1fr) 34px 34px 44px 62px;gap:4px;align-items:center;
  padding:6px 12px;border-top:1px solid var(--line);font-size:14px}
.prow.head{border-top:0;font-size:12px;color:var(--faint);padding-block:9px}
.prow.head span:nth-child(n+3){text-align:right}
.prow.off{color:var(--dim)}
.prow.sel{background:var(--hover)}
.pname{display:flex;align-items:center;gap:6px;min-width:0}
.pname a{color:inherit;text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.pname a:hover{color:var(--accent)}
.pname small{font-size:12px;color:var(--faint);flex:none}
.lamp{width:7px;height:7px;border-radius:50%;flex:none;background:var(--line2)}
.lamp.idle{background:#3fb37f}.lamp.busy{background:#e8a317}.lamp.wait{background:var(--red)}
.n{text-align:right;font-variant-numeric:tabular-nums}
.n.zero{color:var(--line2)}
.n.hot{color:#d0457f;font-weight:700}
:root[data-theme="dark"] .n.hot{color:#eea4c8}
.n.wk{font-size:12px;color:var(--faint)}
.psub{font-size:12px;color:var(--faint);padding:8px 12px;border-top:1px solid var(--line)}
.psub a{color:var(--accent)}
.kbar{display:flex;height:6px;border-radius:3px;overflow:hidden;margin:10px 12px 4px;background:var(--line)}
.kbar span{background:var(--pf)}
.kleg{display:flex;gap:12px;flex-wrap:wrap;font-size:12px;color:var(--faint);padding:2px 12px 8px}
.kleg i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px;background:var(--pf)}
.card:focus-within .cf{opacity:1;pointer-events:auto}
/* 터치 기기에는 올릴 손이 없다 — 카드 버튼을 늘 보인다(폰에서도 할 일을 고친다) */
@media (hover:none){
  .cf{position:static;opacity:1;pointer-events:auto;box-shadow:none;border:0;background:none;padding:0;margin-top:8px}
  .hov{opacity:1}
}
@media (max-width:920px){.grid2>aside{float:none;width:auto;margin:0 0 20px}.board4{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:560px){
  body{padding:18px 16px}
  .board4{grid-template-columns:minmax(0,1fr)}
  .lrow{grid-template-columns:minmax(0,1fr)}
  .ct{overflow-wrap:anywhere}
  .views{margin-left:0}
}
/* ── 사무실 + 대화 한 판 — 오른쪽에 붙는다. 열린 너비만큼 페이지가 비켜 선다(시안 v9) ── */
.chatbtn{margin-left:auto;border:1px solid var(--line2);background:var(--card);color:var(--fg);border-radius:999px;
  padding:5px 14px;font-size:14px;font-weight:600;box-shadow:var(--shadow-card)}
.chatbtn+.views{margin-left:0}
/* 넓은 화면에서는 「대화」가 사무실 머리에 있다(대표 요청 9/15). 폰은 사무실이 숨으므로 머리 줄에 남긴다 */
@media (min-width:901px){.top .chatbtn{display:none}.top .chatbtn+.views{margin-left:auto}}
.chat-open .chatbtn{background:var(--accent-soft);color:var(--accent);border-color:transparent}
/* 판이 있는 페이지(할 일)에서만 비켜 선다 — has-duo는 판의 스크립트가 붙인다 */
:root{--dock-w:640px}
.has-duo body{padding-right:calc(236px + 28px)}
.has-duo.chat-open body{padding-right:calc(236px + var(--dock-w) + 28px)}
.has-duo.office-folded body{padding-right:calc(58px + 28px)}
.has-duo.office-folded.chat-open body{padding-right:calc(58px + var(--dock-w) + 28px)}
.duo{position:fixed;top:12px;right:12px;bottom:12px;display:flex;z-index:20;background:var(--panel);border:1px solid var(--line2);
  border-radius:22px;box-shadow:var(--shadow-card);overflow:hidden}
#back{z-index:30}.sheet{z-index:31}#err{z-index:40}
.office{width:236px;display:flex;flex-direction:column;min-height:0;transition:width .18s ease}
.office-folded .office{width:58px}
.oh{display:flex;align-items:center;gap:6px;padding:10px 8px 8px 14px;border-bottom:1px solid var(--line)}
.oh b{font-size:14px;font-weight:800}
.oh .fold{margin-left:0}
.oh .talk{margin-left:auto;font:inherit;font-size:12px;font-weight:700;color:var(--dim);background:var(--card);border:1px solid var(--line2);border-radius:999px;padding:3px 11px;cursor:pointer}
.oh .talk:hover{color:var(--fg)}
.chat-open .oh .talk{background:var(--accent-soft);color:var(--accent);border-color:transparent}
.office-folded .oh .talk{display:none}
.office-folded .oh{padding:10px 0 8px;justify-content:center}
.office-folded .oh b{display:none}
.office-folded .oh .fold{margin:0}
.tree{flex:1;overflow-y:auto;padding:10px 8px 12px 6px;scrollbar-width:thin}
/* ── 사무실 = 빌딩 ── (대표 결정 9/18, 시안 D1 · docs/20260918_시안_사무실층구조_v2.html)
   ⚠️ **한 층은 가로 한 줄이다.** 팀원을 아래로 쌓던 때는 층이 아니라 목록으로 보여 건물이 안 됐다.
   팀장과 팀원이 같은 층에 나란히 앉고, 층 높이가 고정이라 위로 쌓이면 건물이 된다 —
   이사 층이 꼭대기인 것도 눈으로 보인다. 사람이 많으면 그 층만 옆으로 민다(높이는 안 변한다). */
/* ⚠️ 건물은 **아래로 붙인다**. 위에 붙여 두면 1층이 허공에 뜨고 아래 40%가 빈 배경으로 남아
   지하처럼 보였다(리뷰 9/18). 남는 자리는 위(하늘)로 간다. */
/* ⚠️ 건물 위에 **하늘 그라데이션을 깔지 않는다**(대표 9/20). 창문 그림이 이미 하늘을 말하고 있어서
   위쪽에 색을 또 깔면 두 번 말하는 것이 되고, 창문 색과 미묘하게 어긋나 지저분해 보였다.
   남는 자리는 판 바탕 그대로 둔다 — 건물은 아래로 붙어 있어 그것만으로 건물로 읽힌다. */
.tree{display:flex;flex-direction:column;gap:0;padding:8px 6px 10px;justify-content:flex-end}
.bldg{border-radius:10px;overflow:hidden;border:1px solid var(--line2);margin-top:auto}

:root{--of-wall:#efe7db;--of-wall2:#e5dacb;--of-floorline:#8a6a48;--of-glass:#bcd9f2;--of-desk:#8a6a48;--of-band-color:#e0d5bd}
/* ⚠️ 어두운 판의 벽을 한 단계 밝힌다 — 거의 검정이던 때는 캐릭터 실루엣이 벽에 묻혔다(리뷰 9/18). */
:root[data-theme="dark"]{--of-wall:#3a342c;--of-wall2:#453d33;--of-floorline:#7d6041;--of-glass:#42607d;--of-desk:#7d6041;--of-band-color:#52453a}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--of-wall:#3a342c;--of-wall2:#453d33;--of-floorline:#7d6041;--of-glass:#42607d;--of-desk:#7d6041;--of-band-color:#52453a}}
/* 한 층 = 둥근 카드. 아래 **바닥 띠**에 이름이 앉고 캐릭터는 그 띠 위에 선다(대표 레이아웃 9/18, 참고.png).
   ⚠️ 캐릭터를 키우는 것이 이 배치의 목적이다 — 작게 그리면 누가 일하는지 안 보인다. */
/* ⚠️ 층 사이에 틈을 두지 않는다 — 떨어뜨려 놓으면 카드 목록이지 건물이 아니다(대표 요청 9/18).
   층을 가르는 것은 바닥 띠와 그 아래 그림자 한 줄이다. 둥근 모서리는 건물 전체(.bldg)만 갖는다. */
/* 층 높이 104 = 머리 여백 14 + 캐릭터 64 + 책상 띠 26.
   ⚠️ 책상선을 올려 달라는 요청(9/18)에 띠를 26으로 키웠다. 층 높이를 그대로 두면 머리 위가 6px만 남아
   **층 제목이 캐릭터 머리에 붙는다** — 실제로 그렇게 나왔다. 그래서 층을 8px 늘렸다.
   ⚠️ **캐릭터를 1:1(64px)로 그린다**(대표 결정 9/18). 레티나에서 원본 1픽셀 = 화면 2점으로 딱 떨어져
   층 그림(222×96, 1배)과 픽셀 크기가 같아진다. 0.72배 같은 어중간한 값은 픽셀 선이 들쭉날쭉해진다. */
/* 층 높이·서는 선은 `art/office/layout.json`이 정한다(기본 104 / 78). 캐릭터 64px은 고정이다. */
.team{position:relative;margin:0;border-radius:0;padding:calc(var(--of-h,104px) - 64px - var(--of-band,26px)) 0 0;image-rendering:pixelated;
  background-image:var(--floor-img,none),
    linear-gradient(180deg,rgba(0,0,0,.05) 0 5px,rgba(0,0,0,0) 5px),
    repeating-linear-gradient(90deg,rgba(0,0,0,0) 0 26px,rgba(0,0,0,.03) 26px 27px);
  background-color:var(--of-wall);background-repeat:no-repeat,repeat-x,repeat;
  /* ⚠️ 벽 그림을 **늘이지 않는다.** 원래 픽셀 크기 그대로 아래에 붙이고 위가 잘린다 —
     늘이면 픽셀이 뭉개지고, 층보다 긴 반복 패턴 그림을 쓸 수 없다(대표 9/18). */
  background-size:auto,100% 100%,auto;background-position:bottom center,top,top}
.team+.team{box-shadow:0 -2px 0 rgba(0,0,0,.5)}
.team.boss{background-color:var(--of-wall2)}
/* 창문 — 시간대가 여기서 바뀐다. 층이 옆으로 밀려도 제자리에 남는다(줄 밖에 둔다) */
/* 창문 — 시간대를 말한다. ⚠️ **작고 차분하게** 둔다. 아홉 층에 같은 밝은 사각형이 반복되던 때는
   화면에서 가장 눈에 띄는 것이 창문이었다 — 정작 봐야 할 이름·상태보다 먼저 들어왔다(리뷰 9/18).
   큰 창은 꼭대기(이사) 층에만 둔다. */
/* 창문은 **따로 그린 그림**이다(대표 결정 9/18 — 시간대별로 갈아 끼워야 해서 벽과 분리했다).
   그림이 없으면 코드가 그린 유리가 그대로 남는다(404 → 배경 그림만 비고 아래 층들이 보인다). */
.team .win{position:absolute;z-index:0;right:var(--of-win-right,8px);top:var(--of-win-top,14px);width:var(--of-win-w,48px);height:var(--of-win-h,28px);border-radius:2px;image-rendering:pixelated;
  background-image:var(--win-img,none);background-size:100% 100%;background-repeat:no-repeat;pointer-events:none}
.team .win.none{border:2px solid var(--of-floorline);
  background-image:linear-gradient(90deg,rgba(0,0,0,0) 0 47%,var(--of-floorline) 47% 53%,rgba(0,0,0,0) 53%),
    var(--floor-sky,none),linear-gradient(var(--of-glass),var(--of-glass));opacity:.85}
.team.boss .win.none{opacity:.95}
/* 창밖 색은 시간대를 **한눈에** 말해야 한다 — 하늘 그라데이션만 얹으면 유리색에 묻혀 아침·오후가 같아 보였다. */
.tree.tod-morning{--of-glass:#e5c191}
.tree.tod-afternoon{--of-glass:#8fb6d6}
.tree.tod-evening{--of-glass:#2c3566}
.tree.tod-evening .team .win{box-shadow:0 0 9px 2px rgba(255,196,110,.28)}
.tree.tod-evening .team{filter:brightness(.94)}
/* 바닥 띠 — 이름이 앉는 자리. ⚠️ **벽 그림이 있으면 그 그림의 바닥을 쓴다**(대표가 그린 그림에 이미
   바닥이 들어 있다, 9/18). 코드가 그린 띠를 겹쳐 깔면 두 겹이 된다. */
/* 책상 띠 — 이름이 앉는 자리이자 캐릭터가 서는 바닥이다(대표 선택 9/18: 「발밑 바닥선만 위로」).
   캐릭터를 가리지 않으므로 자리(.row) 아래에 둔다. */
.team .band{position:absolute;left:0;right:0;bottom:0;height:var(--of-band,26px);background:var(--of-band-color);
  border-top:1px solid rgba(0,0,0,.12)}
.team.art .band{background:none;border-top:0}
.team.art{background-color:transparent}
/* ⚠️ 벽 그림이 깔리면 글자색을 화면 테마에 기댈 수 없다 — 밝은 벽돌 위에서 회색 글자가 통째로 사라졌다(9/18).
   층수·팀 이름은 **흰 글자 + 어두운 외곽선**으로(어떤 벽에도 읽힌다), 세션 이름은 바닥 띠 위라 어두운 글자로 둔다. */
.team.art .tname{color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.8)}
.team.art .no{background:rgba(0,0,0,.5);text-shadow:none}
/* ⚠️ 그림이 벽을 캐릭터 키만큼 채우면 머리 위에 제목을 놓을 자리가 없다 — 실제로 층 제목이 왕관과 겹쳤다(9/18).
   책상 띠가 넉넉하면(28px 이상) 제목을 **띠 윗줄**로 내린다: 윗줄은 층 이름, 아랫줄은 세션 이름. */
.tree.title-band .team .no{top:auto;bottom:calc(var(--of-band,26px) - 14px);color:var(--dim);text-shadow:none}
.tree.title-band .team .tname{top:auto;bottom:calc(var(--of-band,26px) - 14px);left:20px;color:var(--dim);text-shadow:none}
.tree.title-band .team .tag{color:var(--dim);border-color:var(--line2)}
.tree.title-band .team .sum{bottom:calc(var(--of-band,26px) - 14px)}
.tree.title-band .seat .nm{bottom:1px}
.team.art .seat .nm{z-index:4}

.team.art .tag{color:#fff;border-color:rgba(255,255,255,.55)}
.team.art .seat .nm{color:#3a2f22;text-shadow:0 1px 0 rgba(255,255,255,.4)}
.team.art .seat[aria-pressed="true"] .nm{color:#5a3608;text-shadow:none}
.team.art .sum{color:#5a4a33;text-shadow:none}
.team.art .sum b{color:#3a2f22}
.team.art .st-dot{box-shadow:0 0 0 1.5px rgba(0,0,0,.35)}
.team.art.s-working .st-dot{box-shadow:0 0 0 1.5px rgba(0,0,0,.35),0 0 6px 1px rgba(232,163,23,.45)}
/* 층수는 **칩**으로 뗀다 — 팀명과 같은 글씨로 붙여 놓으니 한 덩어리로 읽혔다(리뷰 9/18). */
.team .no{position:absolute;left:5px;top:2px;font-size:8.5px;font-weight:800;letter-spacing:.02em;
  padding:0 4px;line-height:13px;border-radius:4px;background:rgba(0,0,0,.42);color:#fff}
/* 팀명은 **층 이름**이다 — 자리에 앉은 세션 이름보다 한 단계 조용하게. */
.team .tname{font-weight:700}
.team .tname{position:absolute;left:32px;top:2px;max-width:100px;font-size:9.5px;font-weight:700;color:var(--faint);line-height:13px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.team .no .tag{margin-left:4px;font-style:normal;font-size:8px;font-weight:800;opacity:.85}
/* ▲▼ — 손을 올린 층에만. 창문 왼쪽에 붙는다 */
/* ▲▼ — 손을 올린 층에만. ⚠️ **창문 자리를 피한다** — 오른쪽 위에 두었더니 창문 그림 위에 겹쳐
   검은 네모처럼 보였다(대표 제보 2026-09-20). 층수 칩 옆이 비어 있고 눈도 거기서 시작한다. */
.team .lift{position:absolute;left:36px;top:2px;display:flex;gap:2px;opacity:0;transition:opacity .12s}
.team:hover .lift,.team .lift:focus-within{opacity:1}
.team .lift button{width:17px;height:14px;border:0;border-radius:4px;background:rgba(0,0,0,.45);color:#fff;font-size:8px;line-height:1;cursor:pointer}
.team .lift button:hover:not(:disabled){background:rgba(0,0,0,.72)}
.team .lift button:disabled{opacity:.3}
/* 자리 줄 — 사람이 많으면 여기만 옆으로 민다 */
/* 층 요약 — 빈 벽을 정보로 채운다(리뷰 9/18: 아홉 층에 열세 명, 오른쪽 70%가 빈 벽이었다) */
/* 층 요약은 **책상 띠 안 오른쪽**에 앉는다 — 벽돌 위에 흰 글씨로 떠 있던 때는 지저분했다(리뷰 9/18). */
.team .sum{position:absolute;right:8px;bottom:6px;z-index:4;display:flex;gap:5px;font-size:9px;font-weight:700;color:var(--faint);pointer-events:none}
.team .sum b{font-weight:800;color:var(--dim)}
.team .sum .w{color:var(--red)}
.team .row{position:relative;z-index:2;display:flex;align-items:flex-end;gap:0;overflow-x:auto;overflow-y:hidden;padding:0 2px;scrollbar-width:none}
.team .row::-webkit-scrollbar{height:0}
/* 옆으로 더 있는 층 — 가장자리를 흐리고 남은 수를 적는다. 숨긴 스크롤바를 대신한다 */
.team.more .row{mask-image:linear-gradient(90deg,#000 0 82%,rgba(0,0,0,.25) 100%)}
.team .rest{position:absolute;right:2px;bottom:calc(var(--of-band,26px) + 1px);z-index:2;font-size:9px;font-weight:800;color:var(--dim);
  background:var(--panel);border:1px solid var(--line2);border-radius:999px;padding:0 4px;line-height:14px}
/* ⚠️ **그림 아래쪽 띠가 곧 책상이다**(대표 9/18 — 내가 바닥으로 본 것이 책상이었다).
   그래서 그 띠를 **캐릭터 앞에 한 번 더 덮어** 그린다. 캐릭터는 `charDrop`만큼 내려앉아
   하반신이 책상에 가려진다 — 책상 그림을 따로 둘 필요가 없다. */
/* ⚠️ 책상은 층에 **한 장**으로 깐다(대표 9/18). 자리마다 잘라 붙이던 때는 그림의 좌우 테두리가
   자리 사이마다 나타나 **책상이 툭툭 끊겨 보였다**(대표 스샷 7·6·5층).
   그리고 **캐릭터가 책상 위에 선다** — 앞에 덮었더니 손이 가려졌다(대표 9/18). */
.team.art .deskstrip{position:absolute;left:0;right:0;bottom:0;height:var(--of-band,26px);z-index:1;
  background-image:var(--desk-img,var(--floor-img,none));background-size:100% auto;background-position:bottom center;
  background-repeat:no-repeat;image-rendering:pixelated;pointer-events:none}
.team.art .seat .desk{display:none}
/* (옛) 자리마다 놓던 책상 그림 — `desk.png`를 넣었을 때만 쓴다.
   그림이 없으면 코드가 그린 나무 상판이 뜬다. 높이는 `layout.json`의 `desk.h`. */
.seat .desk{position:absolute;left:0;right:0;bottom:var(--of-band,26px);height:var(--of-desk-h,24px);z-index:3;
  image-rendering:pixelated;background-size:100% 100%;background-repeat:no-repeat;pointer-events:none}

/* 그림이 없으면 자리 책상은 안 그린다 — 코드가 그린 띠(.band)가 대신한다. */
.team:not(.art) .seat .desk{display:none}
/* ⚠️ 그림이 있는 층에는 코드가 색을 덧칠하지 않는다 — 우선순위가 같아 나중 규칙이 이겨 갈색으로 덮였다(9/18). */
.team:not(.art):not(.deskart) .seat .desk{background:linear-gradient(180deg,var(--of-desk) 0 4px,rgba(0,0,0,.25) 4px 6px,var(--of-desk) 6px);
  border-radius:2px 2px 0 0;box-shadow:0 -1px 0 rgba(255,255,255,.15) inset}
/* 픽셀 얼굴 — 64×64 시트의 첫 칸만 보인다(배경 크기 = 칸 수 × 100%). 자리에 맞게 줄여 쓴다. */
.px{position:relative;flex:none;width:64px;height:64px;image-rendering:pixelated;background-repeat:no-repeat;background-position:0 0}
.px .hat{position:absolute;left:0;width:64px;height:32px;image-rendering:pixelated}
/* 사람 하나 = 책상 한 칸 */
.seat{position:relative;flex:0 0 auto;width:56px;display:flex;flex-direction:column;align-items:center;
  padding:0 0 var(--of-band,26px);border:0;background:none;cursor:pointer;border-radius:8px 8px 0 0}
.seat:hover{background:rgba(255,255,255,.28)}
:root[data-theme="dark"] .seat:hover,
:root:not([data-theme="light"]) .seat:hover{background:rgba(255,255,255,.07)}
/* 캐릭터는 책상 쪽으로 조금 내려 앉는다(`layout.json`의 `charDrop`, 기본 12px) — 대표 결정 9/18
   「책상을 올리지 말고 캐릭터를 내려 맞춘다」. 내려간 만큼 머리 위에 층 제목 자리가 생긴다. */
.seat .px{position:relative;top:calc(var(--seat-foot,0px) + var(--of-char-drop,0px))}
/* 팀원은 팀장보다 작게 앉는다 — **0.75배(48px)**다(대표 요청 9/18 「50% 더 키워줘」).
   ⚠️ 0.5배(32px)는 픽셀이 딱 떨어지지만 너무 작았다. 0.75는 한 픽셀이 1.5점이라 선 굵기가 살짝 들쭉날쭉한데,
   그 대신 얼굴이 보인다 — 대표가 크기를 골랐다. 바닥에 붙여야 하므로 기준점은 아래 가운데다. */
.seat.staff .px{transform:scale(.75);transform-origin:bottom center;
  top:calc((var(--seat-foot,0px) + var(--of-char-drop,0px)) * 0.75)}
.seat.staff{width:50px}
/* 작아진 몸에 맞춰 점·배지도 내려온다 — 스프라이트가 칸의 아래 절반만 차지하기 때문이다. */
.seat.staff .st-dot{top:calc(16px + (var(--seat-foot,0px) + 20px) * 0.75);width:6px;height:6px;right:7px}
.seat.staff.s-working .st-dot,.seat.staff.s-thinking .st-dot,.seat.staff.s-waiting .st-dot{width:8px;height:8px;right:6px}
.seat.staff .mark{top:calc(16px + (var(--seat-foot,0px) + 26px) * 0.75);left:2px;font-size:8px;line-height:12px}
/* 캐릭터는 **원본 그대로 64px**. 자리(56px)보다 넓어 좌우로 조금 겹치는데, 스프라이트 가장자리가
   비어 있어 겹쳐 보이지 않는다. 팀장은 크기가 아니라 **모자(왕관)**로 가른다 — 크기를 키우면 픽셀이 어긋난다. */
.seat .px{transform:none;margin:0 -4px}

/* ⚠️ 이름은 흐름에서 빼 **바닥 아래 띠**에 놓는다. 흐름에 두면 이름이 있는 자리만 책상이 위로 밀려
   한 층 안에서 바닥선이 어긋났다(9/18에 겪었다) — 건물은 바닥이 한 줄이어야 건물이다. */
/* 이름은 바닥 띠 안에 앉는다 — 흐름에서 빼야 자리마다 바닥선이 안 어긋난다 */
/* 이름은 **두 줄까지** 쓴다 — 한 줄이면 한글 다섯 자부터 잘려 「02_클로드…」가 여럿이 됐다(리뷰 9/18). */
/* 이름은 책상 띠 **가운데**에 앉는다 — 아래에 붙여 놨더니 책상 밑단에 걸쳐 보였다(대표 9/18). */
.seat .nm{position:absolute;left:1px;right:1px;bottom:calc((var(--of-band,26px) - 20px) / 2);z-index:2;font-size:8.5px;font-weight:700;line-height:10px;
  color:var(--dim);text-align:center;word-break:break-all;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.seat:hover .nm{color:var(--fg)}
/* 상태 점 — 일하는 중·대기만 키운다. 6px 하나로 다 그리던 때는 먼눈에 누가 일하는지 안 보였다(리뷰 9/18). */
/* 상태 점은 **캐릭터 어깨 옆**에 붙인다 — 머리 위 허공에 떠 있으면 누구 것인지 한 번 더 봐야 한다(리뷰 9/18). */
.seat .st-dot{position:absolute;right:9px;top:calc(var(--seat-foot,0px) + 20px);width:7px;height:7px;border-radius:50%;background:var(--line2);transition:all .12s;z-index:2}
.seat.s-working .st-dot,.seat.s-thinking .st-dot,.seat.s-waiting .st-dot{width:9px;height:9px;right:7px}
.seat.s-idle .st-dot,.seat.s-done .st-dot,.seat.s-bored .st-dot{background:#3fb37f}
.seat.s-working .st-dot,.seat.s-thinking .st-dot{background:#e8a317;box-shadow:0 0 6px 1px rgba(232,163,23,.45)}
.seat.s-waiting .st-dot{background:var(--red);box-shadow:0 0 0 3px rgba(229,72,77,.25)}
.seat.s-ended .st-dot,.seat.s-error .st-dot{background:var(--line2)}
/* 아무도 출근 안 한 층은 **불이 꺼진 사무실**처럼 어둡다(대표 9/18). 벽·책상까지 통째로 가라앉힌다. */
.team.dark::before{content:'';position:absolute;inset:0;z-index:5;pointer-events:none;background:rgba(10,8,16,.45)}
.team.dark .no,.team.dark .seat .nm{opacity:.6}
/* 퇴근한 자리 — 캐릭터도 이름도 흐리다. ⚠️ **지우지는 않는다** — 그 자리에 세션이 있다는 것은 남아야 한다(대표 9/18). */
.seat.s-ended .px{opacity:.45;filter:grayscale(.55)}
.seat.s-ended .nm{opacity:.55}
.seat.s-ended:hover .px{opacity:.75;filter:none}
/* 지금 대화 중인 자리 — ⚠️ **책상 색을 바꾸지 않는다.** 하얗게 칠했더니 얼룩처럼 튀어
   무엇이 선택인지보다 먼저 눈에 들었다(리뷰 9/18). 발밑 띠와 이름 색, 은은한 빛으로만 말한다. */
/* ⚠️ **보라(앱 포인트색)를 쓰지 않는다.** 벽돌·나무 사무실 위에서 혼자 튀어 그림과 따로 놀았다(대표 9/18).
   따뜻한 등불빛(골드)으로 바꾼다 — 나무·벽돌과 같은 계열이라 얹혀도 사무실로 읽힌다. */
.seat[aria-pressed="true"]{background:radial-gradient(40px 32px at 50% 52%,rgba(255,198,109,.22),rgba(255,198,109,0) 72%)}
.seat[aria-pressed="true"] .nm{color:#5a3608;font-weight:800;border-radius:4px;
  background:rgba(255,205,120,.75);box-shadow:0 0 0 2px rgba(255,205,120,.75)}
/* ⚠️ 발밑 띠는 두지 않는다 — 책상 위에 주황 줄이 하나 더 그어져 어수선했다(대표 9/18).
   고른 자리는 **이름 표시 하나로** 충분하다. */
/* 승인 대기·새 답 — 작은 화면이라 색만으로 가르지 않고 표를 얹는다 */
/* 배지는 **가슴께**에 붙인다 — 머리 위로 띄웠더니 층수 칩과 겹쳤다(리뷰 9/18). */
.seat .mark{position:absolute;left:3px;top:calc(var(--seat-foot,0px) + 26px);font-size:9px;font-weight:800;line-height:13px;border-radius:999px;padding:0 4px;color:#fff;background:var(--red)}
.seat .mark.ok{background:#2f9e6a;animation:cwNewAnswer 2s ease-in-out infinite}
.seat .mark.q{background:var(--card);color:#9a6412;border:1px solid var(--line2)}
@media (prefers-reduced-motion:reduce){.seat .mark.ok{animation:none}}
.seat.task-hot{outline:2px dashed var(--accent);outline-offset:-2px}
/* 접었을 때(58px) — 층마다 팀장 얼굴 하나와 남은 수. 건물 모양은 그대로다 */
.office-folded .team .tname,.office-folded .team .win,.office-folded .team .lift,.office-folded .seat .nm,
.office-folded .team .sum,.office-folded .team .rest{display:none}
/* 접힘에서는 표(!·답·줄)를 점 하나로 줄인다 — 58px에서 글자 배지가 얼굴을 덮었다(리뷰 9/18) */
.office-folded .seat .mark{font-size:0;width:8px;height:8px;padding:0;line-height:0;left:auto;right:4px;top:12px;border:1px solid var(--panel)}
.office-folded .team{padding-top:12px}
.office-folded .team .row{justify-content:center;padding:0}
.office-folded .seat{width:34px;padding-bottom:4px}
.office-folded .team .band{display:none}
.office-folded .more-n{font-size:9px;font-weight:800;color:var(--faint);align-self:center;padding:0 2px}
.node .st-dot{display:none}
/* 접은 칸 — 층은 그대로 쌓이고 팀장 얼굴 하나만 남는다(빌딩 모양 유지) */
.office-folded .tree{padding:6px 4px}
/* 대화 */
.dock{position:relative;width:var(--dock-w);display:none;flex-direction:column;min-height:0;border-left:1px solid var(--line2)}
/* 대화 칸 왼쪽 가장자리를 끌어 너비를 바꾼다(360px ~ 화면의 70%). 두 번 누르면 기본 너비 */
.dock-grip{position:absolute;left:-4px;top:0;bottom:0;width:8px;cursor:col-resize;z-index:3}
.dock-grip:hover,.dock-grip.on{background:linear-gradient(90deg,transparent 3px,var(--accent) 3px,var(--accent) 5px,transparent 5px)}
.bub{max-width:min(88%,720px)}
.chat-open .dock{display:flex}
.dh{display:flex;align-items:center;gap:6px;padding:8px 10px 8px 8px;border-bottom:1px solid var(--line)}
.dh .who{display:flex;align-items:center;gap:6px;min-width:0}
.dh .px{transform:scale(.56);margin:-14px -12px}
.dh .nm{font-size:15px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  cursor:text;border-radius:5px;padding:0 3px;margin:0 -3px}
.dh .nm:hover{background:var(--hover);box-shadow:0 0 0 1px var(--line2)}
/* 연필은 손을 올렸을 때만 — 늘 떠 있으면 머리줄이 또 복잡해진다 */
.dh .nm-pen{font-style:normal;font-size:11px;color:var(--faint);opacity:0;transition:opacity .12s;margin-left:-1px}
.dh .who:hover .nm-pen{opacity:1}
/* 고치는 중 — 커서가 깜빡이는 글칸이 이름 자리에 그대로 앉는다 */
.dh .nm-edit{font:inherit;font-size:15px;font-weight:800;color:var(--fg);background:var(--bg);
  border:1px solid var(--accent);border-radius:6px;padding:1px 6px;margin:0 -3px;min-width:120px;max-width:260px}
.dh .nm-edit:focus{outline:none;box-shadow:0 0 0 3px var(--accent-soft)}
.dh .ic{margin-left:auto;flex:none}
/* 진행 스트립은 머리와 같은 톤이라 두 줄이 한 덩어리로 읽혔다 — 옅은 바탕으로 갈라 놓는다(UI 리뷰 9/18). */
.ctx{padding:7px 14px;display:flex;flex-direction:column;gap:4px;border-bottom:1px solid var(--line);background:var(--hover)}
.ctx .row{display:flex;gap:8px;align-items:baseline;font-size:13px}
.ctx .k{flex:none;width:44px;font-size:12px;font-weight:800;color:var(--accent)}
.ctx .v{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
.ctx .v.q{color:#9a6412}
:root[data-theme="dark"] .ctx .v.q{color:#ecc76f}
.lamp.thinking,.lamp.working{background:#e8a317}.lamp.waiting{background:var(--red)}
.lamp.idle,.lamp.done,.lamp.bored{background:#3fb37f}.lamp.ended,.lamp.error{background:var(--line2)}
.lamp.talk{cursor:pointer;box-shadow:0 0 0 3px transparent}
.lamp.talk:hover{box-shadow:0 0 0 3px var(--hover)}
/* 간격이 다 같으면 어디까지가 한 턴인지 안 보인다 — 턴 사이는 넓게, 이어지는 줄은 좁게(UI 리뷰 9/18). */
.ch-log{flex:1;overflow-y:auto;padding:12px 14px 6px;display:flex;flex-direction:column;gap:6px}
.ch-log>.bub.me{margin-top:10px}
.ch-log>.bub.ai+.bub.ai{margin-top:0}
.ch-log>.ch-tools{margin-top:-2px}
/* 한 줄이 길면 눈이 다음 줄 첫 글자를 못 찾는다 — 45~75자가 읽기 좋다(UI 리뷰 9/18). */
.bub{max-width:min(78%,620px);border-radius:16px;padding:8px 12px 5px;font-size:14px;line-height:1.6}
.bub.ai .ch-text{max-width:62ch}
.bub.ai{align-self:flex-start;background:var(--bg);border:1px solid var(--line);border-bottom-left-radius:6px}
.bub.me{align-self:flex-end;background:var(--accent);color:var(--accent-fg);border-bottom-right-radius:6px}
/* 리뷰3 L3(9/17): 다크의 accent는 회색이라 내 말과 답이 같은 무게였다 — 내 말풍선만 옅은 보라 */
:root[data-theme="dark"] .bub.me{background:#4b4bb0;color:#f2f2ff}
.ch-text{white-space:pre-wrap;overflow-wrap:anywhere}
.ch-text b.h{display:block;font-size:15px;margin:6px 0 2px}
/* 답 글 — 문단·목록·제목을 덩어리로 그린다(md의 blocks). 줄바꿈을 그대로 찍지 않는다 */
.bub.ai .ch-text{white-space:normal;line-height:1.65}
.bub.ai .ch-text>*{margin:0}
.bub.ai .ch-text>*+*{margin-top:8px}
.bub.ai .ch-text>.h{font-size:15px;font-weight:800;line-height:1.45}
.bub.ai .ch-text>*+.h{margin-top:14px}
.bub.ai .ch-text ul,.bub.ai .ch-text ol{padding-left:1.35em}
.bub.ai .ch-text li+li{margin-top:3px}
.bub.ai .ch-text li::marker{color:var(--faint)}
.bub.ai .ch-text li.d1{margin-left:1.2em}.bub.ai .ch-text li.d2{margin-left:2.4em}.bub.ai .ch-text li.d3{margin-left:3.6em}
.bub.ai .ch-text blockquote{padding-left:10px;border-left:3px solid var(--line2);color:var(--dim)}
.bub.ai .ch-text hr{border:0;border-top:1px solid var(--line)}
.bub.ai .ch-text pre{margin:8px 0 0}
.ch-text code{font-family:Menlo,monospace;font-size:12px;background:var(--hover);border-radius:5px;padding:1px 4px}
/* 경로 — 누르면 파인더(대표 요청 9/15) */
.ch-text .path{cursor:pointer;text-decoration:underline dotted;text-decoration-color:var(--faint);text-underline-offset:3px;overflow-wrap:anywhere}
.ch-text .path:hover{color:var(--accent);text-decoration-color:var(--accent)}
.ch-text pre{font-family:Menlo,monospace;font-size:12px;background:var(--hover);border-radius:10px;padding:8px 10px;
  white-space:pre-wrap;margin:6px 0}
.bub.me .ch-text code{background:rgba(255,255,255,.2)}
/* 한 턴 안의 말풍선은 전부 같은 분이라 시각이 줄마다 붙으면 노이즈다. 손을 올릴 때만 보인다(UI 리뷰 9/18).
   자리는 늘 잡아 둔다 — 나타날 때마다 말풍선이 커지면 대화가 위아래로 흔들린다. */
.ch-at{font-size:11px;opacity:0;text-align:right;margin-top:2px;transition:opacity .12s}
.bub:hover .ch-at,.bub:focus-within .ch-at{opacity:.55}
/* 시각 구분선 — 말이 한참 끊겼을 때만 가운데 한 줄 */
.ch-gap{align-self:center;font-size:11px;font-weight:700;color:var(--faint);padding:6px 0 2px}
/* 도구 줄은 **곁가지**다. 위 말풍선에 붙여 한 덩어리로 읽히게 하고, 글자는 시각보다 한 단계 밝다(UI 리뷰 9/18). */
.ch-tools{align-self:flex-start;max-width:min(78%,620px);margin-left:2px;font-size:12px;color:var(--dim)}
.ch-tools summary{cursor:pointer;list-style:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:1px 6px;border-radius:8px}
.ch-tools summary::-webkit-details-marker{display:none}
.ch-tools summary:hover{background:var(--hover)}
.ch-note{margin:4px 0 2px 14px;font:11px/1.45 Menlo,monospace;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--faint)}
.ch-tool{padding:1px 6px 1px 14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.wait-note{align-self:stretch;border-radius:14px;padding:10px 12px;background:rgba(229,72,77,.10);display:flex;flex-direction:column;gap:4px}
.wait-note b{font-size:13px;color:var(--red)}
.wait-note span{font-size:12px;color:var(--dim)}
/* 고른 답 — 말풍선이 아니라 칩. 내가 친 말(보라 말풍선)과 한눈에 갈린다(UI 리뷰 9/18). */
.chose{align-self:flex-end;display:flex;align-items:center;gap:6px;max-width:min(78%,620px);font-size:12px;font-weight:700;color:var(--accent);background:var(--accent-soft);border:1px solid var(--accent);border-radius:999px;padding:3px 10px}
.chose i{font-style:normal;font-size:10px;font-weight:800;color:var(--accent-fg);background:var(--accent);border-radius:999px;padding:0 6px;line-height:15px}
.chose span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ch-empty{color:var(--faint);font-size:12px;text-align:center;margin:40px 0;display:flex;flex-direction:column;gap:6px;align-items:center}
.ch-empty b{font-size:13px;color:var(--dim)}
.ch-empty kbd{font:inherit;font-weight:700;color:var(--dim);background:var(--hover);border:1px solid var(--line2);border-radius:5px;padding:0 5px}
.ch-in{display:flex;gap:8px;align-items:flex-end;padding:10px 12px 12px;border-top:1px solid var(--line)}
.ch-in textarea{flex:1;resize:none;max-height:180px;min-height:44px;background:var(--bg);border:1px solid var(--line);
  border-radius:14px;color:var(--fg);font:inherit;font-size:14px;line-height:1.5;padding:10px 12px;outline:none}
.ch-in textarea:focus{border-color:var(--accent)}
.ch-in .go{padding:8px 16px;font-size:14px}
/* 터미널 모양 글꼴 — 한글은 영문 두 칸인 나눔고딕코딩, 표 선(─│┌)만 영문 한 칸 폭 글꼴(Menlo를 83%로 맞춤).
   둘 중 하나만 쓰면 한글 칸이나 선이 어긋난다(선택지 미리보기 시안 9/15, 너비 실측). */
@font-face{font-family:"cw-box";src:local("Menlo"),local("Menlo-Regular");unicode-range:U+2500-257F;size-adjust:83%}
:root{--term:"cw-box","Nanum Gothic Coding","D2Coding",Menlo,monospace}
.cc-split{display:grid;grid-template-columns:minmax(150px,220px) minmax(0,1fr);gap:10px;align-items:stretch}
.cc-list{display:flex;flex-direction:column;gap:6px}
.cc-opt.cur .tx .t::after{content:' ◂';color:var(--faint);font-weight:700}
.cc-pv{min-width:0;display:flex;flex-direction:column;border-radius:12px;background:var(--hover);border:1px solid var(--line)}
.cc-pv .ph{padding:6px 10px;border-bottom:1px solid var(--line);font-size:12px;color:var(--faint)}
.cc-pv .ph b{color:var(--fg);font-weight:700}
.cc-pv.wide .ph::after{content:' · 옆으로 밀어 본다 ↔';color:var(--faint)}
/* 긴 미리보기는 칸 안에서 스크롤 — 선택지 목록이 카드 밖으로 밀려나지 않게. 넓은 것은 옆으로 민다 */
.cc-pv pre{margin:0;padding:10px 12px;font:12px/1.45 var(--term);white-space:pre;overflow:auto;max-height:360px;color:var(--fg)}
/* 대화 칸 폭을 따라 가른다 — 좁으면 미리보기가 선택지 아래로 */
.dock{container-type:inline-size}
.cc-split{grid-template-columns:minmax(0,1fr)}
@container (min-width:520px){.cc-split{grid-template-columns:minmax(150px,220px) minmax(0,1fr)}}
/* 지금 화면 — 일하는 중 · 선택 카드 · 원본 */
.ch-live{flex:none;max-height:62%;overflow-y:auto;padding:0 14px;display:flex;flex-direction:column;gap:8px}
.ch-live:not(:empty){padding-bottom:10px}
.raw-on .ch-log{display:none}
.raw-on .ch-live{flex:1;max-height:none;padding:0}
.rawpre{flex:1;margin:0;overflow:auto;padding:10px 14px;font:12px/1.4 var(--term);white-space:pre;color:var(--fg);background:var(--bg)}
.raw-on .ch-empty{display:flex;flex-direction:column;align-items:center;gap:6px}
.bub.busy{display:flex;flex-direction:column;gap:3px;max-width:92%}
.bz{display:flex;align-items:center;gap:8px;font-size:13px}
.bz b{font-weight:700}
.bz-t{color:var(--faint);font-size:12px;font-variant-numeric:tabular-nums}
.dots{display:inline-flex;gap:3px}
.dots i{width:5px;height:5px;border-radius:50%;background:#e8a317;animation:blink 1.1s infinite}
.dots i:nth-child(2){animation-delay:.18s}.dots i:nth-child(3){animation-delay:.36s}
@keyframes blink{0%,100%{opacity:.25}50%{opacity:1}}
@media (prefers-reduced-motion:reduce){.dots i{animation:none}}
.mono1,.cc-lead{font:12px/1.45 var(--term);color:var(--dim)}
.mono1{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
.bz-act{height:calc(3 * 12px * 1.45);display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden}
.ccard{--tone:#e8a317;--tone-fg:#9a6412;border:1.5px solid var(--tone);border-radius:14px;padding:10px 12px 12px;
  background:color-mix(in srgb,var(--tone) 8%,var(--panel));display:flex;flex-direction:column;gap:8px}
.ccard.violet{--tone:var(--accent);--tone-fg:var(--accent)}
:root[data-theme="dark"] .ccard.gold{--tone-fg:#ecc76f}
.cc-h{display:flex;align-items:center;gap:8px}
.cc-h b{font-size:12px;font-weight:800;color:var(--tone-fg)}
.cc-h .txtbtn{margin-left:auto;font-size:12px;color:var(--faint);background:none;border:0;border-radius:999px;padding:2px 8px;cursor:pointer}
.cc-h .txtbtn:hover{background:var(--hover);color:var(--fg)}
.cc-lead{margin:0;white-space:pre;overflow-x:auto;padding-bottom:2px}
.cc-q{font-size:14px;font-weight:700;line-height:1.45}
.cc-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:6px}
.cc-opt{display:flex;align-items:flex-start;gap:8px;text-align:left;font:inherit;font-size:13px;color:var(--fg);background:var(--card);
  border:1px solid var(--line2);border-radius:10px;padding:8px 10px;cursor:pointer}
.cc-opt:hover:not(:disabled){border-color:var(--tone)}
.cc-opt:disabled{cursor:default;opacity:.7}
.cc-opt .n{flex:none;font-size:12px;font-weight:800;color:var(--faint);padding-top:1px}
.cc-opt .cb{flex:none;color:var(--faint)}
.cc-opt.on .cb{color:var(--tone-fg)}
.cc-opt.on{border-color:var(--tone)}
/* 한 번에 여러 개를 물을 때의 문항 표 */
.cc-tabs{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;margin:8px 0 2px}
.cc-tabs>b{font-size:12px;font-weight:800;color:var(--tone)}
.cc-tabs>small{flex-basis:100%;font-size:11px;color:var(--faint)}
.cc-tab{display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:700;color:var(--dim);background:var(--card);border:1px solid var(--line2);border-radius:999px;padding:1px 9px}
.cc-tab i{font-style:normal;color:var(--faint)}
.cc-tab.done{color:var(--faint)}
.cc-tab.done i{color:#3fb37f}
.cc-tab.now{color:var(--fg);border-color:var(--tone);background:color-mix(in srgb,var(--tone) 12%,transparent)}
.cc-tab.now i{color:var(--tone)}
.cc-opt .tx{display:flex;flex-direction:column;gap:2px;min-width:0;flex:1}
.cc-opt .t{overflow-wrap:anywhere;line-height:1.35}
.cc-opt .d{font-size:12px;color:var(--dim);white-space:pre-wrap;line-height:1.4}
.cc-opt em{flex:none;font-style:normal;font-size:12px;font-weight:800;color:var(--accent)}
.cc-opt.armed{border:1.5px solid var(--accent);background:var(--accent-soft)}
.cc-opt.armed .n{color:var(--accent)}
.cc-opt.sm{padding:5px 12px}
.cc-slide{display:flex;flex-wrap:wrap;gap:6px}
.cc-submit{font:inherit;font-size:13px;font-weight:800;color:var(--tone-fg);background:color-mix(in srgb,var(--tone) 16%,transparent);
  border:1.5px solid var(--tone);border-radius:10px;padding:7px 10px;cursor:pointer}
.cc-submit.quiet{color:var(--dim);background:none;border:1px solid var(--line2)}
.cc-submit:disabled{color:var(--faint);border-color:var(--line2);background:none;cursor:default}
.cc-hint{font-size:12px;color:var(--faint)}
/* 머리 줄 — 칩 · 멈추기 · 원본 */
.dh .chips{display:flex;gap:4px;min-width:0;overflow:hidden}
/* 정보 칩(모델·컨텍스트·권한)은 **읽는 것**이다. 테두리를 두르면 옆의 버튼과 같은 무게가 되어
   머리줄에서 무엇을 눌러야 하는지가 안 보였다(UI 리뷰 9/18). 흐린 글자만 남긴다. */
.dh .chip{flex:none;font-size:11px;font-weight:600;color:var(--faint);border:0;border-radius:6px;padding:0 4px;white-space:nowrap}
.dh .morebtn{font-size:14px;line-height:1;padding:3px 9px;letter-spacing:.06em}
.dh .tools{margin-left:auto;display:flex;align-items:center;gap:4px;flex:none}
.dh .tools .ic{margin-left:0}
.dh .stop{font:inherit;font-size:12px;font-weight:700;color:var(--red);background:rgba(229,72,77,.1);border:0;border-radius:999px;padding:4px 10px;cursor:pointer}
.dh .stop:hover{background:rgba(229,72,77,.18)}
.dh .rawbtn{font:inherit;font-size:12px;font-weight:600;color:var(--dim);background:none;border:1px solid var(--line2);border-radius:999px;padding:3px 10px;cursor:pointer}
.dh .rawbtn[aria-pressed="true"]{color:var(--accent);border-color:var(--accent);background:var(--accent-soft)}
/* 입력창 거들기 */
.ch-in{position:relative}
.ch-menu{position:absolute;left:12px;right:12px;bottom:calc(100% - 4px);max-height:230px;overflow-y:auto;background:var(--panel);
  border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow-pop);padding:4px;z-index:5}
.ch-menu .mi{display:flex;gap:10px;align-items:baseline;width:100%;text-align:left;font:inherit;font-size:13px;color:var(--fg);background:none;border:0;border-radius:8px;padding:6px 10px;cursor:pointer}
.ch-menu .mi b{font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-menu .mi span{font-size:12px;color:var(--faint);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ch-menu .mi.on,.ch-menu .mi:hover{background:var(--hover)}
.ch-menu .mi.none{color:var(--faint);cursor:default;background:none}
.dock.drop-on::after{content:'여기에 놓으면 @경로로 붙는다';position:absolute;inset:8px;border:2px dashed var(--accent);border-radius:14px;
  background:color-mix(in srgb,var(--accent) 8%,transparent);display:flex;align-items:center;justify-content:center;font-weight:700;color:var(--accent);pointer-events:none;z-index:6}
/* 답 안의 표 · 링크 */
.ch-text .tbl{overflow-x:auto;margin:4px 0;white-space:normal}
/* 페이지의 표 모양(둥근 판·44px 줄)이 딸려 오지 않게 되돌린다 */
.ch-text table{width:auto;max-width:none;border-radius:0;box-shadow:none;background:none;border-collapse:collapse;font-size:13px;line-height:1.45}
.ch-text th,.ch-text td{height:auto;white-space:normal;color:var(--fg);font-size:13px;border:1px solid var(--line2);padding:3px 8px;text-align:left;vertical-align:top}
.ch-text th{background:var(--hover);font-weight:700}
/* ⚠️ 말풍선은 긴 주소가 칸을 뚫지 않게 **글자 단위로도** 줄을 바꾼다(overflow-wrap:anywhere). 표 칸이 그걸 물려받으면
   표가 폭을 뒤 칸에 몰아주고 첫 칸이 한 글자 폭까지 줄어 「맵/크/기」처럼 세로로 쌓였다(대표 제보 9/16 스크린샷).
   표 칸은 **낱말 단위로만** 바꾸고(keep-all), 항목 이름인 **첫 칸은 줄을 안 바꾼다.** 넘치면 표 판이 옆으로 밀린다(.tbl) */
.ch-text th,.ch-text td{overflow-wrap:normal;word-break:keep-all}
.ch-text tr>:first-child{white-space:nowrap}
.ch-text a{color:var(--accent);text-decoration:underline;text-underline-offset:2px;overflow-wrap:anywhere}
.bub.me .ch-text a{color:inherit}
/* 새 할 일 창 */
.newsheet .title::placeholder{color:var(--faint)}
/* 새 할 일 창 — 고르는 칸에 이름표를 달고, 받을 세션을 한 줄로 못 박는다(대표 제보 9/18) */
.newsheet .nlab{font-size:12px;font-weight:700;color:var(--faint);margin:0 2px 0 6px}
.newsheet .chips>.nlab:first-child{margin-left:0}
.ntarget{display:flex;align-items:center;gap:8px;margin:10px 0 0;padding:8px 12px;border-radius:12px;background:var(--accent-soft);border:1px solid var(--accent);font-size:13px}
.ntarget b{font-weight:800;color:var(--accent)}
.ntarget span{color:var(--dim);font-size:12px}
.ntarget.none{background:var(--hover);border-color:var(--line2)}
.ntarget.none b{color:var(--fg)}
.ntarget .px{flex:none}
.nseg{display:inline-flex;gap:2px;background:var(--hover);border-radius:999px;padding:2px}
.nseg button{border:0;background:none;border-radius:999px;padding:3px 12px;font:inherit;font-size:13px;font-weight:600;color:var(--dim);cursor:pointer}
.nseg button[aria-pressed="true"]{background:var(--card);color:var(--fg);box-shadow:var(--shadow-card)}
.newsheet .brief{margin-bottom:10px}
.newsheet .chips>.pick{border:1px solid var(--line2);border-radius:999px;padding:3px 12px;margin:0;background:var(--card)}
.newsheet .chips>.pick .pjn{color:var(--fg);font-size:13px;font-weight:600}
.newsheet .sf{justify-content:flex-start}
.newsheet .nsend{margin-left:auto;margin-right:10px;display:inline-flex;gap:6px;align-items:center;font-size:13px;color:var(--dim);cursor:pointer}
.newsheet .nsend[hidden]{display:none}
.newsheet .sf .go.primary{margin-left:auto}
.newsheet .nsend:not([hidden])+.go.primary{margin-left:0}
/* 카드에서 바로 수정요청(시안 C) */
.rvbox{margin-top:10px;flex-basis:100%;cursor:auto}
.lrow .rvbox{width:100%;grid-column:1/-1;max-width:640px}
.lrow:has(.rvbox){flex-wrap:wrap}
.rvbox .rvh{font-size:12px;font-weight:700;color:var(--dim);margin:0 2px 6px}
.rvbox textarea{display:block;width:100%;min-height:64px;max-height:220px;border:1px solid var(--line2);border-radius:12px;background:var(--card);color:var(--fg);
  font:inherit;font-size:14px;line-height:1.55;padding:8px 10px;resize:none;outline:none}
.rvbox textarea::placeholder{color:var(--faint)}
.rvbox textarea:focus{border-color:var(--accent)}
.rvrow{display:flex;align-items:center;gap:6px;margin-top:8px;font-size:12px;color:var(--dim);flex-wrap:wrap}
.rvrow label{display:inline-flex;gap:5px;align-items:center;cursor:pointer;margin-right:auto;white-space:nowrap}
.rvrow input{accent-color:var(--accent);margin:0}
.rvrow .txtbtn{font-size:12px;font-weight:600;padding:4px 8px;border-radius:999px}
.rvrow .go{font-size:12px;padding:4px 12px}
/* 수정요청 칸이 열리면 카드 버튼(완료·수정요청)은 숨긴다 — 남아 있으면 「완료」가 골라진 탭처럼 보였다(대표 수정요청 9/15) */
.card:has(.rvbox) .cf,.lrow:has(.rvbox) .la{display:none}
/* 업무 지시서(시안 A) — 세션 담당 태스크의 상세창 위쪽 */
.sheet .chips{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;margin:2px 0 14px;font-size:13px}
.sheet .chips .sbtns{margin-left:auto}
/* 페이지에는 [hidden] 기본 규칙이 없어 .props{display:grid}가 이긴다 — 지시서 모드의 전체 속성 표를 확실히 숨긴다 */
.props[hidden]{display:none}
.sheet .chips .pick input[type=date]{position:absolute;inset:0;opacity:0;cursor:pointer;width:100%;color-scheme:var(--scheme)}
.submenu.quitmenu{min-width:260px}
.submenu.rnmenu{max-width:320px}
.submenu .rn-box{width:100%;margin:2px 0 6px;padding:8px 10px;border:1px solid var(--line2);border-radius:8px;background:var(--card);color:var(--fg);font:inherit;font-size:14px}
.submenu .mi.danger b{color:var(--red)}
.submenu .mi.danger:hover{background:rgba(229,72,77,.1)}
.dh .who .modelbtn{margin-left:6px;font:inherit;font-size:11px;font-weight:600;color:var(--dim);background:var(--hover);border:1px solid var(--line);border-radius:999px;padding:1px 8px;cursor:pointer;white-space:nowrap}
.dh .who .modelbtn:hover{color:var(--fg);border-color:var(--accent)}
.sheet .chips .clear{color:var(--faint);display:inline-flex;align-items:center;background:none;border:0;padding:2px;margin-left:-4px;cursor:pointer}
.sheet .chips .clear:hover{color:var(--red)}
.sheet .chips .clear svg{width:12px;height:12px}
.brief{border:1px solid var(--line2);border-radius:18px;overflow:hidden}
.brief-h{padding:9px 14px;background:var(--hover);font-size:13px;font-weight:800}
.brief .bf{display:grid;grid-template-columns:96px 1fr;border-top:1px solid var(--line)}
.brief .bf label{padding:12px 0 0 14px;font-size:13px;font-weight:700;color:var(--dim)}

.sheet .brief .bf textarea{border:0;background:none;border-radius:0;min-height:44px;max-height:none;padding:11px 14px 11px 0;resize:none}
.sheet .brief .bf.big textarea{min-height:56px}
/* 파일을 끌고 오면 놓을 자리를 알려 준다(앱 창) */
textarea.drop-in,input.drop-in{outline:2px dashed var(--accent);outline-offset:-2px}
.sheet .brief .bf textarea:focus{border:0}
.brief .bf:focus-within{background:color-mix(in srgb,var(--accent) 5%,transparent)}
/* `.empty`는 페이지의 빈 칸 안내가 이미 쓰는 이름이라 겹치지 않게 `need` */
.brief .bf.need label{color:#9a6412}
:root[data-theme="dark"] .brief .bf.need label{color:#ecc76f}
.brief .bf.rev{background:rgba(229,72,77,.08)}
.brief .bf.rev label{color:var(--red)}
@media (max-width:560px){.brief .bf{grid-template-columns:1fr}.brief .bf label{padding:10px 14px 0}.sheet .brief .bf textarea{padding:4px 14px 10px}}
details.bpv-d{margin:10px 0 0}
details.bpv-d>summary{list-style:none;cursor:pointer;display:flex;align-items:baseline;gap:10px;font-size:12px;font-weight:700;color:var(--faint);padding:4px 2px}
details.bpv-d>summary::-webkit-details-marker{display:none}
details.bpv-d>summary::before{content:'▸';color:var(--faint)}
details.bpv-d[open]>summary::before{content:'▾'}
details.bpv-d>summary:hover{color:var(--fg)}
details.bpv-d>.bpv{margin-top:6px}
.bpv{margin:0;padding:12px 14px;border-radius:14px;background:var(--hover);font:12.5px/1.6 Menlo,"D2Coding",monospace;white-space:pre-wrap;overflow-wrap:anywhere;max-height:240px;overflow:auto}
.bwarn{margin:8px 2px 0;font-size:12.5px;font-weight:600;color:#9a6412;display:flex;gap:6px;align-items:baseline}
.bwarn:empty,.bwarn[hidden]{display:none}
.bwarn::before{content:'⚠';font-weight:800}
:root[data-theme="dark"] .bwarn{color:#ecc76f}
details.more{margin:14px 0 4px}
details.brief-d{margin:4px 0 10px}
details.brief-d>summary{list-style:none;cursor:pointer;font-size:13px;font-weight:700;color:var(--dim);padding:6px 2px}
details.brief-d>summary::-webkit-details-marker{display:none}
details.brief-d>summary::before{content:'▸ ';color:var(--faint)}
details.brief-d[open]>summary::before{content:'▾ '}
details.brief-d>summary:hover{color:var(--fg)}
details.brief-d>.brief{margin-top:6px}
details.more>summary{list-style:none;cursor:pointer;font-size:13px;font-weight:700;color:var(--dim);padding:6px 2px}
details.more>summary::-webkit-details-marker{display:none}
details.more>summary::before{content:'▸ ';color:var(--faint)}
details.more[open]>summary::before{content:'▾ '}
details.more>summary:hover{color:var(--fg)}
details.more>.props{margin-top:6px}
/* 하위 태스크 — 카드의 상위 이름표 · 상위의 진행 · 상세창의 하위 칸 */
.plink{display:inline-flex;align-items:center;gap:4px;max-width:100%;font:inherit;font-size:12px;font-weight:600;color:var(--dim);
  background:var(--hover);border:0;border-radius:999px;padding:1px 9px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.plink:hover{color:var(--fg)}
.plink em,.subn{font-style:normal;font-variant-numeric:tabular-nums;color:var(--faint)}
.subn{font-size:12px;font-weight:700}
.subs{margin:0 0 18px}
.subbar{height:6px;border-radius:999px;background:var(--hover);overflow:hidden;margin:0 0 8px}
.subbar i{display:block;height:100%;background:var(--accent);border-radius:999px}
.subrow{display:flex;align-items:center;gap:8px;padding:5px 2px;border-bottom:1px solid var(--line);font-size:14px}
.subrow .sct{flex:1;min-width:0;text-align:left;font:inherit;color:var(--fg);background:none;border:0;padding:0;cursor:pointer;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.subrow .sct:hover{color:var(--accent)}
.subrow.done .sct{color:var(--faint);text-decoration:line-through}
/* 하위 적는 상자 — 한 상자 안에 제목 칸과 시킬 말 칸을 가로줄로 가른다 */
.subadd{position:relative;margin-top:8px;background:var(--bg);border:1px dashed var(--line2);border-radius:12px;overflow:hidden}
.subadd:focus-within{border-style:solid;border-color:var(--accent)}
.subadd .st,.subadd .sb{display:block;width:100%;font:inherit;color:var(--fg);background:none;border:0;outline:none}
.subadd .st{font-size:14px;font-weight:700;padding:8px 64px 6px 12px}
.subadd .sb{font-size:13px;line-height:1.5;padding:7px 64px 9px 12px;border-top:1px solid var(--line2);resize:none;max-height:160px;overflow:auto}
/* ⚠️ 상세창의 `.sheet textarea:not(.title)`가 더 세서 시킬 말 칸이 **제 라운드 상자와 크기조절 손잡이**를 그대로 썼다
   — 상자 안에 상자가 겹쳐 보였다(대표 제보 9/16 스크린샷). 가르는 것은 상자가 아니라 **줄 하나**다. */
.sheet .subadd .sb{min-height:0;border:0;border-top:1px solid var(--line2);border-radius:0;background:none;
  font-size:13px;line-height:1.5;padding:7px 64px 9px 12px;resize:none;max-height:160px}
.sheet .subadd .sb:focus{border-color:var(--line2)}
.subadd .st::placeholder,.subadd .sb::placeholder{color:var(--faint);font-weight:400}
.subadd .subgo{position:absolute;right:8px;bottom:7px;border:0;border-radius:999px;padding:4px 12px;
  font:inherit;font-size:12px;font-weight:700;background:var(--accent);color:var(--accent-fg);cursor:pointer}
.subadd .subgo:disabled{background:var(--line2);color:var(--faint);cursor:default}
/* 하위 묶음(A안) — 칸 안에서 같은 상위의 하위가 모이고 위에 머리 한 줄 */
.grp{margin:2px 0 10px;border-radius:16px;background:var(--hover);padding:8px 6px 2px}
.gh{display:flex;align-items:center;gap:6px;padding:0 6px;cursor:grab;min-width:0}
.gh .gt{flex:none;font-size:12px;color:var(--faint);background:none;border:0;padding:0 2px;cursor:pointer;transition:transform .15s}
.gh .grip{flex:none;color:var(--faint);font-size:12px;letter-spacing:-1px}
.gh .gn{min-width:0;font:inherit;font-size:13px;font-weight:800;color:var(--fg);background:none;border:0;padding:0;cursor:pointer;
  text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.gh .gn:hover{color:var(--accent)}
.gh .gc{flex:none;margin-left:auto;font-size:12px;font-weight:700;color:var(--faint);font-variant-numeric:tabular-nums}
.gbar{display:block;height:5px;border-radius:999px;background:var(--line2);overflow:hidden;margin:6px 6px 4px}
.gbar i{display:block;height:100%;background:var(--accent);border-radius:999px}
.gsum{font-size:12px;color:var(--faint);padding:0 6px 8px}
.shut>.gk{display:none}
.shut .gh .gt{transform:rotate(-90deg)}
.grp.drag,.lgrp.drag{opacity:.45}
/* 리스트의 하위 묶음 — 머리 한 줄 + 들여쓴 줄만으로는 한 묶음으로 안 읽혔다(대표 제보 9/16).
   묶음을 한 덩이(안쪽 카드)로 세우고, 하위 줄은 왼쪽 기둥으로 상위에 매단다. */
.lgrp{margin:8px 10px;border:1px solid var(--line2);border-radius:14px;overflow:hidden;background:var(--card)}
.lgrp>.gh{padding:9px 14px;background:var(--hover);border-bottom:1px solid var(--line)}
.lgrp.shut>.gh{border-bottom:0}
.lgrp .gh .gn{font-size:13.5px}
.lgrp .gh .gc{margin-left:8px;color:var(--dim)}
.lgrp .gh .gbar{flex:0 0 90px;margin:0 0 0 8px}
.lgrp .gh .gsum{margin-left:auto;padding:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lgrp .gk{padding:2px 0}
.lgrp .gk .lrow{padding-left:32px;position:relative;border-top:0;background:none}
.lgrp .gk .lrow+.lrow{box-shadow:inset 0 1px 0 var(--line)}
/* 기둥과 가지 — 하위 줄을 상위에 매단다. 마지막 줄에서 기둥이 반만 내려와 끝난다 */
.lgrp .gk .lrow::before{content:'';position:absolute;left:18px;top:0;bottom:0;width:2px;background:var(--line2)}
.lgrp .gk .lrow:last-child::before{bottom:calc(50% - 1px)}
.lgrp .gk .lrow::after{content:'';position:absolute;left:18px;top:calc(50% - 1px);width:10px;height:2px;background:var(--line2);border-bottom-left-radius:2px}
/* 리뷰3 M1(9/17): 다크에서 묶음 머리 띠와 하위 세로선이 배경과 거의 같아 계층이 안 보였다 — 띠는 한 단계 밝게, 선은 진하게 */
:root[data-theme="dark"] .lgrp>.gh{background:rgba(255,255,255,.09)}
:root[data-theme="dark"] .lgrp .gk .lrow::before,:root[data-theme="dark"] .lgrp .gk .lrow::after{background:rgba(255,255,255,.28)}
:root[data-theme="dark"] .lgrp{border-color:rgba(255,255,255,.2)}
@media (max-width:620px){.lgrp .gh .gbar,.lgrp .gh .gsum{display:none}}
/* 끄는 동안 몇 장 가는지 · 대화 칸/사무실에 태스크 놓기 */
.hot[data-hint]{position:relative}
.hot[data-hint]::after{content:attr(data-hint);position:absolute;top:6px;right:12px;z-index:3;font-size:12px;font-weight:800;color:var(--accent);
  background:var(--panel);border-radius:999px;padding:1px 9px;box-shadow:var(--shadow-card)}
.dock.task-on::after{content:'여기 놓으면 태스크 표시를 입력칸에 붙인다';position:absolute;inset:8px;border:2px dashed var(--accent);border-radius:14px;
  background:color-mix(in srgb,var(--accent) 8%,transparent);display:flex;align-items:center;justify-content:center;font-weight:700;color:var(--accent);pointer-events:none;z-index:6}
.node.task-hot{box-shadow:inset 0 0 0 2px var(--accent)}
.sf .tochat{margin-left:auto;margin-right:10px}
.sf .txtbtn+.go.primary{margin-left:10px}
/* 할 일 쪽이 좁을 때(대화·사무실을 편 노트북) — fitWidth가 붙인다 */
.main-narrow .grid2>aside{float:none;width:auto;margin:0 0 20px}
.main-narrow .board4{grid-template-columns:repeat(2,minmax(0,1fr))}
.main-tight .board4{grid-template-columns:minmax(0,1fr)}
/* 좁은 화면(폰) — 사무실은 숨기고, 대화를 열면 화면을 덮는다 */
@media (max-width:900px){
  .has-duo body,.has-duo.chat-open body,.has-duo.office-folded body,.has-duo.office-folded.chat-open body{padding-right:16px}
  .duo{display:none}
  .chat-open .duo{display:flex;top:0;right:0;bottom:0;left:0;border-radius:0}
  .office{display:none}
  .dock{width:auto;flex:1;border-left:0}
}
.queued{font-size:12px;font-weight:700;color:#b7791f;white-space:nowrap}
:root[data-theme="dark"] .queued{color:#e8c16f}
.grid2>*{min-width:0}
.lt{min-width:0}
.lrow .ct{overflow-wrap:anywhere}
.blk h2{font-size:14px;font-weight:800;color:var(--fg);letter-spacing:0}
.blk h2 em{color:var(--faint);font-weight:600}
.blk h2 .hint{font-size:12px;font-weight:400;color:var(--faint)}
.go.soft{background:var(--accent-soft);border-color:transparent;color:var(--accent);font-weight:700}
.go.soft:hover{background:var(--accent);color:var(--accent-fg)}
/* 리뷰 3회차 H2: 확인필요 줄마다 채워진 「완료」가 반복돼 어느 것도 안 보였다 — 리스트에서는 테두리만, 올리면 채운다 */
.la .go.soft{background:none;border-color:var(--line2)}
.la .go.soft:hover{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.la .txtbtn,.cf .txtbtn{font-size:12px;font-weight:600;padding:3px 8px;border-radius:999px}
.la .txtbtn:hover,.cf .txtbtn:hover{color:var(--fg);background:var(--hover)}
.board4 .col .empty{padding:2px 6px 6px;font-size:12px;color:var(--faint)}
details.pmore{border-top:1px solid var(--line)}
details.pmore>summary{list-style:none;cursor:pointer;font-size:12px;color:var(--faint);padding:8px 12px}
details.pmore>summary::-webkit-details-marker{display:none}
details.pmore>summary::before{content:'› ';display:inline-block;transition:transform .15s}
details.pmore[open]>summary::before{transform:rotate(90deg)}
details.pmore>summary:hover{color:var(--fg)}
@media (max-width:560px){.blk h2{flex-wrap:wrap}.blk h2 .hint{margin-left:0;flex-basis:100%}}
.gear{position:relative}
.gear>summary{list-style:none;cursor:pointer;width:34px;height:34px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  font-size:16px;color:var(--dim);background:var(--card);border:1px solid var(--line);box-shadow:var(--shadow-card)}
.gear>summary::-webkit-details-marker{display:none}
.gear>summary:hover,.gear[open]>summary{color:var(--fg)}
.gear .menu{position:absolute;right:0;top:42px;z-index:25;min-width:250px;background:var(--panel);border:1px solid var(--line);
  border-radius:16px;box-shadow:var(--shadow-pop);padding:6px;display:flex;flex-direction:column}
.gear .menu a,.gear .menu .off{display:flex;flex-direction:column;padding:8px 12px;border-radius:10px;color:var(--fg);text-decoration:none;font-size:14px;font-weight:600}
.gear .menu a:hover{background:var(--hover)}
.gear .menu .mi-btn{display:flex;flex-direction:column;align-items:flex-start;width:100%;text-align:left;padding:8px 12px;border:0;border-radius:10px;background:none;color:var(--fg);font:inherit;font-size:14px;font-weight:600;cursor:pointer}
.gear .menu .mi-btn:hover{background:var(--hover)}
.gear .menu .mi-h{font-size:11px;font-weight:700;color:var(--faint);letter-spacing:.04em;padding:10px 12px 2px;border-top:1px solid var(--line);margin-top:4px}
.mi-ver{display:flex;align-items:baseline;gap:6px;padding:6px 12px 8px;font-size:13px;color:var(--dim);border-bottom:1px solid var(--line);margin-bottom:4px}
.gear .menu .mi-ver b{font-size:14px;font-weight:800;color:var(--fg);font-variant-numeric:tabular-nums}
.gear .menu .mi-ver small{margin-left:auto;font-size:11px;color:var(--faint)}
.gear .menu .mi-mode{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;padding:8px 12px;font-size:14px;font-weight:600}
.gear .menu .mi-mode small{flex-basis:100%}
.seg2{display:inline-flex;gap:2px;background:var(--hover);border-radius:999px;padding:2px}
.seg2 button{border:0;background:none;border-radius:999px;padding:3px 10px;font:inherit;font-size:12px;font-weight:700;color:var(--dim);cursor:pointer}
.seg2 button[aria-pressed="true"]{background:var(--accent);color:#fff}
/* 폰으로 보기 */
.phonesheet .title{font-size:20px;font-weight:800;padding:4px 0}
.phonesheet .phn{font-size:13px;color:var(--dim);line-height:1.6;margin:0 0 14px}
.phonesheet .ph{display:flex;gap:16px;align-items:center;padding:12px 0;border-top:1px solid var(--line);flex-wrap:wrap}
.phonesheet .qr{width:180px;height:180px;flex:0 0 auto;border-radius:12px;overflow:hidden;background:#fff}
.phonesheet .qr svg{width:100%;height:100%;display:block}
.phonesheet .pi{display:flex;flex-direction:column;gap:6px;min-width:0;align-items:flex-start}
.phonesheet .pi b{font-size:15px}
.phonesheet .pi code{font-size:12px;color:var(--dim);overflow-wrap:anywhere}
.phonesheet .tail{margin:14px 0 0;padding:10px 14px;border-radius:12px;background:var(--hover)}
/* 처음 설정 */
.setupsheet .title{font-size:20px;font-weight:800;padding:4px 0}
.setupsheet .phn{font-size:13px;color:var(--dim);line-height:1.6;margin:0 0 10px}
.setupsheet .su{display:flex;gap:12px;padding:12px 0;border-top:1px solid var(--line)}
.setupsheet .mark{flex:0 0 26px;height:26px;border-radius:50%;display:grid;place-items:center;font-weight:800;color:#fff;background:var(--red)}
/* 다 된 줄은 물러나 있는다 — 꽉 찬 동그라미 일곱 개가 빨간 둘과 같은 세기로 시선을 끌었다(9/20 UX 리뷰). */
.setupsheet .su.ok .mark{background:none;color:var(--accent)}
.setupsheet .su.opt .mark{background:var(--line2);color:var(--fg)}
/* 다 된 것 묶음 — 접어 두고 펴면 안쪽 줄에만 선을 둔다. 열 줄 줄무늬가 밀도를 키웠다. */
.setupsheet .sudone{border-top:1px solid var(--line)}
.setupsheet .sudone>summary{display:flex;align-items:center;gap:12px;padding:12px 0;cursor:pointer;font-size:14px;list-style:none}
.setupsheet .sudone>summary::-webkit-details-marker{display:none}
.setupsheet .sudone>summary .mark{background:none;color:var(--accent)}
.setupsheet .sudone[open]>summary{border-bottom:1px solid var(--line)}
.setupsheet .sudone .su:first-of-type{border-top:0}
.setupsheet details.more{margin-top:4px}
.setupsheet details.more>summary{color:var(--dim);font-size:12px;cursor:pointer}
.setupsheet .st{min-width:0;flex:1;font-size:14px;line-height:1.6}
.setupsheet .faint{color:var(--dim);font-size:12.5px;overflow-wrap:anywhere}
.setupsheet .sa{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;margin-top:8px}
.setupsheet .sa small{flex-basis:100%;color:var(--dim);font-size:12px}
.setupsheet .sa code{font-size:12px;padding:4px 8px;border-radius:8px;background:var(--hover);overflow-wrap:anywhere}
.starter{display:flex;flex-wrap:wrap;align-items:center;gap:6px 12px;margin:12px 20px;padding:12px 16px;border-radius:12px;background:var(--hover);font-size:14px;line-height:1.6}
.starter span{flex:1 1 320px;color:var(--dim)}
.starter a{color:var(--accent)}
.office-empty{flex-direction:column;align-items:flex-start;margin:12px}
.clock{display:inline-flex;gap:4px;align-items:center}
.clock .clk{border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:999px;padding:4px 12px;font:inherit;font-size:13px;font-weight:700;cursor:pointer}
.clock .clk.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.clock .off{color:var(--dim);font-size:12px}
.launchbtn{border:0;border-radius:999px;padding:5px 14px;background:var(--accent);color:#fff;font:inherit;font-size:13px;font-weight:800;cursor:pointer}
.launchbtn:disabled{opacity:.6;cursor:default}
.submenu{position:fixed;z-index:60;min-width:260px;padding:6px;border-radius:12px;background:var(--panel);border:1px solid var(--line);box-shadow:0 8px 24px rgba(0,0,0,.18)}
.submenu .mi{display:flex;flex-direction:column;align-items:flex-start;gap:2px;width:100%;padding:8px 10px;border:0;border-radius:8px;background:none;color:var(--fg);font:inherit;font-size:14px;text-align:left;cursor:pointer}
.submenu .mi:hover{background:var(--hover)}
.submenu .mi small{color:var(--dim);font-size:12px}
.setupsheet .made{flex-basis:100%;display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;font-size:13px}
.setupsheet .foot{border-top:1px solid var(--line);padding-top:12px;justify-content:flex-end}
.gear .menu small{font-size:12px;font-weight:400;color:var(--faint)}
.gear .menu .off{color:var(--faint);font-weight:400}
.sendall{margin-left:auto;font-size:12px;padding:3px 10px;white-space:nowrap}
/* 골라서 시키기 — 체크 칸(대표 요청 9/15) */
.pickchk{width:16px;height:16px;margin:0;accent-color:var(--accent);cursor:pointer;flex:0 0 auto}
.card .pickchk{position:absolute;top:13px;left:12px}
.card:has(.pickchk)>.ct{padding-left:24px}
.lrow:has(.pickchk){grid-template-columns:auto minmax(0,1fr) auto}
.card.picked,.lrow.picked{box-shadow:inset 0 0 0 2px var(--accent)}
.board4 .col h3 .sendall{margin-left:auto}
.blk h2 .sendall{margin-left:auto;letter-spacing:0}
.plabel{flex:none;font-size:14px;font-weight:800;color:var(--fg);margin:0 4px 0 2px}
.pseg{flex:none}
.pseg a{display:inline-flex;align-items:center;gap:4px}
.pseg em{font-style:normal;color:var(--faint);font-weight:500}
.pseg .st{color:#e8a317;font-weight:700}
.pseg a[title]{}
.back{flex-basis:100%;font-size:13px;font-weight:600;color:var(--dim);text-decoration:none;margin-bottom:-6px}
.back:hover{color:var(--fg)}
.gear .menu a.on{background:var(--hover)}
.lsum{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;margin:0 0 16px 4px;font-size:13px;color:var(--dim)}
.lsum a{color:var(--dim);text-decoration:none;border-radius:999px;padding:2px 8px}
.lsum a:hover{background:var(--hover);color:var(--fg)}
.lsum b{color:var(--fg);font-variant-numeric:tabular-nums}
.lsum i{font-style:normal;color:var(--line2)}
.lrow.run{box-shadow:inset 3px 0 0 var(--accent)}
details.fold.warn>summary{border-color:rgba(232,163,23,.55);background:rgba(232,163,23,.08);color:var(--fg)}
details.fold.warn>summary b{color:#b7791f}
:root[data-theme="dark"] details.fold.warn>summary b{color:#e8c16f}
details.fold>summary .sendall{margin-left:auto}
details.fold>summary:has(.sendall)::after{margin-left:10px}
.lrow[draggable="true"]{cursor:grab}
.lrow.drag{opacity:.4}
.blk.hot>.list,details.fold.hot>summary{outline:2px dashed var(--accent);outline-offset:2px}
.blk.hot>h2{color:var(--accent)}
.reclink{text-decoration:none;color:var(--faint);font-size:16px;font-weight:700;padding:0 6px;border-radius:8px;flex:none}
.reclink:hover{color:var(--accent);background:var(--hover)}
.pname .reclink{margin-left:auto}
.who-link{color:var(--accent);font-weight:700;border-radius:6px;padding:0 3px;margin:0 -3px}
.who-link:hover{background:var(--accent-soft)}
.wbadge{font-size:11px;font-weight:800;border-radius:999px;padding:0 6px;line-height:16px;background:var(--red);color:#fff}
#err{position:fixed;left:24px;bottom:20px;background:var(--red);color:#fff;
  padding:9px 16px;border-radius:999px;font-size:14px;display:none;box-shadow:var(--shadow-pop)}
''';

/// 할 일 페이지와 프로젝트 페이지가 같이 쓰는 동작.
const String kTodoJs = r'''
// 판단은 전부 위젯(Dart)이 한다. 여기는 눌러서 알리고 다시 그리기만 한다.
// 밝게 ↔ 어둡게. 고른 것은 이 브라우저에 기억한다.
// 앱 창(WKWebView)에 지금 배경색을 알린다 — 페이지를 옮기는 사이에 **창 바탕(흰색)**이 비쳐
// 어두운 화면에서 한 번씩 번쩍였다(대표 제보 9/16). 창과 웹뷰 바탕을 페이지 색으로 맞춰 둔다.
// 리스트 ↔ 보드는 **같은 한 장**이라 페이지를 새로 부르지 않고 바뀐 조각만 갈아 끼운다(대표 제보 9/16 깜빡임).
// 근무기록·프로젝트·사용량은 페이지가 달라 그대로 옮겨 간다 — 대신 창 바탕색을 맞춰 흰 번쩍임을 없앴다(tellBg).
document.addEventListener('click', ev => {
  if(ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey || ev.button) return;
  const a = ev.target.closest && ev.target.closest('.views a[href], .ptabs a[href], .seg a[href], .months a[href]');
  if(!a) return;
  const u = new URL(a.getAttribute('href'), location.href);
  // 근무기록도 같은 조각·같은 CSS·같은 스크립트를 쓰므로 문서를 새로 부르지 않고 갈아 끼운다(9/16).
  const swapable = v => v === 'list' || v === 'board' || v === 'work';
  const to = u.searchParams.get('view') || 'list';
  const now = new URL(location.href).searchParams.get('view') || 'list';
  if(!(swapable(to) && swapable(now))) return;
  ev.preventDefault();
  history.pushState(null, '', u);
  reload();
});
window.addEventListener('popstate', () => { if(typeof reload === 'function') reload(); });
function tellBg(){
  if(!window.cwBg) return;
  try{ cwBg.postMessage(getComputedStyle(document.documentElement).backgroundColor || ''); }catch(e){}
}
function toggleTheme(){
  const dark = document.documentElement.dataset.theme !== 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  try{ localStorage.setItem('cw_theme', dark ? 'dark' : 'light'); }catch(e){}
  tellBg();
}
tellBg();
async function post(kind, data, btn){
  if(btn){ btn.disabled = true; btn.textContent = '보내는 중'; }
  try{
    const r = await fetch('/todo/'+kind, {method:'POST', body: JSON.stringify(data)});
    const j = await r.json();
    if(!j.ok){ fail(j.error || '실패했다'); return false; }
  }catch(e){ fail('위젯이 꺼져 있는 것 같다'); return false; }
  return true;
}
async function act(kind, id, btn){ if(await post(kind, {id}, btn)) reload(); }
// ── 리스트 · 보드의 선택 ── 범위(scope)와 프로젝트(p)는 주소에 싣는다. 페이지를 새로
// 부르지 않고 주소만 바꿔 다시 그린다. 다른 페이지에서 돌아와도 이어지게 브라우저에 기억한다.
function nav(a){
  history.replaceState(null, '', a.href);
  rememberView();
  reload();
  return false;
}
function rememberView(){
  try{
    const u = new URL(location.href), v = u.searchParams.get('view') || 'list';
    if(v !== 'list' && v !== 'board') return;
    localStorage.setItem('cw_view', v);
    localStorage.setItem('cw_todo_q', 'scope='+(u.searchParams.get('scope')||'today')+'&p='+encodeURIComponent(u.searchParams.get('p')||''));
  }catch(e){}
}
// 주소에 선택이 없으면(위젯·폰에서 막 연 것, 다른 페이지에서 넘어온 것) 기억해 둔 것을 되살린다.
(function(){
  try{
    const u = new URL(location.href), v = u.searchParams.get('view');
    if(v && v !== 'list' && v !== 'board') return;
    if(u.searchParams.has('scope')){ rememberView(); return; }
    const q = new URLSearchParams(localStorage.getItem('cw_todo_q') || '');
    const sv = localStorage.getItem('cw_view');
    if(!q.has('scope') && !sv) return;
    if(!v && sv) u.searchParams.set('view', sv);
    ['scope','p'].forEach(k => { if(q.has(k)) u.searchParams.set(k, q.get(k)); });
    history.replaceState(null, '', u);
    reload();
  }catch(e){}
})();
// 한 번에 시키기 — 실수로 눌러도 바로 나가지 않게 한 번 더 누르게 한다.
async function sendMany(btn){
  // 접기 줄(summary) 안에 있어도 눌렀을 때 칸이 접히거나 펴지지 않게 한다.
  if(window.event){ window.event.preventDefault(); window.event.stopPropagation(); }
  if(!btn.dataset.armed){
    const label = btn.textContent;
    btn.dataset.armed = '1'; btn.dataset.label = label;
    btn.textContent = '한 번 더 누르면 보낸다';
    setTimeout(() => { if(btn.dataset.armed){ delete btn.dataset.armed; btn.textContent = label; } }, 3000);
    return;
  }
  delete btn.dataset.armed;
  const all = JSON.parse(btn.dataset.ids || '[]');
  const chosen = all.filter(id => PICKED.has(id));
  const ids = chosen.length ? chosen : all;
  if(await post('send-many', {ids}, btn)){ ids.forEach(id => PICKED.delete(id)); reload(); }
}
// 골라서 시키기 — 체크한 카드는 다시 그리기(5초)를 지나도 남는다. 칸에서 사라진 것은 잊는다.
const PICKED = new Set();
function pickTask(box){
  if(box.checked) PICKED.add(box.dataset.id); else PICKED.delete(box.dataset.id);
  applyPicks();
}
function applyPicks(){
  const here = new Set([...document.querySelectorAll('.pickchk')].map(b => b.dataset.id));
  [...PICKED].forEach(id => { if(!here.has(id)) PICKED.delete(id); });
  document.querySelectorAll('.pickchk').forEach(b => {
    b.checked = PICKED.has(b.dataset.id);
    const host = b.closest('.card,.lrow');
    if(host) host.classList.toggle('picked', b.checked);
  });
  document.querySelectorAll('.sendall').forEach(btn => {
    if(btn.dataset.armed) return;
    const n = JSON.parse(btn.dataset.ids || '[]').filter(id => PICKED.has(id)).length;
    btn.textContent = n ? '체크한 ' + n + '건 시키기' : btn.dataset.all + '건 한 번에 시키기';
    btn.classList.toggle('primary', n > 0);
  });
}
// 요약 줄에서 그 칸으로 — 접힌 칸이면 펴고 옮긴다.
function jump(id){
  const el = document.getElementById(id);
  if(!el) return false;
  if(el.tagName === 'DETAILS') el.open = true;
  el.scrollIntoView({behavior:'smooth', block:'start'});
  return false;
}
async function fav(id, on){ if(await post('project/edit', {id, favorite:on})) reload(); }
async function stale(ids, action){ if(await post('stale', {ids, action})) reload(); }
// 수정요청 — 상세창의 수정사항 칸을 펴 두고 공을 세션 차례로 넘긴다.
// 적은 수정사항은 시키기가 프롬프트 뒤에 붙여 보낸다.
async function revise(id){
  openSheet(id);
  const sec = document.querySelector('#s-'+CSS.escape(id)+' .sec[data-key="revisionNote"]');
  if(sec){
    const b = sec.querySelector('.add-sec');
    if(b) unfold(b); else sec.querySelector('textarea').focus();
  }
  await post('status', {id, status:'revision'});
}
// 폰으로 보기 — 주소마다 QR. 첫 한 번만 열쇠가 주소에 실리고 그 뒤로는 폰에 쿠키로 남는다.
async function phoneSheet(){
  const g = document.getElementById('f-gear'); if(g) g.open = false;
  let j;
  try{ j = await (await fetch('/todo/app/phone', {cache:'no-store'})).json(); }catch(e){ fail('위젯이 꺼져 있는 것 같다'); return; }
  if(!j.ok){ fail(j.error || '주소를 못 받았다'); return; }
  let sh = document.getElementById('s-phone');
  if(!sh){ sh = document.createElement('div'); sh.id = 's-phone'; sh.className = 'sheet phonesheet'; document.body.append(sh); }
  const body = j.urls.length ? j.urls.map((u, i) =>
      '<div class="ph"><div class="qr">' + u.svg + '</div><div class="pi"><b>' + u.label + '</b>'
      + '<code>' + u.url.replace(/k=.*/, 'k=••••') + '</code>'
      + '<button type="button" class="txtbtn" data-i="' + i + '">주소 복사</button></div></div>').join('')
    : '<p class="nil">망에 안 붙어 있다 — 와이파이나 테일스케일을 켠 뒤 다시 연다.</p>';
  // 집 밖(LTE·다른 와이파이)에서 보려면 테일스케일이 있어야 한다 — 없으면 방법을 적어 둔다(대표 질문 9/16 「꼭 같은 와이파이?」).
  const tail = j.urls.some(u => u.label === '테일스케일') ? ''
    : '<p class="phn tail"><b>집 밖에서도 보려면</b> — 이 맥과 폰에 <b>Tailscale</b> 앱을 깔고 같은 계정으로 로그인한다. '
      + '그러면 이 창에 「테일스케일」 QR이 하나 더 생기고, LTE나 다른 와이파이에서도 그 주소로 열린다. 공유기 포트를 여는 방식은 쓰지 않는다.</p>';
  sh.innerHTML = '<div class="sh"><div class="title">폰으로 보기</div><button class="ic x" title="닫기 (Esc)" onclick="closeSheet()">✕</button></div>'
    + '<p class="phn">폰 카메라로 찍으면 열린다. 폰과 이 맥이 <b>같은 와이파이</b>이거나 둘 다 <b>테일스케일</b>에 붙어 있어야 한다. '
    + '주소에 열쇠가 들어 있어 남에게 보내지 않는다 — 카페 와이파이에서는 열지 않는다.</p>' + body + tail;
  sh.querySelectorAll('[data-i]').forEach(b => b.onclick = async () => {
    try{ await navigator.clipboard.writeText(j.urls[+b.dataset.i].url); b.textContent = '복사했다'; }catch(e){ fail('복사를 못 했다'); }
  });
  openSheet('phone');
}
// 처음 설정 — 준비물·훅·폴더를 한 장에서 본다. 빠진 게 있으면 대시보드를 켤 때 한 번 뜬다(「나중에」를 누르면 안 뜬다).
const SETUP_ROWS = {
  tmux: ['tmux', '세션을 띄우고 화면을 떠 오는 데 쓴다', '터미널에 붙여 넣는다', 'brew install tmux'],
  git: ['git', '파일 찾기(@)와 버전 기록에 쓴다', '터미널에 붙여 넣으면 애플 개발 도구 설치 창이 뜬다', 'xcode-select --install'],
  claude: ['Claude Code', '캐릭터가 될 세션', '터미널에 붙여 넣은 뒤 claude 를 한 번 켜서 로그인한다', 'curl -fsSL https://claude.ai/install.sh | bash'],
  login: ['로그인', 'Claude 구독(또는 API 키)으로 로그인돼 있어야 세션이 일한다', '터미널에 붙여 넣으면 브라우저가 열린다 — 로그인은 브라우저에서 직접 한다. 끝나면 이 창이 저절로 알아챈다', 'claude auth login'],
  hooks: ['훅 연결', '세션이 상태를 마당에 알리는 길 — 없으면 캐릭터가 안 움직인다', '', ''],
  codex: ['Codex', '캐릭터가 될 코덱스 세션', '터미널에 붙여 넣은 뒤 codex 를 한 번 켜서 로그인한다', 'brew install --cask codex'],
  codexLogin: ['Codex 로그인', 'ChatGPT 계정(또는 API 키)으로 로그인돼 있어야 코덱스가 일한다', '터미널에서 codex 를 켜면 로그인 창이 뜬다. 끝나면 이 창이 저절로 알아챈다', 'codex login'],
  codexHooks: ['Codex 훅 연결', '코덱스 세션이 상태를 마당에 알리는 길', '', ''],
  meeting: ['회의 명령 (선택)', '회의실에서 여러 세션을 모아 토론시킬 때 쓰는 /회의 — Claude Code 전용', '', ''],
  folder: ['지켜볼 폴더', '등록한 폴더에서 연 세션만 캐릭터가 된다', '', ''],
};
let setupMade = '';
// 쓰는 에이전트 — {claude, codex}. 처음 한 번 읽고, 처음 설정에서 바꾸면 다시 읽는다.
let agentsPref = null;
fetch('/todo/app/agents', {cache: 'no-store'}).then(r => r.json()).then(j => { if(j.ok) agentsPref = j; }).catch(() => {});
let setupPoll = 0;
async function setupSheet(auto){
  const g = document.getElementById('f-gear'); if(g) g.open = false;
  let j;
  try{ j = await (await fetch('/todo/app/setup', {cache:'no-store'})).json(); }catch(e){ if(!auto) fail('위젯이 꺼져 있는 것 같다'); return; }
  if(!j.ok){ if(!auto) fail(j.error || '점검을 못 했다'); return; }
  if(auto){
    let skip = false; try{ skip = localStorage.getItem('cw_setup_skip') === '1'; }catch(e){}
    if(j.done || skip) return;
  }
  let sh = document.getElementById('s-setup');
  if(!sh){ sh = document.createElement('div'); sh.id = 's-setup'; sh.className = 'sheet setupsheet'; document.body.append(sh); }
  const esc = t => String(t).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const card = it => {
    const [name, why, how, cmd] = SETUP_ROWS[it.key] || [it.key, '', '', ''];
    let act = '';
    if(!it.ok && it.key === 'hooks' && !j.broken) act = '<button type="button" class="go primary" data-do="app/setup-hooks">훅 연결하기</button><small>~/.claude/settings.json 에 한 줄 덧붙인다 · 되돌릴 수 있다</small><details class="more"><summary>무엇이 바뀌나</summary><div class="faint">빠진 이벤트마다 「세션 상태를 127.0.0.1로 알리는 한 줄」을 덧붙인다. 먼저 백업(settings.json.bak-시각)을 남기고, 남의 훅은 건드리지 않는다. 언제든 「훅 빼기」로 되돌린다.</div></details>';
    if(it.key === 'folder') act = '<button type="button" class="go' + (it.ok ? '' : ' primary') + '" data-do="app/add-folder">폴더 고르기</button>'
      + '<button type="button" class="go" data-new>새 폴더 만들기</button>'
      + '<small>처음이면 「새 폴더 만들기」 — 폴더와 시작용 CLAUDE.md(무엇을 하는 곳인지 적는 칸 + 마당 할 일 규칙)를 만들고 등록한다. 있던 CLAUDE.md는 안 덮는다</small>'
      + (setupMade ? '<div class="made">만들었다: <code>' + esc(setupMade) + '</code> '
        + ((j.agents || {}).claude !== false ? '<button type="button" class="go primary" data-launch="claude">이 폴더에서 Claude 켜기</button>' : '')
        + ((j.agents || {}).codex ? '<button type="button" class="go' + ((j.agents || {}).claude === false ? ' primary' : '') + '" data-launch="codex">이 폴더에서 Codex 켜기</button>' : '') + '</div>' : '');
    // 앱이 대신 깔아 준다(대표 결정 9/17) — Claude Code는 공식 스크립트를 앱이 돌리고, git은 애플 설치 창을 띄운다. 명령 복사는 아래에 남긴다.
    if(!it.ok && it.key === 'claude') act = '<button type="button" class="go primary" data-do="app/install-claude" data-busy="설치 중 — 1~2분">Claude Code 설치하기</button>'
      + '<small>공식 설치 스크립트를 앱이 돌린다(사용자 폴더에 깔려 관리자 암호가 필요 없다). 끝나면 아래 「로그인」 줄로 넘어간다 · 직접 하려면</small>'
      + '<code>' + esc(cmd) + '</code><button type="button" class="txtbtn" data-copy="' + esc(cmd) + '">복사</button>';
    if(!it.ok && it.key === 'git') act = '<button type="button" class="go primary" data-do="app/install-git" data-busy="창 띄우는 중">git 설치 창 열기</button>'
      + '<small>애플 명령줄 도구 창이 뜨면 「설치」를 누른다(몇 분 걸린다). 다 되면 「다시 보기」 · 직접 하려면</small>'
      + '<code>' + esc(cmd) + '</code><button type="button" class="txtbtn" data-copy="' + esc(cmd) + '">복사</button>';
    if(!it.ok && cmd && !act){
      // tmux는 Homebrew로 까는데 Homebrew부터 없는 사람이 있다 — 그 명령을 먼저 보여 준다.
      const brewCmd = '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"';
      const pre = it.key === 'tmux' && !j.brew
        ? '<small>먼저 Homebrew(맥 설치 도구)가 필요하다 — 이것부터 붙여 넣는다</small><code>' + esc(brewCmd) + '</code><button type="button" class="txtbtn" data-copy="' + esc(brewCmd) + '">복사</button><small>그다음</small>'
        : '';
      act = pre + '<code>' + esc(cmd) + '</code><button type="button" class="txtbtn" data-copy="' + esc(cmd) + '">복사</button><small>' + esc(how) + ' · 다 되면 「다시 보기」</small>';
    }
    if(!it.ok && it.key === 'meeting') act = '<button type="button" class="go" data-do="app/install-meeting">회의 명령 넣기</button>'
      + '<small>~/.claude/commands/회의.md 를 만든다(앱에 들어 있는 사본). 이미 있으면 덮지 않는다</small>';
    if(!it.ok && it.key === 'codex') act = '<button type="button" class="go primary" data-do="app/install-codex" data-busy="설치 중 — 1~3분">Codex 설치하기</button>'
      + '<small>Homebrew(없으면 npm)로 깐다 · 직접 하려면</small><code>' + esc(cmd) + '</code><button type="button" class="txtbtn" data-copy="' + esc(cmd) + '">복사</button>';
    if(it.key === 'codexHooks'){
      act = (it.ok ? '' : '<button type="button" class="go primary" data-do="app/setup-codex-hooks">Codex 훅 연결하기</button>')
        + '<small><b>코덱스는 새 훅을 직접 신뢰해야 돈다</b> — 코덱스 안에서 <code>/hooks</code> 를 열고 <b>t</b>(전부 신뢰)를 누른다</small>'
        + (it.ok ? '' : '<details class="more"><summary>무엇이 바뀌나</summary><div class="faint">~/.codex/hooks.json 에 이벤트마다 「127.0.0.1로 알리는 한 줄」을 덧붙인다. 백업을 남기고 남의 훅은 그대로 둔다.</div></details>')
        + (it.ok ? '<button type="button" class="txtbtn" data-uncodex>코덱스 훅 빼기</button>' : '');
    }
    if(it.ok && it.key === 'hooks'){
      const sig = j.hookAgo == null ? '아직 신호가 없다 — 등록한 폴더에서 claude를 새로 켜면 온다(켜 둔 세션은 다시 켜야 붙는다)'
        : '마지막 신호 ' + (j.hookAgo < 60 ? j.hookAgo + '초' : Math.floor(j.hookAgo / 60) + '분') + ' 전 — 잘 받고 있다';
      act = '<small>' + esc(sig) + '</small><button type="button" class="txtbtn" data-unhook>훅 빼기</button>';
    }
    // 긴 곁들임(훅 이벤트 이름 여덟 개 같은 것)은 머리에서 자르고 「자세히」 안으로 보낸다.
    const d = String(it.detail || '');
    const cut = d.indexOf(' — ');
    const head = cut > 0 && d.length > 40 ? d.slice(0, cut) : d;
    const rest = head === d ? '' : d.slice(cut + 3);
    return '<div class="su ' + (it.ok ? 'ok' : it.optional ? 'opt' : 'no') + '"><span class="mark">' + (it.ok ? '✓' : it.optional ? '·' : '!') + '</span><div class="st"><b>' + esc(name) + '</b> <span class="faint">' + esc(head) + '</span>'
      + (it.ok ? '' : '<div class="faint">' + esc(why) + '</div>')
      + (rest ? '<details class="more"><summary>자세히</summary><div class="faint">' + esc(rest) + '</div></details>' : '') + (act ? '<div class="sa">' + act + '</div>' : '') + '</div></div>';
  };
  // 할 일이 먼저 온다 — 다 된 줄은 한 줄로 접어 둔다. 열 줄이 통째로 보이면 「할 일 둘」이 안 보인다.
  const left = j.items.filter(it => !it.ok && !it.optional);
  const opt = j.items.filter(it => !it.ok && it.optional);
  const done = j.items.filter(it => it.ok);
  const nameOf = it => (SETUP_ROWS[it.key] || [it.key])[0];
  const rows = left.map(card).join('') + opt.map(card).join('')
    + (done.length ? '<details class="sudone"><summary><span class="mark">✓</span><span>다 된 것 ' + done.length + '개 <span class="faint">'
        + esc(done.map(nameOf).join(' · ')) + '</span></span></summary>' + done.map(card).join('') + '</details>' : '');
  const ag = j.agents || {claude: true, codex: false};
  const agName = ag.claude && ag.codex ? 'claude 나 codex' : ag.codex ? 'codex' : 'claude';
  const chip = (k, label) => '<button type="button" class="agchip' + (ag[k] ? ' on' : '') + '" data-agent="' + k + '" aria-pressed="' + !!ag[k] + '">' + (ag[k] ? '✓ ' : '') + label
    + ((j.installed || {})[k] ? '' : ' <span class="faint">· 설치 안 됨</span>') + '</button>';
  sh.innerHTML = '<div class="sh"><div class="title">처음 설정</div><button class="ic x" title="닫기 (Esc)" onclick="closeSheet()">✕</button></div>'
    + '<div class="agpick"><b>쓰는 에이전트</b><span class="faint">둘 다 골라도 된다 — 고른 것만 점검한다</span><div>' + chip('claude', 'Claude Code') + chip('codex', 'Codex') + '</div></div>'
    + '<p class="phn">' + (j.done ? '다 됐다. 등록한 폴더에서 <b>' + agName + '</b> 를 켜면 사무실에 캐릭터가 뜬다. 이미 켜 둔 세션은 다시 켜야 훅이 붙는다.'
        : '<b>남은 것 ' + left.length + '개</b> <span class="faint">· ' + done.length + '/' + (j.items.length - opt.length) + ' 됐다</span>') + '</p>'
    + rows + '<div class="sa foot"><button type="button" class="txtbtn" data-re>다시 보기</button>'
    + (j.done ? '' : '<button type="button" class="txtbtn" data-skip>나중에 — 켤 때 안 띄우기</button>') + '</div>';
  sh.querySelectorAll('[data-do]').forEach(b => b.onclick = async () => {
    const ok = await post(b.dataset.do, {}, b);
    if(b.dataset.busy && !ok){ b.disabled = false; b.textContent = b.dataset.label || b.textContent; }
    setupSheet(false);
  });
  // 설치 버튼은 「보내는 중」 대신 무엇을 하는지 보인다.
  sh.querySelectorAll('[data-busy]').forEach(b => { b.dataset.label = b.textContent; b.addEventListener('click', () => { setTimeout(() => { if(b.disabled) b.textContent = b.dataset.busy; }, 0); }); });
  sh.querySelectorAll('[data-copy]').forEach(b => b.onclick = async () => {
    try{ await navigator.clipboard.writeText(b.dataset.copy); b.textContent = '복사했다'; }catch(e){ fail('복사를 못 했다'); }
  });
  sh.querySelectorAll('[data-agent]').forEach(b => b.onclick = async () => {
    const next = {claude: !!ag.claude, codex: !!ag.codex};
    next[b.dataset.agent] = !next[b.dataset.agent];
    if(!next.claude && !next.codex){ fail('하나는 골라야 한다'); return; }
    if(await post('app/agents', next, b)){ agentsPref = next; setupSheet(false); }
  });
  const ux = sh.querySelector('[data-uncodex]');
  if(ux) ux.onclick = async () => {
    if(!ux.dataset.armed){ ux.dataset.armed = '1'; ux.textContent = '한 번 더 누르면 뺀다'; return; }
    if(await post('app/setup-codex-hooks', {remove: true}, ux)) setupSheet(false);
  };
  const uh = sh.querySelector('[data-unhook]');
  if(uh) uh.onclick = async () => {
    if(!uh.dataset.armed){ uh.dataset.armed = '1'; uh.textContent = '한 번 더 누르면 뺀다 — 캐릭터가 멈춘다'; return; }
    if(await post('app/setup-hooks', {remove: true}, uh)) setupSheet(false);
  };
  const nb = sh.querySelector('[data-new]');
  if(nb) nb.onclick = async () => {
    nb.disabled = true; nb.textContent = '고르는 중';
    try{
      const r = await (await fetch('/todo/app/new-folder', {method:'POST', body:'{}'})).json();
      if(!r.ok) fail(r.error || '못 만들었다'); else if(r.id) setupMade = r.id;
    }catch(e){ fail('위젯이 꺼져 있는 것 같다'); }
    setupSheet(false);
  };
  // 등록 직후에는 세션 자리가 아직 안 생겼을 수 있다 — 잠깐 기다렸다 한 번 더 누른다.
  sh.querySelectorAll('[data-launch]').forEach(lb => lb.onclick = async () => {
    const agent = lb.dataset.launch, label = lb.textContent;
    lb.disabled = true; lb.textContent = '켜는 중';
    let ok = await post('chat/launch', {path: setupMade, agent});
    if(!ok){ await new Promise(r => setTimeout(r, 1500)); ok = await post('chat/launch', {path: setupMade, agent}); }
    if(ok){ lb.textContent = '켰다 — 사무실에 캐릭터가 뜬다'; }
    else { lb.disabled = false; lb.textContent = label; }
  });
  sh.querySelector('[data-re]').onclick = () => setupSheet(false);
  const sk = sh.querySelector('[data-skip]');
  if(sk) sk.onclick = () => { try{ localStorage.setItem('cw_setup_skip', '1'); }catch(e){} closeSheet(); };
  if(!sh.classList.contains('on')) openSheet('setup');
  // 로그인을 기다리는 동안은 5초마다 다시 본다 — 브라우저에서 끝내고 돌아오면 저절로 ✓가 된다.
  clearTimeout(setupPoll);
  const waitLogin = (j.items.some(it => it.key === 'login' && !it.ok) && j.items.some(it => it.key === 'claude' && it.ok))
    || (j.items.some(it => it.key === 'codexLogin' && !it.ok) && j.items.some(it => it.key === 'codex' && it.ok));
  if(waitLogin){
    setupPoll = setTimeout(() => { if(sh.classList.contains('on')) setupSheet(false); }, 5000);
  }
}
if(location.pathname === '/todo' && !/[?&]view=(chat|work|usage|projects)/.test(location.search)) setupSheet(true);
// 켜는 모양 — 고른 칸이 눌린 채로 남는다. 적용은 다음에 켤 때.
async function appMode(mode){
  if(window.event) window.event.stopPropagation();
  if(!await post('app/mode', {mode})) return;
  document.querySelectorAll('.mi-mode [data-mode]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.mode === mode)));
  const el = document.getElementById('app-mode');
  if(el) el.textContent = (mode === 'dashboard' ? '대시보드 창' : '바탕화면 위젯') + '으로 정했다 — 다음에 켤 때부터';
}
async function setStatus(id, status){ if(await post('status', {id, status})) reload(); }
// 카드에서 바로 수정요청(업무 지시서 시안 C, 9/15) — 상세창을 열지 않고 그 자리에서 수정사항을 적어 넘긴다.
// 넘기면 수정사항 저장 → 수정요청(세션 차례, 대표 담당이면 세션으로) → 「바로 시키기」면 곧장 보낸다(일하는 중이면 줄).
function reviseInline(btn, id){
  if(window.event) window.event.stopPropagation();
  const host = btn.closest('.card,.lrow');
  if(!host){ revise(id); return; }
  if(host.querySelector('.rvbox')){ host.querySelector('.rvbox textarea').focus(); return; }
  const box = document.createElement('div');
  box.className = 'rvbox';
  box.innerHTML = '<div class="rvh">수정요청</div><textarea rows="2" oninput="grow(this)" placeholder="무엇을 고칠지 — 세션에 이대로 붙어 간다"></textarea>'
    + '<div class="rvrow"><label><input type="checkbox" checked> 바로 시키기</label>'
    + '<button type="button" class="txtbtn">취소</button><button type="button" class="go primary" disabled>보내기</button></div>';
  host.append(box);
  const t = box.querySelector('textarea'), now = box.querySelector('input'), [cancel, go] = box.querySelectorAll('button');
  const label = () => { go.textContent = now.checked ? '보내기' : '넘기기'; };
  t.addEventListener('input', () => { go.disabled = !t.value.trim(); });
  t.addEventListener('keydown', e => { if(e.key === 'Escape') cancel.click(); });
  now.addEventListener('change', label);
  cancel.onclick = () => box.remove();
  go.onclick = async () => {
    go.disabled = true; go.textContent = '넘기는 중';
    const ok = await post('edit', {id, revisionNote: t.value}) && await post('move', {id, status: 'revision', who: 'session'});
    if(ok && now.checked) await post('send', {id});
    box.remove();
    reload();
  };
  ['click','mousedown','dragstart'].forEach(ev => box.addEventListener(ev, e => e.stopPropagation()));
  host.draggable = false;
  t.focus();
}
// 본문은 저장만 하고 다시 그리지 않는다 — 쓰던 자리에서 화면이 튀면 성가시다.
// 다만 화면에 드러나는 것(우선순위·마감일)은 고친 티가 나야 하므로 다시 그린다.
// ── 업무 지시서 ── 세 칸을 프롬프트 한 칸에 머리말로 합친다. ⚠️ Dart `TaskBrief.compose`와 같은 모양이어야 한다.
function briefCompose(what, done, dont){
  let s = what.trim();
  const add = (head, v) => { if(!v.trim()) return; if(s) s += '\n\n'; s += head + '\n' + v.trim(); };
  add('완료 기준:', done); add('하지 말 것:', dont);
  return s;
}
function briefParts(box){
  const v = k => { const t = box.querySelector('[data-part="' + k + '"]'); return t ? t.value : ''; };
  return {what: v('what'), done: v('done'), dont: v('dont'), rev: v('rev')};
}
// 세션에 가는 말 미리보기 — Dart `TodoItem.dispatch`와 같은 모양으로 그린다.
function briefPreview(box){
  const p = briefParts(box), body = briefCompose(p.what, p.done, p.dont);
  const tag = '[태스크 ' + box.dataset.id + '] 「' + box.dataset.tt + '」';
  const rev = box.dataset.rev && p.rev.trim() ? '\n\n[수정요청]\n' + p.rev.trim() : '';
  const sheet = box.closest('.sheet');
  // 「세션에 가는 말 보기」는 뺐다(9/16) — 남아 있는 판(폰에 열어 둔 옛 화면)에서만 채운다.
  const pv = sheet.querySelector('.bpv');
  if(pv) pv.textContent = (body ? tag + '\n' + body : tag) + rev;
  const warn = [];
  if(!p.what.trim()) warn.push('무엇을이 비어 제목만 간다');
  if(!p.done.trim()) warn.push('완료 기준이 없다 — 세션이 어디서 멈출지 짐작한다');
  const wb = sheet.querySelector('.bwarn');
  if(wb){
    wb.textContent = warn.join(' · ');
    wb.hidden = warn.length === 0;
  }
  box.querySelectorAll('.bf[data-f="what"],.bf[data-f="done"]').forEach(f => f.classList.toggle('need', !f.querySelector('textarea').value.trim()));
}
function briefInput(t){ grow(t); briefPreview(t.closest('.brief')); }
async function briefSave(t){
  const box = t.closest('.brief');
  if(t.dataset.part === 'rev'){ edit(box.dataset.id, {revisionNote: t.value}); return; }
  const p = briefParts(box), body = briefCompose(p.what, p.done, p.dont);
  if(body === box.dataset.body) return;
  box.dataset.body = body;
  await edit(box.dataset.id, {body});
}
// 상세창의 「+ 하위 태스크」 — 적고 엔터. 창은 열린 채로 다시 그린다.
// 제목이 있어야 적을 수 있다 — 시킬 말만 적어 두면 무슨 일인지 목록에서 안 보인다.
function subReady(t){
  const f = t.form, b = f.querySelector('.subgo');
  if(b) b.disabled = !f.querySelector('.st').value.trim();
}
// Enter로 적고 Shift+Enter로 줄을 바꾼다. 한글 조합 중(isComposing)에는 안 받는다.
function subKey(ev){
  if(ev.key !== 'Enter' || ev.shiftKey || ev.isComposing) return;
  ev.preventDefault();
  ev.target.form.requestSubmit();
}
async function addSub(ev, parentId){
  ev.preventDefault();
  if(ev.isComposing) return false;
  const f = ev.target, title = f.querySelector('.st'), note = f.querySelector('.sb');
  const text = title.value.trim(), rest = note.value.trim();
  if(!text) { title.focus(); return false; }
  const body = rest ? briefCompose(rest, '', '') : '';
  title.value = ''; note.value = '';
  grow(note);
  subReady(title);
  if(await post('add', {parentId, text, body})){
    await reload();
    const again = document.querySelector('#s-' + CSS.escape(parentId) + ' .subadd .st');
    if(again) again.focus();
  }
  return false;
}
// 하위가 남은 상위의 완료 — 막지 않고 한 번 더 묻는다(완료는 대표 말이다).
function checkLeft(btn, id){
  if(!btn.dataset.armed){
    const label = btn.innerHTML;
    btn.dataset.armed = '1';
    btn.textContent = '남은 하위 ' + btn.dataset.left + '개 — 한 번 더';
    setTimeout(() => { if(btn.dataset.armed){ delete btn.dataset.armed; btn.innerHTML = label; } }, 3000);
    return;
  }
  delete btn.dataset.armed;
  act('check', id, btn);
}
async function edit(id, patch, redraw){
  const ok = await post('edit', Object.assign({id}, patch));
  if(ok && redraw) reload();
}
// ── 상세창 ── 노션의 페이지 자리. 미리 그려 두고 감춰 둔 것을 꺼낸다.
// 리뷰3 M6(9/17): 줄·카드는 제목 글자만 눌러야 열렸다 — 카드처럼 생겨 어디를 눌러도 열릴 것 같다.
// 버튼·글칸·고르기·체크·묶음 머리는 제 일을 하고, 글을 끌어 고른 뒤의 놓기는 열지 않는다.
document.addEventListener('click', e => {
  const row = e.target.closest('.lrow, .card');
  if(!row || e.target.closest('button, a, input, select, textarea, label, summary, .rvbox, .cf, .la, .ct, [onclick]')) return;
  const sel = document.getSelection();
  if(sel && !sel.isCollapsed) return;
  const ct = row.querySelector(':scope .lt > .ct, :scope > .ct');
  if(ct && ct.getAttribute('onclick')) ct.click();
});
function openSheet(id){
  closeSheet();
  const el = document.getElementById('s-'+id);
  if(!el) return;
  el.classList.add('on');
  document.getElementById('back').classList.add('on');
  // 펼쳐진 뒤에야 높이를 잴 수 있다. 글상자를 내용만큼 키운다.
  el.querySelectorAll('textarea').forEach(grow);
  const brief = el.querySelector('.brief');
  if(brief && brief.dataset.id) briefPreview(brief);
}
// 글상자를 내용만큼 키운다. 최대 높이는 CSS가 막는다.
// ⚠️ 높이를 잠깐 auto로 되돌리는 순간 글상자 안쪽 스크롤과 상세창 스크롤이 맨 위로 튄다 — 최대 높이를 넘긴
// 긴 작업 내용을 쓸 때 칠 때마다 위로 올라갔다(대표 수정요청 9/15, 1920×1080). 재기 전 자리를 되돌려 놓는다.
function grow(t){
  const box = t.closest('.sheet'), outer = box ? box.scrollTop : 0, inner = t.scrollTop;
  t.style.height = 'auto';
  t.style.height = t.scrollHeight + 2 + 'px';
  t.scrollTop = inner;
  if(box) box.scrollTop = outer;
}
// 접어 둔 빈 칸을 펴고 바로 쓰게 한다.
function unfold(btn){
  const sec = btn.closest('.sec');
  sec.classList.remove('folded');
  btn.remove();
  const t = sec.querySelector('textarea');
  grow(t); t.focus();
}
function closeSheet(){
  document.querySelectorAll('.sheet.on').forEach(e=>e.classList.remove('on'));
  document.getElementById('back').classList.remove('on');
}
// 열려 있으면 Esc 로 닫는다. 뒤 배경을 눌러도 닫힌다.
// 설정 메뉴는 바깥을 누르면 닫는다.
document.addEventListener('click', e=>{
  const g = document.getElementById('f-gear');
  if(g && g.open && !g.contains(e.target)) g.open = false;
});
document.addEventListener('keydown', e=>{
  if(e.key !== 'Escape') return;
  const g = document.getElementById('f-gear'); if(g) g.open = false;
  const sheetWas = document.querySelector('.sheet.on');
  closeSheet();
  document.getElementById('add').classList.remove('open');
  // 상세창이 없을 때의 Esc는 찾기를 푼다 — 걸러 놓은 채로 잊는 일이 잦다.
  const q = document.getElementById('q');
  if(!sheetWas && q && q.value.trim()) findClear();
});
// ── 단축키 · 길 찾기 묶음 (대표 결정 9/16, A안) ──
// `/` 찾기 · `N` 새로 · `1·2·3` 리스트·보드·근무기록 · `Esc` 닫기.
// ⚠️ **글칸에 커서가 있으면 쉰다** — 안 그러면 「나」를 치다가 새 창이 뜬다. 조합 중(isComposing)과
// 조합 키(Process)도 거른다. ⌘·⌃·⌥가 눌린 것은 브라우저·앱 몫이라 건드리지 않는다.
function hotkeyFree(){
  const a = document.activeElement;
  if(!a || a === document.body) return true;
  return !(a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable);
}
// ── 되돌리기 ⌘Z · 다시 실행 ⇧⌘Z (대표 결정 9/16) ──
// 담는 것은 **칸 이동·완료·지우기**뿐이다. 글칸 안에서는 쉰다 — 거기는 글자 되돌리기가 먼저다.
// 물어보지 않고 바로 되돌리고 토스트로 알린다(대표 선택). 잘못 되돌렸으면 토스트의 「다시 실행」으로 돌아온다.
function toast(msg, actionLabel, action){
  let el = document.getElementById('toast');
  if(!el){
    el = document.createElement('div');
    el.id = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = '';
  const text = document.createElement('span');
  text.textContent = msg;
  el.appendChild(text);
  if(action){
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = actionLabel;
    b.onclick = () => { el.classList.remove('on'); action(); };
    el.appendChild(b);
  }
  el.classList.add('on');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.remove('on'), 6000);
}
async function undoStep(back){
  const r = await fetch(back ? '/todo/undo' : '/todo/redo', {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: '{}'});
  const j = await r.json().catch(() => ({ok: false, error: '답을 못 읽었다'}));
  if(!j.ok){ fail(j.error || '되돌리지 못했다'); return; }
  await reload();
  toast(back ? j.label + '을 되돌렸다' : j.label + '을 다시 했다',
        back ? '다시 실행' : '되돌리기', () => undoStep(!back));
}
function findFocus(){
  const q = document.getElementById('q');
  if(!q) return false;
  q.focus(); q.select();
  return true;
}
document.addEventListener('keydown', e => {
  // 찾기는 ⌘F(맥)·Ctrl+F(윈도우) — 다른 앱과 같은 자리다(대표 요청 9/16). 글칸에 커서가 있어도 먹는다,
  // 찾으려고 일부러 누르는 글쇠라서다. 브라우저 제 찾기 창은 막는다(같은 화면에 찾는 칸이 둘이면 헷갈린다).
  // ⌘Z / ⇧⌘Z — 글칸 안에서는 안 잡는다(글자 되돌리기가 먼저다. 대표 요청: 텍스트 박스 제외).
  if((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === 'z' || e.key === 'Z' || e.key === 'ㅋ')){
    if(!hotkeyFree()) return;
    e.preventDefault();
    undoStep(!e.shiftKey);
    return;
  }
  if((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === 'f' || e.key === 'F' || e.key === 'ㄹ')){
    if(findFocus()) e.preventDefault();
    return;
  }
  if(e.metaKey || e.ctrlKey || e.altKey || e.isComposing || e.key === 'Process') return;
  if(!hotkeyFree()) return;
  const k = e.key;
  if(k === '/'){
    if(!findFocus()) return;
    e.preventDefault();
    return;
  }
  // 한글 자판에서도 먹게 같은 자리 글쇠(ㅜ)를 같이 받는다 — 자판을 바꿔 가며 쓰는 자리다.
  if(k === 'n' || k === 'N' || k === 'ㅜ'){
    if(!document.getElementById('s-new')) return;
    e.preventDefault(); newTask();
    return;
  }
  const nth = {'1': 0, '2': 1, '3': 2}[k];
  if(nth === undefined) return;
  const links = document.querySelectorAll('.views a[href]');
  if(!links[nth]) return;
  e.preventDefault();
  location.href = links[nth].getAttribute('href');
});
// ── 카드 끌어 옮기기 ──
// ⚠️ 옮기는 동작 자체가 상태 변경이다. 그래야 보드다.
let dragging = null;
// 끌고 있는 태스크(제목까지) — 대화 칸·사무실 얼굴에 놓으면 그 태스크를 가리키는 표시가 입력칸에 붙는다.
let dragTask = null;
// 끌고 있는 결론 문서 경로 — 회의실 「결론.md」를 대화 칸·사무실 얼굴에 놓으면 그 세션 입력칸에 @경로가 붙는다(대표 기획 9/17).
let dragDoc = null;
function pick(ev, id){
  dragging = id;
  dragTask = {id, title: ev.currentTarget.dataset.tt || ''};
  ev.currentTarget.classList.add('drag');
  ev.dataTransfer.effectAllowed = 'move';
  // ⚠️ 무언가 담지 않으면 파이어폭스에서 끌기가 시작되지 않는다.
  ev.dataTransfer.setData('text/plain', id);
}
// 묶음 머리 끌기 — 그 칸에 있는 하위 전부를 함께 옮긴다(A안, 9/15). 대화 칸에 놓으면 상위를 가리킨다.
function pickGroup(ev, head){
  const ids = JSON.parse(head.dataset.ids || '[]');
  dragging = ids;
  dragTask = {id: head.dataset.pid, title: head.dataset.tt || '', kids: ids.length};
  head.closest('.grp,.lgrp').classList.add('drag');
  ev.dataTransfer.effectAllowed = 'move';
  ev.dataTransfer.setData('text/plain', 'cw-group');
}
function drops(){
  dragging = null;
  dragTask = null;
  dragDoc = null;
  document.querySelectorAll('.drag').forEach(e=>e.classList.remove('drag'));
  document.querySelectorAll('.hot').forEach(e=>{ e.classList.remove('hot'); delete e.dataset.hint; });
  document.querySelectorAll('.task-on,.task-hot').forEach(e=>e.classList.remove('task-on','task-hot'));
}
function over(ev){
  ev.preventDefault();
  const el = ev.currentTarget;
  el.classList.add('hot');
  // 몇 장이 옮겨 가는지 끄는 동안 보인다 — 모르고 여러 장을 옮기지 않게.
  if(Array.isArray(dragging)) el.dataset.hint = '하위 ' + dragging.length + '개 옮김'; else delete el.dataset.hint;
}
// 칸 안의 줄 위를 지나갈 때마다 dragleave가 와서 불이 깜빡인다 — 칸 밖으로 나갔을 때만 끈다.
function leave(ev){
  if(ev.relatedTarget && ev.currentTarget.contains(ev.relatedTarget)) return;
  ev.currentTarget.classList.remove('hot');
}
async function drop(ev, status, who){
  ev.preventDefault();
  const ids = Array.isArray(dragging) ? dragging : [dragging || ev.dataTransfer.getData('text/plain')];
  drops();
  if(!ids[0] || ids[0] === 'cw-group') return;
  if(ids.length === 1){
    if(who){ if(await post('move', {id: ids[0], status, who})) reload(); }
    else setStatus(ids[0], status);
    return;
  }
  for(const id of ids){ await post(who ? 'move' : 'status', who ? {id, status, who} : {id, status}); }
  reload();
}
// 묶음 접기 — 이 브라우저에 기억한다. 칸이 바뀌면 다른 묶음으로 친다(칸|상위).
function foldGroup(btn){
  if(window.event) window.event.stopPropagation();
  const g = btn.closest('.grp,.lgrp');
  const shut = !g.classList.contains('shut');
  g.classList.toggle('shut', shut);
  let keys = [];
  try{ keys = JSON.parse(localStorage.getItem('cw_groups_shut') || '[]'); }catch(e){}
  keys = keys.filter(k => k !== g.dataset.g);
  if(shut) keys.push(g.dataset.g);
  try{ localStorage.setItem('cw_groups_shut', JSON.stringify(keys.slice(-200))); }catch(e){}
}
function applyFolds(){
  let keys = [];
  try{ keys = JSON.parse(localStorage.getItem('cw_groups_shut') || '[]'); }catch(e){}
  document.querySelectorAll('.grp[data-g],.lgrp[data-g]').forEach(g => g.classList.toggle('shut', keys.includes(g.dataset.g)));
}
// 상세창의 「대화에 붙이기」 — 담당 세션이 있으면 그 세션 대화를 열고 붙인다.
function taskToChat(btn){
  closeSheet();
  if(btn.dataset.to) chatFor(btn.dataset.to); else chatToggle(true);
  insertTask({id: btn.dataset.id, title: btn.dataset.tt || ''});
}
// ⚠️ 엔터를 직접 잡는다. 보내기 버튼이 없는 폼의 '암묵적 제출'에 기대면
// 브라우저·입력기에 따라 안 넘어간다. 실제로 안 넘어가는 것을 봤다.
function enter(ev){
  if(ev.key !== 'Enter' || ev.isComposing) return;
  ev.preventDefault();
  ev.target.form.dispatchEvent(new Event('submit', {cancelable:true}));
}
// status 를 주면 그 칸에 바로 적힌다. 어느 프로젝트인지는 머리의 고르는 칸을 따른다.
async function addTodo(ev, status){
  ev.preventDefault();
  const input = ev.target.querySelector('input');
  const text = input.value.trim();
  if(!text) return false;
  input.value = '';
  restoreProject();
  const body = {projectId: document.getElementById('np').value, text};
  // 머리의 적기 칸은 고른 차례로 — 내 차례는 오늘예정(대표), 세션 차례는 세션예정(그 폴더 세션)이다.
  const ns = document.getElementById('ns');
  if(status) body.status = status; else if(ns) body.status = ns.value;
  rememberProject();
  if(await post('add', body)) reload();
  return false;
}
// ── 새로 적기 ── 머리의 [+ 새로]가 편다. 적는 칸이 보드 아래에 떨어져 있으면
// 어디에 적는지 눈이 오가야 했다.
function toggleAdd(){
  const f = document.getElementById('add');
  f.classList.toggle('open');
  if(f.classList.contains('open')){ restoreProject(); document.getElementById('nt').focus(); }
}
// ── 새 할 일 창 ── 상세창과 같은 모양. 세션 차례면 시킬 말 세 칸 + 「적고 바로 시키기」.
function newTask(){
  openSheet('new');
  restoreProject();
  newSync();
  const t = document.getElementById('nt');
  t.focus();
}
function newSync(){
  const ns = document.getElementById('ns').value, np = document.getElementById('np');
  document.querySelectorAll('.nseg [data-ns]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.ns === ns)));
  const session = ns === 'sessionPlanned';
  document.getElementById('nbrief').hidden = !session;
  document.getElementById('nsend-wrap').hidden = !session;
  // 고르는 칸이라는 티가 나게 ▾ — 글자만 있으면 눌러서 바꾸는 줄 모른다.
  document.getElementById('np-face').textContent = (np.selectedOptions[0] ? np.selectedOptions[0].text : '프로젝트') + ' ▾';
  newTarget(session, np.value);
  const go = document.getElementById('ngo');
  go.textContent = session && document.getElementById('nsend').checked ? '적고 시키기' : '적기';
  rememberProject();
}
// 「세션이」를 고르면 **누가 받는지**를 글자로 못 박는다(대표 제보 9/18 「세션 선택하는 것이 명확하지 않다」).
// 프로젝트 폴더 = 그 세션이라는 규칙(`TodoStore.sendTargetOf`)이 화면에 안 적혀 있어서, 프로젝트만 고르고
// 어디로 가는지 모른 채 시키게 됐다. 지금 켜져 있는지까지 같이 보인다.
function newTarget(session, pid){
  const box = document.getElementById('ntarget'), send = document.getElementById('nsend');
  if(!box) return;
  box.hidden = !session;
  if(!session) return;
  const norm = v => (v || '').normalize('NFC');
  const folder = norm((typeof PROJ_FOLDER !== 'undefined' && PROJ_FOLDER[pid]) || '');
  box.className = 'ntarget';
  if(!folder){
    box.textContent = '';
    box.append(el('b', '', '보낼 세션이 없다'),
      el('span', '', '이 프로젝트에는 폴더가 없다 — 적어 둘 수는 있지만 시킬 수는 없다. 프로젝트 화면에서 폴더를 붙인다'));
    box.classList.add('none');
    if(send){ send.checked = false; send.disabled = true; }
    return;
  }
  if(send) send.disabled = false;
  const s = (chat.list || []).find(x => norm(x.path) === folder);
  const name = s ? s.name : folder.split('/').filter(Boolean).pop();
  box.textContent = '';
  const who = el('b', '', name + ' 세션이 받는다');
  const how = el('span', '', !s ? '아직 한 번도 안 켠 폴더다 — 켜면 받아 간다'
    : s.state === 'ended' ? '지금 꺼져 있다 — 시키면 줄에 세워 두고, 출근하면 받아 간다'
    : s.state === 'waiting' ? '지금 승인 대기다 — 먼저 고르고 시킨다'
    : BUSY[s.state] ? '지금 일하는 중이다 — 시키면 줄에 선다' : '지금 쉬고 있다 — 시키면 바로 받는다');
  box.append(who, how);
  if(s && s.sprite){
    const f = face(s);
    box.prepend(f);
  }
}
document.addEventListener('click', e => {
  const b = e.target.closest && e.target.closest('.nseg [data-ns]');
  if(b){ document.getElementById('ns').value = b.dataset.ns; newSync(); }
  if(e.target && e.target.id === 'nsend') newSync();
});
// 제목에서 엔터 — 세션 차례면 시킬 말로 넘어가고, 아니면 곧장 적는다(예전 한 줄 폼처럼).
function newKey(ev){
  if(ev.key !== 'Enter' || ev.shiftKey || ev.isComposing) return;
  ev.preventDefault();
  if(document.getElementById('ns').value === 'sessionPlanned') document.getElementById('nb-what').focus();
  else newSubmit();
}
async function newSubmit(){
  const t = document.getElementById('nt'), text = t.value.trim();
  if(!text){ t.focus(); return; }
  const ns = document.getElementById('ns').value, session = ns === 'sessionPlanned';
  const v = id => document.getElementById(id).value;
  const body = session ? briefCompose(v('nb-what'), v('nb-done'), v('nb-dont')) : '';
  const go = document.getElementById('ngo');
  go.disabled = true;
  let j = null;
  try{
    j = await (await fetch('/todo/add', {method:'POST', body: JSON.stringify({projectId: v('np'), text, status: ns, body})})).json();
  }catch(e){ fail('위젯이 꺼져 있는 것 같다'); }
  go.disabled = false;
  if(!j) return;
  if(!j.ok){ fail(j.error || '못 적었다'); return; }
  if(session && document.getElementById('nsend').checked && j.id) await post('send', {id: j.id});
  ['nt','nb-what','nb-done','nb-dont'].forEach(id => { document.getElementById(id).value = ''; });
  closeSheet();
  reload();
}
// 마지막에 적은 프로젝트를 기억한다. 이 브라우저에만 남는 편의라 못 써도 그만이다.
function rememberProject(){
  try{
    localStorage.setItem('cw_np', document.getElementById('np').value);
    const ns = document.getElementById('ns');
    if(ns) localStorage.setItem('cw_ns', ns.value);
  }catch(e){}
}
function restoreProject(){
  try{
    for(const [id, key] of [['np','cw_np'],['ns','cw_ns']]){
      const v = localStorage.getItem(key), el = document.getElementById(id);
      if(v && el && [...el.options].some(o => o.value === v)) el.value = v;
    }
  }catch(e){}
}
restoreProject();
function fail(msg){
  const el = document.getElementById('err');
  el.textContent = msg; el.style.display='block';
  setTimeout(()=>{el.style.display='none'}, 3000);
}
// ⚠️ **페이지를 통째로 다시 부르지 않는다.** location.reload() 는 바뀐 것이
// 없어도 화면을 새로 그려서 5초마다 한 번씩 깜빡인다. 받아서 바꿔치기한다.
//
// ⚠️ **바뀐 게 없으면 손도 대지 않는다.** 아무 일도 없는 동안에는 DOM 이
// 그대로 있어야 눈에 아무 일도 안 일어난다.
let fetching = false, again = false;
// 펴 둔 접기(details)는 비교에서 뺀다 — 펴 둔 것만으로 매번 다르다고 보고 갈아끼우면 5초마다 접힌다.
function plain(el){
  const c = el.cloneNode(true);
  c.querySelectorAll('details[open]').forEach(d => d.removeAttribute('open'));
  // 접은 묶음은 브라우저가 붙인 표시라 서버 그림과 견줄 때 뺀다 — 안 빼면 5초마다 갈아끼운다.
  c.querySelectorAll('.shut').forEach(g => g.classList.remove('shut'));
  if(c.matches && c.matches('details[open]')) c.removeAttribute('open');
  return c.outerHTML;
}
// 한글을 조합하는 중인가. ⚠️ 조합 중에 화면을 다시 그리면 **자음·모음이 갈라져 박힌다**
// (「가나다」가 「ㄱㅏㄴㅏㄷㅏ」로, 대표 제보 9/16). 조합은 IME가 들고 있는데 글상자가 새 조각으로 갈리면 그 상태가 깨진다.
let composing = false;
document.addEventListener('compositionstart', () => { composing = true; }, true);
document.addEventListener('compositionend', () => { composing = false; }, true);
async function reload(){
  // 받는 중에 또 부르면(선택을 연달아 누름) 끝난 뒤 한 번 더 받는다 — 건너뛰면 옛 선택이 남는다.
  if(fetching){ again = true; return; }
  // 조합이 끝나면 그때 다시 그린다 — 지금 갈아 끼우면 치던 글자가 깨진다.
  if(composing){ again = true; return; }
  fetching = true;
  try{
    const res = await fetch(location.href, {cache:'no-store'});
    const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
    // 받는 사이에 조합을 시작했으면 끝난 뒤로 미룬다.
    if(composing){ again = true; return; }
    const next = doc.body.innerHTML;
    if(next === document.body.innerHTML) return;
    const opened = [...document.querySelectorAll('details[id][open]')].map(d => d.id);
    // 편 상세창은 다시 그린 뒤 도로 연다 — 하위를 적거나 상위를 붙이면 그 창에서 이어 쓴다.
    const sheetOn = document.querySelector('.sheet.on');
    const sheetId = sheetOn ? sheetOn.id : null, sheetTop = sheetOn ? sheetOn.scrollTop : 0;
    // 보드는 옆으로 스크롤한 자리를 지켜준다 — 안 그러면 볼 때마다 왼쪽으로 튄다.
    const before = document.querySelector('.board');
    const left = before ? before.scrollLeft : 0;
    // ⚠️ **바뀐 조각만 갈아끼운다.** 시간이 도는 카드가 하나만 있어도 5초마다
    // 무언가는 바뀌는데, 그때마다 화면 전체를 새로 만들면 펴 둔 것·짚고 있던
    // 것이 매번 처음으로 돌아간다. 상세창은 조각이 따로라 손을 안 탄다.
    // ⚠️ **열려 있는 작은 창(#submenu)은 셈에서 뺀다.** body의 자식이라 조각 수가 하나 어긋나고,
    // 그러면 아래 else 갈래가 그 창을 통째로 지운다 — 이름을 쓰다 말고 창이 사라졌다(9/18).
    // 퇴근·하위 메뉴도 같은 일을 당하고 있었다.
    const olds = [...document.body.children].filter(o => o.id !== 'submenu');
    const news = [...doc.body.children];
    if(olds.length === news.length){
      for(let i = 0; i < olds.length; i++){
        if(olds[i].id === 'duo') continue;
        if(plain(olds[i]) !== news[i].outerHTML) olds[i].replaceWith(news[i]);
      }
    }else{
      // ⚠️ **오른쪽 판(#duo)은 한 번도 떼지 않는다.** 예전에는 body를 통째로 갈고 판을 떼어 다시 붙였는데,
      // 떼었다 붙인 요소는 스크롤이 0으로 돌아간다 — 조각 수가 바뀔 때마다(배너가 뜨거나 상세창이 늘 때)
      // 대화 칸이 맨 아래에서 맨 위로 튀었다(대표 제보 9/15 「채팅창이 최하단이 아닌 곳으로 이동」).
      // 판을 제자리에 두고 나머지 조각만 판 앞뒤 원래 순서로 갈아끼운다.
      const keep = document.getElementById('duo');
      olds.forEach(o => { if(o !== keep) o.remove(); });
      const at = news.findIndex(n => n.id === 'duo');
      news.forEach((n, i) => {
        if(n.id === 'duo') return;
        if(keep && at >= 0 && i < at) keep.before(n); else document.body.append(n);
      });
    }
    const after = document.querySelector('.board');
    if(after) after.scrollLeft = left;
    opened.forEach(id => { const d = document.getElementById(id); if(d) d.open = true; });
    applyFolds();
    applyPicks();
    if(sheetId){
      const sh = document.getElementById(sheetId);
      if(sh && !sh.classList.contains('on')){
        sh.classList.add('on');
        document.getElementById('back').classList.add('on');
        sh.querySelectorAll('textarea').forEach(grow);
        sh.scrollTop = sheetTop;
      }
    }
    restoreProject();
  }catch(e){
    // 위젯이 꺼졌거나 잠깐 못 붙은 것이다. 다음 틱에 다시 해본다.
  }finally{
    fetching = false;
    if(again){ again = false; reload(); }
  }
}
// ⚠️ 쓰던 중에 다시 그리면 글자가 날아간다. 손이 가 있으면 건너뛴다.
// 본문(textarea)과 고르는 칸(select)도 마찬가지다 — 입력창만 보면 놓친다.
// ⚠️ 끄는 중에 다시 그리면 잡고 있던 카드가 사라진다.
setInterval(()=>{
  // 회의 화면은 제 스크립트가 3초마다 그린다 — 여기서 본문을 갈아 끼우면 「읽는 중…」으로 돌아가 깜빡인다(대표 제보 9/17).
  if(/view=meeting/.test(location.search)) return;
  const el = document.activeElement;
  // 대화 칸에서 치는 중이면 보드는 계속 새로 그린다 — 그 칸은 다시 그리기에서 빠져 있다.
  if(el && ['INPUT','TEXTAREA','SELECT'].includes(el.tagName) && !el.closest('#duo')) return;
  if(dragging) return;
  // ⚠️ 상세창을 펴 둔 채로 다시 그리면 쓰던 것이 통째로 닫힌다.
  if(document.querySelector('.sheet.on')) return;
  // 적는 칸을 펴 둔 채로 다시 그리면 접힌다.
  if(document.querySelector('#add.open')) return;
  // 카드에서 수정요청을 쓰는 중이면 — 체크박스를 누르면 글상자에서 손이 떠나도 쓰던 것이 날아가지 않게.
  if(document.querySelector('.rvbox')) return;
  // 프로젝트 기록에서 「+ 적기」로 연 입력줄 — 초점이 날짜 칸 달력으로 가 있어도 쓰던 것이 접히지 않게.
  if(document.querySelector('.nadd:not([hidden])')) return;
  // 글을 끌어 고르는 중이면 다시 그리지 않는다 — 다시 그리면 고른 것이 풀려 복사가 안 된다(대표 제보 9/16).
  const sel = document.getSelection();
  if(sel && !sel.isCollapsed && sel.rangeCount) return;
  reload();
}, 5000);
''';

/// 대시보드 오른쪽 **사무실 + 대화 한 판**(시안 v9, 2026-09-15 대표 확정).
///
/// - 사무실: 이사 → 팀장 → 사원을 댓글 이어 달기처럼 선으로 잇는다. ⟩로 접으면 얼굴만, 팀마다 선
/// - 대화: 머리 한 줄(얼굴·이름·상태 점) · 있는 맥락만(진행중·줄) · 대화 · 입력
/// - 승인 대기 표시는 두 곳뿐 — 사무실 목록의 「대기」 배지와 대화 안 카드(v8 리뷰에서 덜어냄)
///
/// ⚠️ 이 판은 페이지의 5초 다시 그리기(`reload`)가 건드리지 않는다 — 서버가 빈 껍데기만
/// 그리고 내용은 여기서 채우므로, 갈아끼우면 읽던 대화가 매번 사라진다.
const String kChatJs = r'''
const chat = {open:false, path:null, sig:'', sending:false, folded:false, teams:{}, list:[], width:640,
  pane:null, raw:false, armed:null, acting:false};
try{
  chat.open = localStorage.getItem('cw_chat_open') === '1';
  chat.path = localStorage.getItem('cw_chat_path');
  chat.folded = localStorage.getItem('cw_office_folded') === '1';
  chat.teams = JSON.parse(localStorage.getItem('cw_office_teams') || '{}');
  chat.width = +localStorage.getItem('cw_dock_w') || 640;
  chat.raw = localStorage.getItem('cw_chat_raw') === '1';
}catch(e){}
// 주소로 대화 칸을 연다(`?chat=<세션 폴더>`) — 스크린샷·링크로 특정 세션 대화를 바로 보인다.
try{
  const want = new URLSearchParams(location.search).get('chat');
  if(want){ chat.open = true; chat.path = want; }
}catch(e){}
// 대화 칸 너비 — 대표 피드백(9/15): 대화가 좁다. 기본을 넓히고 끌어서 바꾸게 한다.
function dockWidth(w){
  const max = Math.max(360, Math.round(window.innerWidth * 0.7));
  chat.width = Math.min(max, Math.max(360, Math.round(w)));
  fitWidth();
}
// 끌어 둔 너비(chat.width)는 바람일 뿐 — 실제 너비는 할 일 쪽에 최소 560px를 남기고 줄인다.
// 1440px 노트북에서 대화(640)+사무실(236)을 다 펴면 할 일이 500px 남짓이 되어 카드 글자가 세로로 섰다(UI 리뷰 9/15).
// 할 일 쪽이 좁아지면 화면 폭 기준 미디어 쿼리가 못 알아채므로, 남은 폭으로 직접 한 줄·두 줄을 고른다.
// 네이티브(앱 창)가 이 창이 놓인 모니터의 가로를 알려 준다 — 페이지의 screen 값이 못 미더워서다.
function cwScreen(w){
  if(!(w > 0) || window.cwScreenW === w) return;
  window.cwScreenW = w;
  fitWidth();
}
function fitWidth(){
  const r = document.documentElement, W = window.innerWidth;
  const office = chat.folded ? 58 : 236;
  const room = W - office - 28 - 32 - 560;
  const eff = Math.max(360, Math.min(chat.width, room));
  r.style.setProperty('--dock-w', eff + 'px');
  const main = W - 32 - (W <= 900 ? 16 : office + 28 + (chat.open ? eff : 0));
  // 1920×1080에서 대화 칸을 열면 남는 폭이 ~980px이다. 예전 기준(1040)이면 보드가 두 줄로 접혀
  // 네 칸을 한눈에 못 봤다(대표 요청 9/16 — 「1920에서도 4개가 일렬로」). 칸 폭 230px까지는 한 줄로 둔다.
  r.classList.toggle('main-narrow', W > 900 && main < 860);
  r.classList.toggle('main-tight', W > 900 && main < 560);
  r.classList.toggle('main-narrow-ish', W > 900 && main >= 860 && main < 1100);
  // 창을 모니터 가로의 **반 아래로** 줄이면 할 일 목록을 접고 대화만 남긴다(대표 결정 9/16 — 따로 누르는 버튼 없이).
  // 반 이상이면 지금처럼 보드·리스트와 대화를 같이 본다. 폰처럼 화면 자체가 좁은 기기는 창 = 화면이라 걸리지 않는다.
  // ⚠️ **앱 창에서는 `screen.availWidth`를 믿을 수 없다** — WKWebView가 창 크기를 돌려주는 일이 있어
  // 「창이 화면의 반보다 좁다」가 영영 참이 안 됐다(대표 3차 제보 9/16 화면 기록). 네이티브가 알려 준 값을 먼저 쓴다.
  const screenW = window.cwScreenW || (window.screen && (screen.availWidth || screen.width)) || W;
  // 모니터가 넓을 때만 본다 — 작은 화면(폰·좁은 노트북)은 창 = 화면이라 반쪽이라는 말이 뜻이 없다.
  //
  // ⚠️ **반쪽 기준 하나로는 큰 모니터에서 안 먹는다**(대표 제보 9/16 — 1920 화면은 되는데 4K에서 안 된다).
  // 2560pt짜리 화면에서는 창을 1280 아래로 줄여야 걸리는데, 그전에 이미 보드가 쓸 수 없을 만큼 좁아진다.
  // 그래서 **남는 칸이 보드를 담을 수 없으면**(대화 칸을 연 채로) 화면 크기와 상관없이 대화만 남긴다.
  const boardDead = chat.open && main < 620;
  const onlyChat = boardDead || (screenW >= 1000 && W < screenW * 0.5);
  r.classList.toggle('only-chat', onlyChat);
  if(window.cwDbg && /[?&]dbg=focus/.test(location.search)){
    try{ cwDbg.postMessage('fit 창=' + W + ' 화면=' + screenW + '(네이티브 ' + (window.cwScreenW || '-') + ' · screen ' + (window.screen ? screen.availWidth : '-') + ') 대화만=' + onlyChat); }catch(e){}
  }
  if(onlyChat && !chat.open) chatToggle(true);
}
dockWidth(chat.width);
window.addEventListener('resize', fitWidth);
(function(){
  const g = document.getElementById('dock-grip');
  if(!g) return;
  g.addEventListener('dblclick', () => { dockWidth(640); try{ localStorage.setItem('cw_dock_w', String(chat.width)); }catch(e){} });
  g.addEventListener('pointerdown', ev => {
    ev.preventDefault();
    g.setPointerCapture(ev.pointerId); g.classList.add('on');
    const startX = ev.clientX, startW = chat.width;
    const move = e => dockWidth(startW + (startX - e.clientX));
    const up = () => { g.classList.remove('on'); g.removeEventListener('pointermove', move); g.removeEventListener('pointerup', up);
      try{ localStorage.setItem('cw_dock_w', String(chat.width)); }catch(e){} };
    g.addEventListener('pointermove', move); g.addEventListener('pointerup', up);
  });
})();
// ── 세션마다 쓰다 만 말 ── (대표 요청 9/16)
// 「클로드워쳐에 쓰다가 이사로 갔다 오면 쓰던 글이 그대로」. 보낼 때까지는 그 세션 것으로 남겨 둔다.
// ⚠️ 브라우저에만 담는다(localStorage) — 서버로 보내면 안 보낸 말이 기록에 남고, 폰·앱 창이 서로 덮어쓴다.
const kDrafts = 'cw_chat_drafts';
let drafts = {};
try{ drafts = JSON.parse(localStorage.getItem(kDrafts) || '{}') || {}; }catch(e){ drafts = {}; }
function draftSave(){
  const box = document.getElementById('chat-text');
  if(!box || !chat.path) return;
  const v = box.value;
  if(v.trim()) drafts[chat.path] = v.slice(0, 20000); else delete drafts[chat.path];
  // 세션이 늘 만큼 쌓이지 않게 서른 개까지만 든다 — 오래된 것부터 버린다.
  const keys = Object.keys(drafts);
  if(keys.length > 30) keys.slice(0, keys.length - 30).forEach(k => delete drafts[k]);
  try{ localStorage.setItem(kDrafts, JSON.stringify(drafts)); }catch(e){}
}
function draftLoad(){
  const box = document.getElementById('chat-text');
  if(!box) return;
  const want = (chat.path && drafts[chat.path]) || '';
  if(box.value === want) return;
  box.value = want;
  if(typeof grow === 'function') grow(box);
}
function chatRemember(){
  try{
    localStorage.setItem('cw_chat_open', chat.open ? '1' : '0');
    localStorage.setItem('cw_office_folded', chat.folded ? '1' : '0');
    localStorage.setItem('cw_office_teams', JSON.stringify(chat.teams));
    if(chat.path) localStorage.setItem('cw_chat_path', chat.path);
  }catch(e){}
}
function chatToggle(force){
  chat.open = force === undefined ? !chat.open : force;
  chatRemember(); chatApply();
}
function officeFold(){
  chat.folded = !chat.folded;
  chatRemember(); chatApply(); drawOffice();
}
function chatApply(){
  const r = document.documentElement;
  r.classList.add('has-duo');
  r.classList.toggle('chat-open', chat.open);
  r.classList.toggle('office-folded', chat.folded);
  fitWidth();
  const f = document.getElementById('ofold');
  if(f){ f.textContent = chat.folded ? '⟨' : '⟩'; f.title = chat.folded ? '사무실 펴기' : '사무실 접기'; }
  chatSessions();
  if(chat.open){ chatTick(); chatPane(); }
}
// 찾기 — 주소의 q에 실어 서버가 거른다(리스트·보드 같은 규칙). 치는 동안 0.35초 쉬었다가 다시 그린다.
let findTimer = 0;
function findTask(el, ev){
  clearTimeout(findTimer);
  // 조합 중(한글을 치는 중)에는 기다린다 — 다시 그리면 자음·모음이 갈라진다.
  if((ev && ev.isComposing) || composing) return;
  findTimer = setTimeout(() => findGo(el.value), 350);
}
function findKey(ev){
  // Esc는 **찾기 모드에서 나온다**(대표 수정요청 9/16) — 글자를 지우는 데 그치지 않고 칸에서 손을 뗀다.
  // 그래야 N·1·2·3 같은 글쇠가 곧바로 다시 먹는다(글칸에 커서가 있으면 단축키는 쉰다).
  if(ev.key === 'Escape'){
    ev.preventDefault();
    const had = ev.target.value.trim();
    ev.target.value = '';
    ev.target.blur();
    if(had) findGo('');
    return;
  }
  if(ev.key === 'Enter' && !ev.isComposing){ ev.preventDefault(); clearTimeout(findTimer); findGo(ev.target.value); }
}
function findClear(){
  const el = document.getElementById('q');
  if(el) el.value = '';
  findGo('');
}
async function findGo(q){
  const u = new URL(location.href);
  if(q.trim()) u.searchParams.set('q', q.trim()); else u.searchParams.delete('q');
  if((u.href) === location.href) return;
  history.replaceState(null, '', u);
  await reload();
  // 다시 그린 뒤에도 치던 자리에 그대로 있는다 — 한 글자 칠 때마다 초점이 튀면 못 쓴다.
  const el = document.getElementById('q');
  if(el && q.trim()){ el.focus(); el.setSelectionRange(el.value.length, el.value.length); }
}
// 사무실에서 세션을 고르면 리스트·보드가 그 세션 몫만 보인다(주소의 who). 빈 글자면 푼다.
// 리스트·보드 화면에서만 — 다른 페이지(근무기록·프로젝트)에는 거를 목록이 없다.
function filterWho(path){
  const u = new URL(location.href), v = u.searchParams.get('view');
  if(v && v !== 'list' && v !== 'board') return;
  if((u.searchParams.get('who') || '') === path) return;
  if(path) u.searchParams.set('who', path); else u.searchParams.delete('who');
  history.replaceState(null, '', u);
  reload();
}
// 보드 카드·프로젝트 판·사무실에서 그 세션의 대화를 연다.
// 출근·휴식·퇴근 — 이사 세션에 말을 보낸다. 기록은 세션이 적고, 버튼 모양은 5초 다시 그리기로 따라온다.
async function clockSay(action, btn){
  if(await post('app/clock', {action}, btn)){
    btn.textContent = '보냈다';
    setTimeout(reload, 4000);
  }
}
// 하위 세션 추가 — 메뉴는 머리(#dh) 밖(body)에 띄운다. 머리는 1.5초마다 다시 그려져 안에 두면 사라진다.
// ── 모델 — 캐릭터 옆 표시 · 누르면 골라서 `/model`로 바꾼다(대표 요청 9/17) ──
// 모델은 세션 기록의 마지막 응답에서 읽으므로 **바꾼 뒤 새 답이 나와야** 표시가 바뀐다. 그 사이는 「→ 고른 것」으로 보인다.
const MODELS = [
  // Fable은 이 계정에서 `claude --model fable`로 돌아가는 것을 확인했다(2026-09-17, claude-fable-5-1).
  {alias: 'fable', label: 'Fable', hint: '가장 새롭고 강하다 · 한도를 가장 많이 쓴다'},
  {alias: 'opus', label: 'Opus', hint: '아주 똑똑하다 · 한도를 많이 쓴다'},
  {alias: 'sonnet', label: 'Sonnet', hint: '빠르고 넉넉하다 · 대부분의 일'},
  {alias: 'haiku', label: 'Haiku', hint: '가장 빠르다 · 간단한 일'},
];
function modelName(id){
  if(!id) return '';
  // claude-opus-5 → Opus 5 · claude-haiku-4-5-20251001 → Haiku 4.5
  const m = id.replace(/^claude-/, '').replace(/-\d{8}$/, '').replace(/\[.*\]$/, '').split('-');
  const fam = m.find(x => /^[a-z]+$/i.test(x)) || m[0];
  const ver = m.filter(x => /^\d+$/.test(x)).join('.');
  return fam.charAt(0).toUpperCase() + fam.slice(1) + (ver ? ' ' + ver : '');
}
chat.modelWant = chat.modelWant || {};
function modelButton(s, p){
  if(!p || !p.alive) return null;
  const want = chat.modelWant[s.path];
  // 고른 계열로 바뀌었으면(또는 5분이 지나면) 기다림을 푼다.
  if(want && ((p.model && p.model.includes(want.alias)) || Date.now() - want.at > 300000)) delete chat.modelWant[s.path];
  const w = chat.modelWant[s.path];
  const b = el('button', 'modelbtn', w ? '→ ' + w.label : (modelName(p.model) || '모델 ?'));
  b.type = 'button';
  b.title = w ? '바꿔 달라고 보냈다 — 다음 답부터 ' + w.label + '로 표시된다' : (p.model ? p.model + ' · 눌러서 바꾸기' : '아직 답이 없어 모델을 모른다 · 눌러서 고르기');
  b.onclick = ev => { ev.stopPropagation(); modelMenu(ev.currentTarget, s, p); };
  return b;
}
function modelMenu(btn, s, p){
  const old = document.getElementById('submenu');
  if(old){ old.remove(); return; }
  const m = el('div', 'submenu'); m.id = 'submenu';
  const r = btn.getBoundingClientRect();
  m.style.top = (r.bottom + 6) + 'px';
  m.style.left = Math.max(8, r.left) + 'px';
  if(p.waiting){ m.append(el('div', 'mi none', '승인을 기다리는 중이라 지금은 못 바꾼다')); }
  // 대화가 이미 있으면 클로드가 「바꿀까요?」를 한 번 묻는다(실측 9/17) — 그 선택 카드는 대화 칸에 뜬다.
  else m.append(el('div', 'mi none', '대화 중이면 클로드가 한 번 더 묻는다 — 대화 칸의 선택 카드에서 고른다'));
  for(const o of MODELS){
    const b = el('button', 'mi'); b.type = 'button';
    const on = p.model && p.model.includes(o.alias);
    b.append(el('b', '', o.label + (on ? ' ✓' : '')), el('small', '', o.hint + (p.busy ? ' · 지금 답이 끝난 뒤 바뀐다' : '')));
    b.disabled = !!p.waiting || on;
    b.onclick = async () => {
      m.remove();
      if(await post('chat/send', {path: s.path, text: '/model ' + o.alias})){
        chat.modelWant[s.path] = {alias: o.alias, label: o.label, at: Date.now()};
        drawHead();
      }
    };
    m.append(b);
  }
  document.body.append(m);
  setTimeout(() => document.addEventListener('click', function off(e){
    if(!m.contains(e.target)){ m.remove(); document.removeEventListener('click', off); }
  }), 0);
}
function subMenu(btn, parent){
  const old = document.getElementById('submenu');
  if(old){ old.remove(); return; }
  const m = el('div', 'submenu'); m.id = 'submenu';
  const r = btn.getBoundingClientRect();
  m.style.top = (r.bottom + 6) + 'px';
  m.style.right = Math.max(8, window.innerWidth - r.right) + 'px';
  const pick = (mode, label, hint) => {
    const b = el('button', 'mi'); b.type = 'button';
    b.append(el('b', '', label), el('small', '', hint));
    b.onclick = async () => {
      m.remove();
      let j;
      try{ j = await (await fetch('/todo/app/sub-folder', {method:'POST', body: JSON.stringify({path: parent, mode})})).json(); }
      catch(e){ fail('위젯이 꺼져 있는 것 같다'); return; }
      if(!j.ok){ fail(j.error || '못 만들었다'); return; }
      if(!j.id) return;   // 취소
      // 등록한 뒤 세션 자리가 생기면 그 대화로 옮기고 켠다 — 시작용 CLAUDE.md가 비어 있으면 세션이 먼저 묻는다.
      for(let i = 0; i < 10; i++){
        await chatSessions();
        if(chat.list.some(x => x.path === j.id)) break;
        await new Promise(r => setTimeout(r, 500));
      }
      chatFor(j.id);
      await post('chat/launch', {path: j.id});
    };
    m.append(b);
  };
  pick('new', '새 하위 폴더 만들기', '이름을 적으면 이 폴더 안에 만들고 시작용 CLAUDE.md를 둔다');
  pick('pick', '있는 폴더 고르기', '이 폴더 안의 폴더를 골라 등록한다 · CLAUDE.md가 없으면 만든다');
  document.body.append(m);
  setTimeout(() => document.addEventListener('click', function off(e){
    if(!m.contains(e.target)){ m.remove(); document.removeEventListener('click', off); }
  }), 0);
}
function chatFor(path){
  if(chat.path !== path){
    draftSave();                       // 떠나기 전에 쓰던 말을 그 세션 앞에 둔다
    chat.pane = null; chat.armed = null;
  }
  chat.path = path; chat.sig = ''; chat.open = true;
  draftLoad();                         // 새 세션이 쓰다 만 말이 있으면 꺼낸다
  chatRemember(); chatApply();
}
function el(tag, cls, text){
  const e = document.createElement(tag);
  if(cls) e.className = cls;
  if(text !== undefined) e.textContent = text;
  return e;
}
// 마크다운 조금만. **먼저 전부 이스케이프한 뒤** 모양만 입힌다 — 대화에는 세션이 읽은
// 파일 내용이 섞이므로 HTML을 그대로 넣으면 안 된다.
function md(src){
  const esc = src.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const parts = esc.split('```');
  return parts.map((p, i) => i % 2 ? '<pre>' + p.replace(/^[a-z]*\n/, '') + '</pre>' : blocks(p)).join('');
}
// 한 줄 안의 모양 — 링크 · 경로 · 굵게 · 코드.
function inline(t){
  return paths(links(t))
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/`([^`\n]+)`/g, (m, c) => isPath(c) ? '<code class="path" data-path="' + c + '" title="파인더에서 보기">' + c + '</code>' : '<code>' + c + '</code>');
}
// 경로 — 누르면 파인더에서 보인다(대표 요청 9/15). 코드 칸(`…`) 안의 경로와, 글에 그냥 박힌 /Users/… · ~/… 를 잡는다.
// 상대 경로(lib/main.dart:12)는 코드 칸 안에서만 — 글 속 「A/B」 같은 말을 경로로 오인하지 않게. 푸는 것은 서버(revealTarget)다.
const PATH_EXT = /\.(dart|md|py|js|mjs|ts|tsx|json|html|css|swift|ya?ml|txt|png|jpe?g|gif|svg|pdf|sh|toml|csv|kt|java|xml|plist|lock|log)(:\d+){0,2}$/i;
function isPath(c){
  const v = c.replace(/&amp;/g, '&').trim();
  if(/^(~|\/(Users|Volumes|Applications|private|tmp|opt|usr|etc|Library))(\/|$)/.test(v)) return v.length > 1;
  if(/\s/.test(v) || /^https?:/.test(v)) return false;
  if(/^\.{1,2}\//.test(v)) return true;
  const bare = v.replace(/(:\d+){1,2}$/, '');
  return /^[\p{L}\p{N}_.@-]+(\/[\p{L}\p{N}_.@-]+)*\/?$/u.test(bare) && (PATH_EXT.test(bare) || (bare.includes('/') && bare.endsWith('/')));
}
function paths(p){
  return p.replace(/(^|[\s(（「『])((?:~|\/Users|\/Volumes)\/[^\s<>`"'）」』\u0001]+)/g, (m, lead, raw) => {
    const tail = (raw.match(/[.,;:!?)\]}]+$/) || [''])[0];
    const v = tail && !/:\d+$/.test(raw) ? raw.slice(0, -tail.length) : raw;
    return lead + '<span class="path" data-path="' + v + '" title="파인더에서 보기">' + v + '</span>' + (v === raw ? '' : raw.slice(v.length));
  });
}
document.addEventListener('click', e => {
  const p = e.target.closest && e.target.closest('.path');
  if(!p) return;
  e.preventDefault();
  post('chat/reveal', {path: p.dataset.path, cwd: chat.path || ''});
});
// 덩어리 — 문단 · 목록 · 제목 · 표 · 인용 · 가로줄. 세션 답은 마크다운으로 오는데 줄바꿈만 찍으면
// 목록 둘째 줄이 글머리표 아래로 안 들어가고, 빈 줄(문단)과 줄바꿈이 안 갈리고, 제목이 본문에 붙는다(9/15 대표 지적).
// 빈 줄로 나뉜 것은 문단, 빈 줄 없이 이어진 줄은 한 문단 안의 줄바꿈이다.
function blocks(p){
  const ls = p.split('\n'), out = [];
  let para = [], list = null;
  const endPara = () => { if(para.length){ out.push('<p>' + para.map(inline).join('<br>') + '</p>'); para = []; } };
  const endList = () => { if(list){ out.push(list.html + '</li></' + list.tag + '>'); list = null; } };
  const end = () => { endPara(); endList(); };
  const cells = l => l.trim().replace(/^\||\|$/g, '').split('|').map(c => inline(c.trim()));
  for(let i = 0; i < ls.length; i++){
    const l = ls[i];
    if(!l.trim()){ end(); continue; }
    // 표 — `|`로 시작하는 줄 다음이 `|---|`면.
    if(/^\s*\|/.test(l) && i + 1 < ls.length && /^\s*\|?\s*:?-{2,}/.test(ls[i + 1])){
      end();
      let h = '<div class="tbl"><table><tr>' + cells(l).map(c => '<th>' + c + '</th>').join('') + '</tr>';
      i += 2;
      while(i < ls.length && /^\s*\|/.test(ls[i])){ h += '<tr>' + cells(ls[i]).map(c => '<td>' + c + '</td>').join('') + '</tr>'; i++; }
      i--;
      out.push(h + '</table></div>');
      continue;
    }
    const h = l.match(/^\s*#{1,6}\s+(.+)$/);
    if(h){ end(); out.push('<div class="h">' + inline(h[1]) + '</div>'); continue; }
    if(/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)){ end(); out.push('<hr>'); continue; }
    const q = l.match(/^\s*&gt;\s?(.*)$/);
    if(q){ end(); out.push('<blockquote>' + inline(q[1]) + '</blockquote>'); continue; }
    const li = l.match(/^(\s*)([-*•]|(\d+)[.)])\s+(.*)$/);
    if(li){
      endPara();
      const tag = li[3] ? 'ol' : 'ul', depth = Math.min(3, Math.floor(li[1].length / 2));
      // 맨 바깥에서 글머리표 종류가 바뀌면 새 목록이다. 들여쓴 항목은 같은 목록 안에서 한 단 들여 앉힌다.
      if(list && depth === 0 && list.tag !== tag) endList();
      if(!list) list = {tag, html: '<' + tag + (li[3] && li[3] !== '1' ? ' start="' + li[3] + '"' : '') + '>'};
      else list.html += '</li>';
      list.html += '<li' + (depth ? ' class="d' + depth + '"' : '') + '>' + inline(li[4]);
      continue;
    }
    // 목록 바로 아래 들여쓴 줄은 그 항목이 이어지는 줄이다.
    if(list && /^\s{2,}\S/.test(l)){ list.html += '<br>' + inline(l.trim()); continue; }
    endList();
    para.push(l.trim());
  }
  end();
  return out.join('');
}
// 링크 — `[글](주소)`와 그냥 박힌 주소. **http·https만** 누르게 한다(위젯과 같다).
// 이미 이스케이프된 글자라 주소에 따옴표가 들어와도 속성을 못 깬다. 문장 끝 부호는 주소에서 뗀다.
// 마크다운 링크는 먼저 자리표(\u0001번호\u0001)로 빼 두어야 그냥 주소 규칙이 한 번 더 감싸지 않는다.
function links(p){
  const keep = [];
  p = p.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, (m, t, u) => '\u0001' + (keep.push('<a href="' + u + '" target="_blank" rel="noopener">' + t + '</a>') - 1) + '\u0001');
  p = p.replace(/https?:\/\/[^\s<`\u0001]+/g, u => {
    // `**주소**`·`**주소**에서` — 굵게 닫는 별표에서 끊는다. 뒤에 붙은 문장 부호·별표도 주소가 아니다(위젯 parseLinks와 같다).
    const stars = u.indexOf('**');
    const rest = stars > 0 ? u.slice(stars) : '';
    if(stars > 0) u = u.slice(0, stars);
    const tail = (u.match(/[.,;:!?*)\]}']+$/) || [''])[0];
    const url = tail ? u.slice(0, -tail.length) : u;
    return '<a href="' + url + '" target="_blank" rel="noopener">' + url + '</a>' + tail + rest;
  });
  return p.replace(/\u0001(\d+)\u0001/g, (m, n) => keep[+n]);
}
const BUSY = {thinking:1, working:1};
// 픽셀 얼굴 + 계층 모자. 시트의 첫 칸만 보인다(배경 크기 = 칸 수 × 100%).
function face(s){
  const w = el('span', 'px');
  w._s = s;
  if(s.sprite){
    w.style.backgroundImage = 'url("' + s.sprite + '")';
    w.style.backgroundSize = (s.frames * 100) + '% 100%';
  }
  if(s.hat && s.head != null){
    const h = el('img', 'hat'); h.src = s.hat; h.alt = '';
    h.style.top = (s.head - s.hatBottom) + 'px';
    if(s.headX != null) h.style.left = (s.headX - 32) + 'px';
    w.append(h);
  }
  animFace(w, Date.now());
  return w;
}
// 캐릭터 애니메이션 — 위젯 책상의 `_frameIndex`와 같은 규칙. 한 칸 180ms이고, 상태에 들어온 뒤
// 반복 구간 앞의 칸은 한 번만 지나가고 그 뒤로는 구간 안에서만 돈다. 모자는 칸마다 머리를 따라간다.
// 타이머 하나로 화면의 얼굴을 다 넘긴다(CSS 애니메이션으로는 칸별 모자 자리와 반복 구간을 못 맞춘다).
const motionOk = !matchMedia('(prefers-reduced-motion: reduce)').matches;
function animFace(w, now){
  const s = w._s;
  if(!s || !s.cells || s.cells.length < 2) return;
  let i = 0;
  // 퇴근한(tmux 없는) 세션은 첫 칸에 멈춘다 — 꺼진 세션이 움직이면 살아 있는 것처럼 보인다(대표 요청 9/17).
  if(motionOk && s.state !== 'ended'){
    const [start, end] = s.loop || [0, s.cells.length - 1];
    const ticks = Math.floor((now - (s.since ? new Date(s.since).getTime() : 0)) / 180);
    i = ticks < start ? Math.max(0, ticks) : start + (ticks - start) % Math.max(1, end - start + 1);
  }
  if(w._i === i) return;
  w._i = i;
  const c = s.cells[i] || s.cells[0];
  w.style.backgroundPosition = (s.cells.length > 1 ? -c[0] * 64 : 0) + 'px 0';
  const h = w.querySelector('.hat');
  if(h && c[1] != null){
    h.style.top = (c[1] - s.hatBottom) + 'px';
    if(c[2] != null) h.style.left = (c[2] - 32) + 'px';
  }
}
// ⚠️ **한글을 조합하는 중에는 캐릭터를 멈춘다**(v1.76.1). 일하는 세션의 얼굴이 0.18초마다 바뀌는데, 그 한 번의 스타일 변경만으로
// WKWebView가 조합을 끊어 대화 칸에 「ㅇㅣㄱㅓ」처럼 낱자가 박혔다(대표 제보 9/16 밤 — 세션이 일할 때만 생기고 쉴 때는 멀쩡했다).
if(motionOk) setInterval(() => { if(composing) return; const now = Date.now(); document.querySelectorAll('#duo .px').forEach(w => animFace(w, now)); }, 180);
// ── 새 답 표시 ── (대표 제보 9/16: 「답이 끝난 걸 애니메이션만으로는 알기 힘들다」)
// 완료는 초록 점 하나라 쉬는 중(대기)과 구분이 안 됐다. **아직 안 열어 본 완료**만 「새 답」 배지로 크게 알린다.
// 한 번 열어 보면 배지는 사라지고 예전처럼 점만 남는다 — 끝난 지 오래된 세션까지 배지를 달면 사무실이 온통 초록이 된다.
let seenDone = {};
try{ seenDone = JSON.parse(localStorage.getItem('cw_seen_done') || '{}') || {}; }catch(e){ seenDone = {}; }
function markSeen(s){
  if(!s || s.state !== 'done' || !s.since || seenDone[s.path] === s.since) return;
  seenDone[s.path] = s.since;
  try{ localStorage.setItem('cw_seen_done', JSON.stringify(seenDone)); }catch(e){}
}
function unseenDone(s){
  if(s.state !== 'done' || !s.since) return false;
  if(s.path === chat.path && chat.open){ markSeen(s); return false; }
  return seenDone[s.path] !== s.since;
}
// 자리 하나 = 사람 하나 + 그 앞의 책상. 이름은 발밑에 작게 붙인다(시안 D1, 대표 결정 9/18).
// ⚠️ 236px에 자리가 여섯이라 이름을 크게 적을 데가 없다. 그래서 8.5px로 적고, 긴 이름은 잘리되
// 손을 올리면 제목(title)에서 다 보인다. 이름을 아예 떼는 안(D2)은 캐릭터 그림이 다 달라야 성립해서 접었다.
function seatBtn(s, cls, at){
  const fresh = unseenDone(s);
  const b = el('button', 'seat ' + cls + ' s-' + s.state + (fresh ? ' unseen' : ''));
  b.type = 'button';
  b.setAttribute('aria-pressed', String(s.path === chat.path && chat.open));
  b.title = s.name + ' — ' + (fresh ? '답이 끝났다 · 눌러서 보기' : s.label);
  b.onclick = () => { chatFor(s.path); filterWho(s.path); };
  // 자리에 태스크를 놓으면 그 세션 대화를 열고 태스크 표시를 붙인다.
  b.addEventListener('dragover', e => { if(dragTask || dragDoc){ e.preventDefault(); b.classList.add('task-hot'); } });
  b.addEventListener('dragleave', () => b.classList.remove('task-hot'));
  b.addEventListener('drop', e => {
    if(dragDoc){
      e.preventDefault();
      const doc = dragDoc;
      drops();
      chatFor(s.path);
      setTimeout(() => insertDoc(doc), 80);
      return;
    }
    if(!dragTask) return;
    e.preventDefault();
    const t = dragTask;
    drops();
    chatFor(s.path);
    insertTask(t);
  });
  b.append(el('i', 'st-dot'), face(s));
  b.style.setProperty('--seat-x', (at || 0) + '');
  // 캐릭터마다 발밑 여백이 다르다 — 그만큼 더 내려 발을 책상 윗선에 붙인다.
  b.style.setProperty('--seat-foot', (s.foot || 0) + 'px');
  // 책상은 **캐릭터 앞**에 깔린다 — 앉아서 일하는 것처럼 보이고, 사람이 늘면 책상도 그만큼 는다.
  // 그림(`art/office/desk.png`)이 없으면 코드가 그린 나무 상판이 대신 뜬다.
  // 책상 — 벽 그림 아래쪽 띠가 곧 책상이다(대표 9/18). 그 띠를 자리마다 캐릭터 **앞에** 덮는다.
  const d = el('span', 'desk');
  b.append(d);
  // ⚠️ **모든 자리가 책상에 제 이름을 적는다**(리뷰 9/18). 팀장만 생략하고 층 이름으로 대신하던 때는
  // 같은 층에서 팀장은 큰 흰 글씨, 팀원은 작은 갈색 글씨가 되어 같은 지위가 달라 보였다.
  // 게다가 고른 자리만 이름이 나타나 자리가 들쭉날쭉했다.
  b.append(el('span', 'nm', s.agent === 'codex' ? s.name + ' (Cx)' : s.name));
  // 색만으로 가르지 않는다 — 대기·새 답·줄은 작은 표를 얹는다.
  if(s.state === 'waiting') b.append(el('span', 'mark', '!'));
  else if(fresh) b.append(el('span', 'mark ok', '답'));
  else if(s.queue) b.append(el('span', 'mark q', String(s.queue)));
  return b;
}
function drawOffice(){
  const tree = document.getElementById('tree');
  if(!tree || picking()) return;
  chatHold();
  try{ drawOfficeNow(tree); } finally { chatSettle(); }
}
// 층 규격과 어떤 그림이 들어와 있는지 — `art/office/layout.json`이 정한다(없으면 기본값).
// ⚠️ **그림 한 장이 다 정할 수 있어야 한다**(대표 결정 9/18). 서는 선·창문 자리를 그림에 맞춰 옮기고,
// 창문을 그림에 그려 넣었으면 코드가 그리던 유리는 물러난다.
const officeArt = {window: false, floor: false, boss: false};
async function askOfficeArt(){
  let j;
  try{ j = await (await fetch('/todo/art/office-layout', {cache: 'no-store'})).json(); }catch(e){ return; }
  if(!j) return;
  Object.assign(officeArt, j.art || {});
  const r = document.documentElement.style;
  const band = Math.max(8, j.band != null ? j.band : (j.height || 104) - (j.floorLine || 78));
  r.setProperty('--of-h', (j.height || 104) + 'px');
  r.setProperty('--of-band', band + 'px');
  // ⚠️ 층 제목은 **벽 위**에 둔다(대표 선택 9/18). 띠 안으로 내려 봤더니 이름 줄과 붙어 답답했다.
  // 제목 자리는 캐릭터를 책상 쪽으로 내려서(`charDrop`) 만든다.
  r.setProperty('--of-char-drop', ((j.charDrop == null ? 12 : j.charDrop)) + 'px');
  r.setProperty('--of-desk-h', ((j.desk && j.desk.h) || 24) + 'px');
  const w = j.window || {};
  r.setProperty('--of-win-w', (w.w || 48) + 'px');
  r.setProperty('--of-win-h', (w.h || 28) + 'px');
  r.setProperty('--of-win-right', (w.right || 8) + 'px');
  r.setProperty('--of-win-top', (w.top || 14) + 'px');
  drawOffice();
}
askOfficeArt();
function drawOfficeNow(tree){
  // 빈 사무실 — 처음 받은 사람은 여기가 텅 빈다. 무엇부터 할지 한 줄과 버튼으로 보인다(첫 실행 빈 화면 안내, 9/16).
  if(!chat.list.length){
    const w = el('div', 'starter office-empty');
    w.append(el('b', '', '아직 사무실이 비었다'), el('span', '', '폴더를 등록하면 그 폴더에서 켠 Claude Code 세션이 여기 앉는다.'));
    const go = el('button', 'go primary', '처음 설정 열기'); go.type = 'button'; go.onclick = () => setupSheet(false);
    w.append(go);
    tree.replaceChildren(w);
    return;
  }
  const teams = [];
  for(const s of chat.list){
    let t = teams.find(x => x.id === s.team);
    if(!t){ t = {id: s.team, name: s.teamName, top: s.top, lead: [], staff: []}; teams.push(t); }
    (s.tier === 'staff' ? t.staff : t.lead).push(s);
  }
  // 이사 층이 꼭대기, 그 아래 팀 층의 차례는 대표가 ▲▼로 정한다. 서버가 이미 그 차례로 보낸다.
  const order = [...teams.filter(t => t.top), ...teams.filter(t => !t.top)];
  const tod = officeTod();
  const bldg = el('div', 'bldg');
  order.forEach((t, gi) => {
    const g = el('div', 'team' + (t.top ? ' boss' : ''));
    // 벽 그림 — 없으면 서버가 404를 주고 코드가 그린 벽만 남는다.
    // 맨 위(이사)·맨 아래 층은 그림이 따로 있으면 그것을 쓴다 — 지붕과 1층은 모양이 다르다(대표 9/18).
    const last = gi === order.length - 1;
    const wallKind = (t.top && officeArt.boss) ? 'boss'
      : (last && officeArt.base) ? 'base'
      : officeArt.wall ? 'wall' : 'floor';
    g.style.setProperty('--floor-img', 'url(/todo/art/office?kind=' + wallKind + '&tod=' + tod + ')');
    // 책상을 따로 그려 줬으면(`desk.png`) 캐릭터 앞에 덮을 그림은 그것이다 — 없으면 벽 그림의 아래쪽 띠를 쓴다.
    if(officeArt.desk) g.style.setProperty('--desk-img', 'url(/todo/art/office?kind=desk&tod=' + tod + ')');
    // 층수는 **꼭대기부터 세지 않는다.** 이사가 맨 위이므로 맨 아래가 1층이다.
    // 이사 층은 층수 대신 R(옥상) — 「9F」 옆에 「이사」 꼬리표까지 붙으면 작은 회색 글자 뭉치가 된다(리뷰 9/18).
    g.append(el('span', 'no', t.top ? 'R' : String(order.length - gi) + 'F'));
    // ⚠️ **팀명 줄을 벽에 달지 않는다**(리뷰 9/18). 밝은 벽돌 위에서 안 읽혔고, 아래 책상의
    // 팀장 이름과 **같은 글자가 한 층에 두 번** 나왔다. 층 이름은 층수 칩과 팀장 이름이 대신한다.
    if(t.top) g.querySelector('.no').append(el('i', 'tag', '이사'));
    // 창문 그림은 벽과 따로 온다 — 시간대별로 갈아 끼우기 위해서다(대표 결정 9/18).
    const win = el('span', 'win');
    win.style.setProperty('--win-img', 'url(/todo/art/office?kind=window&tod=' + tod + ')');
    // 창문 그림이 있으면 그대로 얹는다. 없을 때만 — 그리고 벽 그림도 없을 때만 — 코드가 유리를 그린다.
    // 벽 그림만 있고 창문 그림이 없으면 창문은 벽에 그려져 있다고 본다.
    if(officeArt.window){ /* 그림이 얹힌다 */ }
    else if(!officeArt.floor && !officeArt.wall) win.classList.add('none');
    else win.style.display = 'none';
    g.append(win);
    if(!t.top){
      // 이사 층은 고정이라 옮길 것이 없다. 팀 층끼리만 자리를 바꾼다.
      const lift = el('span', 'lift');
      const first = gi === 1, last = gi === order.length - 1;
      for(const [dir, glyph, why] of [['up', '▲', '한 층 위로'], ['down', '▼', '한 층 아래로']]){
        const b = el('button'); b.type = 'button'; b.textContent = glyph; b.title = why;
        b.disabled = (dir === 'up' && first) || (dir === 'down' && last);
        b.onclick = async ev => { ev.stopPropagation(); if(await post('chat/floor', {team: t.id, dir})) chatSessions(); };
        lift.append(b);
      }
      g.append(lift);
    }
    if(officeArt.floor || officeArt.wall) g.classList.add('art');
    if(officeArt.desk) g.classList.add('deskart');

    g.append(el('span', 'band'));
    const all_ = [...t.lead, ...t.staff];
    // 한 층 = 가로 한 줄. 팀장이 먼저 앉고 그 옆에 팀원이 앉는다. 많으면 이 줄만 옆으로 민다.
    const row = el('div', 'row');
    let seatAt = 0;
    for(const s of t.lead) row.append(seatBtn(s, 'lead', seatAt++));
    // 접었을 때는 팀장만 남기고 나머지는 수로 — 층이 쌓인 모양은 그대로 둔다.
    if(chat.folded){
      const rest = t.staff.length + Math.max(0, t.lead.length - 1);
      if(rest) row.append(el('span', 'more-n', '+' + rest));
      while(row.children.length > 2) row.removeChild(row.children[1]);
    }else{
      for(const s of t.staff) row.append(seatBtn(s, 'staff', seatAt++));
    }
    g.append(row);
    // 책상은 층에 한 장 — 자리마다 자르지 않는다(대표 9/18 「책상이 옆에서 끊긴다」).
    if(officeArt.desk || officeArt.floor || officeArt.wall) g.append(el('span', 'deskstrip'));
    // 아무도 켜지 않은 층은 불을 끈다.
    if(all_.every(x => x.state === 'ended')) g.classList.add('dark');
    // 층 요약 — 빈 벽을 정보로 채운다. 일하는 중·대기·줄 선 것만 적고 아무 일도 없으면 비운다.
    const all = all_;
    const busyN = all.filter(x => BUSY[x.state]).length;
    const waitN = all.filter(x => x.state === 'waiting').length;
    const queueN = all.reduce((n, x) => n + (x.queue || 0), 0);
    const sum = el('span', 'sum');
    if(busyN) sum.append(el('span', '', '일하는 중 ' + busyN));
    if(waitN) sum.append(el('span', 'w', '대기 ' + waitN));
    if(queueN) sum.append(el('span', '', '줄 ' + queueN));
    // ⚠️ 아무 일도 없는 층에는 **아무것도 적지 않는다.** 사람 수를 적어 봤더니(9/20) 캐릭터가 이미
    // 말하고 있는 것을 글자로 되풀이하는 것이었다 — 일하는 중인지는 애니메이션이 말한다.
    g.append(sum);
    // 층 이름은 제목으로도 남긴다 — 이름이 잘렸을 때 손을 올리면 보인다.
    g.title = (t.name || '') + (t.staff.length ? ' · 팀원 ' + t.staff.length : '');
    bldg.append(g);
  });
  // ⚠️ 옛 지붕 띠(.bldg-roof)는 뺐다 — 벽 그림을 넣기 전 코드가 그리던 것이라, 그림이 들어온 뒤로는
  // 건물 위에 갈색 막대만 남아 「예전 디자인이 남은 것」으로 보였다(대표 제보 2026-09-20).
  tree.replaceChildren(bldg);
  // 자리가 칸을 넘으면 그 사실을 적는다 — 스크롤바를 숨겨 두어 더 있는지 알 길이 없었다(리뷰 9/18).
  requestAnimationFrame(() => {
    for(const g of bldg.children){
      const row = g.querySelector('.row');
      if(!row) continue;
      const over = row.scrollWidth - row.clientWidth;
      g.classList.toggle('more', over > 8);
      const old = g.querySelector('.rest');
      if(old) old.remove();
      if(over > 8 && !chat.folded){
        const hid = Math.max(1, Math.round(over / 44));
        g.append(el('span', 'rest', '+' + hid));
      }
    }
  });
  tree.classList.toggle('anim', motionOk);

  for(const c of ['tod-morning', 'tod-afternoon', 'tod-evening']) tree.classList.toggle(c, c === 'tod-' + tod);
}
// 지금이 아침인가 오후인가 저녁인가 — 6시·12시·18시에 바뀐다(대표 결정 9/18).
// 이 맥의 시계를 그대로 본다. 서버도 같은 기계라 맞출 것이 없다.
function officeTod(){
  const h = new Date().getHours();
  return h < 6 ? 'evening' : h < 12 ? 'morning' : h < 18 ? 'afternoon' : 'evening';
}
// 시간대가 넘어가는 순간을 놓치지 않게 1분마다 본다. 바뀔 때만 다시 그린다.
let lastTod = officeTod();
setInterval(() => { const t = officeTod(); if(t !== lastTod){ lastTod = t; drawOffice(); } }, 60000);
async function chatSessions(){
  let j;
  try{ j = await (await fetch('/todo/chat/sessions', {cache:'no-store'})).json(); }catch(e){ return; }
  if(!j.ok || composing) return;
  chat.list = j.sessions;
  if(!chat.path || !chat.list.some(s => s.path === chat.path)){
    // 처음 고를 세션: 승인 대기 → 이사 → 첫 세션
    const first = chat.list.find(s => s.state === 'waiting') || chat.list.find(s => s.tier === 'director') || chat.list[0];
    chat.path = first ? first.path : null;
    chat.sig = '';
    draftLoad();
    chatRemember();
  }
  drawOffice();
  drawHead();
}
function drawHead(){
  if(picking()) return;
  chatHold();
  try{ drawHeadNow(); } finally { chatSettle(); }
}
// ── 머리줄의 작은 창 ── (UI 리뷰 9/18에 셋으로 갈랐다 — ⋯ 메뉴·퇴근 확인·이름 바꾸기가 같은 틀을 쓴다)
// ⚠️ 창은 body에 붙인다. 머리(#dh)는 1.5초마다 갈아 끼워지므로 그 안에 두면 열자마자 사라진다.
function openMenu(anchor, build, cls){
  const old = document.getElementById('submenu'); if(old){ old.remove(); return null; }
  const m = el('div', 'submenu ' + (cls || '')); m.id = 'submenu';
  const r = anchor.getBoundingClientRect();
  m.style.top = (r.bottom + 6) + 'px'; m.style.right = Math.max(8, window.innerWidth - r.right) + 'px';
  build(m);
  document.body.append(m);
  setTimeout(() => document.addEventListener('click', function away(e){
    if(!m.contains(e.target)){ m.remove(); composing = false; document.removeEventListener('click', away); }
  }), 0);
  return m;
}
// 퇴근 — 되돌릴 수 없으니 한 겹 더 묻는다. 같은 버튼을 두 번 누르게 하면 글자가 길어져 자리가 밀린다(대표 제보 9/17).
function quitMenu(anchor, s, p){
  openMenu(anchor, m => {
    m.append(el('div', 'mi none', (p && p.busy ? '일하는 중이다 — ' : '') + s.name + ' 세션을 퇴근시킬까? 켜 둔 대화는 끝난다'));
    const yes = el('button', 'mi danger'); yes.type = 'button'; yes.append(el('b', '', '퇴근시키기'), el('small', '', 'tmux 세션을 내린다'));
    yes.onclick = () => { m.remove(); chatAct('quit', {}); };
    const no = el('button', 'mi'); no.type = 'button'; no.append(el('b', '', '취소'));
    no.onclick = () => m.remove();
    m.append(yes, no);
  }, 'quitmenu');
}
// 이름 바꾸기 — 보이는 이름만 바꾸고 폴더·tmux·캐릭터 그림은 그대로다(대표 요청 9/18).
// ⚠️ `prompt()`를 쓰지 않는다 — 앱 창(WKWebView)에서 대화상자가 뜨면 그 뒤 조작이 통째로 막힌다.
// 이름 바꾸기 — **머리의 이름 그 자리**를 글칸으로 바꾼다(대표 요청 9/20).
// ⚠️ 창을 따로 띄우던 때는 「어디서 바꾸는지」가 안 보였다. 이름에 커서가 깜빡이는 것이 가장 분명한 신호다.
function startRename(s){
  const dh = document.getElementById('dh');
  const nm = dh && dh.querySelector('.who .nm');
  if(!nm || chat.renaming) return;
  chat.renaming = true;                       // 고치는 동안 머리를 다시 그리지 않는다(1.5초마다 갈아 끼워진다)
  const box = document.createElement('input');
  box.type = 'text'; box.className = 'nm-edit'; box.maxLength = 30; box.value = s.name;
  box.placeholder = s.folder || s.name;
  box.title = '이 세션을 부를 이름 — 폴더 이름은 그대로다. Enter 저장 · Esc 취소';
  box.addEventListener('compositionstart', () => { composing = true; });
  box.addEventListener('compositionend', () => { composing = false; });
  let done = false;
  const finish = async (save) => {
    if(done) return;
    done = true; chat.renaming = false; composing = false;
    const v = box.value.trim();
    box.replaceWith(nm);
    if(save && v !== s.name){ if(await post('chat/rename', {path: s.path, name: v})) chatSessions(); }
    drawHead();
  };
  box.onkeydown = e => {
    if(e.isComposing) return;
    if(e.key === 'Enter'){ e.preventDefault(); finish(true); }
    if(e.key === 'Escape'){ e.preventDefault(); finish(false); }
  };
  box.onblur = () => finish(true);
  nm.replaceWith(box);
  box.focus(); box.select();
}
function renameMenu(anchor, s){
  const m = openMenu(anchor, m => {
    m.append(el('div', 'mi none', '이 세션을 부를 이름 — 폴더는 「' + (s.folder || s.name) + '」 그대로다. 세션에게도 바뀐 이름을 알린다'));
    const box = document.createElement('input');
    box.type = 'text'; box.className = 'rn-box'; box.maxLength = 30; box.value = s.name;
    box.placeholder = s.folder || s.name;
    // 한글 조합 중에는 다시 그리기를 막는다 — 다른 입력칸과 같은 규칙이다.
    box.addEventListener('compositionstart', () => { composing = true; });
    box.addEventListener('compositionend', () => { composing = false; });
    const save = async v => { m.remove(); composing = false; if(await post('chat/rename', {path: s.path, name: v})) chatSessions(); };
    box.onkeydown = e => {
      if(e.isComposing) return;
      if(e.key === 'Enter'){ e.preventDefault(); save(box.value); }
      if(e.key === 'Escape'){ m.remove(); composing = false; }
    };
    const ok = el('button', 'mi'); ok.type = 'button'; ok.append(el('b', '', '이 이름으로'));
    ok.onclick = () => save(box.value);
    const back = el('button', 'mi'); back.type = 'button';
    back.append(el('b', '', '폴더 이름으로 되돌리기'), el('small', '', s.folder || s.name));
    back.onclick = () => save('');
    m.append(box, ok, back);
  }, 'quitmenu rnmenu');
  if(m){ const b = m.querySelector('.rn-box'); b.focus(); b.select(); }
}
function drawHeadNow(){
  if(chat.renaming) return;   // 이름을 고치는 중에는 머리를 갈아 끼우지 않는다 — 치던 글자가 날아간다
  const s = chat.list.find(x => x.path === chat.path);
  const dh = document.getElementById('dh'), ctx = document.getElementById('ctx');
  if(!dh || !s) return;
  const who = el('span', 'who s-' + s.state);
  const dot = el('i', 'dot'); dot.title = s.label;
  const nameEl = el('b', 'nm', s.name);
  // 이름을 누르면 그 자리에서 고친다. ✎는 손을 올렸을 때만 나와 「고칠 수 있다」를 알린다.
  nameEl.title = '눌러서 이름 바꾸기 — 폴더 이름은 그대로다';
  nameEl.onclick = () => startRename(s);
  who.append(face(s), nameEl, el('i', 'nm-pen', '✎'), dot);
  if(s.agent === 'codex') who.append(el('span', 'agent-tag', 'Codex'));
  const p = chat.pane;
  // 모델 칩은 클로드 모델(/model)을 바꾸는 버튼이다 — 코덱스 세션에 보내면 다른 명령이 된다(9/17).
  const mb = s.agent === 'codex' ? null : modelButton(s, p);
  if(mb) who.append(mb);
  // 컨텍스트 크기·백그라운드 셸·에이전트·권한 모드 — 턴이 끝나도 남는 것이라 말풍선이 아니라 머리에 건다.
  const chips = el('span', 'chips');
  for(const c of (p && p.chips) || []) chips.append(el('span', 'chip', c));
  const tools = el('span', 'tools');
  // 멈추기는 일하는 중에만. 되돌릴 수 없는 일이 아니라(다시 시키면 된다) 겨누기 없이 한 번에 먹는다.
  if(p && p.busy && !p.choice){
    const st = el('button', 'stop', '■ 멈추기'); st.type = 'button'; st.title = '터미널의 esc'; st.disabled = chat.acting;
    st.onclick = () => chatAct('key', {key: 'Escape'});
    tools.append(st);
  }
  // 꺼진 세션이면 켜기를 머리에 크게 — 예전에는 「원본」 탭 안에만 있어 찾기 어려웠다(대표 요청 9/17).
  if(p && p.tmux && p.alive === false){
    // 쓰는 에이전트가 둘이면 버튼도 둘 — 무엇으로 켤지 고른다(9/17 코덱스).
    const both = agentsPref && agentsPref.claude && agentsPref.codex;
    const only = agentsPref && !agentsPref.claude && agentsPref.codex ? 'codex' : 'claude';
    const kinds = both ? [['claude', '▶ Claude로 출근'], ['codex', '▶ Codex로 출근']] : [[only, '▶ 출근시키기']];
    for(const [agent, label] of kinds){
      const on = el('button', 'launchbtn', chat.acting ? '출근하는 중' : label); on.type = 'button';
      on.title = '이 폴더에서 세션을 켠다(tmux 세션을 만들고 ' + agent + ' 실행)'; on.disabled = !!chat.acting;
      on.onclick = () => chatAct('launch', {agent});
      tools.append(on);
    }
  }
  // 원본 보기는 눌러 둔 채로 쓰는 것이라(켜면 화면이 통째로 바뀐다) 메뉴가 아니라 머리에 남긴다.
  const rb = el('button', 'rawbtn', '원본'); rb.type = 'button'; rb.title = '터미널 화면 그대로 보기';
  rb.setAttribute('aria-pressed', String(!!chat.raw)); rb.onclick = () => chatRaw();
  if(chat.raw) tools.append(rb);
  // ── ⋯ 더보기 ── (UI 리뷰 9/18)
  // ⚠️ **머리줄에 알약을 늘어놓지 않는다.** 이름·모델·컨텍스트·권한 칩에 버튼 다섯이 같은 테두리로 서니
  // 「지금 눌러야 하는 것」이 안 보였다. 늘 보이는 것은 멈추기·출근 같은 **급한 것**뿐이고 나머지는 여기 접는다.
  const more = el('button', 'rawbtn morebtn', '⋯'); more.type = 'button'; more.title = '이름·하위 세션·원본·퇴근';
  more.onclick = ev => {
    ev.stopPropagation();
    openMenu(more, m => {
      if(!chat.raw){
        const raw = el('button', 'mi'); raw.type = 'button';
        raw.append(el('b', '', '터미널 원본 보기'), el('small', '', '세션 화면을 그대로 떠온다'));
        raw.onclick = () => { m.remove(); chatRaw(); };
        m.append(raw);
      }
      const rn = el('button', 'mi'); rn.type = 'button';
      rn.append(el('b', '', '✎ 이름 바꾸기'), el('small', '', '폴더는 「' + (s.folder || s.name) + '」 그대로다'));
      rn.onclick = () => { m.remove(); startRename(s); };
      const sub = el('button', 'mi'); sub.type = 'button';
      sub.append(el('b', '', '＋ 하위 세션'), el('small', '', '이 폴더 안에 새 세션을 붙인다'));
      sub.onclick = () => { m.remove(); subMenu(more, s.path); };
      m.append(rn, sub);
      // 퇴근은 되돌릴 수 없어 한 겹 더 묻는다 — 메뉴 안에서도 바로 내리지 않는다.
      if(p && p.tmux && p.alive !== false){
        const off = el('button', 'mi danger'); off.type = 'button'; off.disabled = !!chat.acting;
        off.append(el('b', '', '퇴근'), el('small', '', (p.busy ? '일하는 중이다 · ' : '') + 'tmux 세션을 내린다'));
        off.onclick = () => { m.remove(); quitMenu(more, s, p); };
        m.append(off);
      }
    });
  };
  const x = el('button', 'ic'); x.textContent = '✕'; x.title = '대화 닫기'; x.onclick = () => chatToggle(false);
  tools.append(more, x);
  dh.replaceChildren(who, chips, tools);
  // 맥락은 있는 것만 — 진행중이 없고 줄도 비면 칸째 숨긴다.
  const rows = [];
  if(s.run){ const r = el('div', 'row'); r.append(el('span', 'k', '진행중'), el('span', 'v', s.run)); rows.push(r); }
  if(s.queue){ const r = el('div', 'row'); r.append(el('span', 'k', '줄'), el('span', 'v q', s.queueText || (s.queue + '건'))); rows.push(r); }
  ctx.replaceChildren(...rows);
  ctx.hidden = !rows.length;
  const box = document.getElementById('chat-text'), go = document.getElementById('chat-go');
  // ⚠️ 같은 글이라도 다시 넣으면 조합이 끊긴다 — 달라졌을 때만 넣는다.
  if(box){
    const off = p && p.tmux && p.alive === false;
    const ph = off ? '퇴근한 세션이다 — 위의 「▶ 출근시키기」를 누른다' : s.state === 'waiting' ? '승인을 기다리는 중 — 보내지 않는다' : BUSY[s.state] ? '일하는 중 — 보내면 줄에 선다 · Enter' : '보낼 말 — Enter 보내기 · Shift+Enter 줄바꿈';
    if(box.placeholder !== ph) box.placeholder = ph;
  }
  // 리뷰3 L7(9/17): 퇴근한 세션은 보낼 곳이 없다 — placeholder만 말하지 말고 버튼도 잠근다
  if(go && go.textContent !== '올리는 중') go.disabled = s.state === 'waiting' || chat.sending || !!(p && p.tmux && p.alive === false);
}
// 글을 끌어 고르는 중이면 다시 그리지 않는다.
// ⚠️ 대화 칸은 1.5~5초마다 다시 그리는데, 그때 고른 글이 통째로 새 조각으로 갈려 **선택이 풀린다.**
// 그래서 코드 상자(검은 라운드 박스)를 끌어 고르다 ⌘C를 누르면 아무것도 안 복사됐다(대표 제보 9/16).
// ⚠️ 한글을 조합하는 중에는 대화 칸도 손대지 않는다 — 머리(#dh)를 갈아 끼우거나 입력칸의 placeholder를 다시 넣기만 해도
// WebKit이 조합을 끊어 「가나다」가 「ㄱㅏㄴㅏㄷㅏ」로 박혔다(대표 화면 기록 9/16 15:49, 앱 창).
function picking(){
  if(typeof composing !== 'undefined' && composing) return true;
  const sel = document.getSelection();
  if(!sel || sel.isCollapsed || !sel.rangeCount) return false;
  const duo = document.getElementById('duo');
  return !!duo && duo.contains(sel.anchorNode) && duo.contains(sel.focusNode);
}
async function chatTick(){
  if(!chat.open || !chat.path || picking()) return;
  let j;
  try{
    j = await (await fetch('/todo/chat/log?path=' + encodeURIComponent(chat.path), {cache:'no-store'})).json();
  }catch(e){ return; }
  // 받는 사이에 조합을 시작했을 수 있다 — 받아 온 뒤에 한 번 더 본다.
  if(picking()) return;
  const log = document.getElementById('chat-log');
  if(!log) return;
  if(!j.ok){ log.replaceChildren(el('p', 'ch-empty', j.error || '못 읽었다')); chat.sig = ''; return; }
  const last = j.entries[j.entries.length - 1];
  const sig = chat.path + '|' + j.state + '|' + j.entries.length + '|' + (last ? last.at + last.text.length + (last.tools || '') : '');
  if(sig === chat.sig) return;
  chat.sig = sig;
  const rows = [];
  let tools = null;
  let last5 = null;
  for(const e of j.entries){
    if(e.kind === 'tool'){
      // 도구 줄은 잇달아 오면 한 묶음으로 접는다 — 한 턴에 수십 줄이라 대화가 묻힌다.
      if(!tools){ tools = el('details', 'ch-tools'); tools.append(el('summary')); tools.count = 0; rows.push(tools); }
      tools.count++;
      tools.append(el('div', 'ch-tool', e.text));
      // ⚠️ 접힌 제목에 명령 글자를 붙이지 않는다 — 어차피 잘려서 못 읽는데 말풍선만큼 자리를 먹었다(UI 리뷰 9/18).
      // 무슨 도구를 몇 번 썼는지까지만 내걸고, 명령은 펼쳤을 때 본다.
      const names = [...new Set([...tools.querySelectorAll('.ch-tool')]
        .map(d => (d.textContent.split(' · ')[0] || '').trim()).filter(Boolean))];
      tools.querySelector('summary').textContent = '⚙ 도구 ' + tools.count
        + (names.length ? ' · ' + names.slice(0, 3).join(' · ') : '');
      continue;
    }
    tools = null;
    // 백그라운드 작업이 끝났다는 시스템 알림도 「내가 한 말」로 들어온다. 말풍선으로 세우면
    // XML이 대화를 덮으므로 한 줄로 접는다(UI 리뷰 9/15).
    if(e.kind === 'mine' && /^\s*<task-notification>/.test(e.text)){
      const sum = (e.text.match(/<summary>([\s\S]*?)<\/summary>/) || [])[1];
      const d = el('details', 'ch-tools');
      d.append(el('summary', '', '▸ 백그라운드 알림 · ' + (sum || '작업이 끝났다').trim()), el('pre', 'ch-note', e.text.trim()));
      rows.push(d);
      continue;
    }
    const t = new Date(e.at);
    const hm = String(t.getHours()).padStart(2,'0') + ':' + String(t.getMinutes()).padStart(2,'0');
    // 시각은 말풍선마다가 아니라 **말이 한참 끊겼을 때만** 가운데 한 줄로(UI 리뷰 9/18).
    // 한 턴 안의 줄은 전부 같은 분이라 줄마다 적으면 노이즈다.
    if(last5 && t - last5 > 5 * 60000) rows.push(el('div', 'ch-gap', hm));
    last5 = t;
    // 선택창에서 고른 답은 말풍선이 아니라 작은 칩이다 — 내가 친 말과 구별된다.
    if(e.kind === 'chose'){
      const c = el('div', 'chose');
      c.append(el('i', '', '고름'), el('span', '', e.text));
      c.title = hm + ' · 선택창에서 고른 답';
      rows.push(c);
      continue;
    }
    const b = el('div', 'bub ' + (e.kind === 'mine' ? 'me' : 'ai'));
    const tx = el('div', 'ch-text');
    // 내 말은 친 그대로, 답은 마크다운 몇 가지(제목·굵게·코드)만 입힌다.
    if(e.kind === 'mine') tx.textContent = e.text; else tx.innerHTML = md(e.text);
    b.append(tx);
    b.append(el('div', 'ch-at', hm));
    rows.push(b);
  }
  if(!rows.length){
    const w = el('div', 'ch-empty');
    w.append(el('b', '', '아직 주고받은 말이 없다'));
    const tip = el('span');
    tip.append(document.createTextNode('아래에 적어 보낸다 · '), el('kbd', '', '/'),
      document.createTextNode(' 명령 · '), el('kbd', '', '@'),
      document.createTextNode(' 파일 · 할 일 카드를 끌어다 놓아도 된다'));
    w.append(tip);
    rows.push(w);
  }
  // ⚠️ 통째로 갈아 끼우면 펴 둔 도구 묶음이 접히고, 위로 올려 읽던 자리가 그 높이만큼 튀었다(대표 제보 9/16 「대화 칸이 왔다갔다」).
  // 같은 세션이면 펴 둔 묶음을 순서대로 도로 펴고, 맨 아래가 아니면 보고 있던 줄이 화면의 같은 높이에 남게 한다.
  const same = chat.fresh === chat.path;
  const openIdx = same ? [...log.children].map((c, i) => c.tagName === 'DETAILS' && c.open ? i : -1).filter(i => i >= 0) : [];
  log.replaceChildren(...rows);
  openIdx.forEach(i => { if(log.children[i] && log.children[i].tagName === 'DETAILS') log.children[i].open = true; });
  if(!same){ chat.stick = true; chat.fresh = chat.path; }
  chatSettle();
}
// ── 대화 목록 자리 지키기 ──
// ⚠️ 크롬은 위쪽 내용이 바뀌어도 보던 줄을 붙잡아 주는데(스크롤 앵커링) **사파리·앱 창(WKWebView)은 안 한다.**
// 그래서 브라우저에서는 멀쩡하고 앱 창에서만 대화 칸이 한 줄씩 위아래로 오갔다(대표 화면 기록 9/16 00:45 — 5초마다 28px).
// 다시 그릴 때마다 「지금 맨 아래인가」를 재면 그 순간의 흔들린 높이로 잘못 재므로, **사람이 스크롤한 순간에만** 맨 아래에 붙었는지와
// 보던 줄을 기억하고, 목록·말풍선·칸 크기가 바뀔 때마다(MutationObserver·ResizeObserver) 그 기억대로 되돌린다.
// ⚠️ 앱 창(WKWebView)에서는 머리(#dh)·사무실(#tree)을 갈아 끼우는 사이 목록 칸이 잠깐 커져 스크롤이 끝값으로 잘렸다가(36px)
// 머리가 돌아와도 그대로 남았다 — 5초마다(chatSessions) 대화가 한 줄씩 튄 진짜 원인(진단 로그 9/16 01:0x). 갈아 끼우는 동안
// 생기는 스크롤 신호는 사람이 한 것이 아니므로 무시하고(chatHold), 끝나면 기억대로 되돌린다(chatSettle).
function chatHold(){ chat.settling = true; }
function chatSettle(){
  const log = document.getElementById('chat-log');
  if(!log) return;
  chat.settling = true;
  if(chat.stick !== false) log.scrollTop = log.scrollHeight;
  else if(chat.anchor) chatRestore(log, chat.anchor);
  requestAnimationFrame(() => { chat.settling = false; });
}
(function(){
  const log = document.getElementById('chat-log');
  if(!log) return;
  log.addEventListener('scroll', () => {
    if(chat.settling) return;
    chat.stick = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
    chat.anchor = chat.stick ? null : chatAnchor(log);
  }, {passive: true});
  let queued = false;
  const later = () => { if(queued) return; queued = true; requestAnimationFrame(() => { queued = false; chatSettle(); }); };
  new MutationObserver(later).observe(log, {childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['open']});
  if(window.ResizeObserver){
    const ro = new ResizeObserver(later);
    ro.observe(log);
    const live = document.getElementById('ch-live'); if(live) ro.observe(live);
  }
})();
// 보고 있던 줄 — 목록 위 끝에 걸친 첫 줄의 순서와 화면 속 높이. 다시 그린 뒤 같은 줄을 같은 높이에 둔다.
// 화면(창) 기준 높이를 적는다 — 머리 줄(진행중·줄)이 생겨 목록 칸 자체가 내려가도 글자는 제자리에 남게.
function chatAnchor(log){
  const top = log.getBoundingClientRect().top;
  const kids = [...log.children];
  const i = kids.findIndex(c => c.getBoundingClientRect().bottom > top);
  return i < 0 ? null : {i, off: kids[i].getBoundingClientRect().top};
}
function chatRestore(log, a){
  const c = log.children[a.i];
  if(!c) return;
  log.scrollTop += c.getBoundingClientRect().top - a.off;
}
function chatKey(ev){
  if(menu.items.length && !ev.isComposing){
    if(ev.key === 'ArrowDown' || ev.key === 'ArrowUp'){
      ev.preventDefault();
      menu.sel = (menu.sel + (ev.key === 'ArrowDown' ? 1 : menu.items.length - 1)) % menu.items.length;
      showMenu(menu.kind, menu.token, menu.items);
      return;
    }
    if((ev.key === 'Enter' && !ev.shiftKey) || ev.key === 'Tab'){ ev.preventDefault(); pickMenu(menu.sel); return; }
    if(ev.key === 'Escape'){ ev.preventDefault(); hideMenu(); return; }
  }
  if(ev.key !== 'Enter' || ev.shiftKey || ev.isComposing) return;
  ev.preventDefault();
  chatSend(ev);
}
async function chatSend(ev){
  ev.preventDefault();
  const box = document.getElementById('chat-text');
  const text = box.value.trim();
  if(!text || !chat.path || chat.sending) return false;
  chat.sending = true;
  const go = document.getElementById('chat-go');
  go.disabled = true;
  const ok = await post('chat/send', {path: chat.path, text});
  chat.sending = false;
  go.disabled = false; go.textContent = '보내기';
  if(ok){ box.value = ''; draftSave(); hideMenu(); chat.sig = ''; chatTick(); chatSessions(); chatPane(); }
  box.focus();
  return false;
}
// ── 지금 화면 — 선택 카드 · 일하는 중 · 원본 · 칩 ── 위젯 메시지 탭과 같은 것(`/todo/chat/pane`).
// 대화가 열려 있는 동안만 1.5초마다 받는다. 무엇을 그릴지는 서버가 정하고 여기는 그리기만 한다.
async function chatPane(){
  if(!chat.open || !chat.path || chat.acting || composing) return;
  const path = chat.path;
  let j;
  try{
    j = await (await fetch('/todo/chat/pane?path=' + encodeURIComponent(path) + (chat.raw ? '&raw=1' : ''), {cache:'no-store'})).json();
  }catch(e){ return; }
  if(path !== chat.path || composing) return;
  chat.pane = j.ok ? j : null;
  // 창이 닫혔거나 바뀌었으면 겨눠 둔 것도 푼다 — 다음 창에서 한 번만 눌러 넘어가면 두 번 묻는 뜻이 없다.
  if(chat.armed && !(j.choice && j.choice.options.some(o => o.n === chat.armed.n && o.text === chat.armed.text))) chat.armed = null;
  drawLive();
  drawHead();
}
function ago(iso){
  const sec = Math.max(0, Math.round((Date.now() - new Date(iso)) / 1000));
  return sec < 60 ? sec + '초' : Math.floor(sec / 60) + '분 ' + String(sec % 60).padStart(2, '0') + '초';
}
setInterval(() => { if(composing) return; document.querySelectorAll('[data-since]').forEach(e => e.textContent = ago(e.dataset.since)); }, 1000);
function drawLive(){
  const live = document.getElementById('ch-live'), dock = document.getElementById('dock');
  if(!live || !dock || picking()) return;
  const p = chat.pane;
  dock.classList.toggle('raw-on', !!chat.raw);
  // 바뀐 것이 없으면 손대지 않는다 — 누르려던 버튼이 1.5초마다 새로 만들어지면 겨누기가 풀린다.
  const sig = JSON.stringify([chat.raw, chat.armed, chat.acting, p && [p.alive, p.busy, p.waiting, p.tool, p.label, p.since, p.activity, p.choice, p.slider, p.screen, chat.raw ? p.raw : 0]]);
  if(sig === live.dataset.sig) return;
  live.dataset.sig = sig;
  if(!p){ live.replaceChildren(); return; }
  if(chat.raw){ live.replaceChildren(rawView(p)); return; }
  const rows = [];
  if(p.choice) rows.push(choiceCard(p.choice));
  else if(p.slider) rows.push(sliderCard(p.slider));
  else if(p.screen && p.screen.length) rows.push(screenCard(p.screen));
  else if(p.busy) rows.push(busyBubble(p));
  // 훅은 승인 대기인데 화면을 못 떴다(세션 없음·tmux 없음) — 고를 수 없으니 어디서 고르는지만 알린다.
  else if(p.waiting){
    const w = el('div', 'wait-note');
    w.append(el('b', '', '승인 대기' + (p.tool ? ' — ' + p.tool : '')), el('span', '', p.alive ? '터미널 원본에서 고른다' : '세션 화면을 못 읽었다 — 터미널에서 고른다'));
    rows.push(w);
  }
  // 선택창이 아닌 채로 기다리는 중 — 「직접 적기(Type something)」를 고르면 여기로 온다.
  // ⚠️ 카드가 사라지면 대표에게는 멈춘 것처럼 보인다(제보 9/16). 무엇을 기다리는지와 적을 자리를 내준다.
  if(p.waiting && !p.choice && !p.slider){
    const t = el('div', 'wait-note type-note');
    t.append(el('b', '', '적어 주기를 기다린다'), el('span', '', '대화 칸에 쓰고 Enter — 그대로 세션에 간다'));
    const go = el('button', 'txtbtn', '여기에 적기');
    go.type = 'button';
    go.onclick = askType;
    t.append(go);
    rows.push(t);
  }
  live.replaceChildren(...rows);
  chatSettle();
}
function busyBubble(p){
  const b = el('div', 'bub ai busy');
  const top = el('div', 'bz');
  const dots = el('span', 'dots');
  dots.append(el('i'), el('i'), el('i'));
  top.append(dots, el('b', '', p.label || '일하는 중'));
  if(p.since){ const t = el('span', 'bz-t', ago(p.since)); t.dataset.since = p.since; top.append(t); }
  b.append(top);
  // 하는 일 줄은 늘 세 줄 높이 — 줄 수가 0·1·3으로 오갈 때마다 말풍선이 커졌다 줄어 대화 칸 전체가 위아래로 흔들렸다(9/16).
  const act = el('div', 'bz-act');
  for(const l of (p.activity || []).slice(-3)) act.append(el('div', 'mono1', l));
  b.append(act);
  return b;
}
function cardFrame(title, tone){
  const c = el('div', 'ccard ' + (tone || ''));
  const h = el('div', 'cc-h');
  const x = el('button', 'txtbtn', '취소 (esc)');
  x.type = 'button'; x.disabled = !!chat.acting;
  x.onclick = () => chatAct('key', {key: 'Escape'});
  h.append(el('b', '', title), x);
  c.append(h);
  return c;
}
function choiceCard(ch){
  const c = cardFrame(ch.multi ? '고를 것이 있다 — 여러 개 고를 수 있다'
    : (ch.preview && ch.preview.length) ? '고를 것이 있다 — 눌러서 미리보고, 한 번 더 누르면 고른다'
    : '고를 것이 있다 — 두 번 눌러서 고른다', 'gold');
  // 왜 묻는지가 먼저다 — 터미널 모양 그대로(표가 무너지지 않게 고정폭, 줄바꿈 없이 옆으로 민다).
  if(ch.lead && ch.lead.length) c.append(el('pre', 'cc-lead', ch.lead.join('\n')));
  // 한 번에 여러 개를 물을 때 — 터미널의 「← ☒ … ✔ Submit →」 줄 대신 문항 이름과 답했는지를 보여 준다(대표 제보 9/16).
  if(ch.tabs && ch.tabs.length){
    const bar = el('div', 'cc-tabs');
    bar.append(el('b', '', '물음 ' + (ch.tabAt || 1) + '/' + ch.tabs.length));
    ch.tabs.forEach((t, i) => {
      const now = (ch.tabAt || 1) === i + 1;
      const x = el('span', 'cc-tab' + (t.done ? ' done' : '') + (now ? ' now' : ''));
      x.append(el('i', '', t.done ? '✓' : now ? '▸' : '·'), el('span', '', t.label));
      if(now) x.title = '지금 묻는 것';
      bar.append(x);
    });
    bar.append(el('small', '', '왼쪽부터 차례로 묻는다 — 답하면 다음으로 넘어간다'));
    c.append(bar);
  }
  if(ch.question) c.append(el('div', 'cc-q', ch.question));
  // 미리보기가 붙은 창(시안 A, 대표 결정 9/15) — 왼쪽 선택지 · 오른쪽 커서가 놓인 선택지의 미리보기.
  // 한 번 누르면 겨누면서 터미널 커서를 그 선택지로 옮기고(고르기 아님) 화면을 다시 떠 미리보기가 바뀐다. 두 번째에 고른다.
  const withPreview = ch.preview && ch.preview.length && !ch.multi;
  const grid = el('div', withPreview ? 'cc-list' : 'cc-grid');
  for(const o of ch.options){
    const armed = chat.armed && chat.armed.n === o.n && chat.armed.text === o.text;
    const b = el('button', 'cc-opt' + (armed ? ' armed' : '') + (o.checked ? ' on' : ''));
    b.type = 'button'; b.disabled = !!chat.acting;
    b.append(el('span', 'n', String(o.n)));
    if(o.checked !== undefined) b.append(el('span', 'cb', o.checked ? '☑' : '☐'));
    const t = el('span', 'tx');
    t.append(el('span', 't', o.text));
    if(o.detail) t.append(el('span', 'd', o.detail));
    b.append(t);
    if(armed) b.append(el('em', '', '한 번 더'));
    // 체크박스는 한 번에 켜고 끈다(되돌리기 쉽다). 한 개 고르는 창은 겨누고 한 번 더 — 승인이 섞여 있다.
    if(withPreview && ch.cursor === o.n) b.classList.add('cur');
    // 「Type something」(직접 적기)은 고르고 나면 선택창이 닫히고 **터미널이 글자를 기다린다**.
    // 그때 카드가 사라져서 대표에게는 멈춘 것처럼 보였다(제보 9/16). 고른 뒤 대화 입력칸으로 데려간다.
    const typeIn = /type\s*something/i.test(o.text || '');
    if(typeIn) b.append(el('em', '', '직접 적기'));
    b.onclick = () => {
      if(o.checked !== undefined) return chatAct('toggle', {n: o.n, text: o.text});
      if(armed){
        chat.armed = null;
        return chatAct('choose', {n: o.n, text: o.text}).then(() => { if(typeIn) askType(); });
      }
      chat.armed = {n: o.n, text: o.text};
      if(withPreview && ch.cursor !== o.n) return chatAct('point', {n: o.n, text: o.text});
      drawLive();
    };
    grid.append(b);
  }
  if(withPreview){
    const split = el('div', 'cc-split');
    const pane = el('div', 'cc-pv');
    const cur = ch.options.find(o => o.n === ch.cursor);
    const ph = el('div', 'ph', '미리보기');
    if(cur) ph.append(document.createTextNode(' · '), el('b', '', cur.n + '. ' + cur.text));
    const pre = el('pre', '', ch.preview.join('\n'));
    pane.append(ph, pre);
    // 칸보다 넓으면(넓은 표) 옆으로 밀어 보라고 머리에 한마디 — 잘린 줄 알고 넘어가지 않게.
    requestAnimationFrame(() => pane.classList.toggle('wide', pre.scrollWidth > pre.clientWidth + 2));
    split.append(grid, pane);
    c.append(split);
  }else c.append(grid);
  if(ch.multi){
    const n = ch.options.filter(o => o.checked).length;
    const s = el('button', 'cc-submit', !ch.canSubmit ? '확정은 터미널 원본에서 (커서를 못 읽었다)'
      : ch.next ? (n ? '다음 문항으로 · ' + n + '개' : '아무것도 안 고르고 다음 문항으로')
      : (n ? '이걸로 확정 · ' + n + '개' : '아무것도 안 고르고 넘기기'));
    s.type = 'button'; s.disabled = !ch.canSubmit || !!chat.acting;
    // 아무것도 안 고른 채 넘기기는 눈에 띄는 버튼이 아니어야 한다 — 고르면 그때 금색으로 선다.
    if(!n) s.classList.add('quiet');
    s.onclick = () => chatAct('submit', {});
    c.append(s);
  }
  // 터미널 키 안내(Enter to select · ↑/↓ …)는 눌러 고르는 카드에서는 쓸모가 없다(UI 리뷰 9/15). 원본 보기에는 그대로 있다.
  return c;
}
function sliderCard(sl){
  const c = cardFrame(sl.title ? '고를 것이 있다 — ' + sl.title : '고를 것이 있다', 'violet');
  const row = el('div', 'cc-slide');
  sl.options.forEach((o, i) => {
    const b = el('button', 'cc-opt sm' + (i === sl.current ? ' armed' : ''), o);
    b.type = 'button'; b.disabled = i === sl.current || !!chat.acting;
    b.onclick = () => chatAct('slide', {i, label: o});
    row.append(b);
  });
  const ok = el('button', 'cc-submit', '이걸로 확정');
  ok.type = 'button'; ok.disabled = !!chat.acting;
  ok.onclick = () => chatAct('key', {key: 'Enter'});
  c.append(row, ok, el('div', 'cc-hint', sl.hint || '눌러서 옮기고 확정한다'));
  return c;
}
function screenCard(lines){
  const c = cardFrame('고를 것이 있다 — 터미널 원본에서 고른다', 'violet');
  c.append(el('pre', 'cc-lead', lines.join('\n')));
  const b = el('button', 'cc-submit', '원본 보기');
  b.type = 'button'; b.onclick = () => chatRaw(true);
  c.append(b);
  return c;
}
function rawView(p){
  if(!p.tmux) return el('p', 'ch-empty', 'tmux가 없다 — brew install tmux 로 설치하면 원본이 보인다.');
  if(!p.alive){
    const w = el('div', 'ch-empty');
    w.append(el('div', '', '떠 있는 세션이 없다 (' + p.session + ')'), el('div', '', '터미널에서 cw 로 띄워도 되고, 여기서 띄워도 된다.'));
    const b = el('button', 'go soft', '여기서 기동');
    b.type = 'button'; b.disabled = !!chat.acting;
    b.onclick = () => chatAct('launch', {});
    w.append(b);
    return w;
  }
  const old = document.querySelector('#ch-live .rawpre');
  const pre = el('pre', 'rawpre', p.raw || '불러오는 중');
  // 새로 그려도 읽던 자리를 지킨다. 맨 아래를 보고 있었으면 맨 아래에 붙는다.
  requestAnimationFrame(() => {
    if(!old || old.scrollHeight - old.scrollTop - old.clientHeight < 40) pre.scrollTop = pre.scrollHeight;
    else { pre.scrollTop = old.scrollTop; pre.scrollLeft = old.scrollLeft; }
  });
  return pre;
}
function chatRaw(on){
  chat.raw = on === undefined ? !chat.raw : on;
  try{ localStorage.setItem('cw_chat_raw', chat.raw ? '1' : '0'); }catch(e){}
  drawLive(); drawHead(); chatPane();
}
// 직접 적기로 넘어갔다 — 입력칸에 초점을 주고 무엇을 하는 중인지 알린다.
// ⚠️ 보내는 길은 평소와 같다(대화 입력칸 → 세션). 여기서 따로 붙이면 길이 둘이 된다.
function askType(){
  chat.open = true; chatApply();
  const box = document.getElementById('chat-text');
  if(box){ box.focus(); }
  if(typeof toast === 'function') toast('직접 적기로 넘어갔다 — 여기에 쓰고 Enter를 누른다', '', null);
}
async function chatAct(kind, body){
  if(!chat.path || chat.acting) return;
  chat.acting = true; drawLive(); drawHead();
  await post('chat/' + kind, Object.assign({path: chat.path}, body));
  chat.acting = false;
  chat.sig = '';
  await chatPane(); chatTick(); chatSessions();
}
setInterval(chatPane, 1500);

// ── 입력창 거들기 — `/` 명령 목록 · `@` 파일 · 붙여넣기 · 끌어다 놓기 ──
// 고르면 채우기만 하고 보내지 않는다 — 인자를 더 붙일 것이 있고, 눈으로 보고 Enter를 치는 편이 안전하다.
const menu = {items: [], sel: 0, kind: '', token: '', timer: 0};
function chatMenu(){
  const box = document.getElementById('chat-text');
  if(!box) return;
  const v = box.value;
  // 공백이 들어갔으면 이미 인자를 쓰는 중이다 — 그때 목록이 뜨면 방해만 된다.
  if(/^\/\S*$/.test(v)){
    return showMenu('slash', v, SLASH.filter(c => c.name.startsWith(v)).map(c => ({label: c.name, hint: c.hint, value: c.name + ' '})));
  }
  // 글 끝에 쓰다 만 `@…`만 받는다 — 중간 편집까지 따라가면 목록이 엉뚱한 자리에서 튀어나온다.
  // 위젯 입력창과 같게 글 끝의 `@…`만 본다 — 글자에 바로 붙여 쳐도(`문서@기획`) 잡는다.
  const at = v.match(/@([^\s@]*)$/);
  if(at && chat.path){
    const token = at[1], path = chat.path;
    clearTimeout(menu.timer);
    menu.timer = setTimeout(async () => {
      let j;
      try{ j = await (await fetch('/todo/chat/files?path=' + encodeURIComponent(path) + '&q=' + encodeURIComponent(token), {cache:'no-store'})).json(); }catch(e){ return; }
      if(!j.ok || box.value !== v) return;
      showMenu('file', token, j.files.map(f => ({label: f, value: v.slice(0, v.length - token.length - 1) + '@' + f + ' '})),
        token ? '「' + token + '」에 맞는 파일이 없다' : '이 세션 폴더에 고를 파일이 없다');
    }, 150);
    return;
  }
  hideMenu();
}
function showMenu(kind, token, items, emptyText){
  const m = document.getElementById('ch-menu');
  if(!m) return;
  // 아무것도 안 걸렸으면 조용히 닫지 않고 왜 비었는지 한 줄 — 안 그러면 기능이 안 도는 것처럼 보인다(대표 QA 9/15).
  // 안내 줄은 고를 것이 아니라 키(↑↓·Enter)를 가로채지 않는다.
  if(!items.length){
    if(!emptyText) return hideMenu();
    menu.items = []; menu.kind = kind; menu.token = token;
    m.replaceChildren(el('div', 'mi none', emptyText));
    m.hidden = false;
    return;
  }
  if(menu.kind !== kind || menu.token !== token) menu.sel = 0;
  Object.assign(menu, {items, kind, token});
  menu.sel = Math.min(menu.sel, items.length - 1);
  m.replaceChildren(...items.map((it, i) => {
    const b = el('button', 'mi' + (i === menu.sel ? ' on' : ''));
    b.type = 'button';
    b.append(el('b', '', it.label));
    if(it.hint) b.append(el('span', '', it.hint));
    b.onmousedown = e => { e.preventDefault(); pickMenu(i); };
    return b;
  }));
  m.hidden = false;
  m.children[menu.sel]?.scrollIntoView({block: 'nearest'});
}
function hideMenu(){
  const m = document.getElementById('ch-menu');
  if(m) m.hidden = true;
  menu.items = []; menu.kind = '';
}
function pickMenu(i){
  const box = document.getElementById('chat-text'), it = menu.items[i];
  if(!box || !it) return;
  box.value = it.value;
  hideMenu();
  box.focus();
  box.setSelectionRange(box.value.length, box.value.length);
}
// 태스크를 대화에 붙인다 — 열쇠(id)와 제목을 같이 넣어 세션이 목록을 훑지 않고 그 하나만 읽게 한다
// (대표 요청 9/15 — 찾는 데 토큰·시간이 든다). 세션 쪽 읽는 법은 규칙 문안 2절 `GET tasks?id=`.
function taskToken(t){
  return '[태스크 ' + t.id + '] 「' + t.title + '」' + (t.kids ? ' · 이 칸의 하위 ' + t.kids + '개' : '');
}
function insertTask(t){
  if(!t || !t.id) return;
  if(!chat.open) chatToggle(true);
  const box = document.getElementById('chat-text');
  if(!box) return;
  const v = box.value;
  box.value = (v && !/\s$/.test(v) ? v + '\n' : v) + taskToken(t) + '\n';
  box.focus();
  box.setSelectionRange(box.value.length, box.value.length);
}
// 끌어다 놓거나 붙여넣은 파일을 올리고 `@경로`를 글 끝에 박는다. 쓰던 글은 지우지 않는다.
async function chatUpload(files){
  const box = document.getElementById('chat-text'), go = document.getElementById('chat-go');
  if(!box || !chat.path || !files.length) return;
  go.disabled = true; go.textContent = '올리는 중';
  const tokens = [];
  for(const f of files){
    try{
      const r = await fetch('/todo/chat/upload?path=' + encodeURIComponent(chat.path) + '&name=' + encodeURIComponent(f.name || 'paste.png'), {method: 'POST', body: f});
      const j = await r.json();
      if(j.ok) tokens.push(j.token); else fail(j.error || '파일을 못 올렸다');
    }catch(e){ fail('위젯이 꺼져 있는 것 같다'); }
  }
  go.textContent = '보내기'; drawHead();
  if(!tokens.length) return;
  const v = box.value;
  box.value = (v && !/\s$/.test(v) ? v + ' ' : v) + tokens.join(' ') + ' ';
  box.focus();
  box.setSelectionRange(box.value.length, box.value.length);
}
// 앱 창(WKWebView)에서 끌어놓은 파일 — 앱이 진짜 경로를 넘겨준다(DashboardApp). 세션 폴더 아래면 상대경로로 줄인다.
function cwDropHint(on){
  const dock = document.getElementById('dock');
  if(dock && chat.open) dock.classList.toggle('drop-on', !!on);
  if(!on) document.querySelectorAll('.drop-in').forEach(e => e.classList.remove('drop-in'));
}
function cwDropAt(x, y){
  const el = document.elementFromPoint(x, y);
  const t = el && el.closest ? el.closest('textarea,input') : null;
  return dropOk(t) ? t : null;
}
function cwDropHover(x, y){
  const t = cwDropAt(x, y);
  if(dropBox && dropBox !== t) dropBox.classList.remove('drop-in');
  dropBox = t;
  if(dropBox) dropBox.classList.add('drop-in');
}
// 지금 파일이 떠 있는 글상자. 앱 창은 끌어놓기를 창 전체가 받으므로(desktop_drop) 어디에 놓았는지는
// 마우스가 지나간 자리로 기억한다 — 작업 내용·시킬 말 같은 글상자에 놓으면 그 자리에 경로가 들어간다(대표 요청 9/16).
let dropBox = null;
// 경로를 받을 수 있는 칸인가 — 글을 적는 칸은 모두(대표 요청 9/16), **찾기 칸만 뺀다**(거기 경로가 들어가면 목록이 빈다).
// 날짜·체크 같은 칸도 뺀다. 대화 입력칸은 따로 다룬다(@경로).
function dropOk(t){
  if(!t || t.disabled || t.readOnly) return false;
  if(t.id === 'q' || t.id === 'chat-text') return false;
  if(t.tagName === 'TEXTAREA') return true;
  if(t.tagName !== 'INPUT') return false;
  return ['text', 'search', ''].includes((t.type || '').toLowerCase()) && t.type !== 'search';
}
// 앱 창(WKWebView)에서는 반투명 흐림(backdrop-filter)을 끈다 — 흐림 층이 여럿이면 글자를 칠 때마다 다시 그리는 값이 커져
// 대화 칸 입력이 늦게 따라왔다(대표 제보 9/17, 흐림이 들어온 9/16 저녁부터). 브라우저는 그대로 둔다.
if(window.cwFocus) document.documentElement.classList.add('in-app');
document.addEventListener('dragover', e => {
  const t = e.target.closest && e.target.closest('textarea,input');
  if(dropBox && dropBox !== t) dropBox.classList.remove('drop-in');
  dropBox = dropOk(t) ? t : null;
  if(dropBox) dropBox.classList.add('drop-in');
}, true);
// 결론 문서를 지금 열린 세션 입력칸에 @경로로 붙인다 — 파일 끌어놓기와 같은 모양이다.
function insertDoc(path){
  if(dropBox) dropBox.classList.remove('drop-in');
  dropBox = null;
  cwDropPaths([path]);
  if(chat.open && chat.path) toast('결론 문서를 붙였다 — 보낼 말을 더 적고 Enter');
}
function cwDropPaths(paths, x, y){
  // 앱이 놓은 자리를 같이 주면 그 자리의 칸이 먼저다(브라우저는 좌표 없이 dragover로 기억한 칸을 쓴다).
  if(typeof x === 'number') dropBox = cwDropAt(x, y) || null;
  // 글상자 위에 놓았으면 거기에 경로를 넣는다. 적어 두는 자리라 **있는 그대로의 경로**를 넣는다(@는 세션에 보내는 표시라 안 붙인다).
  if(dropBox && document.contains(dropBox)){
    const t = dropBox;
    t.classList.remove('drop-in');
    const at = t.selectionStart ?? t.value.length, tail = t.value.slice(t.selectionEnd ?? at);
    const head = t.value.slice(0, at);
    // 한 줄짜리 칸(제목·링크 주소 같은 것)에는 줄을 못 바꾸므로 빈칸으로 잇는다.
    const one = t.tagName === 'INPUT';
    const ins = paths.map(x => (x || '').normalize('NFC')).join(one ? ' ' : '\n');
    const sep = head && !/\s$/.test(head) ? (one ? ' ' : '\n') : '';
    t.value = head + sep + ins + (tail ? (one ? ' ' : '\n') : '') + tail;
    t.focus();
    const end = (head + ins).length + 1;
    t.setSelectionRange(end, end);
    if(t.tagName === 'TEXTAREA') grow(t);
    // 적은 것은 바로 저장한다 — 상세창 글상자는 손을 뗄 때(blur) 저장하는데, 끌어놓기는 손을 떼는 일이 없다.
    t.dispatchEvent(new Event('input', {bubbles: true}));
    const save = t.getAttribute('onblur');
    if(save) new Function(save).call(t);
    return;
  }
  const box = document.getElementById('chat-text');
  if(!chat.open || !box || !chat.path){ fail('대화 칸을 열고 세션을 고른 뒤 거기에 놓는다'); return; }
  const nfc = x => (x || '').normalize('NFC').replace(/\/+$/, '');
  const root = nfc(chat.path);
  const tokens = paths.map(p => { const f = nfc(p); return '@' + (f.startsWith(root + '/') ? f.slice(root.length + 1) : f); });
  const v = box.value;
  box.value = (v && !/\s$/.test(v) ? v + ' ' : v) + tokens.join(' ') + ' ';
  box.focus();
  box.setSelectionRange(box.value.length, box.value.length);
}
(function(){
  const box = document.getElementById('chat-text'), dock = document.getElementById('dock');
  if(!box || !dock) return;
  box.addEventListener('paste', e => {
    const files = [...(e.clipboardData?.files || [])];
    if(!files.length) return;
    // 그림만 들어 있으면 붙일 글자가 없다. 글자도 같이 있으면 글자는 평소대로 붙고 경로가 뒤에 붙는다.
    if(!e.clipboardData.types.includes('text/plain')) e.preventDefault();
    chatUpload(files);
  });
  box.addEventListener('blur', () => setTimeout(hideMenu, 120));
  // 태스크 카드·줄·묶음 머리를 대화 칸에 놓으면 그 태스크 표시가 입력칸에 붙는다.
  dock.addEventListener('dragover', e => { if(dragTask || dragDoc){ e.preventDefault(); dock.classList.add('task-on'); } });
  dock.addEventListener('dragleave', e => { if(!dock.contains(e.relatedTarget)) dock.classList.remove('task-on'); });
  dock.addEventListener('drop', e => {
    if(dragDoc){
      e.preventDefault();
      const doc = dragDoc;
      drops();
      insertDoc(doc);
      return;
    }
    if(!dragTask) return;
    e.preventDefault();
    const t = dragTask;
    drops();
    insertTask(t);
  });
  let depth = 0;
  dock.addEventListener('dragenter', e => { if(e.dataTransfer?.types.includes('Files')){ depth++; dock.classList.add('drop-on'); } });
  dock.addEventListener('dragleave', () => { if(--depth <= 0){ depth = 0; dock.classList.remove('drop-on'); } });
  dock.addEventListener('dragover', e => { if(e.dataTransfer?.types.includes('Files')) e.preventDefault(); });
  dock.addEventListener('drop', e => {
    if(!e.dataTransfer?.files.length) return;
    e.preventDefault(); depth = 0; dock.classList.remove('drop-on');
    chatUpload([...e.dataTransfer.files]);
  });
})();
setInterval(chatTick, 2000);
setInterval(chatSessions, 5000);
// 붙는 머리의 높이를 재서 탭 줄이 그 아래에 붙게 한다(폭에 따라 머리가 두 줄이 되기도 한다).
(function(){
  const top = document.querySelector('header.top'); if(!top) return;
  const set = () => document.documentElement.style.setProperty('--top-h', (top.getBoundingClientRect().height - 10) + 'px');
  set();
  if(window.ResizeObserver) new ResizeObserver(set).observe(top);
})();
// 회의가 돌면 머리에 표시 — 회의 화면으로 가는 길(9/17). 회의 화면 자체에서는 안 단다.
async function mtgBadge(){
  const h1 = document.querySelector('header.top h1');
  const room = document.getElementById('mtg-room');
  if(!h1 && !room) return;
  let j; try{ j = await (await fetch('/todo/chat/meeting', {cache: 'no-store'})).json(); }catch(e){ return; }
  let hidden = ''; try{ hidden = localStorage.getItem('cw_mtg_hide') || ''; }catch(e){}
  if(j.ok && j.has && hidden === j.meeting.folder && !j.meeting.done) j = {ok: true, has: false};
  // 사무실 맨 아래 「회의실」 — 회의가 돌면 초록 점과 라운드·상태, 아니면 「회의 없음」(대표 요청 9/17)
  if(room){
    const live = j.ok && j.has && !j.meeting.done;
    room.classList.toggle('live', live);
    const st = document.getElementById('mtg-room-st');
    const txt = live ? 'R' + j.meeting.round + ' · ' + j.meeting.state : (j.ok && j.has ? '지난 회의 끝남' : '회의 없음');
    if(st && st.textContent !== txt) st.textContent = txt;
    room.title = live ? '회의 중 — ' + j.meeting.topic : '회의실 — 원탁·회의록 · 회의 시작';
  }
  if(!h1 || /view=meeting/.test(location.search)) return;
  const old = document.getElementById('mtg-badge');
  if(!j.ok || !j.has || j.meeting.done){ if(old) old.remove(); return; }
  const text = '회의 중 · R' + j.meeting.round + ' · ' + j.meeting.state;
  if(old){ if(old.dataset.t !== text){ old.dataset.t = text; old.lastChild.textContent = text; } return; }
  const a = el('a', 'mtg-badge'); a.id = 'mtg-badge'; a.href = '?view=meeting'; a.dataset.t = text; a.title = j.meeting.topic;
  a.append(el('i'), document.createTextNode(text));
  h1.after(a);
}
mtgBadge();
setInterval(mtgBadge, 5000);
// 알림을 누르면 서버가 그 세션 경로를 들고 있다 — 2초마다 물어 그 대화를 연다.
async function focusTick(){
  let j; try{ j = await (await fetch('/todo/chat/focus', {cache: 'no-store'})).json(); }catch(e){ return; }
  if(j.ok && j.path){ chatFor(j.path); const b = document.getElementById('chat-text'); if(b) b.focus(); }
}
setInterval(focusTick, 2000);
chatApply();
applyFolds();
// [임시 진단] ?dbg=scroll — 대화 목록 자리가 바뀔 때 무엇이 바뀌었는지 서버 로그로 보낸다(앱 창 흔들림 원인 찾기, 9/16).
(function(){
  const q = new URLSearchParams(location.search);
  if(q.get('dbg') !== 'scroll') return;
  if(q.get('chat')) chatFor(q.get('chat'));
  const muts = [];
  const dock = document.getElementById('duo');
  new MutationObserver(ms => ms.forEach(m => muts.push((m.target.id || m.target.className || m.target.nodeName) + ':' + m.type))).observe(dock, {childList: true, subtree: true, characterData: true, attributes: true});
  let prev = '';
  const t0 = Date.now();
  setInterval(() => {
    const log = document.getElementById('chat-log'), live = document.getElementById('ch-live'), dh = document.getElementById('dh'), ctx = document.getElementById('ctx');
    if(!log) return;
    const r = log.getBoundingClientRect();
    const first = [...log.children].find(c => c.getBoundingClientRect().bottom > r.top);
    const cur = [Math.round(log.scrollTop), log.scrollHeight, log.clientHeight, Math.round(r.top), Math.round(live.getBoundingClientRect().height), Math.round(dh.getBoundingClientRect().height), ctx.hidden ? 0 : Math.round(ctx.getBoundingClientRect().height), first ? Math.round(first.getBoundingClientRect().top) : -1, chat.stick, document.documentElement.scrollTop].join(',');
    if(cur !== prev){
      const uniq = [...new Set(muts.splice(0))].slice(0, 12).join(' ');
      fetch('/todo/debug', {method: 'POST', body: JSON.stringify({t: Date.now() - t0, m: cur, why: uniq})});
      prev = cur;
    } else muts.length = 0;
  }, 50);
})();
''';

/// 담당 값을 캐릭터 목록과 같은 모양으로. 세션이 `pwd`를 그대로 보내면 한글이
/// 풀어진 모양(NFD)으로 올 수 있어, 그대로 담으면 「시키기」가 캐릭터를 못 찾는다
/// (2026-09-14, 루트 세션이 만든 시험 태스크에서 실제로 났다).
String? _normAssignee(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  if (raw == kOwnerAssignee) return raw;
  final c = ProjectStore.composeHangul(raw.trim());
  return c.length > 1 && c.endsWith('/') ? c.substring(0, c.length - 1) : c;
}

/// 세션용 할 일 API. **노션 MCP·update_task.py 자리를 대신한다**(노션이사, 2026-09-14).
///
/// 모두 JSON이고 `cwd`(부르는 세션의 폴더)가 필수다 — 범위는 [ApiScope]가 정한다.
/// 답은 `{"ok": bool, "error": 문장|null, …}`.
///
/// ⚠️ **완료는 `ownerConfirmed: true`가 있을 때만 옮긴다.** 대표가 「완료처리해줘」라고
/// 했을 때만 세션이 그 표시를 붙인다(루트 CLAUDE.md 6번-5). 표시 없는 완료는 거절한다.
Future<Map<String, dynamic>> handleTaskApi(String method, String path,
    Map<String, String> query, Map data, Todos todos, ProjectDb db,
    SessionLog sessions, Map<String, String> pendingMemo) async {
  Map<String, dynamic> fail(String e) => {'ok': false, 'error': e};
  final cwd = (method == 'GET' ? query['cwd'] : data['cwd'] as String?) ?? '';
  final scope = ApiScope.of(cwd, db.all);
  if (scope == null) {
    return fail('cwd가 등록된 프로젝트 폴더가 아니다 — 프로젝트 목록에 폴더를 먼저 붙인다 ($cwd)');
  }
  // 가벼운 조회 — 제목·상태·담당·마감만. 본문(작업 내용·프롬프트)은 그 태스크를 열 때만 받는다.
  final summary = query['fields'] == 'summary';
  Map<String, dynamic> taskJson(TodoItem t) {
    final row = t.projectId == null ? null : db.byId(t.projectId!);
    final now = DateTime.now();
    // 하위 요약 — 상위면 진행률·하위 포함 시간, 하위면 상위 이름. 본문은 그 태스크를 열 때 받는다.
    final kids = TaskTree.childrenOf(todos.all, Todos.idOf(t));
    final prog = TaskTree.progress(kids);
    final tree = {
      if (t.parentId != null) 'parentId': t.parentId,
      if (t.parentId != null) 'parentText': todos.byId(t.parentId!)?.text,
      if (kids.isNotEmpty)
        'children': {
          'done': prog.done, 'total': prog.total,
          'spentMin': (TaskTree.spentAt(t, kids, now) / 60).round(),
          'ids': [for (final k in kids) Todos.idOf(k)],
        },
    };
    if (summary) {
      return {
        'id': Todos.idOf(t), 'text': t.text, 'status': t.status.name,
        'statusLabel': t.status.label, 'priority': t.priority.name,
        'projectId': t.projectId, 'projectName': row?.name,
        if (t.assignee != null) 'assignee': t.assignee,
        if (t.due != null) 'due': t.due!.toIso8601String().substring(0, 10),
        'ticking': t.ticking, 'spentMin': (t.spentAt(now) / 60).round(),
        ...tree,
      };
    }
    return {
      'id': Todos.idOf(t),
      ...t.toJson(),
      'statusLabel': t.status.label,
      'group': t.status.group.label,
      'projectName': row?.name,
      'spentMin': (t.spentAt(now) / 60).round(),
      'ticking': t.ticking,
      ...tree,
    };
  }
  Map<String, dynamic> scopeJson() => {
        'all': scope.all,
        if (scope.project != null) 'project': {'id': scope.project!.id, 'name': scope.project!.name},
      };
  TodoItem? mine(String id) {
    final t = todos.byId(id);
    return (t != null && scope.allows(t)) ? t : null;
  }

  if (method == 'GET') {
    switch (path) {
      case '/todo/api/tasks':
        final wanted = query['status'];
        // 대화에 붙은 `[태스크 <id>]`를 받은 세션은 목록을 훑지 않고 이것으로 그 하나만 읽는다(쉼표로 여럿).
        final ids = (query['id'] ?? '').split(',').where((x) => x.isNotEmpty).toSet();
        final list = todos.all.where(scope.allows).where((t) => ids.isEmpty || ids.contains(Todos.idOf(t))).where((t) =>
            wanted == null || wanted.isEmpty ||
            wanted.split(',').any((w) => TaskStatus.parse(w) == t.status && (w == t.status.name || w == t.status.label)));
        return {'ok': true, 'scope': scopeJson(), 'tasks': [for (final t in list) taskJson(t)]};
      case '/todo/api/projects':
        final rows = scope.all ? ProjectDbStore.sorted(db.all) : [scope.project!];
        return {'ok': true, 'scope': scopeJson(), 'projects': [for (final r in rows) r.toJson()]};
      // 프로젝트 기록 한 장 — 현황·기록·문서를 한 번에. 루트는 id를 준다, 그 밖은 자기 프로젝트다.
      case '/todo/api/projects/page':
        final row = scope.all ? db.byId(query['id'] ?? '') : scope.project;
        if (row == null) return fail(scope.all ? 'id가 필요하다' : '프로젝트를 못 찾았다');
        final askedId = query['id'] ?? '';
        if (!scope.all && askedId.isNotEmpty && askedId != row.id) return fail('자기 프로젝트만 읽는다');
        return {'ok': true, 'scope': scopeJson(), ...projectPageData(row, db, todos, sessions.all)};
      case '/todo/api/sessions':
        final date = query['date'] ?? '';
        final rows = sessions.all.where((r) => date.isEmpty || r.date == date).where((r) =>
            scope.all || r.projectId == scope.project!.id);
        return {
          'ok': true, 'scope': scopeJson(),
          'sessions': [for (final r in rows) r.toJson()],
          if (scope.all && date.isNotEmpty)
            'minutesByKind': SessionLogStore.minutesByKind(sessions.all, date, db.byId),
        };
    }
    return fail('없는 주소다');
  }

  final id = data['id'] as String? ?? '';
  switch (path) {
    case '/todo/api/tasks/add':
      // 하위 태스크 — parentId를 주면 그 상위의 프로젝트에 붙는다(한 단계뿐).
      final parentId = data['parentId'] as String? ?? '';
      if (parentId.isNotEmpty) {
        final parent = mine(parentId);
        if (parent == null) return fail('상위 태스크가 없거나 자기 프로젝트 것이 아니다');
        final refusal = TaskTree.parentRefusal(todos.all, '', parentId);
        if (refusal != null) return fail(refusal);
        // 진행사항을 안 주면 상위를 따른다 — 상위가 오늘예정·세션예정이면 같은 차례, 아니면 백로그(상세창과 같다).
        final status = data['status'] != null
            ? TaskStatus.parse(data['status'])
            : switch (parent.status) {
                TaskStatus.today || TaskStatus.sessionPlanned => parent.status,
                _ => TaskStatus.waiting,
              };
        if (status == TaskStatus.done) return fail('완료로 만들지 않는다');
        String? newId;
        todos.quietly(() => newId = todos.apiAdd(TodoItem(
          text: data['text'] as String? ?? '',
          project: parent.project,
          projectId: parent.projectId,
          status: status,
          priority: TaskPriority.parse(data['priority']),
          kind: TaskKind.parse(data['kind']),
          body: data['body'] as String? ?? '',
          content: data['content'] as String? ?? '',
          due: DateTime.tryParse(data['due'] as String? ?? ''),
          assignee: _normAssignee(data['assignee']) ?? parent.assignee,
          parentId: parentId,
        )));
        return newId == null ? fail('이름이 비었다') : {'ok': true, 'error': null, 'id': newId};
      }
      // 루트는 프로젝트를 골라 적고, 그 밖의 세션은 자기 프로젝트에만 적는다.
      final pid = data['projectId'] as String?;
      final row = scope.all ? (pid == null ? null : db.byId(pid)) : scope.project;
      if (row == null) return fail(scope.all ? 'projectId가 필요하다' : '프로젝트를 못 찾았다');
      // 세션이 바꾼 것은 대표 소식이 아니다 — 아래 쓰기는 모두 조용히 한다.
      if (!scope.all && pid != null && pid != row.id) return fail('자기 프로젝트에만 적는다');
      final status = TaskStatus.parse(data['status']);
      if (status == TaskStatus.done) return fail('완료로 만들지 않는다');
      String? newId;
      todos.quietly(() => newId = todos.apiAdd(TodoItem(
        text: data['text'] as String? ?? '',
        project: row.path ?? '',
        projectId: row.id,
        status: status,
        priority: TaskPriority.parse(data['priority']),
        kind: TaskKind.parse(data['kind']),
        body: data['body'] as String? ?? '',
        content: data['content'] as String? ?? '',
        due: DateTime.tryParse(data['due'] as String? ?? ''),
        assignee: _normAssignee(data['assignee']),
      )));
      return newId == null ? fail('이름이 비었다') : {'ok': true, 'error': null, 'id': newId};
    case '/todo/api/tasks/update':
      if (mine(id) == null) return fail('그 할 일이 없거나 자기 프로젝트 것이 아니다');
      final rawDue = data['due'] as String?;
      todos.quietly(() => todos.apiUpdate(id,
          text: data['text'] as String?,
          body: data['body'] as String?,
          content: data['content'] as String?,
          revisionNote: data['revisionNote'] as String?,
          priority: data.containsKey('priority') ? TaskPriority.parse(data['priority']) : null,
          kind: TaskKind.parse(data['kind']),
          assignee: _normAssignee(data['assignee']),
          due: (rawDue == null || rawDue.isEmpty) ? null : DateTime.tryParse(rawDue),
          clearDue: rawDue != null && rawDue.isEmpty));
      // 상위 붙이기·떼기 — 빈 글자면 뗀다. 상위도 자기 프로젝트 것이어야 한다.
      if (data['parentId'] is String) {
        final want = data['parentId'] as String;
        if (want.isNotEmpty && mine(want) == null) return fail('상위 태스크가 없거나 자기 프로젝트 것이 아니다');
        String? err;
        todos.quietly(() => err = todos.setParent(id, want));
        if (err != null) return fail(err!);
      }
      return {'ok': true, 'error': null};
    case '/todo/api/tasks/status':
      if (mine(id) == null) return fail('그 할 일이 없거나 자기 프로젝트 것이 아니다');
      final st = TaskStatus.parse(data['status']);
      if (st == TaskStatus.done && data['ownerConfirmed'] != true) {
        return fail('완료는 대표가 「완료처리해줘」라고 했을 때만 — ownerConfirmed: true를 붙인다');
      }
      final memo = data['memo'] as String?;
      if (memo != null) pendingMemo[id] = memo;
      todos.quietly(() => st == TaskStatus.running ? todos.startHeld(id) : todos.setStatus(id, st));
      // 하위가 남은 상위를 완료했으면 막지 않고 알린다 — 완료는 대표 말이다.
      final left = st == TaskStatus.done ? TaskTree.left(todos.all, todos.byId(id)!) : 0;
      return {'ok': true, 'error': null, if (left > 0) 'warning': '남은 하위 $left개가 아직 안 끝났다'};
    case '/todo/api/tasks/start':
      if (mine(id) == null) return fail('그 할 일이 없거나 자기 프로젝트 것이 아니다');
      // 세션이 스스로 시작한 시계는 턴 끝에 멈추지 않는다 — stop을 부를 때까지 돈다(대표 결정 9/15).
      todos.quietly(() => todos.startHeld(id));
      return {'ok': true, 'error': null};
    case '/todo/api/tasks/stop':
      final t = mine(id);
      if (t == null) return fail('그 할 일이 없거나 자기 프로젝트 것이 아니다');
      if (!t.ticking) {
        return fail('시계가 이미 멈춰 있다(지금 ${t.status.label}) — 다른 태스크를 시작했거나, 세션이 끝났거나, 대표가 화면에서 옮겼다. '
            '기록만 남기려면 tasks/update로 content를 적는다');
      }
      final st = data.containsKey('status') ? TaskStatus.parse(data['status']) : TaskStatus.review;
      if (st == TaskStatus.done && data['ownerConfirmed'] != true) {
        return fail('완료는 대표가 「완료처리해줘」라고 했을 때만 — ownerConfirmed: true를 붙인다');
      }
      final memo = data['memo'] as String?;
      if (memo != null) pendingMemo[id] = memo;
      todos.quietly(() => todos.setStatus(id, st == TaskStatus.running ? TaskStatus.review : st));
      return {'ok': true, 'error': null};
    // 결정 한 줄 덧붙이기 — 덮어쓰지 않고 맨 위에 붙인다. 대표가 방향을 정하면 세션이 올린다(지우는 것은 대표).
    case '/todo/api/projects/decision':
      final pid = data['projectId'] as String?;
      final row = scope.all ? (pid == null ? null : db.byId(pid)) : scope.project;
      if (row == null) return fail(scope.all ? 'projectId가 필요하다' : '프로젝트를 못 찾았다');
      if (!scope.all && pid != null && pid != row.id) return fail('자기 프로젝트에만 적는다');
      final text = (data['text'] as String? ?? '').trim();
      if (text.isEmpty) return fail('text가 비었다');
      final kind = data['kind'] == 'holds' ? 'holds' : 'decisions';
      // date(YYYY-MM-DD)를 주면 그날로 적는다 — 노션 등에서 옮기는 결정은 실제로 정한 날이 들어가야 찾는다. 없으면 오늘.
      final date = NoteEntry.dateOf(data['date'], DateTime.now().toIso8601String().substring(0, 10));
      if (date == null) return fail('date는 오늘까지의 YYYY-MM-DD다');
      db.setNote(row.id, (n) => n.added(kind, NoteEntry(
          date: date, text: text, why: (data['why'] as String? ?? '').trim())));
      return {'ok': true, 'error': null};
    // 적힌 결정·보류 한 줄 고치기 — 날짜·글·근거. index는 GET projects/page의 notes 목록 순서(0부터).
    // 지우고 다시 적으면 줄 번호가 밀려 여러 줄을 고칠 때 엉킨다 — 그래서 제자리 고치기를 따로 둔다.
    case '/todo/api/projects/decision/edit':
      final pid = data['projectId'] as String?;
      final row = scope.all ? (pid == null ? null : db.byId(pid)) : scope.project;
      if (row == null) return fail(scope.all ? 'projectId가 필요하다' : '프로젝트를 못 찾았다');
      if (!scope.all && pid != null && pid != row.id) return fail('자기 프로젝트에만 적는다');
      final kind = data['kind'] == 'holds' ? 'holds' : 'decisions';
      final index = (data['index'] as num?)?.toInt() ?? -1;
      final list = row.note.listOf(kind);
      if (index < 0 || index >= list.length) return fail('그 줄이 없다 — index는 0부터 ${list.length - 1}까지');
      final old = list[index];
      final want = data['text'] as String?;
      if (want != null && want.trim().isEmpty) return fail('text를 비울 수는 없다');
      // 줄 번호가 밀렸을 때 엉뚱한 줄을 고치지 않도록, expectText를 주면 그 글과 같을 때만 고친다.
      final expect = data['expectText'] as String?;
      if (expect != null && expect.trim() != old.text) return fail('그 줄의 글이 expectText와 다르다 — 다시 읽고 index를 확인한다');
      String? date = old.date;
      if (data.containsKey('date')) {
        date = NoteEntry.dateOf(data['date'], DateTime.now().toIso8601String().substring(0, 10));
        if (date == null) return fail('date는 오늘까지의 YYYY-MM-DD다');
      }
      final fixed = NoteEntry(
          date: date,
          text: want == null ? old.text : want.trim(),
          why: data.containsKey('why') ? (data['why'] as String? ?? '').trim() : old.why);
      db.setNote(row.id, (n) => n.editedAt(kind, index, (_) => fixed));
      final after = db.byId(row.id)!.note.listOf(kind);
      return {'ok': true, 'error': null, 'index': after.indexOf(fixed)};
    case '/todo/api/sessions/add':
      // 태스크에 안 걸린 시간(논의·규칙 정리)을 손으로 남긴다.
      final start = DateTime.tryParse(data['start'] as String? ?? '');
      final end = DateTime.tryParse(data['end'] as String? ?? '');
      if (start == null || end == null || !end.isAfter(start)) return fail('start·end가 필요하다(ISO-8601, end가 뒤)');
      final task = id.isEmpty ? null : mine(id);
      if (id.isNotEmpty && task == null) return fail('그 할 일이 없거나 자기 프로젝트 것이 아니다');
      final pid = task?.projectId ?? (scope.all ? data['projectId'] as String? : scope.project!.id);
      sessions.add(SessionRecord(
        id: 'm${start.microsecondsSinceEpoch}', start: start, end: end,
        taskId: task == null ? null : Todos.idOf(task), taskText: task?.text ?? '',
        projectId: pid, method: '수동', memo: data['memo'] as String? ?? ''));
      return {'ok': true, 'error': null};
  }
  return fail('없는 주소다');
}

/// 워쳐 진행사항을 노션 진행사항 이름으로 되돌린다. 노션에 없는 것은 가장 가까운 값이다.
String notionStatusOf(TaskStatus s) => switch (s) {
      TaskStatus.waiting => '시작 전',
      TaskStatus.today => '오늘예정',
      TaskStatus.sessionPlanned => '클로드코드작업',
      TaskStatus.running => '진행중',
      TaskStatus.review => '확인필요',
      TaskStatus.revision => '수정요청',
      TaskStatus.paused => '일시 중지',
      TaskStatus.done => '완료',
      TaskStatus.blocked => '일시 중지',
    };

/// 할 일을 CSV로. **노션 업적모음 칸 이름을 머리글로 쓴다** — 노션 가져오기가
/// 이름으로 칸을 맞춘다. 관계 칸은 노션에서 다시 이을 수 있게 이름을 글자로 넣는다.
///
/// 엑셀·노션이 한글을 깨뜨리지 않게 BOM을 붙인다.
String todosToCsv(List<TodoItem> items, ProjectDb db) {
  String cell(Object? v) {
    final t = v?.toString() ?? '';
    return (t.contains(',') || t.contains('"') || t.contains('\n'))
        ? '"${t.replaceAll('"', '""')}"'
        : t;
  }
  String day(DateTime? d) => d == null ? '' : d.toIso8601String().substring(0, 10);
  String time(DateTime? d) => d?.toIso8601String() ?? '';
  const head = [
    '이름', '진행사항', '워쳐 진행사항', '우선순위', '유형', '하위프로젝트', '담당',
    '마감일', '완료 날짜', '시작시간', '최근 중지 시간', '누적 시간(분)',
    '프롬프트', '작업 내용', '수정사항', '생성 일시', '노션 ID',
  ];
  final buf = StringBuffer('\u{FEFF}')..writeln(head.join(','));
  for (final t in items) {
    final row = t.projectId == null ? null : db.byId(t.projectId!);
    final who = t.assignee == null
        ? ''
        : (t.assignee == kOwnerAssignee ? '대표' : t.assignee!.split('/').last);
    buf.writeln([
      t.text, notionStatusOf(t.status), t.status.label, t.priority.label,
      t.kind?.label, row?.name ?? t.project.split('/').last, who,
      day(t.due), day(t.doneDate), time(t.startedAt), time(t.stoppedAt),
      (t.spentSec / 60).round(), t.body, t.content, t.revisionNote,
      time(t.at), t.notionId,
    ].map(cell).join(','));
  }
  return buf.toString();
}

/// 머리의 보기 바꾸기. 할 일(리스트·보드)과 근무기록이 같은 줄에 선다.
/// 「표」 보기는 뺐다 — 리스트가 그 자리를 한다(대표 결정 2026-09-15).
///
/// [keep]은 리스트·보드를 오갈 때 따라갈 선택(범위·프로젝트)이다. 다른 페이지에서
/// 넘어올 때는 비어 있고, 그때는 브라우저가 기억해 둔 선택을 되살린다(`kTodoJs`).
/// [gear]는 ⚙ 설정 메뉴에 그 페이지만의 줄을 더할 때 쓴다. 메뉴 자체는 **모든 페이지에 있다**(대표 요청 9/15).
String viewTabs(String on, {String keep = '', String gear = ''}) => '<span class="views">'
    '<span class="seg">'
    '<a href="?view=list$keep" class="${on == 'list' ? 'on' : ''}">리스트</a>'
    '<a href="?view=board$keep" class="${on == 'board' ? 'on' : ''}" title="공을 쥔 쪽으로 나눈 4칸">보드</a></span>'
    '<a href="?view=work" class="${on == 'work' ? 'on' : ''}">근무기록</a>'
    '<button class="theme-btn" title="밝게 · 어둡게" onclick="toggleTheme()">◐</button></span>'
    '${ClockButtons.html()}'
    '<details class="gear" id="f-gear"><summary title="설정">⚙</summary><div class="menu">'
    '<div class="mi-ver">Madang <b>$kVersion</b><small>${kIsDevInstance ? '확인용 판 · 포트 $kPort' : '설치본'}</small></div>'
    '<div class="mi-keys">단축키 <b>⌘F</b> 찾기(<b>/</b>도 된다) · <b>N</b> 새로 · <b>1 2 3</b> 리스트·보드·근무기록 · <b>Esc</b> 닫기 · <b>⌘Z</b> 되돌리기'
    '<small>글칸에 커서가 있을 때는 쉰다 · 되돌리기는 칸 이동·완료·지우기만</small></div>'
    // 리뷰3 M7(9/17): 항목 10개가 한 줄로 길어 화면 아래로 넘쳤다 — 보기 · 설정 · 내보내기 세 묶음 머리를 둔다.
    '<div class="mi-h">보기</div>'
    '<a href="?view=chat">대화만 보기 <small>가이드를 옆 창에 띄우고 쓴다 · 할 일 목록 없이 대화만</small></a>'
    '<a href="?view=meeting"${on == 'meeting' ? ' class="on"' : ''}>회의 <small>원탁 · 회의록 — 터미널 /회의가 굴리는 것을 본다</small></a>'
    '<a href="?view=usage"${on == 'usage' ? ' class="on"' : ''}>토큰 사용량 <small>남은 한도 · 세션별로 쓴 토큰(최근 7일)</small></a>'
    '<a href="?view=projects"${on == 'projects' ? ' class="on"' : ''}>프로젝트 관리 <small>이름·거래처·종류·폴더·상태 · 새 프로젝트</small></a>'
    '<button type="button" class="mi-btn" onclick="phoneSheet()">폰으로 보기 <small>QR을 찍으면 폰에서 열린다 · 같은 와이파이·테일스케일</small></button>'
    '<button type="button" class="mi-btn" onclick="post(\'app/open-browser\',{})">브라우저에서 열기 <small>같은 화면을 기본 브라우저로</small></button>'
    '<div class="mi-h">설정</div>'
    '<button type="button" class="mi-btn" onclick="setupSheet(false)">처음 설정 <small>tmux · Claude Code · 훅 · 지켜볼 폴더를 점검한다</small></button>'
    '${launchModeRow()}'
    '<div class="mi-h">내보내기</div>'
    '<a href="/todo/export.csv">CSV 내보내기 <small>표 프로그램·다른 도구로 옮길 수 있는 모양</small></a>'
    '$gear'
    // 켜는 모양 토글은 launchModeRow — 지금 값이 늘 보이는 두 칸(대표 QA 9/16). 프로젝트 관리는 탭에서 빼고 여기(대표 결정 9/15).
    '</div></details>';

/// ⚙ 메뉴의 「앱을 켜면」 토글 줄. 지금 값이 눌려 있다. 폰(열쇠 입구)에서도 보이지만 누르면 서버가 거절한다.
String launchModeRow() {
  if (!kWidgetMode) return '';
  final mode = LaunchModeStore.load();
  String b(String v, String label) =>
      '<button type="button" data-mode="$v" aria-pressed="${mode == v}" onclick="appMode(\'$v\')">$label</button>';
  return '<div class="mi-mode"><span>앱을 켜면</span><span class="seg2">${b('dashboard', '대시보드 창')}${b('widget', '바탕화면 위젯')}</span>'
      '<small id="app-mode">다음에 켤 때부터 이 모양으로 뜬다</small></div>';
}

/// 대화만 보는 한 장(`?view=chat`) — 화면을 반으로 갈라 **한쪽에 가이드(브라우저), 한쪽에 대화**를 두려고 만든다
/// (대표 요청 9/16). 할 일 목록·보드를 그리지 않으므로 창을 좁혀도 대화가 넓게 남는다.
///
/// 판은 대시보드와 **같은 조각**을 쓴다(`#duo`) — 대화 칸을 두 벌로 만들면 한쪽만 고치는 일이 생긴다.
String chatOnlyPageHtml() => '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>대화 · Madang</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss
/* 대화만 보기 — 판이 창을 가득 채운다. 머리 줄은 돌아갈 길과 보기 바꾸기만 남긴다. */
body.chat-only{padding:0;overflow:hidden}
.chat-only .cbar{display:flex;align-items:center;gap:8px;padding:8px 12px;border-bottom:1px solid var(--line);background:var(--panel)}
.chat-only .cbar b{font-size:13px;font-weight:800}
.chat-only .cbar .sp{margin-left:auto;display:flex;gap:6px;align-items:center}
.chat-only .duo{position:fixed;top:45px;right:0;bottom:0;left:0;border-radius:0;border:0;box-shadow:none}
.chat-only .dock{display:flex !important;flex:1}
/* 좁은 창에서도 사무실은 남긴다 — 여기서 세션을 고르는 것이 이 화면의 절반이다(접기 단추로 58px까지 줄인다) */
.chat-only .office{display:flex !important}
.chat-only .dock-grip{display:none}
</style></head><body class="chat-only">
$kThemeBoot
<div class="cbar"><b>대화</b><span class="faint">가이드를 옆 창에 띄우고 쓰라고 만든 화면이다</span>
<span class="sp"><a class="csv" href="?view=list">← 할 일로</a>
<button class="theme-btn" title="밝게 · 어둡게" onclick="toggleTheme()">◐</button></span></div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
// 대화만 보는 화면에서는 늘 펴 둔다 — 접는 버튼이 있으면 빈 화면이 된다.
chat.open = true;
chatApply();
</script></body></html>''';

/// 사무실+대화 판 — 할 일·대화만 보기·근무기록이 **같은 조각**을 쓴다.
///
/// ⚠️ 판을 페이지마다 베껴 두면 한쪽만 고치는 일이 생긴다(실제로 두 벌이 돌아다녔다). 한 곳에서 고친다.
const String kDuoHtml = '''<aside id="duo" class="duo" aria-label="사무실과 대화">
<section class="office" id="office"><div class="oh"><b>사무실</b><button class="talk" type="button" onclick="chatToggle()" title="세션과 주고받은 대화 — 위젯의 메시지 탭">대화</button><button class="ic fold" id="ofold" onclick="officeFold()" title="사무실 접기">⟩</button></div>
<div class="tree" id="tree"></div><a class="mtg-room" id="mtg-room" href="?view=meeting" title="회의실 — 원탁·회의록 · 회의 시작"><i class="dot"></i><span class="txt"><b>회의실</b><small id="mtg-room-st">회의 없음</small></span></a></section>
<section class="dock" id="dock"><div class="dock-grip" id="dock-grip" title="끌어서 대화 칸 너비 바꾸기 · 두 번 누르면 기본"></div><div class="dh" id="dh"></div><div class="ctx" id="ctx" hidden></div>
<div class="ch-log" id="chat-log"></div><div class="ch-live" id="ch-live"></div>
<form class="ch-in" onsubmit="return chatSend(event)"><div class="ch-menu" id="ch-menu" hidden></div>
<textarea id="chat-text" rows="2" placeholder="보낼 말 — Enter 보내기 · Shift+Enter 줄바꿈" onkeydown="chatKey(event)" oninput="chatMenu(); draftSave()"></textarea>
<button type="submit" class="go primary" id="chat-go">보내기</button></form></section>
</aside>''';

/// 남은 한도를 원 그래프로. 대시보드 머리(작게)와 토큰 사용량 페이지(크게)가 같은 것을 쓴다(대표 요청 9/16).
///
/// 누르면 토큰 사용량 페이지로 간다. 원 안에 %를, 아래에 **초기화까지 남은 시간**을 함께 보여 준다 —
/// 남은 시간이 안 보이면 「78%」가 급한 건지 아닌지 알 수 없다.
String limitDonuts(LimitStore? limits, {required bool big}) {
  final lim = limits;
  if (lim == null || !lim.has) {
    return big
        ? '<p class="nil">아직 받은 값이 없다 — 상태줄이 붙은 세션이 한 턴 돌면 채워진다.</p>'
        : '';
  }
  String one(LimitWindow? w, String label) {
    if (w == null) return '';
    final pct = w.percent.clamp(0, 100).toDouble();
    final tone = pct >= 90 ? ' hot' : pct >= 70 ? ' warm' : '';
    // 둘레 = 2πr. r을 16으로 두면 100.53 — 채운 만큼만 그리고 나머지는 비운다.
    final dash = (100.53 * pct / 100).toStringAsFixed(1);
    return '<span class="donut$tone" title="$label · ${w.percent.round()}% · ${w.leftText} 뒤 다시 참">'
        '<svg viewBox="0 0 40 40" aria-hidden="true">'
        '<circle class="bg" cx="20" cy="20" r="16"></circle>'
        '<circle class="fg" cx="20" cy="20" r="16" stroke-dasharray="$dash 100.53"></circle></svg>'
        '<b>${w.percent.round()}<i>%</i></b>'
        '<span class="dl">$label</span><span class="dt">${w.leftText}</span></span>';
  }

  final inner = '${one(lim.fiveHour, '5시간')}${one(lim.sevenDay, '7일')}${one(lim.spend, '지출')}';
  if (inner.isEmpty) return '';
  return '<a class="donuts${big ? ' big' : ''}" href="?view=usage" title="누르면 토큰 사용량 자세히 보기">$inner'
      '${lim.stale ? '<span class="dstale" title="두 시간 넘게 소식이 없다">오래됨</span>' : ''}</a>';
}

/// 토큰 사용량 한 장 — 남은 한도와 세션별로 쓴 토큰(대표 요청 9/16).
///
/// 값은 위젯이 이미 들고 있는 것을 그대로 쓴다. 사용량은 transcript를 훑어 모은 것([UsageStore]),
/// 남은 한도는 상태줄이 보내 준 것([LimitStore])이다. 돈은 **API 정가**라 구독 청구액이 아니다.
String usagePageHtml(UsageStore? usage, LimitStore? limits) {
  String n(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(v >= 10000000 ? 0 : 1)}M'
      : v >= 1000
          ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k'
          : '$v';
  String money(double v) => v >= 100 ? '\$${v.round()}' : '\$${v.toStringAsFixed(2)}';

  final cells = usage?.cells ?? const <UsageCell>[];
  final today = DateTime.now().toIso8601String().substring(0, 10);
  final weekAgo = DateTime.now().subtract(const Duration(days: 6)).toIso8601String().substring(0, 10);

  // 세션(폴더)별로 오늘·이번 주를 모은다. 돈은 단가를 아는 모델만 더한다.
  final byCwd = <String, ({UsageTally day, UsageTally week, double dayCost, double weekCost, bool unknown})>{};
  final models = <String, UsageTally>{};
  for (final c in cells) {
    if (c.day.compareTo(weekAgo) < 0) continue;
    final cur = byCwd[c.cwd] ??
        (day: UsageTally(), week: UsageTally(), dayCost: 0.0, weekCost: 0.0, unknown: false);
    final cost = ModelPrice.cost(c.model, c.tally);
    final isDay = c.day == today;
    cur.week.add(c.tally);
    if (isDay) cur.day.add(c.tally);
    byCwd[c.cwd] = (
      day: cur.day,
      week: cur.week,
      dayCost: cur.dayCost + (isDay ? (cost ?? 0) : 0),
      weekCost: cur.weekCost + (cost ?? 0),
      unknown: cur.unknown || cost == null,
    );
    (models[c.model] ??= UsageTally()).add(c.tally);
  }
  final rows = byCwd.entries.toList()
    ..sort((a, b) => b.value.week.total.compareTo(a.value.week.total));
  final weekAll = UsageTally();
  var weekCost = 0.0;
  final dayAll = UsageTally();
  var dayCost = 0.0;
  for (final e in rows) {
    weekAll.add(e.value.week);
    dayAll.add(e.value.day);
    weekCost += e.value.weekCost;
    dayCost += e.value.dayCost;
  }

  final lim = limits;
  final limHtml = limitDonuts(lim, big: true) +
      (lim != null && lim.has && lim.stale
          ? '<p class="nil">두 시간 넘게 소식이 없다 — 세션이 다 닫혔거나 상태줄이 빠졌을 수 있다.</p>'
          : '');

  // 폴더 이름만 쓰면 `scripts`처럼 겹치는 것이 여럿이라 어느 세션인지 모른다 — 겹치면 윗 폴더까지 보여 준다.
  final seen = <String, int>{};
  for (final k in byCwd.keys) {
    final b = k.split('/').where((x) => x.isNotEmpty).lastOrNull ?? k;
    seen[b] = (seen[b] ?? 0) + 1;
  }
  String row(String cwd, ({UsageTally day, UsageTally week, double dayCost, double weekCost, bool unknown}) v) {
    final parts = cwd.split('/').where((x) => x.isNotEmpty).toList();
    final base = parts.isEmpty ? cwd : parts.last;
    final name = (seen[base] ?? 0) > 1 && parts.length > 1 ? '${parts[parts.length - 2]}/$base' : base;
    return '<tr><td class="who">${htmlEscape(name)}</td>'
        '<td>${n(v.day.total)}</td><td>${v.day.calls}</td><td>${money(v.dayCost)}</td>'
        '<td>${n(v.week.total)}</td><td>${v.week.calls}</td>'
        '<td>${money(v.weekCost)}${v.unknown ? '<i title="단가를 모르는 모델이 섞여 있다">+</i>' : ''}</td></tr>';
  }

  final table = rows.isEmpty
      ? '<p class="nil">${usage == null || !usage.ready ? '아직 다 훑지 못했다 — 처음 한 번은 몇십 초 걸린다.' : '이번 주에 쓴 기록이 없다.'}</p>'
      : '<div class="uscroll"><table class="ut"><tr><th>세션</th><th>오늘 토큰</th><th>오늘 호출</th><th>오늘 돈</th>'
          '<th>이번 주 토큰</th><th>주 호출</th><th>주 돈</th></tr>'
          '${rows.map((e) => row(e.key, e.value)).join()}'
          '<tr class="sum"><td>합계</td><td>${n(dayAll.total)}</td><td>${dayAll.calls}</td><td>${money(dayCost)}</td>'
          '<td>${n(weekAll.total)}</td><td>${weekAll.calls}</td><td>${money(weekCost)}</td></tr></table></div>';

  final byModel = models.entries.toList()..sort((a, b) => b.value.total.compareTo(a.value.total));
  final modelHtml = byModel.isEmpty
      ? ''
      : '<div class="mods">${byModel.take(6).map((e) => '<span class="mod"><b>${htmlEscape(e.key)}</b>${n(e.value.total)}</span>').join()}</div>';

  final scanned = usage?.scannedAt;
  return '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>토큰 사용량</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss
.usage{max-width:1100px}
.ublock{background:var(--panel);border:1px solid var(--line);border-radius:18px;box-shadow:var(--shadow-card);padding:14px 16px;margin:0 0 14px}
.ublock h2{font-size:14px;font-weight:800;margin:0 0 10px;display:flex;align-items:center;gap:8px}
.ublock h2 .tag{font-size:11px;font-weight:700;color:var(--faint);background:var(--hover);border-radius:999px;padding:1px 8px}

.uscroll{overflow-x:auto}
.ut{width:100%;min-width:660px;border-collapse:collapse;font-size:13px}
.ut th{text-align:right;font-size:12px;color:var(--faint);font-weight:700;padding:0 0 8px;white-space:nowrap}
.ut th:first-child{text-align:left}
.ut td{text-align:right;padding:7px 0;border-top:1px solid var(--line);font-variant-numeric:tabular-nums}
.ut td.who{text-align:left;font-weight:700}
.ut tr.sum td{font-weight:800;border-top:2px solid var(--line2)}
.ut i{font-style:normal;color:var(--faint)}
.mods{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px}
.mod{font-size:12px;color:var(--dim);background:var(--hover);border-radius:999px;padding:2px 10px;display:flex;gap:6px}
.mod b{color:var(--fg);font-weight:700}
</style>$kThemeBoot</head><body>
<header class="top"><h1>토큰 사용량</h1>${viewTabs('usage')}</header>
<div class="usage">
<section class="ublock"><h2>남은 한도 <span class="tag">상태줄이 보내 준다</span></h2>$limHtml</section>
<section class="ublock"><h2>세션별로 쓴 것 <span class="tag">최근 7일</span></h2>$table$modelHtml
<p class="nil">돈은 <b>API 정가로 셈한 값</b>이라 구독 청구액이 아니다. 캐시 읽기까지 더한 토큰 수다.
${scanned == null ? '' : '마지막 훑기 ${scanned.hour.toString().padLeft(2, '0')}:${scanned.minute.toString().padLeft(2, '0')}'}</p></section>
</div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
</script></body></html>''';
}

/// 근무기록에서 쓰는 사람마다 다른 값 — `work_settings.json`(설정 자리, gitignore).
///
/// ⚠️ 예전엔 「무위다라니(시간)」「월 130시간 대비」가 코드에 박혀 있었다 — 한 회사의 규칙이라
/// 남이 받아 쓰면 뜻이 없다(오픈소스 보안 점검 9/16). 기본은 「본업 시간」이고 월 목표는 **꺼져 있다**.
///
/// ```json
/// { "mainLabel": "본업 시간", "monthlyTargetHours": 130 }
/// ```
class WorkSettings {
  const WorkSettings({this.mainLabel = '본업 시간', this.monthlyTargetHours});
  final String mainLabel;
  /// 월 목표 시간. 없으면 「월 N시간 대비」 칸을 안 그린다.
  final double? monthlyTargetHours;

  static WorkSettings load() {
    try {
      final f = File(resolveConfigPath('work_settings.json'));
      if (!f.existsSync()) return const WorkSettings();
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return const WorkSettings();
      final label = (j['mainLabel'] as String?)?.trim();
      final target = (j['monthlyTargetHours'] as num?)?.toDouble();
      return WorkSettings(
        mainLabel: label == null || label.isEmpty ? '본업 시간' : label,
        monthlyTargetHours: target != null && target > 0 ? target : null,
      );
    } catch (_) {
      return const WorkSettings();
    }
  }
}

/// 근무기록 페이지. 달마다 한 장 — 폰에서도 본다(노션에 둔 이유가 그것이었다).
///
/// 맨 위에 그 달 합계를 둔다: 근무일 · 실근무 · 본업 시간(이름은 설정) · 월 목표 대비(설정했을 때만).
String workPageHtml(WorkLog work, {String? month}) {
  final ws = WorkSettings.load();
  final months = {for (final d in work.all) d.date.substring(0, 7)}.toList()
    ..sort((a, b) => b.compareTo(a));
  final now = DateTime.now().toIso8601String().substring(0, 7);
  final m = month ?? (months.isEmpty ? now : months.first);
  final days = work.all.where((d) => d.date.startsWith(m)).toList();
  String pill(String label, String color) =>
      '<span class="pill c-$color">${htmlEscape(label)}</span>';
  String hours(double? h) => h == null ? '<span class="faint">—</span>' : h.toStringAsFixed(1);
  final actual = days.fold<double>(0, (a, d) => a + (d.actualHours ?? 0));
  final muwi = days.fold<double>(0, (a, d) => a + (d.muwidaraniHours ?? 0));
  final rows = StringBuffer();
  for (final d in days) {
    final tl = d.timeline.trim();
    rows.write('<tr class="row">'
        '<td class="txt">${htmlEscape(d.title)}</td>'
        '<td>${pill(d.state.label, d.state.color)}</td>'
        '<td class="meta">${d.clockIn ?? '<span class="faint">—</span>'}</td>'
        '<td class="meta">${d.clockOut ?? '<span class="faint">—</span>'}</td>'
        '<td class="meta">${d.breakMin == 0 ? '<span class="faint">—</span>' : '${d.breakMin}분'}'
        '${d.breakFrom == null ? '' : ' <span class="faint">(${d.breakFrom}~)</span>'}</td>'
        '<td class="meta num">${hours(d.actualHours)}</td>'
        '<td class="meta num">${hours(d.muwidaraniHours)}</td>'
        '<td>${d.intensity == null ? '<span class="faint">—</span>' : '<span class="ktxt c-${d.intensity!.color}">${htmlEscape(d.intensity!.label)}</span>'}</td>'
        '<td class="tl">${tl.isEmpty ? '<span class="faint">—</span>' : '<details><summary>${htmlEscape(tl.length > 40 ? '${tl.substring(0, 40)}…' : tl)}</summary><div>${htmlEscape(tl).replaceAll(' / ', '<br>')}</div></details>'}</td>'
        '</tr>');
  }
  if (days.isEmpty) {
    rows.write('<tr><td colspan="9" class="empty">이 달 기록이 없다.</td></tr>');
  }
  final monthLinks = [
    for (final x in months)
      '<a href="?view=work&month=$x" class="${x == m ? 'on' : ''}">${x.substring(5)}월</a>',
  ].join();

  return '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><title>근무기록 · Madang</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss</style>$kThemeBoot</head><body>
<header class="top"><h1>근무기록 <b>$m</b></h1>${viewTabs('work')}</header>
<div class="wrk">
<div class="months">$monthLinks</div>
<div class="stats">
<div class="stat"><b>${days.where((d) => d.actualHours != null).length}<small>일</small></b><span>근무한 날</span></div>
<div class="stat"><b>${actual.toStringAsFixed(1)}<small>시간</small></b><span>실근무</span></div>
<div class="stat"><b>${muwi.toStringAsFixed(1)}<small>시간</small></b><span>${htmlEscape(ws.mainLabel.replaceAll('(시간)', ''))}</span></div>
${ws.monthlyTargetHours == null ? '' : '<div class="stat"><b>${(actual / ws.monthlyTargetHours! * 100).round()}<small>%</small></b><span>월 ${ws.monthlyTargetHours!.round()}시간 대비</span></div>'}
</div>
<table><thead><tr><th>날짜</th><th>상태</th><th>출근</th><th>퇴근</th><th>휴게</th>
<th class="num">실근무</th><th class="num">${htmlEscape(ws.mainLabel)}</th><th>강도</th><th>타임라인</th></tr></thead>
<tbody>
$rows
</tbody></table>
</div>
<div id="back"></div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
</script></body></html>''';
}

/// 회의 화면 JSON — 위젯 원탁이 읽는 [Meeting]을 그대로 편다. 회의가 없으면 `has: false`.
///
/// 캐릭터 그림은 `/todo/art/sprite?path=`로 따로 받는다(사무실과 같은 길) — 그 폴더의 세션이 살아 있을 때만 나온다.
/// 회의록.md는 사람이 읽는 글이라 통째로 붙인다(60KB까지). 값이 안 바뀌면 `sig`가 같아 화면이 다시 그리지 않는다.
/// 회의실 「지난 회의」 목록 — 최근 것부터. 끝난 회의는 결론 문서도 이때 채운다.
Map<String, dynamic> meetingListApi() {
  final store = kMeetings;
  if (store == null) return {'ok': true, 'meetings': []};
  return {
    'ok': true,
    'now': store.now?.folder,
    'meetings': [
      for (final (folder, at) in store.all.take(30))
        if (store.load(folder) case final m?)
          {
            'folder': folder,
            'topic': m.topic,
            'round': m.round,
            'state': m.state,
            'done': m.done,
            'at': at.toIso8601String(),
            'people': m.speakers.map((s) => s.name).toList(),
            'conclusion': m.conclusion,
            if (MeetingStore.writeDoc(m) case final doc?) 'doc': doc,
          },
    ],
  };
}

Map<String, dynamic> meetingApi([String? folder]) {
  final viewing = folder != null && folder.isNotEmpty && folder != kMeetings?.now?.folder;
  final m = viewing ? kMeetings?.load(folder) : kMeetings?.now;
  if (m == null) return {'ok': true, 'has': false, if (viewing) 'missing': true};
  // 지난 라운드 발언 — 화면에서 사라지던 것(9/17 QA). 파일에서 라운드별로 읽는다.
  final rounds = <Map<String, dynamic>>[];
  for (var r = 1; r < m.round; r++) {
    final says = <Map<String, dynamic>>[];
    for (final sp in m.speakers) {
      try {
        final f = File('${m.folder}/발언/${sp.name}_r$r.md');
        if (f.existsSync()) says.add({'name': sp.name, if (sp.path != null) 'path': sp.path, if (sp.role.isNotEmpty) 'role': sp.role, 'say': f.readAsStringSync().trim()});
      } catch (_) {}
    }
    if (says.isNotEmpty) rounds.add({'round': r, 'says': says});
  }
  final docFile = File('${m.folder}/결론.md');
  String log = '';
  try {
    final f = File(m.logPath);
    if (f.existsSync()) {
      log = f.readAsStringSync();
      if (log.length > 60000) log = '${log.substring(0, 60000)}\n\n… (긴 회의록은 파일에서 본다)';
    }
  } catch (_) {}
  DateTime? at;
  try {
    at = File('${m.folder}/상태.json').lastModifiedSync();
  } catch (_) {}
  return {
    'ok': true,
    'has': true,
    'sig': '${m.signature}|${log.length}|${rounds.length}|$viewing',
    'viewing': viewing,
    'meeting': {
      'rounds': rounds,
      if (docFile.existsSync()) 'doc': docFile.path,
      if (docFile.existsSync()) 'docText': docFile.readAsStringSync(),
      'folder': m.folder,
      'topic': m.topic,
      'round': m.round,
      'state': m.state,
      'done': m.done,
      'needsUser': m.needsUser,
      if (at != null) 'at': at.toIso8601String(),
      'speakers': [
        for (final s in m.speakers)
          {
            'name': s.name,
            if (s.path != null) 'path': s.path,
            'state': s.state,
            'say': s.say,
            'summary': s.summary,
            'line': s.line,
            if (s.role.isNotEmpty) 'role': s.role,
          },
      ],
      'userNotes': m.userNotes,
      'draft': m.draft,
      'conclusion': m.conclusion,
      'log': log,
    },
  };
}

/// 회의 한 장(`?view=meeting`) — 위젯의 원탁(누가 말하는지)과 회의 탭(발언 전문)을 대시보드에 옮긴 것(대표 결정 9/17).
///
/// **여기서 회의를 굴리지 않는다.** 읽기 전용이다 — 회의는 터미널의 `/회의`가 시작하고 사회자 세션이 진행한다.
/// 공개판은 대시보드만 뜨므로 이 화면이 없으면 회의가 아예 안 보였다.
String meetingPageHtml() => '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>회의 · Madang</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss</style>$kThemeBoot</head><body>
<header class="top"><h1>회의</h1>${viewTabs('meeting')}</header>
<div class="mtg" id="mtg"><p class="nil">회의 상태를 읽는 중…</p></div>
<div id="back"></div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
$kMeetingJs
</script></body></html>''';

/// 회의 화면 스크립트 — 3초마다 `/todo/meeting`을 보고, 값이 바뀌었을 때만 다시 그린다(스크롤이 매번 위로 튀지 않게).
const String kMeetingJs = r'''
let mtgSig = '';
const MTG_STATE = {'발언중': ['blue', '참석자가 발언을 쓰는 중'], '정리중': ['purple', '사회자가 라운드를 정리하는 중'], '의견대기': ['yellow', '대표 의견을 기다리는 중 — 사회자 세션에 말한다'], '완료': ['green', '회의가 끝났다']};
const SPK = {'발언완료': ['green', '발언 완료'], '대기중': ['gray', '아직 안 썼다'], '무응답': ['red', '무응답']};
async function mtgTick(){
  let j;
  const want = new URLSearchParams(location.search).get('folder') || '';
  try{ j = await (await fetch('/todo/chat/meeting' + (want ? '?folder=' + encodeURIComponent(want) : ''), {cache: 'no-store'})).json(); }catch(e){ return; }
  if(!j.ok) return;
  const sig = j.has ? j.sig : 'none';
  // ⚠️ 5초 다시 그리기(reload)가 본문을 서버 HTML로 갈아 끼우면 그린 것이 「읽는 중…」으로 돌아간다 — 그때는 값이 같아도 다시 그린다.
  const root = document.getElementById('mtg');
  if(sig === mtgSig && root && root.dataset.drawn) return;
  mtgSig = sig;
  drawMtg(j);
}
// 결론 밑 대표 의견 칸 — 이어가기는 의견을 사회자에게 보내 다음 라운드, 끝내기는 「완료」(적은 의견이 있으면 같이).
// 발언 파일이 「**이름 (R1)** — 」로 시작할 때가 많다 — 말풍선 위에 이름이 이미 있으니 뗀다.
function mtgSay(t){ return String(t || '').replace(/^\s*(#+\s*)?\*\*[^*\n]{1,40}\(R\d+\)\*\*\s*(—|-|:)?\s*/, '').replace(/^\s*#+\s*[^\n]*\(R\d+\)\s*\n+/, ''); }
// 결론 문서의 # 머리를 굵은 줄로 — md()는 머리 글을 모른다.
function mtgDocMd(t){ return md(String(t || '').replace(/^#{1,3}\s+(.+)$/gm, '**$1**')); }
function mtgAsk(){
  const w = el('div', 'mtg-ask');
  const ta = el('textarea'); ta.rows = 3; ta.placeholder = '내 의견 — 다음 라운드에 참석자들이 읽는다';
  let draft = ''; try{ draft = sessionStorage.getItem('cw_mtg_note') || ''; }catch(e){}
  ta.value = draft;
  ta.oninput = () => { try{ sessionStorage.setItem('cw_mtg_note', ta.value); }catch(e){} sync(); };
  const row = el('div', 'row');
  const end = el('button', 'go', '회의 끝내기'); end.type = 'button';
  const next = el('button', 'go primary', '다음 회의 이어가기'); next.type = 'button';
  const sync = () => { next.disabled = !ta.value.trim(); };
  const send = async (finish, btn) => {
    if(!finish && !ta.value.trim()){ ta.focus(); return; }
    if(await post('chat/meeting-say', {text: ta.value.trim(), finish}, btn)){
      try{ sessionStorage.removeItem('cw_mtg_note'); }catch(e){}
      toast(finish ? '사회자에게 「완료」를 보냈다 — 최종 결론을 적는다' : '의견을 보냈다 — 다음 라운드가 시작된다');
      w.replaceChildren(el('p', 'faint', finish ? '최종 결론을 기다리는 중' : '다음 라운드를 여는 중'));
    }
  };
  end.onclick = () => send(true, end);
  next.onclick = () => send(false, next);
  row.append(end, next); w.append(ta, row); sync();
  return w;
}
function drawMtg(j){
  const root = document.getElementById('mtg');
  if(!root) return;
  root.dataset.drawn = '1';
  if(!j.has){
    const w = el('div', 'starter mtg-empty');
    w.append(el('b', '', '지금 도는 회의가 없다'), el('span', '', '주제를 적고 사회자 세션을 고르면 그 세션이 「/회의」로 다른 세션들을 불러 모은다. 회의가 시작되면 여기에 원탁과 회의록이 뜬다.'));
    const go = el('button', 'go primary', '회의 시작'); go.type = 'button'; go.onclick = meetingStart;
    w.append(go);
    const past = el('section', 'mtg-past'); past.id = 'mtg-past';
    root.replaceChildren(w, past);
    mtgPast('');
    return;
  }
  const m = j.meeting;
  let hidden = ''; try{ hidden = localStorage.getItem('cw_mtg_hide') || ''; }catch(e){}
  if(hidden === m.folder && !m.done){
    const w = el('div', 'starter mtg-empty');
    w.append(el('b', '', '숨긴 회의가 하나 있다'), el('span', '', m.topic + ' · R' + m.round + ' · ' + m.state));
    const back = el('button', 'go', '다시 보기'); back.type = 'button'; back.onclick = () => { try{ localStorage.removeItem('cw_mtg_hide'); }catch(e){} mtgSig = ''; mtgTick(); };
    const nb = el('button', 'go primary', '회의 시작'); nb.type = 'button'; nb.onclick = meetingStart;
    w.append(back, nb);
    root.replaceChildren(w);
    return;
  }
  const st = MTG_STATE[m.state] || ['gray', m.state];
  // 머리 — 주제 · 라운드 · 상태
  const head = el('div', 'mtg-head');
  const meta = el('div', 'mtg-meta');
  meta.append(el('span', 'pill c-' + st[0], 'R' + m.round + ' · ' + m.state));
  if(!m.done) meta.append(el('span', 'faint', st[1]));
  if(m.at) meta.append(el('span', 'faint', '· ' + new Date(m.at).toLocaleTimeString('ko-KR', {hour: '2-digit', minute: '2-digit'}) + ' 갱신'));
  const acts = el('div', 'mtg-acts');
  const viewing = !!j.viewing;
  if(viewing){ const back = el('a', 'go', '지금 회의로'); back.href = '?view=meeting'; acts.append(back); }
  // 「새 회의」가 글자 버튼이라 안 보였다(대표 제보 9/17) — 끝난 회의에서는 머리 오른쪽의 주 버튼이다.
  if(viewing){}
  else if(m.done){ const nb = el('button', 'go primary', '+ 새 회의'); nb.type = 'button'; nb.onclick = meetingStart; acts.append(nb); }
  else if(!m.needsUser){
    // 사회자가 멈춘 회의(테스트·중단)를 여기서 닫는다 — 결론 없이 끝나니 한 번 더 묻는다. 정상 끝내기는 의견 칸의 「회의 끝내기」다.
    const endb = el('button', 'txtbtn', '회의 중단'); endb.type = 'button';
    endb.onclick = async () => {
      if(!endb.dataset.armed){ endb.dataset.armed = '1'; endb.textContent = '한 번 더 누르면 결론 없이 닫는다'; return; }
      if(await post('chat/meeting-end', {}, endb)) { mtgSig = ''; mtgTick(); }
    };
    const hideb = el('button', 'txtbtn', '안 보기'); hideb.type = 'button'; hideb.title = '이 회의를 이 브라우저에서 숨긴다 — 회의실 표시도 꺼진다';
    hideb.onclick = () => { try{ localStorage.setItem('cw_mtg_hide', m.folder); }catch(e){} mtgSig = ''; mtgTick(); };
    acts.append(hideb, endb);
  }
  const titleCol = el('div', 'mtg-tt'); titleCol.append(el('h2', '', m.topic), meta);
  head.append(titleCol, acts);
  // 무대 — 참석자가 나란히 서서 말풍선을 든다. 책상·타원은 뺐다(대표 요청 9/17 「말풍선 느낌으로, 책상은 없어도」).
  const table = el('div', 'mtg-stage');
  // 진행자가 맨 앞 — 누가 회의를 굴리는지 보이게(9/17).
  const order = [...m.speakers].sort((a, b) => (b.role === '진행자') - (a.role === '진행자'));
  order.forEach(s => {
    const seat = el('div', 'mtg-seat s-' + (SPK[s.state] ? SPK[s.state][0] : 'gray') + (s.role === '진행자' ? ' boss' : ''));
    // 글은 안쪽 span에서 두 줄로 자른다 — 말풍선 꼬리(::after)가 보여야 해서 바깥은 overflow를 못 막는다(9/17 대표 제보: 긴 요약이 칸 밖으로 흘렀다).
    const bub = el('div', 'mtg-bub' + (s.line ? '' : ' think'));
    const bt = s.line || (s.state === '무응답' ? '무응답' : '…');
    bub.append(el('span', '', bt.length > 80 ? bt.slice(0, 80) + '…' : bt)); bub.title = s.line || '';
    // 살아 있는 세션이면 캐릭터, 아니면 이름 첫 글자.
    const px = el('div', 'mtg-px', (s.name || '?').slice(0, 1));
    if(s.path){
      const img = new Image();
      img.onload = () => { px.style.backgroundImage = 'url(' + img.src + ')'; px.classList.add('real'); };
      img.src = '/todo/art/sprite?path=' + encodeURIComponent(s.path) + '&v=' + m.round;
    }
    const dot = el('i', 'dot'); dot.title = SPK[s.state] ? SPK[s.state][1] : s.state;
    const nmrow = el('div', 'mtg-nmrow'); nmrow.append(dot, el('b', 'mtg-nm', s.name));
    if(s.role === '진행자') nmrow.append(el('span', 'mtg-role', '진행자'));
    seat.append(bub, px, nmrow);
    table.append(seat);
  });
  // 회의록 — 결론 · 잠정 결론 · 대표 의견 · 발언 전문 · 회의록.md
  const log = el('div', 'mtg-log');
  if(m.conclusion){
    const c = el('div', 'mtg-card done'); const b = el('div', 'ch-text'); b.innerHTML = md(m.conclusion); c.append(el('b', '', '결론'), b);
    // 회의마다 한 장 남는 결론 문서 — 펼쳐 읽고, 경로를 복사해 세션에 줄 수 있다(대표 기획 9/17).
    if(m.doc){
      const d = el('details', 'mtg-doc');
      const sm = el('summary'); sm.append(el('span', 'ic', '📄'), el('b', '', '결론.md'), el('span', 'faint', ' 대화 칸이나 사무실 얼굴로 끌어 세션에 넘긴다'));
      sm.draggable = true; sm.classList.add('mtg-drag');
      sm.addEventListener('dragstart', e => {
        dragDoc = m.doc;
        e.dataTransfer.effectAllowed = 'copy';
        e.dataTransfer.setData('text/plain', m.doc);
        sm.classList.add('drag');
        // 대화 칸이 닫혀 있으면 열어 둔다 — 놓을 자리가 보여야 한다.
        const dock = document.getElementById('dock'); if(dock) dock.classList.add('task-on');
      });
      sm.addEventListener('dragend', () => drops());
      const cp = el('button', 'txtbtn', '경로 복사'); cp.type = 'button';
      cp.onclick = ev => { ev.preventDefault(); navigator.clipboard.writeText(m.doc).then(() => toast('결론 문서 경로를 복사했다'), () => fail('복사하지 못했다')); };
      sm.append(cp);
      const body = el('div', 'ch-text'); body.innerHTML = mtgDocMd(m.docText);
      d.append(sm, body); c.append(d);
    }
    log.append(c);
  }
  if(m.done && (m.draft || m.userNotes.length)){
    const d = el('details', 'mtg-card mtg-fold');
    d.append(el('summary', '', '마지막 라운드 정리' + (m.userNotes.length ? ' · 대표 의견 ' + m.userNotes.length + '건' : '')));
    if(m.draft){ const b = el('div', 'ch-text'); b.innerHTML = md(m.draft); d.append(b); }
    if(m.userNotes.length){ const ul = el('ul'); m.userNotes.forEach(x => ul.append(el('li', '', x))); d.append(el('b', '', '대표 의견'), ul); }
    log.append(d);
  } else if(m.draft){
    const c = el('div', 'mtg-card' + (m.needsUser ? ' now' : '')); const b = el('div', 'ch-text'); b.innerHTML = md(m.draft);
    c.append(el('b', '', m.done ? '라운드 정리' : 'R' + m.round + ' 결론'), b);
    // 결론 바로 밑이 대표 차례다 — 의견을 적어 한 라운드 더 돌리거나, 여기서 끝낸다(대표 기획 9/17).
    if(m.needsUser && !viewing) c.append(mtgAsk());
    log.append(c);
  } else if(m.needsUser){
    const c = el('div', 'mtg-card now'); c.append(el('b', '', 'R' + m.round + ' 결론'), el('p', 'faint', '사회자가 결론을 적지 않았다'), mtgAsk()); log.append(c);
  } else if(!m.done){
    const spoke = m.speakers.filter(s => s.say.trim()).length;
    const c = el('div', 'mtg-card wait');
    c.append(el('b', '', m.state === '정리중' || spoke === m.speakers.length ? '사회자가 결론을 정리하는 중' : '발언을 기다리는 중 — ' + spoke + '/' + m.speakers.length),
      el('p', 'faint', '결론이 나오면 여기에 대표 의견 칸이 열린다.'));
    log.append(c);
  }
  if(m.userNotes.length && !m.done){
    const c = el('div', 'mtg-card'); c.append(el('b', '', '대표 의견'));
    const ul = el('ul'); m.userNotes.forEach(x => ul.append(el('li', '', x))); c.append(ul); log.append(c);
  }
  const say = el('div', 'mtg-says');
  say.append(el('h3', '', 'R' + m.round + ' 발언'));
  order.forEach(s => {
    const row = el('div', 'mtg-msg' + (s.role === '진행자' ? ' boss' : ''));
    const px = el('div', 'mtg-px sm', (s.name || '?').slice(0, 1));
    if(s.path){ const img = new Image(); img.onload = () => { px.style.backgroundImage = 'url(' + img.src + ')'; px.classList.add('real'); }; img.src = '/todo/art/sprite?path=' + encodeURIComponent(s.path) + '&v=' + m.round; }
    const b = el('div', 'mtg-bubble' + (s.say.trim() ? '' : ' empty'));
    const nm = el('b', '', s.name); nm.append(el('span', 'faint', ' · ' + (s.role === '진행자' ? '진행자 의견' : (SPK[s.state] ? SPK[s.state][1] : s.state))));
    const body = el('div', 'ch-text'); body.innerHTML = s.say.trim() ? md(mtgSay(s.say)) : '<p class="faint">아직 발언이 없다</p>';
    b.append(nm, body); row.append(px, b); say.append(row);
  });
  log.append(say);
  if(m.log){
    const d = el('details', 'mtg-full'); const b = el('div', 'ch-text'); b.innerHTML = md(m.log);
    d.append(el('summary', '', '회의록 전문 (회의록.md)'), b);
    log.append(d);
  }
  // 지난 라운드 발언 — 접어 둔다. 마지막 라운드만 위에 펼쳐 보인다.
  for(const r of [...(m.rounds || [])].reverse()){
    const d = el('details', 'mtg-round');
    d.append(el('summary', '', 'R' + r.round + ' 발언 ' + r.says.length + '건'));
    for(const x of r.says){
      const row = el('div', 'mtg-msg');
      const px = el('div', 'mtg-px sm', (x.name || '?').slice(0, 1));
      if(x.path){ const img = new Image(); img.onload = () => { px.style.backgroundImage = 'url(' + img.src + ')'; px.classList.add('real'); }; img.src = '/todo/art/sprite?path=' + encodeURIComponent(x.path); }
      const b = el('div', 'mtg-bubble'); const body = el('div', 'ch-text'); body.innerHTML = md(mtgSay(x.say));
      b.append(el('b', '', x.name + (x.role === '진행자' ? ' · 진행자 의견' : '')), body); row.append(px, b); d.append(row);
    }
    log.insertBefore(d, log.querySelector('.mtg-full'));
  }
  const past = el('section', 'mtg-past'); past.id = 'mtg-past';
  const foot = el('p', 'faint mtg-foot', '회의록 폴더: ' + m.folder);
  root.replaceChildren(head, table, log, past, foot);
  mtgPast(m.folder);
}
// 지난 회의 — 회의마다 한 줄. 누르면 그 회의를 연다(결론·발언·결론 문서).
async function mtgPast(cur){
  const box = document.getElementById('mtg-past');
  if(!box) return;
  let j; try{ j = await (await fetch('/todo/chat/meetings', {cache: 'no-store'})).json(); }catch(e){ return; }
  const list = (j.meetings || []).filter(x => x.folder !== cur);
  if(!list.length){ box.replaceChildren(); return; }
  box.replaceChildren(el('h3', '', '지난 회의'));
  for(const x of list){
    const a = el('a', 'mtg-prow'); a.href = '?view=meeting&folder=' + encodeURIComponent(x.folder);
    const st = MTG_STATE[x.state] || ['gray', x.state];
    const d = new Date(x.at);
    a.append(el('span', 'dt', (d.getMonth() + 1) + '/' + d.getDate()), el('b', '', x.topic));
    // 끝난 회의가 대부분이라 「완료」 알약은 소음이다 — 안 끝난 것만 표시한다.
    if(!x.done) a.append(el('span', 'pill c-' + st[0], x.state));
    a.append(el('span', 'faint who', x.people.join(' · ')));
    box.append(a);
  }
}
// ── 회의 시작 창 ── 주제를 적고 사회자 세션을 고르면 그 세션에 「/회의 주제」를 보낸다(9/17).
// 참석자는 여기서 고르지 않는다 — /회의 커맨드(Step 2)가 사회자 세션에서 AskUserQuestion으로 묻고, 그 선택 카드는
// 대화 칸에 뜬다. 여기서 또 고르게 하면 같은 것을 두 번 정하게 된다.
function meetingStart(){
  const g = document.getElementById('f-gear'); if(g) g.open = false;
  let sh = document.getElementById('s-mtgstart');
  if(!sh){ sh = document.createElement('div'); sh.id = 's-mtgstart'; sh.className = 'sheet mtgstart'; document.body.append(sh); }
  // 진행자는 루트(이사) 세션으로 고정한다 — 회의록도 그 폴더 아래 .claude/회의록/에 생긴다(대표 결정 9/17).
  const all = (chat.list || []).filter(s => s.path);
  const boss = all.find(s => s.tier === 'director') || [...all].sort((a, b) => a.path.length - b.path.length)[0];
  const picked = new Set();
  const launching = new Set();
  sh.innerHTML = '<div class="sh"><div class="title">회의 시작</div><button class="ic x" type="button" title="닫기 (Esc)" onclick="closeSheet()">✕</button></div>'
    + '<section class="ms"><h4>진행자</h4><div class="mtg-pick" id="mtg-boss"></div></section>'
    + '<section class="ms"><h4>대시보드에 어떤 세션을 모을까요? <em id="mtg-n"></em></h4>'
    + '<div class="mtg-pick" id="mtg-on"></div>'
    + '<h5 id="mtg-off-h">퇴근한 세션 <span>누르면 출근시켜 회의에 넣는다</span></h5><div class="mtg-pick" id="mtg-off"></div></section>'
    + '<section class="ms"><h4><label for="mtg-topic">회의 주제는?</label></h4>'
    + '<textarea id="mtg-topic" rows="2" placeholder="예: 다음 주 우선순위 — 무엇부터 내보내나"></textarea></section>'
    + '<div class="sf"><button type="button" class="go primary" id="mtg-go" disabled>진행하기</button></div>';
  const go = sh.querySelector('#mtg-go');
  const topicEl = sh.querySelector('#mtg-topic');
  const sync = () => {
    const n = picked.size;
    sh.querySelector('#mtg-n').textContent = n === 1 ? '1명 — 진행자와 1:1로 주고받는다' : n ? n + '명 선택' : '';
    go.textContent = n ? n + '명과 진행하기' : '진행하기';
    go.disabled = !boss || !n || !topicEl.value.trim();
  };
  topicEl.oninput = sync;
  const chip = (s, cls, sub) => {
    const btn = el('button', 'mp ' + cls); btn.type = 'button';
    const ck = el('i', 'ck', '✓');
    btn.append(face(s), el('b', '', s.name));
    if(sub) btn.append(el('small', '', sub));
    btn.append(ck);
    return btn;
  };
  const draw = () => {
    const list = (chat.list || []).filter(s => s.path && !(boss && s.path === boss.path));
    const bossBox = sh.querySelector('#mtg-boss');
    bossBox.replaceChildren();
    if(boss){ const b = chip(boss, 'boss', '고정'); b.disabled = true; bossBox.append(b); }
    else bossBox.append(el('p', 'faint', '루트 세션이 없다 — 사무실에서 먼저 켠다'));
    const onBox = sh.querySelector('#mtg-on'), offBox = sh.querySelector('#mtg-off');
    onBox.replaceChildren(); offBox.replaceChildren();
    for(const s of list){
      // 퇴근 = 끝난 세션이거나 tmux가 꺼진 세션(앱을 다시 켜면 state는 idle로 돌아와 이것만으론 모른다). 일하는 중이면 켜진 것으로 본다.
      const off = s.state === 'ended' || (s.live === false && !BUSY[s.state] && s.state !== 'waiting');
      const going = off && launching.has(s.path);
      const on = picked.has(s.path);
      const btn = chip(s, (off && !going ? 'off' : '') + (on ? ' on' : ''), going ? '출근하는 중' : '');
      btn.setAttribute('aria-pressed', on ? 'true' : 'false');
      btn.onclick = async () => {
        if(off){
          if(going) return;
          launching.add(s.path); picked.add(s.path); draw();
          const ok = await post('chat/launch', {path: s.path});
          if(!ok){ launching.delete(s.path); picked.delete(s.path); }
          await chatSessions(); draw();
          return;
        }
        on ? picked.delete(s.path) : picked.add(s.path);
        draw();
      };
      (off && !going ? offBox : onBox).append(btn);
      if(!off) launching.delete(s.path);
    }
    if(!onBox.children.length) onBox.append(el('p', 'faint', '출근한 세션이 없다 — 아래에서 골라 출근시킨다'));
    sh.querySelector('#mtg-off-h').hidden = !offBox.children.length;
    sync();
  };
  draw();
  // 출근시킨 세션이 켜지면 위 무리로 올라가게 목록을 따라 그린다.
  const tick = setInterval(() => { if(!sh.classList.contains('on')){ clearInterval(tick); return; } if(launching.size) chatSessions().then(draw); }, 2000);
  go.onclick = async () => {
    const topic = topicEl.value.trim();
    if(!picked.size || !topic) return;
    await chatSessions();
    const list = (chat.list || []).filter(s => picked.has(s.path));
    // 일하는 세션이 있으면 시작하지 않는다 — 끊으면 돌던 빌드·설치가 반쯤 남는다(대표 결정 9/17).
    const busy = [...list, ...(chat.list || []).filter(s => s.path === boss.path)].filter(s => BUSY[s.state] || s.state === 'waiting');
    const notReady = list.filter(s => s.state === 'ended' || (s.live === false && !BUSY[s.state] && s.state !== 'waiting'));
    mtgConfirm(busy, notReady, async () => {
      go.disabled = true; go.textContent = '보내는 중';
      const names = list.map(s => s.name).join(', ');
      const ok = await post('chat/send', {path: boss.path, text: '/회의 ' + topic + '\n참석: ' + names}, go);
      if(!ok){ sync(); return; }
      closeSheet();
      location.href = '?view=meeting';
    });
  };
  openSheet('mtgstart');
  setTimeout(() => topicEl && sh.querySelector('#mtg-on button') ? sh.querySelector('#mtg-on button').focus() : null, 50);
}
// 진행하기 확인 — 일하는 세션이 있으면 막고, 없으면 한 번 묻는다.
function mtgConfirm(busy, notReady, yes){
  const old = document.getElementById('mtg-confirm'); if(old) old.remove();
  const bg = el('div', 'mtg-confirm'); bg.id = 'mtg-confirm';
  const card = el('div', 'card');
  const close = () => bg.remove();
  if(busy.length || notReady.length){
    card.append(el('h4', '', busy.length ? '참석할 세션이 아직 일하는 중이다' : '아직 출근하는 중인 세션이 있다'));
    card.append(el('p', '', (busy.length ? busy : notReady).map(s => s.name).join(' · ')));
    card.append(el('p', 'faint', busy.length ? '작업이 끝난 뒤 다시 진행한다.' : '켜질 때까지 잠시 기다렸다가 다시 누른다.'));
    const ok = el('button', 'go primary', '확인'); ok.type = 'button'; ok.onclick = close;
    const row = el('div', 'row'); row.append(ok); card.append(row);
  } else {
    card.append(el('h4', '', '회의를 시작한다'));
    const no = el('button', 'go', '취소'); no.type = 'button'; no.onclick = close;
    const ok = el('button', 'go primary', '확인'); ok.type = 'button'; ok.onclick = () => { close(); yes(); };
    const row = el('div', 'row'); row.append(no, ok); card.append(row);
  }
  bg.onclick = e => { if(e.target === bg) close(); };
  bg.append(card); document.body.append(bg);
}
function htmlEsc(s){ return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
mtgTick();
setInterval(mtgTick, 3000);
''';

/// 프로젝트 목록 페이지. **노션이사 3/6** — 칸 다섯을 한 표에서 고친다.
///
/// 상태별로 묶어 보인다(진행→대기→보류→종료). 이름·거래처·폴더는 그 자리에서
/// 고쳐 쓰고, 종류·상태는 꼬리표를 눌러 고른다. 할 일 수는 폴더가 같은 할 일을
/// 센다 — 할 일을 프로젝트 ID로 잇기 전까지의 임시 연결이다.
String projectPageHtml(ProjectDb db, Todos todos) {
  final rows = ProjectDbStore.sorted(db.all);
  String pill(String label, String color) =>
      '<span class="pill c-$color">${htmlEscape(label)}</span>';
  String options<T extends Enum>(List<T> values, T selected, String Function(T) label) => [
        for (final v in values)
          '<option value="${v.name}"${v == selected ? ' selected' : ''}>${label(v)}</option>',
      ].join();
  String picker(String face, String opts, String onchange) =>
      '<label class="pick">$face<select onchange="$onchange">$opts</select></label>';
  // 폴더는 길어서 뒤쪽 두 마디만 보인다. 고칠 때는 전체 경로가 들어 있다.
  String shortPath(String p) {
    final parts = p.split('/').where((x) => x.isNotEmpty).toList();
    return parts.length <= 2 ? p : '…/${parts.sublist(parts.length - 2).join('/')}';
  }
  int openTodos(ProjectRow r) => r.path == null
      ? 0
      : todos.all.where((t) => t.project == r.path && !t.done).length;

  final body = StringBuffer();
  for (final st in ProjectState.values) {
    final mine = rows.where((r) => r.state == st).toList();
    body.write('<tr class="grp"><td colspan="7">${pill(st.label, st.color)}'
        '<em>${mine.length}</em></td></tr>');
    for (final r in mine) {
      final id = htmlEscape(r.id);
      final n = openTodos(r);
      body.write('<tr class="row${st == ProjectState.closed ? ' done' : ''}">'
          // ⭐ — 할 일 리스트·보드가 기본으로 보이는 프로젝트다.
          '<td class="txt"><span class="nm"><a class="reclink" href="?view=project&id=$id" title="기록 페이지">›</a><button class="star${r.favorite ? ' on' : ''}"'
          ' title="${r.favorite ? '즐겨찾기 빼기' : '즐겨찾기 — 할 일 리스트·보드에 기본으로 보인다'}"'
          ' onclick="fav(\'$id\',${!r.favorite})">${r.favorite ? '★' : '☆'}</button>'
          '<input class="cell strong" value="${htmlEscape(r.name)}"'
          ' onchange="pedit(\'$id\',{name:this.value})"></span></td>'
          '<td><input class="cell" value="${htmlEscape(r.client)}" placeholder="—"'
          ' onchange="pedit(\'$id\',{client:this.value})"></td>'
          // 리뷰 3회차 M3: 종류는 셋뿐인데 알약이 열두 번 반복됐다 — 글자만, 색은 글자색으로만.
          '<td>${picker('<span class="ktxt c-${r.kind.color}">${r.kind.label}</span>', options(ProjectKind.values, r.kind, (k) => k.label), "pedit('$id',{kind:this.value},true)")}</td>'
          // ⚠️ 경로는 앞부분이 다 같아서(`/Users/…/02_무위다라니/`) 그대로 두면 모든 줄이
          // 똑같아 보인다. 평소엔 끝 두 마디만 보이고, 누르면 전체 경로를 고친다.
          '<td class="pathcell" title="${htmlEscape(r.path ?? '')}">'
          '<span class="short${r.path == null ? ' faint' : ''}">${r.path == null ? '폴더 없음' : htmlEscape(shortPath(r.path!))}</span>'
          '<input class="cell path" value="${htmlEscape(r.path ?? '')}" placeholder="폴더 절대경로"'
          ' onchange="pedit(\'$id\',{path:this.value},true)"></td>'
          '<td>${picker(pill(r.state.label, r.state.color), options(ProjectState.values, r.state, (x) => x.label), "pedit('$id',{state:this.value},true)")}</td>'
          '<td class="meta">${n == 0 ? '<span class="faint">—</span>' : '$n'}</td>'
          '<td class="act"><span class="hov"><button class="ic del" title="지우기"'
          ' onclick="premove(\'$id\')"><svg viewBox="0 0 16 16"><path d="M4.5 4.5l7 7m0-7l-7 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></button></span></td>'
          '</tr>');
    }
  }
  if (rows.isEmpty) {
    body.write('<tr><td colspan="7" class="empty">위의 + 새 프로젝트 로 적으면 여기 쌓인다.</td></tr>');
  }
  final counts = [
    for (final k in ProjectKind.values)
      '${k.label} ${rows.where((r) => r.kind == k && r.state != ProjectState.closed).length}',
  ].join(' · ');

  return '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><title>프로젝트 · Madang</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss
tr.grp td{padding:18px 10px 6px;border-bottom:1px solid var(--line);height:auto}
tr.grp em{font-style:normal;color:var(--faint);margin-left:8px;font-size:12px}
input.cell{width:100%;background:none;border:1px solid transparent;border-radius:4px;
  color:var(--fg);font:inherit;padding:3px 6px;margin:0 -6px;outline:none}
input.cell:hover{background:var(--hover)}
input.cell:focus{background:var(--card);border-color:var(--accent)}
input.cell.strong{font-weight:500}
.nm{display:flex;align-items:center;gap:4px}
.nm input.cell{margin:0}
.nm .reclink{order:3;margin-left:auto}
.pathcell{position:relative;min-width:200px}
.pathcell .short{font-size:12px;color:var(--dim);padding:3px 0;display:inline-block}
.pathcell input.cell.path{position:absolute;left:10px;right:10px;top:50%;transform:translateY(-50%);
  width:auto;margin:0;font-size:12px;color:var(--fg);opacity:0}
.pathcell input.cell.path:focus{opacity:1;background:var(--card)}
.pathcell:hover .short{color:var(--fg)}
input.cell::placeholder{color:var(--faint)}
tr.done input.cell.strong{color:var(--faint)}
.sum{font-size:12px;color:var(--faint)}
</style>$kThemeBoot</head><body>
<header class="top"><h1>프로젝트 관리 <b>${rows.where((r) => r.state != ProjectState.closed).length}</b></h1>
<button class="newbtn" onclick="toggleAdd()">+ 새 프로젝트</button>
<form class="add" id="add" onsubmit="return addProject(event)">
<input id="nt" placeholder="프로젝트 이름 적고 엔터" autocomplete="off" onkeydown="enter(event)">
<button type="submit" class="go">적기</button></form>
<span class="sum">종료 뺀 $counts</span>
${viewTabs('projects')}</header>
<table><thead><tr><th>이름</th><th>거래처</th><th>종류</th><th>폴더</th><th>상태</th><th>열린 할 일</th><th></th></tr></thead>
<tbody>
$body
</tbody></table>
<div id="back"></div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
async function pedit(id, patch, redraw){
  const ok = await post('project/edit', Object.assign({id}, patch));
  if(ok && redraw) reload();
}
async function premove(id){ if(await post('project/remove', {id})) reload(); }
async function addProject(ev){
  ev.preventDefault();
  const input = document.getElementById('nt');
  const name = input.value.trim();
  if(!name) return false;
  input.value = '';
  if(await post('project/add', {name})) reload();
  return false;
}
</script></body></html>''';
}

/// 프로젝트 기록 페이지가 보여 줄 값 — 화면과 세션 API가 **같은 계산**을 쓴다.
///
/// 현황(진행중·확인필요·다음 마감·최근 완료·이번 주 시간)과 문서 목록은 열 때마다 계산한다.
/// 저장하는 것은 사람이 쓴 기록(`ProjectRow.note`)뿐이다.
Map<String, dynamic> projectPageData(ProjectRow r, ProjectDb db, Todos todos, List<SessionRecord> sessions,
    {DateTime? now}) {
  final at = now ?? DateTime.now();
  bool mine(TodoItem t) => t.projectId == r.id || (t.projectId == null && r.path != null && t.project == r.path);
  final ts = todos.all.where(mine).toList();
  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  final open = ts.where((t) => !t.done).toList();
  final next = open.where((t) => t.due != null).toList()..sort((a, b) => a.due!.compareTo(b.due!));
  final done = ts.where((t) => t.done && t.doneDate != null).toList()
    ..sort((a, b) => b.doneDate!.compareTo(a.doneDate!));
  final wStart = TodoBoard.weekStart(at), wEnd = TodoBoard.weekEnd(at).add(const Duration(days: 1));
  final week = sessions
      .where((x) => x.projectId == r.id && !x.start.isBefore(wStart) && x.start.isBefore(wEnd))
      .fold<int>(0, (a, x) => a + x.minutes);
  Map<String, dynamic> brief(TodoItem t) => {
        'id': Todos.idOf(t), 'text': t.text, 'status': t.status.name, 'statusLabel': t.status.label,
        if (t.due != null) 'due': day(t.due!),
        if (t.doneDate != null) 'doneDate': day(t.doneDate!),
      };
  final docs = r.path == null
      ? const <ProjectDoc>[]
      : ProjectDocs.scan(r.path!, otherProjects: [for (final x in db.all) if (x.path != null) x.path!]);
  return {
    'project': {
      'id': r.id, 'name': r.name, 'kind': r.kind.name, 'kindLabel': r.kind.label,
      'state': r.state.name, 'stateLabel': r.state.label, if (r.path != null) 'path': r.path,
      'favorite': r.favorite,
    },
    'status': {
      'running': open.where((t) => t.status == TaskStatus.running).length,
      'review': open.where((t) => t.status == TaskStatus.review).length,
      'open': open.length,
      'weekMinutes': week,
      'runningTasks': [for (final t in open.where((t) => t.status == TaskStatus.running)) brief(t)],
      'nextDue': [for (final t in next.take(5)) brief(t)],
      'recentDone': [for (final t in done.take(5)) brief(t)],
    },
    'note': r.note.toJson(),
    'docs': [for (final d in docs) d.toJson()],
  };
}

/// 프로젝트 기록 페이지 한 장(`?view=project&id=`). 왼쪽은 자동(지금·다음 마감·최근 완료),
/// 오른쪽은 사람 기록(소개·결정·보류·링크)과 폴더 문서. 설계는 02_클로드워쳐/20260915_기획_프로젝트기록페이지.html.
String projectRecordPageHtml(ProjectRow r, ProjectDb db, Todos todos, List<SessionRecord> sessions,
    {required bool local}) {
  final d = projectPageData(r, db, todos, sessions);
  final st = d['status'] as Map<String, dynamic>;
  final note = r.note;
  final id = htmlEscape(r.id);
  String e(Object? v) => htmlEscape('${v ?? ''}');
  String md(String s) => s.length >= 10 ? '${s.substring(5, 7)}/${s.substring(8, 10)}' : s;
  String taskLines(List list, String dateKey, String empty) => list.isEmpty
      ? '<p class="nil">$empty</p>'
      : '<ul class="tl">${[
          for (final t in list)
            '<li><time>${md('${t[dateKey] ?? ''}')}</time><span>${e(t['text'])}</span><em>${e(t['statusLabel'])}</em></li>',
        ].join()}</ul>';
  final mins = st['weekMinutes'] as int;
  String entries(String kind, String emptyText, {bool link = false}) {
    final list = note.listOf(kind);
    final rows = [
      for (var i = 0; i < list.length; i++)
        '<li>${link ? '<time></time>' : '<time>${md(list[i].date)}</time>'}<div>'
            '${link ? '<a href="${e(list[i].why)}" target="_blank" rel="noopener">${e(list[i].text)}</a>' : '<b>${e(list[i].text)}</b>'}'
            '${list[i].why.isNotEmpty ? '<small>${e(list[i].why)}</small>' : ''}</div>'
            '<button class="ic del" title="지우기" onclick="noteDel(\'$id\',\'$kind\',$i)">✕</button></li>',
    ].join();
    // 입력줄은 접어 둔다 — 칸 머리의 「+ 적기」가 연다(읽는 페이지가 양식처럼 보였다, 대표 태스크 9/15).
    final form = '<form class="nadd" hidden onsubmit="return noteAdd(event,\'$id\',\'$kind\')" onkeydown="if(event.key===\'Escape\')noteClose(this)">'
        '<input name="text" placeholder="${link ? '이름' : kind == 'decisions' ? '무엇을 정했나' : '무엇을 보류했나'}" autocomplete="off" required>'
        '<input name="why" placeholder="${link ? 'https://…' : '근거 · 이유 (선택)'}" autocomplete="off"${link ? ' required' : ''}>'
        // 정한 날(선택) — 비워 두면 오늘. 지난 결정을 옮겨 적을 때 실제 날짜를 넣는다.
        '${link ? '' : '<input name="date" type="date" title="정한 날 — 비워 두면 오늘" max="${DateTime.now().toIso8601String().substring(0, 10)}">'}'
        '<button class="go">적기</button><button type="button" class="txtbtn" onclick="noteClose(this.form)">취소</button></form>';
    return '${list.isEmpty ? '<p class="nil">$emptyText</p>' : '<ul class="ne">$rows</ul>'}$form';
  }
  final docs = d['docs'] as List;
  final kinds = <String, int>{};
  for (final x in docs) {
    final k = x['kind'] as String;
    kinds[k] = (kinds[k] ?? 0) + 1;
  }
  // 최근 kDocsShown건만 펴 두고 나머지는 「전부 보기」로 — 문서가 수십 건이면 왼쪽 열이 오른쪽보다 길어진다.
  const kDocsShown = 10, kDocsMax = 200;
  final docRows = [
    for (final (i, x) in docs.take(kDocsMax).indexed)
      // 다시 그리기(reload) 뒤에도 기본 모양(최근 10건)이 맞도록 서버가 hidden을 찍어 둔다.
      '<li data-kind="${e(x['kind'])}"${i >= kDocsShown ? ' hidden' : ''}><time>${md(x['date'] as String)}</time>'
          '${local ? '<button class="doc" onclick="openDoc(\'$id\',this.dataset.path)" data-path="${e(x['path'])}" title="${e(x['path'])}">${e(x['title'])}</button>' : '<span>${e(x['title'])}</span>'}'
          '<em>${e(x['kind'])}</em></li>',
  ].join();
  final pathParts = r.path?.split('/').where((x) => x.isNotEmpty).toList() ?? const <String>[];
  final shortPath = pathParts.length <= 2 ? pathParts.join('/') : pathParts.sublist(pathParts.length - 2).join('/');
  final runningTasks = st['runningTasks'] as List;
  return '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${e(r.name)} · 프로젝트 기록</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss
.rec{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.3fr);gap:18px;max-width:1300px;align-items:start}
.card2{background:var(--panel);border:1px solid var(--line);border-radius:20px;box-shadow:var(--shadow-card);padding:14px 16px;margin-bottom:14px}
.card2 h2{font-size:14px;font-weight:800;margin:0 0 10px;display:flex;align-items:center;gap:8px}
.card2 h2 .tag{font-size:11px;font-weight:700;color:var(--faint);background:var(--hover);border-radius:999px;padding:1px 8px}
.stats3{display:flex;gap:26px;flex-wrap:wrap}.stats3 b{display:block;font-size:24px;font-weight:800;font-variant-numeric:tabular-nums}.stats3 span{font-size:12px;color:var(--faint)}
.tl,.ne,.dl{list-style:none;margin:0;padding:0;display:flex;flex-direction:column}
.tl li,.dl li,.ne li{display:grid;grid-template-columns:44px minmax(0,1fr) auto;gap:8px;align-items:baseline;padding:6px 0;border-top:1px solid var(--line)}
.tl li:first-child,.dl li:first-child,.ne li:first-child{border-top:0}
.rec time{font-size:12px;color:var(--faint);font-variant-numeric:tabular-nums}
.tl em,.dl em{font-style:normal;font-size:12px;color:var(--faint);white-space:nowrap}
.tl li span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ne li a{color:var(--accent);font-weight:700;text-decoration:none;overflow-wrap:anywhere}.ne li a:hover{text-decoration:underline}
.ne li{align-items:start;padding:8px 0}
.ne li b{font-weight:700}.ne li small{display:block;font-size:12px;color:var(--dim);margin-top:2px;overflow-wrap:anywhere}
.card2 h2 .nopen{margin-left:auto;font-size:12px;font-weight:700;padding:3px 10px;border-radius:999px}
.card2 h2 .nopen:hover{background:var(--hover);color:var(--fg)}
/* ✕는 줄에 마우스를 올리거나 초점이 갔을 때만 — 늘 보이면 결정 10줄에 ✕ 10개라 잘못 누르기 쉽다. 터치 기기는 늘 보인다 */
.ne li .del{opacity:0;transition:opacity .12s}
.ne li:hover .del,.ne li:focus-within .del{opacity:1}
@media (hover:none){.ne li .del{opacity:1}}
.nil{color:var(--faint);font-size:13px;margin:0 0 8px}
.nadd{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}
.nadd[hidden]{display:none}
.nadd input{flex:1;min-width:140px;background:var(--bg);border:1px solid var(--line);border-radius:10px;color:var(--fg);font:inherit;font-size:13px;padding:6px 10px;outline:none}
.nadd input:focus{border-color:var(--accent)}
.nadd input[type=date]{flex:0 0 auto;min-width:0;color:var(--dim);color-scheme:var(--scheme)}
.intro{display:block;width:100%;min-height:54px;background:transparent;border:1px solid transparent;border-radius:12px;color:var(--fg);font:inherit;font-size:15px;line-height:1.6;padding:6px 8px;resize:vertical;outline:none}
.intro:hover{background:var(--hover)}.intro:focus{border-color:var(--accent);background:var(--card)}
.meta2{display:flex;gap:8px;align-items:center;flex-wrap:wrap;font-size:13px;color:var(--dim);margin:0 0 14px}
.doc{color:var(--fg);text-align:left;font-weight:600;overflow-wrap:anywhere}.doc:hover{color:var(--accent);text-decoration:underline}
/* 폴더 문서는 왼쪽(자동으로 채워지는 것) — 종류 칩은 눌러 거른다(대표 태스크 9/15) */
.kinds{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
.kinds button{font:inherit;font-size:12px;font-weight:600;color:var(--dim);background:var(--card);border:1px solid var(--line2);border-radius:999px;padding:2px 10px;cursor:pointer}
.kinds button b{font-weight:700;color:var(--faint);margin-left:2px;font-variant-numeric:tabular-nums}
.kinds button:hover{color:var(--fg);border-color:var(--dim)}
.kinds button[aria-pressed="true"]{background:var(--accent);border-color:var(--accent);color:#fff}
.kinds button[aria-pressed="true"] b{color:#fff;opacity:.8}
.kinds button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.dl li[hidden]{display:none}
.more-docs{margin-top:6px;font-size:13px;font-weight:700}
@media (max-width:900px){.rec{grid-template-columns:minmax(0,1fr)}}
</style>$kThemeBoot</head><body>
<header class="top"><a class="back" href="?view=projects">← 프로젝트 관리</a>
<h1>${e(r.name)}</h1>
<button class="star${r.favorite ? ' on' : ''}" onclick="fav('$id',${!r.favorite})" title="즐겨찾기">${r.favorite ? '★' : '☆'}</button>
${viewTabs('project')}</header>
<div class="meta2"><span class="pill c-${r.kind.color}">${r.kind.label}</span><span class="pill c-${r.state.color}">${r.state.label}</span>
${r.client.isEmpty ? '' : '<span>거래처 ${e(r.client)}</span>'}
${r.path == null ? '<span class="faint">폴더 없음</span>' : '<span class="faint" title="${e(r.path)}">…/${e(shortPath)}</span>'}
<a class="csv" href="?view=list&scope=all&p=$id">이 프로젝트 할 일</a></div>
<div class="rec"><div>
<section class="card2"><h2>지금 <span class="tag">자동</span></h2>
<div class="stats3"><div><b>${st['running']}</b><span>진행중</span></div><div><b>${st['review']}</b><span>확인필요</span></div><div><b>${st['open']}</b><span>안 끝난 할 일</span></div><div><b>${mins == 0 ? '—' : formatSpent(mins * 60)}</b><span>이번 주 시간</span></div></div>
${runningTasks.isEmpty ? '' : '<div style="margin-top:10px">${taskLines(runningTasks, 'due', '')}</div>'}</section>
<section class="card2"><h2>다음 마감 <span class="tag">자동</span></h2>${taskLines(st['nextDue'] as List, 'due', '마감이 잡힌 할 일이 없다.')}</section>
<section class="card2"><h2>최근 완료 <span class="tag">자동</span></h2>${taskLines(st['recentDone'] as List, 'doneDate', '완료한 할 일이 없다.')}</section>
<section class="card2 docs" id="docs"><h2>폴더 문서 ${docs.length} <span class="tag">자동 · 파일 이름만</span></h2>
${docs.isEmpty ? '<p class="nil">${r.path == null ? '폴더 없는 프로젝트다.' : 'YYYYMMDD_구분_내용 이름의 문서가 없다.'}</p>' : '<div class="kinds" role="group" aria-label="종류로 거르기">${[for (final k in kinds.entries) '<button type="button" data-kind="${e(k.key)}" aria-pressed="false" onclick="docKind(this)">${e(k.key)} <b>${k.value}</b></button>'].join()}</div><ul class="dl">$docRows</ul><button type="button" class="more-docs txtbtn" onclick="docAll(this)"${docs.length > kDocsShown ? '' : ' hidden'}>전부 보기 · ${docs.take(kDocsMax).length}건</button>${docs.length > kDocsMax ? '<p class="nil">최근 $kDocsMax건까지만 보인다.</p>' : ''}'}
${local ? '' : '<p class="nil">폰에서는 문서를 열 수 없다.</p>'}</section>
</div><div>
<section class="card2"><h2>소개 <span class="tag">기록</span></h2>
<textarea class="intro" id="intro" placeholder="이 프로젝트가 무엇인지 한두 줄 — 적고 나가면 저장된다" onchange="noteIntro('$id',this.value)">${e(note.intro)}</textarea></section>
<section class="card2"><h2>결정 사항 <span class="tag">기록</span><button type="button" class="nopen txtbtn" onclick="noteOpen(this)">+ 적기</button></h2>${entries('decisions', '다시 논의 안 해도 되는 결정을 적는다 — 날짜를 비우면 오늘로 붙는다.')}</section>
<section class="card2"><h2>보류 · 남긴 이유 <span class="tag">기록</span><button type="button" class="nopen txtbtn" onclick="noteOpen(this)">+ 적기</button></h2>${entries('holds', '미뤄 둔 것과 그 이유.')}</section>
<section class="card2"><h2>링크 <span class="tag">기록</span><button type="button" class="nopen txtbtn" onclick="noteOpen(this)">+ 적기</button></h2>${entries('links', '저장소·스토어·외부 문서 주소.', link: true)}</section>
</div></div>
<div id="back"></div>
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs
async function noteIntro(id, text){ await post('project/note', {id, intro:text}); }
async function noteAdd(ev, id, kind){
  ev.preventDefault();
  const f = ev.target, text = f.text.value.trim(), why = f.why.value.trim(), date = f.date ? f.date.value : '';
  if(!text) return false;
  if(await post('project/note-add', {id, kind, text, why, date})){ f.reset(); reload(); }
  return false;
}
// 「+ 적기」 — 그 칸 입력줄을 열고 초점. 적고 나면 다시 그리며 접힌다, Esc·취소면 닫힌다.
function noteOpen(b){
  const f = b.closest('section').querySelector('.nadd');
  if(!f) return;
  f.hidden = false; b.hidden = true;
  f.text.focus();
}
function noteClose(f){
  f.reset(); f.hidden = true;
  const b = f.closest('section').querySelector('.nopen');
  if(b){ b.hidden = false; b.focus(); }
}
async function noteDel(id, kind, index){ if(await post('project/note-remove', {id, kind, index})) reload(); }
async function openDoc(id, path){ await post('project/open-doc', {id, path}); }
// 폴더 문서 — 종류 칩 하나를 누르면 그 종류만, 다시 누르면 전부. 기본은 최근 10건 + 「전부 보기」.
const DOCS_SHOWN = 10;
function docApply(){
  const box = document.getElementById('docs');
  if(!box) return;
  const on = box.querySelector('.kinds [aria-pressed="true"]');
  const kind = on ? on.dataset.kind : '', all = box.dataset.all === '1';
  let n = 0, match = 0;
  box.querySelectorAll('.dl li').forEach(li => {
    const ok = !kind || li.dataset.kind === kind;
    if(ok) match++;
    li.hidden = !ok || (!all && n >= DOCS_SHOWN);
    if(ok && !li.hidden) n++;
  });
  const more = box.querySelector('.more-docs');
  if(more){
    more.hidden = match <= DOCS_SHOWN;
    more.textContent = all ? '최근 ' + DOCS_SHOWN + '건만' : '전부 보기 · ' + match + '건';
  }
}
function docKind(b){
  const was = b.getAttribute('aria-pressed') === 'true';
  b.closest('.kinds').querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', 'false'));
  if(!was) b.setAttribute('aria-pressed', 'true');
  docApply();
}
function docAll(b){
  const box = document.getElementById('docs');
  box.dataset.all = box.dataset.all === '1' ? '' : '1';
  docApply();
}
docApply();
</script></body></html>''';
}

String todoPageHtml(SessionStore store, Todos todos, ProjectDb db,
    {String view = 'list',
    bool showClosed = false,
    TodoScope scope = TodoScope.today,
    String pick = '',
    String who = '',
    String query = '',
    List<SessionRecord> sessionRecords = const []}) {
  // 프로젝트 고르는 칸. **책상에 선 순서 그대로다** — 위젯과 눈이 맞아야 한다.
  final names = <String, String>{
    for (final s in store.sessions) s.cwdPath: s.name,
  };
  String nameOf(String path) => names[path] ?? path.split('/').last;
  // ── 프로젝트 ── 할 일의 프로젝트는 프로젝트 목록(`ProjectDb`)에서 고른다.
  // 프로젝트 ID가 먼저고, 없으면(옛 할 일) 폴더가 같은 프로젝트를 찾는다.
  final dbRows = ProjectDbStore.sorted(db.all);
  ProjectRow? rowOf(TodoItem t) =>
      (t.projectId == null ? null : db.byId(t.projectId!)) ??
      (t.project.isEmpty
          ? null
          : dbRows.where((r) => r.path == t.project).firstOrNull);
  String projectName(TodoItem t) =>
      rowOf(t)?.name ?? (t.project.isEmpty ? '프로젝트 없음' : nameOf(t.project));
  // 고르는 칸에는 끝난 프로젝트를 빼고 둔다. 지금 붙은 것이 끝났으면 그것만 남긴다.
  String projectOptions(TodoItem? t) {
    final current = t == null ? null : rowOf(t);
    return [
      if (current == null && t != null)
        '<option value="" selected>${htmlEscape(projectName(t))}</option>',
      for (final r in dbRows)
        if (r.state != ProjectState.closed || r.id == current?.id)
          '<option value="${htmlEscape(r.id)}"'
              '${r.id == current?.id ? ' selected' : ''}>'
              '${htmlEscape(r.name)}${r.state == ProjectState.active ? '' : ' (${r.state.label})'}</option>',
    ].join();
  }

  // 표는 한 장이다. 안 끝난 것이 위, 그 안에서는 책상 순서 · 적은 순서다.
  final order = names.keys.toList();
  // ⚠️ **종료된 프로젝트의 할 일은 숨긴다 — 지우지 않는다**(대표 결정, 2026-09-14).
  // 파일과 CSV에는 그대로 있고, 머리의 스위치로 펼친다. 안 끝난 채 숨은 것은
  // 프로젝트 보기의 「열린 할 일」에 계속 센다.
  bool inClosed(TodoItem t) => rowOf(t)?.state == ProjectState.closed;
  final hiddenCount = todos.all.where(inClosed).length;
  final rows = [...todos.all.where((t) => showClosed || !inClosed(t))];
  rows.sort((a, b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    final ai = order.indexOf(a.project), bi = order.indexOf(b.project);
    if (ai != bi) return (ai < 0 ? 1 << 20 : ai).compareTo(bi < 0 ? 1 << 20 : bi);
    return a.at.compareTo(b.at);
  });

  final now = DateTime.now();

  /// 마감일 꼬리표. 지난 것은 빨갛다.
  String dueMark(TodoItem t) => t.due == null
      ? ''
      : '<span class="due${t.overdue(now) ? ' late' : ''}">'
          '${formatDue(t.due!, now)}</span>';

  String statusOptions(TaskStatus selected) => [
        for (final g in TaskGroup.values)
          '<optgroup label="${g.label}">${[
            for (final s in TaskStatus.values.where((s) => s.group == g))
              '<option value="${s.name}"${s == selected ? ' selected' : ''}>'
                  '${s.label}</option>',
          ].join()}</optgroup>',
      ].join();
  // 타임기록은 노션 시절 값이라 새로 고르지 않는다(대표 요청 9/17) — 이미 타임기록인 할 일에서만 목록에 남는다.
  String priorityOptions(TaskPriority selected) => [
        for (final p in TaskPriority.values)
          if (p != TaskPriority.timeLog || p == selected)
          '<option value="${p.name}"${p == selected ? ' selected' : ''}>'
              '${p.label}</option>',
      ].join();
  String kindOptions(TaskKind? selected) => [
        '<option value=""${selected == null ? ' selected' : ''}>—</option>',
        for (final k in TaskKind.values)
          '<option value="${k.name}"${k == selected ? ' selected' : ''}>'
              '${k.label}</option>',
      ].join();
  String day(DateTime? d) => d == null ? '' : d.toIso8601String().substring(0, 10);
  String clock(DateTime? d) => d == null
      ? '—'
      : '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
  const faintDash = '<span class="faint">—</span>';
  String whoName(String? a) =>
      a == null ? '' : (a == kOwnerAssignee ? '대표' : nameOf(a));
  String assigneeOptions(String? selected) => [
        '<option value=""${selected == null ? ' selected' : ''}>—</option>',
        '<option value="$kOwnerAssignee"${selected == kOwnerAssignee ? ' selected' : ''}>대표</option>',
        for (final e in names.entries)
          '<option value="${htmlEscape(e.key)}"'
              '${e.key == selected ? ' selected' : ''}>'
              '${htmlEscape(e.value)}</option>',
      ].join();
  // 담당 꼬리표. 대표와 세션을 모양으로 가른다 — 대표는 사람, 세션은 로봇.
  // 세션 담당은 누르면 오른쪽에 그 세션 대화가 열린다. 그 세션이 승인 대기면 빨간 「대기」.
  String whoMark(String? a) {
    if (a == null) return '';
    if (a == kOwnerAssignee) return '<span class="who me">👤 ${htmlEscape(whoName(a))}</span>';
    final want = ProjectStore.composeHangul(a);
    final waiting = store.sessions.any((x) => ProjectStore.composeHangul(x.cwdPath) == want && x.status == AgentStatus.waiting);
    return '<button class="who who-link" onclick="event.stopPropagation();chatFor(\'${htmlEscape(a)}\')" title="이 세션과 대화">'
        '🤖 ${htmlEscape(whoName(a))}${waiting ? ' <span class="wbadge">대기</span>' : ''}</button>';
  }

  // ── 표시 조각 ────────────────────────────────────────────
  //
  // ⚠️ **색은 꼭 필요한 곳에만 쓴다**(UI 리뷰, 2026-09-14). 카드 하나에 색
  // 꼬리표가 셋 붙고 절반이 넘는 카드에 빨간 줄이 서니 어느 색도 눈에 안
  // 들어왔다. 상태만 바탕색 꼬리표로 두고, 우선순위는 불만, 유형은 점 하나다.

  // 노션의 선택지 꼬리표. 색 이름이 곧 클래스다(`c-orange`).
  String pill(String label, String color, {bool dot = false}) =>
      '<span class="pill c-$color">${dot ? '<i class="dot"></i>' : ''}'
      '${htmlEscape(label)}</span>';
  // 우선순위는 바탕 없이 불만. 기본값(🔥)은 안 붙인다 — 전부에 붙으면 뜻이 없다.
  String fireMark(TaskPriority p, {bool always = false}) {
    if (p == TaskPriority.timeLog) return '<span class="tl">타임기록</span>';
    if (p.mark.isNotEmpty) return '<span class="fire">${p.mark}</span>';
    return always ? '<span class="fire soft">${p.label}</span>' : '';
  }
  String kindMark(TaskKind? k) => k == null
      ? ''
      : '<span class="kd c-${k.color}"><i class="dot"></i>${k.label}</span>';
  String spentMark(TodoItem t) {
    final sec = t.spentAt(now);
    if (sec <= 0) return '';
    return '<span class="cs${t.ticking ? ' on' : ''}">'
        '${t.ticking ? '● ' : ''}${formatSpent(sec)}</span>';
  }
  // 빨간 줄은 🔥🔥🔥이거나 마감이 지난 것에만 — 급한 것이 절반이면 급한 게 없다.
  bool alarm(TodoItem t) => !t.done && (t.priority == TaskPriority.three || t.overdue(now));

  // 고르는 칸을 꼬리표 위에 투명하게 겹친다. 평소에는 꼬리표만 보여 표가
  // 입력 폼처럼 안 보이고, 누르면 그 자리에서 목록이 뜬다.
  String picker(String face, String options, String onchange) =>
      '<label class="pick">$face'
      '<select onchange="$onchange">$options</select></label>';

  // 아이콘은 흑백 SVG다. 컬러 이모지(▶️✅)는 줄마다 반복되면 제목보다 먼저 보인다.
  const icPlay = '<svg viewBox="0 0 16 16"><path d="M5 3.5v9l7-4.5z" fill="currentColor"/></svg>';
  const icPause = '<svg viewBox="0 0 16 16"><path d="M5 3.5h2v9H5zm4 0h2v9H9z" fill="currentColor"/></svg>';
  const icCheck = '<svg viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const icDel = '<svg viewBox="0 0 16 16"><path d="M4.5 4.5l7 7m0-7l-7 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';

  // ── 하위 태스크 ── 칸에는 하위가 서고 카드에 상위 이름표가 붙는다. 상위는 상세창에서 진행률로 본다.
  final everything = todos.all;
  List<TodoItem> kidsOf(TodoItem t) => TaskTree.childrenOf(everything, Todos.idOf(t));
  // 상세창 「상위」 고르기 후보 — 열린 맨 위 태스크, 최근 것부터. 태스크마다 다시 만들지 않는다.
  final openTops = [for (final c in everything) if (c.parentId == null && !c.done) c]..sort((a, b) => b.at.compareTo(a.at));
  String short(String x, int n) => x.length > n ? '${x.substring(0, n)}…' : x;
  String subMark(TodoItem t) {
    if (t.parentId != null) {
      final parent = todos.byId(t.parentId!);
      if (parent == null) return '';
      final pr = TaskTree.progress(kidsOf(parent));
      return '<button class="plink" onclick="event.stopPropagation();openSheet(\'${t.parentId}\')" title="상위 태스크 열기">'
          '↳ ${htmlEscape(short(parent.text, 22))} <em>${pr.done}/${pr.total}</em></button>';
    }
    final kids = kidsOf(t);
    if (kids.isEmpty) return '';
    final pr = TaskTree.progress(kids);
    return '<span class="subn" title="하위 태스크">하위 ${pr.done}/${pr.total}</span>';
  }
  // 하위가 남은 상위의 완료 — 한 번은 겨누고 한 번 더 누르면 완료(막지는 않는다).
  String checkAttrs(TodoItem t, String id) {
    final left = t.parentId == null ? TaskTree.left(everything, t) : 0;
    return left == 0
        ? 'onclick="act(\'check\',\'$id\',this)"'
        : 'data-left="$left" onclick="checkLeft(this,\'$id\')" title="남은 하위 $left개"';
  }

  // 줄에 선 순서(1부터). 줄에 없으면 0.
  int queuePos(TodoItem t) => t.queuedAt == null
      ? 0
      : TodoStore.queueFor(todos.all, TodoStore.sendTargetOf(t))
              .indexWhere((x) => Todos.idOf(x) == Todos.idOf(t)) + 1;
  String queueMark(TodoItem t) {
    final n = queuePos(t);
    return n == 0 ? '' : '<span class="queued" title="앞 일이 끝나면 보낸다">⏳ 줄 $n번째</span>';
  }
  // 대표 담당이면 세션에 보낼 일이 아니다. 폴더도 담당 세션도 없으면 보낼 데가 없다.
  // 줄에 서 있으면 시키기 대신 줄 빼기다.
  String sendBtn(TodoItem t, String id) => t.done || TodoStore.sendRefusal(t, null) != null
      ? ''
      : t.queuedAt != null
          ? '<button class="go" onclick="act(\'unqueue\',\'$id\',this)">줄 빼기</button>'
          : '<button class="go" onclick="act(\'send\',\'$id\',this)">시키기</button>';
  String memo(TodoItem t) =>
      t.body.isEmpty ? '' : '\u2060<i class="memo" title="프롬프트가 있다">≡</i>';

  // ── 상세창 ─────────────────────────────────────────────
  //
  // 노션의 페이지 자리다. 카드를 누르면 열려 모든 필드를 한 자리에서 다룬다.
  //
  // ⚠️ **미리 그려 두고 감춰 둔다.** 눌렀을 때 자바스크립트로 만들려면 값을
  // 따로 실어 보내야 하는데, 그러면 화면 만드는 일이 HTML로 넘어온다.
  // 판단은 Dart에 둔다는 규칙을 지키려면 이쪽이 맞다.
  final sheets = StringBuffer();
  // 상세창 리뷰(2026-09-14 19:16, refactoring-ui) — 되돌리지 말 것
  // - 제목이 한 줄 입력칸이라 잘렸다 → 줄바꿈되는 글상자
  // - 속성 13줄이 같은 무게였다 → 고치는 칸 여섯만 표로 두고, 시계·생성 같은
  //   읽기 전용 값은 한 줄 요약(meta)으로 내린다
  // - 「비어 있음」이 줄마다 반복됐다 → 빈 칸은 흐린 「—」, 손을 올리면 고를 수 있다
  // - 가장 중요한 작업 내용이 작은 칸이고 빈 프롬프트가 큰 칸이었다 → 작업 내용을
  //   맨 위·내용만큼 크게, 빈 프롬프트·수정사항은 「+ 적기」로 접는다
  // - ▶ ✓ 아이콘만 있어 뜻을 몰랐다 → 글자를 붙인다
  String sheetButtons(TodoItem t, String id) => t.done
      ? ''
      : '<span class="sbtns">'
          '${t.ticking ? '<button class="sb" onclick="act(\'pause\',\'$id\')">$icPause 멈춤</button>' : '<button class="sb" onclick="act(\'play\',\'$id\')">$icPlay 시작</button>'}'
          '<button class="sb" ${checkAttrs(t, id)}>$icCheck 완료</button></span>';
  String section(String id, String label, String key, String value,
      {String hint = '', bool big = false, String badge = ''}) {
    final empty = value.trim().isEmpty;
    return '<div class="sec${empty ? ' folded' : ''}" data-key="$key">'
        '<div class="sec-h"><span>$label$badge</span>${hint.isEmpty ? '' : '<i>$hint</i>'}</div>'
        '${empty ? '<button class="add-sec" onclick="unfold(this)">+ $label 적기</button>' : ''}'
        '<textarea class="${big ? 'big' : ''}" rows="${big ? 6 : 3}" oninput="grow(this)"'
        ' onblur="edit(\'$id\',{$key:this.value})">${htmlEscape(value)}</textarea></div>';
  }
  // 작업 내용 — 회차가 있으면 「N회차」를 달고, 바로 앞 회차의 수정요청을 위에, 지난 회차들을 밑에 접어 둔다.
  String contentBlock(TodoItem t, String id) {
    final rs = t.rounds;
    if (rs.isEmpty) return section(id, '작업 내용', 'content', t.content, big: true);
    String short(String x) {
      final line = x.trim().split('\n').first;
      return line.length > 40 ? '${line.substring(0, 40)}…' : line;
    }
    final note = '<div class="rnote"><b>${rs.length}회차에 받은 수정요청</b>'
        '<p>${htmlEscape(rs.last.note.trim())}</p></div>';
    // 이번 회차를 아직 안 적었으면 지난 회차를 펴 둔다(대표 9/16 — 「작업내용이 안보여 내 수정사항만 보이네」).
    // 회차로 넘어가는 순간 작업 내용 칸은 비는데, 지난 회차가 접혀 있으면 화면에 한 일이 하나도 안 남는다.
    final fresh = t.content.trim().isEmpty;
    final past = StringBuffer();
    for (var i = rs.length - 1; i >= 0; i--) {
      final r = rs[i];
      past.write('<details class="round"${fresh && i == rs.length - 1 ? ' open' : ''}>'
          '<summary><b>${i + 1}회차</b> ${r.at.month}/${r.at.day}'
          '<span>수정요청 「${htmlEscape(short(r.note))}」</span></summary>'
          '<pre class="rc">${r.content.trim().isEmpty ? '<i>작업 내용이 없다</i>' : htmlEscape(r.content.trim())}</pre>'
          // 접힌 줄에 수정요청이 다 보이면 펼친 곳에 되풀이하지 않는다.
          '${short(r.note) == r.note.trim() ? '' : '<div class="rn"><b>수정요청</b><p>${htmlEscape(r.note.trim())}</p></div>'}</details>');
    }
    return '$note${section(id, '작업 내용', 'content', t.content, big: true, badge: ' <em class="rnd">${rs.length + 1}회차</em>')}'
        '<details class="rounds"${fresh ? ' open' : ''} id="rounds-$id">'
        '<summary>지난 회차 ${rs.length}개${fresh ? ' — 여태 한 일' : ''}</summary>$past</details>';
  }
  // 상세창 「상위」 줄 — 하위면 상위로 가는 이름표와 떼기, 맨 위 태스크면 같은 프로젝트의 열린 태스크에서 고른다.
  // 하위가 있는 태스크는 하위가 될 수 없어(한 단계) 줄을 비워 둔다.
  String parentProp(TodoItem t, String id, List<TodoItem> kids) {
    if (kids.isNotEmpty) return '';
    if (t.parentId != null) {
      return '<label>상위</label><span>${subMark(t)}'
          '<button class="clear" title="상위에서 떼기" onclick="edit(\'$id\',{parentId:\'\'},true)">$icDel</button></span>';
    }
    if (t.done) return '';
    // ⚠️ 예전엔 후보마다 TaskTree.parentRefusal(전체를 세 번 훑는다)을 불렀다 — 태스크 285개에서 285³번이라
    // 리스트·보드 페이지 한 번에 1.2초가 걸렸다(대표 제보 9/17 「탭 전환 딜레이」). 여기 오는 t는 하위도 상위도 없는
    // 열린 태스크라 남는 조건은 「같은 프로젝트」뿐이다 — 같은 판단을 미리 정렬해 둔 목록에서 한다.
    final cands = [
      for (final c in openTops)
        if (Todos.idOf(c) != id &&
            (t.projectId != null && c.projectId != null ? t.projectId == c.projectId : t.project == c.project))
          c,
    ];
    if (cands.isEmpty) return '';
    final options = '<option value="" selected>—</option>${[
      for (final c in cands.take(40))
        '<option value="${Todos.idOf(c)}">${htmlEscape(short(c.text, 40))}</option>',
    ].join()}';
    return '<label class="emp">상위</label><span class="emp">${picker(faintDash, options, "edit('$id',{parentId:this.value},true)")}</span>';
  }
  // 하위 태스크 칸 — 진행률 막대 · 하위 줄(누르면 그 상세창) · 적는 칸. 맨 위 태스크에만.
  String subsBlock(TodoItem t, String id, List<TodoItem> kids, ({int done, int total}) prog) {
    if (t.parentId != null || (t.done && kids.isEmpty)) return '';
    final pct = prog.total == 0 ? 0 : (prog.done / prog.total * 100).round();
    final sortedKids = [...kids]..sort((a, b) => a.done != b.done ? (a.done ? 1 : -1) : a.at.compareTo(b.at));
    return '<div class="subs"><div class="sec-h"><span>하위 태스크</span>'
        '${kids.isEmpty ? '<i>큰 일을 나눠 적으면 진행률과 시간 합계가 여기 모인다</i>' : '<i>${prog.done}/${prog.total} 끝남</i>'}</div>'
        '${kids.isEmpty ? '' : '<div class="subbar" role="progressbar" aria-valuenow="$pct" aria-valuemin="0" aria-valuemax="100"><i style="width:$pct%"></i></div>'}'
        '${sortedKids.map((k) {
          final kid = Todos.idOf(k);
          final ks = k.spentAt(now);
          return '<div class="subrow${k.done ? ' done' : ''}">${pill(k.status.label, k.status.color, dot: true)}'
              '<button class="sct" onclick="openSheet(\'$kid\')">${htmlEscape(k.text)}</button>'
              '${dueMark(k)}${ks > 0 ? '<span class="cs${k.ticking ? ' on' : ''}">${k.ticking ? '● ' : ''}${formatSpent(ks)}</span>' : ''}</div>';
        }).join()}'
        // 채팅처럼 길게 적게 된다(대표 9/16) — 한 상자 안을 **반으로 갈라** 위는 제목, 아래는 시킬 말이다.
        // 첫 줄만 제목으로 잘라내던 방식은 어디까지가 제목인지 눈에 안 보였다(대표 수정요청 9/16).
        '${t.done ? '' : '<form class="subadd" onsubmit="return addSub(event,\'$id\')">'
            '<input class="st" placeholder="하위 태스크 제목" autocomplete="off" oninput="subReady(this)" onkeydown="subKey(event)">'
            '<textarea class="sb" rows="1" placeholder="시킬 말 — 비워도 된다 (Shift+Enter 줄바꿈)"'
            ' oninput="grow(this);subReady(this)" onkeydown="subKey(event)"></textarea>'
            // 적기 단추는 칸 오른쪽 끝 안쪽에(대표 요청 9/16) — 엔터를 모르는 사람도 어디를 눌러야 할지 보인다.
            '<button type="submit" class="subgo" disabled title="적기 (Enter)">적기</button></form>'}'
        '</div>';
  }
  for (final t in rows) {
    final id = Todos.idOf(t);
    final kids = kidsOf(t);
    final prog = TaskTree.progress(kids);
    final spent = t.spentAt(now);
    final withKids = TaskTree.spentAt(t, kids, now);
    final meta = [
      if (spent > 0) '<b class="${t.ticking ? 'on' : ''}">${t.ticking ? '● ' : ''}누적 ${formatSpent(spent)}</b>',
      if (kids.isNotEmpty && withKids > spent) '<b>하위 포함 ${formatSpent(withKids)}</b>',
      if (kids.isNotEmpty && TaskTree.lastDue(kids) != null) '하위 마감 ~${day(TaskTree.lastDue(kids))}',
      if (t.startedAt != null) '시작 ${clock(t.startedAt)}',
      if (t.stoppedAt != null) '중지 ${clock(t.stoppedAt)}',
      if (t.doneDate != null) '완료 ${day(t.doneDate)}',
      // 다른 도구에서 옮겨 온 연결 — 옮겨 온 태스크에만 있다(처음 쓰는 사람에게는 안 뜬다).
      if (t.sessionIds.isNotEmpty) '가져온 세션 ${t.sessionIds.length}건',
      if (t.clientIds.isNotEmpty) '가져온 거래처 ${t.clientIds.length}건',
      '생성 ${clock(t.at)}',
    ].join('<em>·</em>');
    // 업무 지시서(시안 A, 대표 결정 9/15) — 담당이 세션이고 안 끝난 태스크는 상세창 위쪽이 지시서다.
    // 속성은 칩 한 줄, 속성 표·작업 내용·하위는 「속성 전체 · 작업 내용」 접기 안으로 내린다. 대표 담당은 예전 모양 그대로.
    // 보낼 세션이 있고(대표 담당·폴더 없는 프로젝트는 빠진다) 세션 몫인 태스크 — 담당이 세션이거나, 비어 있어도 세션예정·수정요청이면.
    final briefMode = !t.done && TodoStore.sendRefusal(t, null) == null &&
        (t.assignee != null || t.status == TaskStatus.sessionPlanned || t.status == TaskStatus.revision);
    final revOn = t.status == TaskStatus.revision;
    // 시킬 때(백로그·오늘·세션예정·수정요청)는 지시서가 위, 세션이 한 뒤(진행중·확인필요·멈춤·대기)는 작업 내용이 위고
    // 지시서는 「시킨 말 보기」로 접는다(대표 수정요청 9/15 — 지시서는 처음 시킬 때, 일하면 작업 내용이 위로).
    final briefFirst = switch (t.status) {
      TaskStatus.waiting || TaskStatus.today || TaskStatus.sessionPlanned || TaskStatus.revision => true,
      _ => false,
    };
    String briefBlock() {
      final b = TaskBrief.parse(t.body);
      // UI 리뷰(9/15 대표 수정요청) — 칸마다 붙던 작은 안내(「한두 줄로」…)는 예시 글과 겹쳐 뺐다.
      String field(String part, String label, String value, String hold, {bool big = false}) =>
          '<div class="bf${big ? ' big' : ''}${value.trim().isEmpty && part != 'dont' ? ' need' : ''}" data-f="$part">'
          '<label for="bf-$part-$id">$label</label>'
          '<textarea id="bf-$part-$id" data-part="$part" rows="${big ? 2 : 1}" placeholder="$hold"'
          ' oninput="briefInput(this)" onblur="briefSave(this)">${htmlEscape(value)}</textarea></div>';
      return '<div class="brief" data-id="$id" data-tt="${htmlEscape(t.text)}" data-rev="${revOn ? '1' : ''}"'
          ' data-body="${htmlEscape(t.body.trim())}">'
          '<div class="brief-h">시킬 말</div>'
          '${field('what', '무엇을', b.what, '무엇을 해야 하는지 — 비워 두면 제목만 간다', big: true)}'
          '${field('done', '완료 기준', b.done, '이게 되면 끝 — 예) 새 답이 와도 읽던 자리가 그대로다')}'
          '${field('dont', '하지 말 것', b.dont, '비워도 된다 — 예) 위젯 메시지 탭은 건드리지 않는다')}'
          '${revOn ? '<div class="bf rev" data-f="rev"><label for="bf-rev-$id">수정사항</label>'
              '<textarea id="bf-rev-$id" data-part="rev" rows="1" oninput="briefInput(this)" onblur="briefSave(this)">${htmlEscape(t.revisionNote)}</textarea></div>' : ''}'
          '</div>'
          // ⚠️ 「세션에 가는 말 보기」는 뺐다(대표 결정 9/16, A안) — 위에 적은 글을 한 번 더 보여 줄 뿐이라 자리만 먹었다.
          // 쓸모 있던 **빠진 것 경고**만 남겨 접지 않고 칸 아래에 둔다. 접혀 있으면 정작 봐야 할 때 안 보인다.
          '<p class="bwarn"></p>';
    }
    final chips = '<div class="chips">'
        '${picker(pill(t.status.label, t.status.color, dot: true), statusOptions(t.status), "setStatus('$id',this.value)")}'
        '${picker(fireMark(t.priority, always: true), priorityOptions(t.priority), "edit('$id',{priority:this.value},true)")}'
        '${picker(t.assignee == null ? '<span class="pjn">담당 —</span>' : whoMark(t.assignee), assigneeOptions(t.assignee), "edit('$id',{assignee:this.value},true)")}'
        '${picker('<span class="pjn">${htmlEscape(projectName(t))}</span>', projectOptions(t), "edit('$id',{projectId:this.value},true)")}'
        '<label class="pick">${t.due == null ? '<span class="pjn">마감 —</span>' : '<span class="pjn">마감 ${day(t.due)}</span> ${dueMark(t)}'}'
        '<input type="date" value="${day(t.due)}" onclick="try{this.showPicker()}catch(e){}" onchange="edit(\'$id\',{due:this.value},true)"></label>'
        // 마감일 지우기 — 계속 하는 일은 마감이 없다. 날짜 칸은 한 번 넣으면 비울 길이 없었다(대표 요청 9/17).
        '${t.due == null ? '' : '<button class="clear" title="마감일 지우기" onclick="edit(\'$id\',{due:\'\'},true)">$icDel</button>'}'
        '${queueMark(t)}${t.status == TaskStatus.review ? '' : sheetButtons(t, id)}</div>';
    sheets.write('<div class="sheet${briefMode ? ' brief-mode' : ''}" id="s-$id"><div class="sh">'
        '<textarea class="title" rows="1" oninput="grow(this)"'
        ' onkeydown="if(event.key===\'Enter\'&&!event.isComposing){event.preventDefault();this.blur()}"'
        ' onchange="edit(\'$id\',{text:this.value})">${htmlEscape(t.text)}</textarea>'
        '<button class="ic x" title="닫기 (Esc)" onclick="closeSheet()">$icDel</button></div>'
        // 하위가 있으면 **하위 칸이 맨 위**다(대표 요청 9/16). 하위가 달린 상위는 제 작업 내용보다
        // 「무엇이 몇 개 남았나」가 먼저 궁금하고, 시계도 하위에서 돈다 — 접기 안에 있으면 매번 펴야 했다.
        // 하위가 없으면 예전 자리 그대로다(빈 칸이 맨 위에 서면 자리만 먹는다).
        '${kids.isEmpty ? '' : subsBlock(t, id, kids, prog)}'
        '${briefMode && !briefFirst ? '$chips${contentBlock(t, id)}<details class="brief-d" id="brief-$id"><summary>시킨 말 보기</summary>${briefBlock()}</details>' : ''}'
        '${briefMode ? '${briefFirst ? '$chips${briefBlock()}' : ''}<details class="more" id="more-$id"><summary>유형 · 상위${briefFirst ? ' · 작업 내용' : ''}</summary>'
            // 칩 줄과 겹치는 진행사항·우선순위·담당·프로젝트·마감은 펼친 표에 다시 두지 않는다(대표 수정요청 9/15).
            '<div class="props"><label>유형</label>'
            '<span>${picker(t.kind == null ? faintDash : kindMark(t.kind), kindOptions(t.kind), "edit('$id',{kind:this.value},true)")}</span>'
            '${parentProp(t, id, kids)}</div>' : ''}'
        // 지시서 모드면 전체 속성 표는 칩 줄·위 표와 겹치므로 숨긴다(대표 담당 모양에서만 보인다).
        // 리뷰3 L6(9/17): 담당·마감일·유형·상위가 전부 —면 네 줄이 비어 보였다 — 빈 것은 접고 「빈 칸 N개 보기」로 편다.
        '<div class="props${[t.assignee, t.due, t.kind, t.parentId].where((x) => x == null).length >= 3 ? ' fold-empty' : ''}"${briefMode ? ' hidden' : ''}>'
        '<label>진행사항</label>'
        '<span>${picker(pill(t.status.label, t.status.color, dot: true), statusOptions(t.status), "setStatus('$id',this.value)")}'
        '${sheetButtons(t, id)}${queueMark(t)}</span>'
        '<label>우선순위</label>'
        '<span>${picker(fireMark(t.priority, always: true), priorityOptions(t.priority), "edit('$id',{priority:this.value},true)")}</span>'
        '<label${t.assignee == null ? ' class="emp"' : ''}>담당</label>'
        '<span${t.assignee == null ? ' class="emp"' : ''}>${picker(t.assignee == null ? faintDash : whoMark(t.assignee), assigneeOptions(t.assignee), "edit('$id',{assignee:this.value},true)")}</span>'
        '<label>하위프로젝트</label>'
        '<span>${picker('<span class="proj">${htmlEscape(projectName(t))}</span>', projectOptions(t), "edit('$id',{projectId:this.value},true)")}</span>'
        '<label${t.due == null ? ' class="emp"' : ''}>마감일</label>'
        '<span${t.due == null ? ' class="emp"' : ''}><label class="pick">${t.due == null ? faintDash : '<span class="proj">${day(t.due)}</span> ${dueMark(t)}'}'
        '<input type="date" value="${day(t.due)}" onclick="try{this.showPicker()}catch(e){}"'
        ' onchange="edit(\'$id\',{due:this.value},true)"></label>'
        '${t.due == null ? '' : '<button class="clear" title="마감일 지우기" onclick="edit(\'$id\',{due:\'\'},true)">$icDel</button>'}</span>'
        '<label${t.kind == null ? ' class="emp"' : ''}>유형</label>'
        '<span${t.kind == null ? ' class="emp"' : ''}>${picker(t.kind == null ? faintDash : kindMark(t.kind), kindOptions(t.kind), "edit('$id',{kind:this.value},true)")}</span>'
        '${parentProp(t, id, kids)}'
        '<button type="button" class="txtbtn more-emp" onclick="this.closest(\'.props\').classList.remove(\'fold-empty\')">빈 칸 ${[t.assignee, t.due, t.kind, t.parentId].where((x) => x == null).length}개 보기</button>'
        '</div>'
        '<div class="meta-line">$meta</div>'
        '${kids.isEmpty ? subsBlock(t, id, kids, prog) : ''}'
        '${briefMode && !briefFirst ? '' : contentBlock(t, id)}'
        '${briefMode ? '' : section(id, '프롬프트', 'body', t.body, hint: '시키기가 보내는 말 · 비워 두면 작업명을 보낸다')}'
        '${briefMode && (revOn || t.revisionNote.trim().isEmpty) ? '' : section(id, '수정사항', 'revisionNote', t.revisionNote)}'
        '${briefMode ? '</details>' : ''}'
        '<div class="sf">'
        '<button class="txtbtn del" onclick="act(\'remove\',\'$id\')">지우기</button>'
        '<button class="txtbtn tochat" data-id="$id" data-tt="${htmlEscape(t.text)}"'
        ' data-to="${t.assignee != null && t.assignee != kOwnerAssignee ? htmlEscape(t.assignee!) : ''}"'
        ' onclick="taskToChat(this)" title="이 태스크를 가리키는 표시를 대화 입력칸에 붙인다 — 세션이 찾지 않고 바로 안다">대화에 붙이기</button>'
        // 확인필요면 할 일은 보고 닫거나 돌려보내는 것이다 — 주 버튼은 완료, 옆에 수정요청(UI 리뷰 9/15).
        // 다시 시키기가 주 버튼이면 끝난 일을 한 번 더 보내기 쉽다.
        '${t.status == TaskStatus.review ? '<button class="txtbtn" onclick="setStatus(\'$id\',\'revision\')">수정요청</button>'
            '<button class="go primary" ${checkAttrs(t, id)}>완료</button>' : sendBtn(t, id).replaceFirst('class="go"', 'class="go primary"')}'
        '</div></div>');
  }

  // ── 리스트 · 보드 ─────────────────────────────────────────
  //
  // 2026-09-14 대표 확정(작업지시서 `20260914_작업지시서_할일리스트보드.md`).
  // 12칸 보드는 77장이 한 화면에 깔려 무엇이 내 차례인지 안 보였다. 그래서
  // - 칸은 진행사항이 아니라 **공을 쥔 쪽 넷**이다([BallLane])
  // - 백로그는 칸이 아니라 서랍이다. 마감이 범위 안에 든 것만 올라온다([TodoBoard.onBoard])
  // - 기본으로 ⭐ 즐겨찾기 프로젝트만 보인다. 리스트와 보드가 선택(주소의 `p`)을 같이 쓴다
  // 상태별로 전부 보고 싶으면 「표」다 — 12칸 보드는 설정으로 남기지 않고 뺐다.
  final open = rows.where((t) => !t.done).toList();
  final favIds = {for (final r in dbRows) if (r.favorite) r.id};
  // 즐겨찾기가 하나도 없으면 전체를 보인다 — 빈 화면으로 시작하면 쓰는 법을 모른다.
  final pickAll = pick == '*' || (pick.isEmpty && favIds.isEmpty);
  // 사무실에서 세션을 누르면 그 세션 몫만 본다(대표 요청 9/15) — 시키기가 보낼 곳(담당 세션, 없으면 프로젝트 폴더)이
  // 그 세션인 태스크. 프로젝트 고르기(p)보다 앞선다. 주소의 who에 실리고, 프로젝트 탭을 누르면 풀린다.
  //
  // **팀원을 누르면 그 팀 전체가 보인다**(대표 요청 9/16) — 사원 하나만 보면 팀장이 들고 있는 같은 일이 안 보여
  // 무엇이 남았는지 판단이 안 된다. 같은 칸(Floor)에 선 세션들의 몫을 함께 낸다. 칸을 못 찾으면 그 세션만 낸다.
  final whoKey = ProjectStore.composeHangul(who);
  final whoFloor = whoKey.isEmpty
      ? null
      : store.floors.where((f) => f.sessions.any((x) => ProjectStore.composeHangul(x.cwdPath) == whoKey)).firstOrNull;
  final whoTeam = <String>{
    if (whoKey.isNotEmpty) whoKey,
    for (final x in whoFloor?.sessions ?? const <AgentSession>[]) ProjectStore.composeHangul(x.cwdPath),
  };
  final whoTeamName = whoFloor == null || whoFloor.sessions.length < 2 ? '' : whoFloor.name;
  // 찾기(q) — 제목·시킬 말·작업 내용·수정사항·프로젝트 이름에서 글자를 찾는다(대표 요청 9/16).
  // 띄어쓰기로 나눈 낱말을 **모두** 품은 것만 낸다. 한글은 풀어 쓴 모양(NFD)으로 저장된 것이 섞여 있어 맞춰 준다.
  final qWords = ProjectStore.composeHangul(query).toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  bool hit(TodoItem t) {
    if (qWords.isEmpty) return true;
    final hay = ProjectStore.composeHangul(
            '${t.text} ${t.body} ${t.content} ${t.revisionNote} ${projectName(t)}')
        .toLowerCase();
    return qWords.every(hay.contains);
  }
  bool picked(TodoItem t) {
    if (!hit(t)) return false;
    if (whoKey.isNotEmpty) return whoTeam.contains(ProjectStore.composeHangul(TodoStore.sendTargetOf(t)));
    if (pickAll) return true;
    final id = rowOf(t)?.id;
    return pick.isEmpty ? favIds.contains(id) : id == pick;
  }
  final f = open.where(picked).toList();
  // 하위가 남은 상위는 칸에서 뺀다 — 그 하위들이 대신 선다(같은 일이 두 장 깔리지 않게).
  bool isOnBoard(TodoItem t) => TodoBoard.onBoard(t, scope, now) && !TaskTree.hiddenOnBoard(everything, t);
  List<TodoItem> laneCards(List<TodoItem> from, BallLane l) =>
      from.where((t) => isOnBoard(t) && TodoBoard.laneOf(t) == l).toList()
        ..sort(TodoBoard.compare);
  final drawer = f.where((t) => t.status == TaskStatus.waiting && !isOnBoard(t) && !TaskTree.hiddenOnBoard(everything, t)).toList()
    ..sort(TodoBoard.compare);

  // 주소에 실어 다니는 선택. 보기를 바꿔도 범위와 프로젝트가 따라간다.
  // 세션 거르기(who)는 범위를 바꿔도 따라가고, 프로젝트를 고르면(p를 줌) 풀린다.
  String qs({String? v, TodoScope? sc, String? p}) =>
      '?view=${v ?? view}&scope=${(sc ?? scope).name}&p=${Uri.encodeQueryComponent(p ?? pick)}'
      '${p == null && who.isNotEmpty ? '&who=${Uri.encodeQueryComponent(who)}' : ''}'
      '${query.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(query)}'}';
  String navLink(String href, String inner, {String cls = ''}) =>
      '<a class="$cls" href="${htmlEscape(href)}" onclick="return nav(this)">$inner</a>';

  // 카드·줄의 버튼. **칸이 버튼을 정한다** — 그 칸에서 공을 넘기는 동작 하나(확인필요는 둘)다.
  // 완료는 대표가 이 페이지에서 누르는 것이라 그대로 옮긴다(세션 API의 ownerConfirmed와 같은 뜻).
  String ballButtons(TodoItem t, String id) {
    if (t.done) return '';
    if (t.status == TaskStatus.waiting && !isOnBoard(t)) {
      return '<button class="go" onclick="setStatus(\'$id\',\'today\')">꺼내기</button>';
    }
    return switch (TodoBoard.laneOf(t)) {
      _ when t.queuedAt != null =>
        '<button class="go" onclick="act(\'unqueue\',\'$id\',this)">줄 빼기</button>',
      // 줄마다 반복되는 버튼이라 진한 파랑을 쓰지 않는다 — 진한 파랑은 머리의 [+ 새로] 하나다(UI 리뷰 2026-09-14 23:4x).
      _ when t.status == TaskStatus.review =>
        '<button class="go soft" ${checkAttrs(t, id)}>완료</button>'
            '<button class="txtbtn" onclick="reviseInline(this,\'$id\')">수정요청</button>',
      BallLane.session when TodoStore.sendRefusal(t, null) == null =>
        '<button class="go" onclick="act(\'send\',\'$id\',this)">시키기</button>',
      // 대표가 직접 하는 일은 확인할 사람이 자기 자신이라 바로 완료다(A안, 대표 결정 9/16).
      // 세션에게 시킨 일은 예전대로 「끝냄」 → 확인필요 — 대표가 보고 판단할 거리가 남아 있다.
      BallLane.running => TodoStore.finishesSelf(t)
          ? '<button class="go" ${checkAttrs(t, id)}>완료</button>'
          : '<button class="go" onclick="setStatus(\'$id\',\'review\')">끝냄</button>',
      BallLane.hold =>
        '<button class="go" onclick="setStatus(\'$id\',\'today\')">다시</button>',
      _ => '<button class="go" onclick="act(\'play\',\'$id\',this)">시작</button>',
    };
  }
  // [implied]는 칸 제목이 이미 말하는 상태다 — 그 상태면 꼬리표를 또 붙이지 않는다.
  String cardProps(TodoItem t, {TaskStatus? implied}) =>
      '${t.parentId == null ? subMark(t) : ''}${t.status == implied ? '' : pill(t.status.label, t.status.color, dot: true)}${queueMark(t)}${fireMark(t.priority)}'
      '${dueMark(t)}${spentMark(t)}';

  // ── 하위 묶음(A안, 대표 결정 9/15) ── 칸 안에서 같은 상위의 하위가 모이고 위에 머리 한 줄이 선다.
  // 카드마다 붙던 「↳ 상위」 이름표는 뺀다. 하위가 여러 칸에 흩어지면 칸마다 머리가 선다.
  // 머리를 끌면 **그 칸의** 하위만 함께 옮겨 간다(다른 칸의 하위는 그대로).
  // 묶음 머리 요약에 쓰는 짧은 칸 이름 — 「대기 · 멈춤 3」은 요약의 「·」 구분과 겹쳐 안 읽혔다(UI 리뷰 9/15).
  String laneShort(BallLane? l) => switch (l) {
        BallLane.me => '내 차례',
        BallLane.session => '세션',
        BallLane.running => '진행중',
        BallLane.hold => '멈춤',
        null => '',
      };
  String laneName(TodoItem k) {
    if (k.done) return '완료';
    if (!isOnBoard(k)) return '백로그';
    return laneShort(TodoBoard.laneOf(k));
  }
  String groupHead(TodoItem parent, List<TodoItem> here, {required String laneLabel, required bool list}) {
    final pid = Todos.idOf(parent);
    final kids = kidsOf(parent);
    final pr = TaskTree.progress(kids);
    final pct = pr.total == 0 ? 0 : (pr.done / pr.total * 100).round();
    final elsewhere = <String, int>{};
    for (final k in kids) {
      if (k.done || here.contains(k)) continue;
      final n = laneName(k);
      if (n.isNotEmpty && n != laneLabel) elsewhere[n] = (elsewhere[n] ?? 0) + 1;
    }
    final due = parent.due ?? TaskTree.lastDue(kids);
    final sum = [
      '여기 ${here.length}',
      for (final e in elsewhere.entries) '${e.key} ${e.value}',
      if (due != null) '마감 ${due.month}/${due.day}',
    ].join(' · ');
    final ids = htmlEscape(jsonEncode([for (final k in here) Todos.idOf(k)]));
    return '<div class="gh" draggable="true" data-ids="$ids" data-pid="$pid" data-tt="${htmlEscape(parent.text)}"'
        ' ondragstart="pickGroup(event,this)" ondragend="drops()" title="끌면 이 칸의 하위 ${here.length}개가 함께 옮겨 간다">'
        '<button class="gt" onclick="foldGroup(this)" title="접기 · 펴기">▾</button><span class="grip" aria-hidden="true">⠿</span>'
        '<button class="gn" onclick="openSheet(\'$pid\')" title="상위 태스크 열기">${htmlEscape(parent.text)}</button>'
        '<span class="gc">${pr.done}/${pr.total}</span>'
        '${list ? '<span class="gbar"><i style="width:$pct%"></i></span><span class="gsum">$sum</span>' : ''}</div>'
        '${list ? '' : '<div class="gbar"><i style="width:$pct%"></i></div><div class="gsum">$sum</div>'}';
  }
  /// 칸의 카드·줄을 그리되 같은 상위의 하위는 첫 하위 자리에 묶어 세운다.
  String grouped(List<TodoItem> items, String Function(TodoItem) render,
      {required String lane, required String laneLabel, required bool list}) {
    final out = StringBuffer();
    final done = <String>{};
    for (final t in items) {
      final pid = t.parentId;
      final parent = pid == null ? null : todos.byId(pid);
      if (parent == null) {
        out.write(render(t));
        continue;
      }
      if (!done.add(pid!)) continue;
      final here = items.where((x) => x.parentId == pid).toList();
      out.write('<div class="${list ? 'lgrp' : 'grp'}" data-g="${htmlEscape('$lane|$pid')}">'
          '${groupHead(parent, here, laneLabel: laneLabel, list: list)}'
          '<div class="gk">${here.map(render).join()}</div></div>');
    }
    return out.toString();
  }

  // 한 줄(리스트·서랍). 버튼은 늘 보인다 — 줄이 넓어 자리가 있다.
  // 세션 차례에서 지금 시킬 수 있는 것 — 세션예정·수정요청이고 줄에 안 섰고 보낼 데가 있다.
  // 마감 때문에 칸에 올라온 백로그까지 보내면 맡기지 않은 일이 나간다.
  bool sendable(TodoItem t) =>
      (t.status == TaskStatus.sessionPlanned || t.status == TaskStatus.revision) &&
      t.queuedAt == null && TodoStore.sendRefusal(t, null) == null;
  // 체크 칸 — 골라서 시키기(대표 요청 9/15). 시킬 수 있는 카드에만 선다.
  String pickBox(TodoItem t) => sendable(t)
      ? '<input type="checkbox" class="pickchk" data-id="${Todos.idOf(t)}" aria-label="시킬 것으로 고르기" title="체크한 것만 한 번에 시킨다"'
          ' onclick="event.stopPropagation()" onchange="pickTask(this)">'
      : '';
  String listRow(TodoItem t, {TaskStatus? implied}) {
    final id = Todos.idOf(t);
    return '<div class="lrow${alarm(t) ? ' alarm' : ''}" draggable="true" data-tt="${htmlEscape(t.text)}"'
        ' ondragstart="pick(event,\'$id\')" ondragend="drops()">'
        '${pickBox(t)}<div class="lt"><div class="ct" onclick="openSheet(\'$id\')">${htmlEscape(t.text)}${memo(t)}</div>'
        '<div class="cp">${cardProps(t, implied: implied)}<span class="pjn">${htmlEscape(projectName(t))}</span>'
        '${t.assignee == kOwnerAssignee ? whoMark(t.assignee) : ''}</div></div>'
        '<div class="la">${ballButtons(t, id)}</div></div>';
  }
  // 진행중 한 줄 — 누가 하는지 · 이번에 몇 분째 · 멈춤/끝냄.
  String runRow(TodoItem t) {
    final id = Todos.idOf(t);
    final mins = t.ticking ? now.difference(t.startedAt!).inMinutes : 0;
    final who = t.assignee == null ? '' : whoMark(t.assignee);
    return '<div class="lrow run${alarm(t) ? ' alarm' : ''}" draggable="true" data-tt="${htmlEscape(t.text)}"'
        ' ondragstart="pick(event,\'$id\')" ondragend="drops()">'
        '<div class="lt"><div class="ct" onclick="openSheet(\'$id\')">${htmlEscape(t.text)}${memo(t)}</div>'
        '<div class="cp">$who<span class="pjn">${htmlEscape(projectName(t))}</span>'
        '${t.ticking ? '<span class="cs on">● ${mins < 1 ? '방금' : '$mins분째'}</span>' : ''}${dueMark(t)}</div></div>'
        '<div class="la"><button class="txtbtn" onclick="act(\'pause\',\'$id\',this)">⏸ 멈춤</button>'
        '${TodoStore.finishesSelf(t) ? '<button class="go" ${checkAttrs(t, id)}>완료</button>' : '<button class="go" onclick="setStatus(\'$id\',\'review\')">끝냄</button>'}</div></div>';
  }
  String listOf(List<TodoItem> items, String empty, {TaskStatus? implied, String lane = '', String laneLabel = ''}) => items.isEmpty
      ? '<div class="list"><div class="empty">$empty</div></div>'
      : '<div class="list">${grouped(items, (t) => listRow(t, implied: implied), lane: lane, laneLabel: laneLabel, list: true)}</div>';

  // 한 번에 시키기 — 세션 차례에서 **아직 안 시킨 것**만(줄에 선 것·보낼 데 없는 것은 뺀다).
  String sendAll(List<TodoItem> lane) {
    final ids = [for (final t in lane) if (sendable(t)) Todos.idOf(t)];
    if (ids.isEmpty) return '';
    // 카드를 체크하면 이 단추가 「체크한 N건 시키기」로 바뀐다(applyPicks). 아무것도 안 골랐으면 전부다.
    return '<button class="go soft sendall" data-ids="${htmlEscape(jsonEncode(ids))}" data-all="${ids.length}" onclick="sendMany(this)"'
        ' title="세션 차례 카드를 한 번에 시킨다 — 카드를 체크하면 체크한 것만. 같은 세션에 여러 장이면 줄을 서서 차례로 나간다">${ids.length}건 한 번에 시키기</button>';
  }

  // ── 보드 ──
  final cards = StringBuffer();
  for (final l in BallLane.values) {
    final mine = laneCards(f, l);
    final rv = l == BallLane.session
        ? mine.where((t) => t.status == TaskStatus.revision).length
        : 0;
    // 끌어다 놓으면 그 칸의 대표 상태로 옮긴다.
    final dropTo = switch (l) {
      BallLane.me => TaskStatus.review,
      BallLane.session => TaskStatus.sessionPlanned,
      BallLane.running => TaskStatus.running,
      BallLane.hold => TaskStatus.paused,
    };
    cards.write('<div class="col l-${l.color}"'
        ' ondragover="over(event)" ondragleave="leave(event)"'
        ' ondrop="drop(event,\'${dropTo.name}\'${l == BallLane.session ? ',\'session\'' : ''})">'
        '<h3>${pill(l.label, l.color, dot: true)}<em>${mine.length}</em>'
        '${rv == 0 ? '' : '<span class="rvc">· 수정 $rv</span>'}'
        '${l == BallLane.session ? sendAll(mine) : ''}</h3>');
    String boardCard(TodoItem t) {
      final id = Todos.idOf(t);
      return '<div class="card${alarm(t) ? ' alarm' : ''}" draggable="true" data-tt="${htmlEscape(t.text)}"'
          ' ondragstart="pick(event,\'$id\')" ondragend="drops()">'
          '${pickBox(t)}<div class="ct" onclick="openSheet(\'$id\')">${htmlEscape(t.text)}${memo(t)}</div>'
          // 리뷰3 M4(9/17): 알약·시간·담당·폴더가 두 줄로 흐르고 아이콘 크기가 들쭉날쭉했다 — 한 줄(넘치면 감김)에 붙인다.
          '<div class="cp">${cardProps(t)}<span class="pj">${whoMark(t.assignee)}'
          '${t.assignee == t.project && t.project.isNotEmpty ? '' : '<span>${htmlEscape(projectName(t))}</span>'}</span></div>'
          // ⚠️ 버튼은 손이 가면 오른쪽 아래에 겹쳐 뜬다 — 카드 높이가 안 변한다.
          // 터치 기기는 올릴 손이 없어 늘 보인다(CSS `hover: none`).
          '<div class="cf">${ballButtons(t, id)}</div></div>';
    }
    cards.write(grouped(mine, boardCard, lane: l.name, laneLabel: laneShort(l), list: false));
    if (mine.isEmpty) {
      cards.write('<div class="empty">${switch (l) {
        BallLane.me => '대표 차례가 비었다.',
        BallLane.session => '세션에 넘긴 일이 없다.',
        BallLane.running => '돌고 있는 일이 없다.',
        BallLane.hold => '막힌 일이 없다.',
      }}</div>');
    }
    cards.write('</div>');
  }

  // 보드 위 프로젝트 탭 — ⭐ 즐겨찾기(기본) · 전체 · 카드가 있는 프로젝트.
  final live = open.where(isOnBoard).toList();
  final perProject = <String, int>{};
  for (final t in live) {
    final id = rowOf(t)?.id;
    if (id != null) perProject[id] = (perProject[id] ?? 0) + 1;
  }
  final tabRows = dbRows.where((r) => (perProject[r.id] ?? 0) > 0).toList()
    ..sort((a, b) => a.favorite != b.favorite
        ? (a.favorite ? -1 : 1)
        : perProject[b.id]!.compareTo(perProject[a.id]!));
  String star(ProjectRow r) =>
      '<button class="star${r.favorite ? ' on' : ''}" title="${r.favorite ? '즐겨찾기 빼기' : '즐겨찾기'}"'
      ' onclick="fav(\'${htmlEscape(r.id)}\',${!r.favorite})">${r.favorite ? '★' : '☆'}</button>';
  // 「프로젝트 [전체][★]」 — 범위 스위치와 같은 버튼 모양으로 세운다. 글자 탭이라 안 보인다는 대표 수정요청(9/15).
  // 즐겨찾기가 없으면 ★를 골라도 전체가 보이므로 불도 전체에 켠다.
  final allOn = whoKey.isEmpty && (pick == '*' || (pick.isEmpty && favIds.isEmpty));
  final favOn = whoKey.isEmpty && pick.isEmpty && favIds.isNotEmpty;
  final tabs = StringBuffer()
    ..write('<span class="plabel">프로젝트</span><span class="seg pseg">')
    ..write(navLink(qs(p: '*'), '전체 <em>${live.length}</em>', cls: allOn ? 'on' : ''))
    ..write(navLink(qs(p: ''), '<b class="st">★</b> <em>${live.where((t) => favIds.contains(rowOf(t)?.id)).length}</em>',
        cls: favOn ? 'on' : ''))
    ..write('</span><span class="sep"></span>');
  for (final r in tabRows) {
    final sel = pick == r.id;
    tabs.write('<span class="pt${sel ? ' on' : ''}${r.favorite ? '' : ' off'}">${star(r)}'
        '${navLink(qs(p: sel ? '' : r.id), '${htmlEscape(r.name)} <em>${perProject[r.id]}</em>')}</span>');
  }
  final whoBar = whoKey.isEmpty
      ? ''
      : '<div class="whobar"><span>🤖 <b>${htmlEscape(nameOf(who))}</b>'
          '${whoTeamName.isEmpty ? ' 세션 몫만 보는 중' : ' 팀(${htmlEscape(whoTeamName)} · ${whoFloor!.sessions.length}명) 몫을 보는 중'}'
          ' <em>${f.length}건</em></span>'
          '<button class="txtbtn" onclick="filterWho(\'\')" title="세션 거르기 풀기">전체로 ✕</button></div>';
  final noFavNote = favIds.isEmpty
      ? '<p class="bnote">★ 즐겨찾기한 프로젝트가 없어 전체를 보인다 — 프로젝트 이름 옆 ☆를 누르면 그 프로젝트가 기본으로 보인다.</p>'
      : '';

  // ── 리스트 ──
  final stale = f.where((t) => TodoBoard.staleToday(t, now)).toList();
  final staleIds = stale.map((t) => "'${Todos.idOf(t)}'").join(',');
  final review = laneCards(f, BallLane.me).where((t) => t.status == TaskStatus.review).toList();
  final myToday = laneCards(f, BallLane.me).where((t) => t.status != TaskStatus.review).toList();
  // 진행중은 맨 위 늘 펼친 칸으로 꺼냈다 — 세션 차례에 섞어 접어 두니 안 보여 보드를 오갔다(대표 결정 9/15 12시).
  final running = laneCards(f, BallLane.running);
  final sess = laneCards(f, BallLane.session);
  final planN = sess.where((t) => t.status == TaskStatus.sessionPlanned).length;
  final revN = sess.where((t) => t.status == TaskStatus.revision).length;
  final hold = laneCards(f, BallLane.hold);

  // 프로젝트 판 — 이번 주 시간은 세션 기록의 합이다.
  final wStart = TodoBoard.weekStart(now), wEnd = TodoBoard.weekEnd(now);
  final weekRows = sessionRecords.where((r) =>
      !r.start.isBefore(wStart) && r.start.isBefore(wEnd.add(const Duration(days: 1))));
  final weekMin = <String, int>{};
  for (final r in weekRows) {
    if (r.projectId != null) weekMin[r.projectId!] = (weekMin[r.projectId!] ?? 0) + r.minutes;
  }
  String hm(int m) => m <= 0 ? '·' : formatSpent(m * 60);
  final kindMin = {for (final k in ProjectKind.values) k: 0};
  for (final r in dbRows) {
    kindMin[r.kind] = kindMin[r.kind]! + (weekMin[r.id] ?? 0);
  }
  final kindTotal = kindMin.values.fold<int>(0, (a, b) => a + b);
  String light(ProjectRow r) {
    if (r.path == null) return '<i class="lamp" title="폴더 없음"></i>';
    final want = ProjectStore.composeHangul(r.path!);
    final s = store.sessions
        .where((x) => ProjectStore.composeHangul(x.cwdPath) == want)
        .firstOrNull;
    if (s == null) return '<i class="lamp" title="세션 꺼짐"></i>';
    // 불빛을 누르면 그 세션의 대화가 오른쪽에 열린다.
    final open = ' onclick="chatFor(\'${htmlEscape(s.cwdPath)}\')"';
    return switch (s.status) {
      AgentStatus.waiting => '<i class="lamp wait talk" title="승인 대기 · 대화 보기"$open></i>',
      AgentStatus.thinking || AgentStatus.working => '<i class="lamp busy talk" title="일하는 중 · 대화 보기"$open></i>',
      _ => '<i class="lamp idle talk" title="세션 켜짐 · 대화 보기"$open></i>',
    };
  }
  final panelRows = dbRows.where((r) => r.state != ProjectState.closed).map((r) {
    final ts = open.where((t) => rowOf(t)?.id == r.id).toList();
    final me = ts.where((t) => TodoBoard.laneOf(t) == BallLane.me && isOnBoard(t)).length;
    final se = ts.where((t) => isOnBoard(t) &&
        (TodoBoard.laneOf(t) == BallLane.session || TodoBoard.laneOf(t) == BallLane.running)).length;
    final bk = ts.where((t) => t.status == TaskStatus.waiting).length;
    return (r: r, me: me, se: se, bk: bk, week: weekMin[r.id] ?? 0);
  }).toList()
    ..sort((a, b) {
      if (a.r.favorite != b.r.favorite) return a.r.favorite ? -1 : 1;
      final w = (b.me + b.se).compareTo(a.me + a.se);
      return w != 0 ? w : b.week.compareTo(a.week);
    });
  String cell(int n, {bool hot = false}) =>
      '<span class="n${n == 0 ? ' zero' : hot ? ' hot' : ''}">${n == 0 ? '·' : n}</span>';
  final panel = StringBuffer('<div class="prow head"><span></span><span>프로젝트</span>'
      '<span title="내 차례">대표</span><span title="세션 차례 · 진행중">세션</span><span>백로그</span><span>이번 주</span></div>');
  String prow(({ProjectRow r, int me, int se, int bk, int week}) x) {
    final sel = pick == x.r.id;
    return '<div class="prow${x.r.favorite ? '' : ' off'}${sel ? ' sel' : ''}">${star(x.r)}'
        '<span class="pname">${light(x.r)}${navLink(qs(p: sel ? '' : x.r.id), htmlEscape(x.r.name))}'
        '<small>${x.r.kind.label}</small><a class="reclink" href="?view=project&id=${htmlEscape(x.r.id)}" title="기록 페이지">›</a></span>'
        '${cell(x.me, hot: true)}${cell(x.se)}${cell(x.bk)}<span class="n wk">${hm(x.week)}</span></div>';
  }
  // 할 일도 이번 주 시간도 없는 프로젝트는 접는다 — 빈 줄이 절반이면 읽을 줄이 묻힌다(UI 리뷰).
  bool quiet(({ProjectRow r, int me, int se, int bk, int week}) x) =>
      !x.r.favorite && x.r.id != pick && x.me + x.se + x.bk == 0 && x.week == 0;
  var divided = false;
  for (final x in panelRows.where((x) => !quiet(x))) {
    if (!x.r.favorite && !divided && favIds.isNotEmpty) {
      panel.write('<div class="psub">즐겨찾기 밖 — 리스트·보드 기본 화면에서 빠진다</div>');
      divided = true;
    }
    panel.write(prow(x));
  }
  final quietRows = panelRows.where(quiet).toList();
  if (quietRows.isNotEmpty) {
    panel.write('<details class="pmore" id="f-pmore"><summary>할 일 없는 프로젝트 ${quietRows.length}개</summary>'
        '${quietRows.map(prow).join()}</details>');
  }
  String pct(ProjectKind k) => kindTotal == 0 ? '0' : (kindMin[k]! / kindTotal * 100).toStringAsFixed(1);
  panel.write('<div class="kbar">${[for (final k in ProjectKind.values) '<span class="c-${k.color}" style="width:${pct(k)}%"></span>'].join()}</div>'
      '<div class="kleg">${[for (final k in ProjectKind.values) '<span class="c-${k.color}"><i></i>${k.label} ${hm(kindMin[k]!)}</span>'].join()}</div>'
      '<div class="psub">이번 주 = ${wStart.month}/${wStart.day}(월)~${wEnd.month}/${wEnd.day} 세션 기록 합계 · 이름을 누르면 그 프로젝트만 보인다'
      '${pick.isEmpty ? '' : ' · ${navLink(qs(p: ''), '즐겨찾기로')}'}</div>');

  // 프로젝트 탭은 리스트에도 둔다 — 보드에만 있으면 리스트에서 「전체」로 넓힐 길이 오른쪽 판뿐이었다(대표 요청 9/15).
  final findBar = query.isEmpty
      ? ''
      : '<div class="whobar find-bar"><span>🔎 <b>${htmlEscape(query)}</b> 찾는 중 <em>${f.length}건</em>'
          '</span>'
          '<button class="txtbtn" onclick="findClear()" title="찾기 지우기">전체로 ✕</button></div>';
  // 찾기 칸은 프로젝트 줄 오른쪽 끝에 둔다(대표 요청 9/16) — 머리에 두니 「+ 새로」와 붙어 눈이 갔다.
  final findBox = '<label class="find" title="제목·시킬 말·작업 내용에서 찾는다">'
      '<input id="q" type="search" placeholder="찾기" value="${htmlEscape(query)}" autocomplete="off"'
      ' oninput="findTask(this,event)" onkeydown="findKey(event)" oncompositionend="findTask(this)">'
      '${query.isEmpty ? '' : '<button type="button" class="x" onclick="findClear()" title="찾기 지우기">✕</button>'}</label>';
  // ⚠️ 리스트에서는 오른쪽에 프로젝트 판이 서서, 줄 끝에 둔 찾기 칸이 그 판 위로 삐져나와 보였다(대표 제보 9/16).
  // 목록 칸(왼쪽)과 같은 폭으로 맞춘다 — 보드에서는 판이 없어 예전처럼 맨 오른쪽 끝이다.
  final listHtml = '''$findBar$whoBar<div class="ptabsrow list-row"><nav class="ptabs">$tabs</nav>$findBox</div>
<div class="grid2"><aside><section class="blk"><h2>프로젝트 <span class="hint">★ 즐겨찾기한 프로젝트가 기본으로 보인다</span></h2>
<div class="ppanel">$panel</div></section></aside><main>
${stale.isEmpty ? '' : '<div class="banner"><span><b>어제 못 한 오늘예정 ${stale.length}건</b> <span class="faint">— ${stale.take(4).map((t) => htmlEscape(t.text)).join(' · ')}${stale.length > 4 ? ' …' : ''}</span></span>'
    '<span class="ba"><button class="go primary" onclick="stale([$staleIds],\'keep\')">오늘 다시</button>'
    '<button class="go" onclick="stale([$staleIds],\'drop\')">백로그로</button></span></div>'}
<nav class="lsum" aria-label="칸 요약">${[
    ('s-run', '진행중', running.length),
    ('s-review', '확인필요', review.length),
    ('s-today', '오늘', myToday.length),
    ('f-sess', '세션', sess.length),
    ('f-hold', '대기', hold.length),
    ('f-back', '백로그', drawer.length),
  ].map((x) => '<a href="#${x.$1}" onclick="return jump(\'${x.$1}\')">${x.$2} <b>${x.$3}</b></a>').join('<i>·</i>')}</nav>
<section class="blk" id="s-run" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'running')"><h2>진행중 <em>${running.length}</em></h2>
${running.isEmpty ? '<div class="list"><div class="empty">돌고 있는 일이 없다.</div></div>' : '<div class="list">${grouped(running, runRow, lane: 'running', laneLabel: laneShort(BallLane.running), list: true)}</div>'}</section>
<section class="blk" id="s-review" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'review')"><h2>내 차례 · 확인필요 <em>${review.length}</em><span class="hint">위에서부터 넘기며 비운다</span></h2>
${listOf(review, '확인할 것이 없다. 세션들이 다음 일로 넘어갈 수 있다.', implied: TaskStatus.review, lane: 'review', laneLabel: laneShort(BallLane.me))}</section>
<section class="blk" id="s-today" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'today','owner')"><h2>내 차례 · 오늘 할 일 <em>${myToday.length}</em></h2>
${listOf(myToday, scope == TodoScope.today ? '오늘 대표가 할 일은 확인필요뿐이다. 「이번 주」로 넓혀 본다.' : '이 범위에 대표 몫이 없다.', implied: TaskStatus.today, lane: 'today', laneLabel: laneShort(BallLane.me))}</section>
<details class="fold" id="f-sess" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'sessionPlanned','session')"><summary>세션 차례 <b>${sess.length}</b> <span class="faint">세션예정 $planN${revN == 0 ? '' : ' · <span class="rvc">수정요청 $revN</span>'}</span>${sendAll(sess)}</summary>
${listOf(sess, '세션에 넘긴 일이 없다.', lane: 'session', laneLabel: laneShort(BallLane.session))}</details>
<details class="fold${hold.isEmpty ? '' : ' warn'}" id="f-hold" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'paused')"><summary>대기 · 멈춤 <b>${hold.length}</b></summary>
${listOf(hold, '막힌 일이 없다.', lane: 'hold', laneLabel: laneShort(BallLane.hold))}</details>
<details class="fold" id="f-back" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'waiting')"><summary>백로그 <b>${drawer.length}</b> <span class="faint">마감 없음 ${drawer.where((t) => t.due == null).length}</span></summary>
${listOf(drawer, '백로그가 없다.', lane: 'drawer', laneLabel: '백로그')}</details>
$noFavNote
</main>
</div>''';

  // 백로그 서랍도 놓는 자리다 — 리스트의 백로그 칸과 같게 끌어다 놓으면 백로그로 내린다(대표 요청 9/15).
  // 마감이 범위 안이면 서랍이 아니라 차례 칸에 다시 선다(TodoBoard.onBoard) — 서랍은 「마감 없는·먼 백로그」다.
  final boardHtml = '''$findBar$whoBar<div class="ptabsrow"><nav class="ptabs">$tabs</nav>$findBox</div>$noFavNote
<div class="board4">$cards</div>
<details class="fold drawer" id="f-drawer" ondragover="over(event)" ondragleave="leave(event)" ondrop="drop(event,'waiting')"><summary>백로그 서랍 <b>${drawer.length}</b> <span class="faint">· 칸이 아니라 서랍이다 — 꺼내면 차례 칸으로 간다</span></summary>
${listOf(drawer, '서랍이 비었다.', lane: 'drawer', laneLabel: '백로그')}</details>''';

  // 「새 할 일」 창 — 상세창과 같은 모양(업무 지시서처럼, 대표 요청 9/15). 세션 차례를 고르면 시킬 말 세 칸이 펴지고
  // 적자마자 시킬 수 있다. 한 줄 폼은 뺐다. 제목만 적고 엔터면 예전처럼 곧장 적힌다(내 차례·백로그).
  final newSheet = '<div class="sheet brief-mode newsheet" id="s-new"><div class="sh">'
      '<textarea class="title" id="nt" rows="1" placeholder="할 일 제목" oninput="grow(this)" onkeydown="newKey(event)"></textarea>'
      '<button class="ic x" title="닫기 (Esc)" onclick="closeSheet()">$icDel</button></div>'
      '<div class="chips">'
      // ⚠️ 고르는 칸에 이름표를 단다. 「프로젝트 ▾」 하나만 떠 있던 때는 **무엇을 고르는 칸인지**가 안 보였다(대표 제보 9/18).
      '<span class="nlab">어디에</span>'
      '<label class="pick"><span class="pjn" id="np-face">프로젝트</span>'
      '<select id="np" title="어느 프로젝트에 적을지" onchange="newSync()">${projectOptions(null)}</select></label>'
      '<span class="nlab">누가</span>'
      '<span class="nseg" role="group" aria-label="누가 할지">'
      '<button type="button" data-ns="waiting">나중에</button><button type="button" data-ns="today">내가</button>'
      '<button type="button" data-ns="sessionPlanned">세션이</button></span>'
      '<select id="ns" style="display:none"><option value="waiting">백로그</option><option value="today">내 차례</option><option value="sessionPlanned">세션 차례</option></select>'
      '</div>'
      // **받을 세션을 글자로 못 박는다.** 예전에는 「세션 차례」를 골라도 어느 세션이 받는지가
      // 화면에 없어서, 프로젝트를 잘못 고른 채 시키는 일이 생겼다(대표 제보 9/18).
      '<div class="ntarget" id="ntarget" hidden></div>'
      '<div class="brief" id="nbrief" hidden><div class="brief-h">시킬 말</div>'
      '<div class="bf big" data-f="what"><label for="nb-what">무엇을</label><textarea id="nb-what" data-part="what" rows="2" oninput="grow(this)" placeholder="무엇을 해야 하는지 — 비워 두면 제목만 간다"></textarea></div>'
      '<div class="bf" data-f="done"><label for="nb-done">완료 기준</label><textarea id="nb-done" data-part="done" rows="1" oninput="grow(this)" placeholder="이게 되면 끝"></textarea></div>'
      '<div class="bf" data-f="dont"><label for="nb-dont">하지 말 것</label><textarea id="nb-dont" data-part="dont" rows="1" oninput="grow(this)" placeholder="비워도 된다"></textarea></div>'
      '</div>'
      '<div class="sf">'   // 리뷰3 L5(9/17): 「닫기」 글자는 뺐다 — 위 ✕와 겹친다
      '<label class="nsend" id="nsend-wrap" hidden><input type="checkbox" id="nsend" checked> 적고 바로 시키기</label>'
      '<button class="go primary" id="ngo" onclick="newSubmit()">적기</button></div></div>';
  // 새 할 일 창이 「이 프로젝트를 고르면 어느 세션이 받는가」를 보여주려면 폴더를 알아야 한다(9/18).
  final projFolders = '<script>const PROJ_FOLDER = ${jsonEncode({
        for (final r in dbRows)
          if ((r.path ?? '').isNotEmpty) r.id: r.path,
      })};</script>';
  final scopeSeg = '<span class="seg scope">${[
          for (final sc in TodoScope.values)
            navLink(qs(sc: sc), sc.label, cls: sc == scope ? 'on' : ''),
        ].join()}</span>';

  return '''<!doctype html><html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>할 일 · Madang</title><link rel="icon" href="/todo/art/icon.png">
<style>
$kTodoCss</style>$kThemeBoot</head><body>
<header class="top v-$view"><h1>할 일 <b>${todos.remaining}</b></h1>
$scopeSeg
<button class="newbtn" onclick="newTask()">+ 새로</button>
<button class="chatbtn" onclick="chatToggle()" title="세션과 주고받은 대화 — 위젯의 메시지 탭">대화</button>
${limitDonuts(kLimits, big: false)}
${viewTabs(view, keep: '&scope=${scope.name}&p=${Uri.encodeQueryComponent(pick)}${who.isEmpty ? '' : '&who=${Uri.encodeQueryComponent(who)}'}', gear: hiddenCount == 0 ? '<span class="off">종료 프로젝트 할 일 없음</span>' : '<a href="?view=$view${showClosed ? '' : '&closed=1'}">종료 프로젝트 할 일 $hiddenCount건 ${showClosed ? '숨기기' : '보기'}</a>')}</header>
${todos.all.isEmpty ? '<div class="starter"><b>할 일이 아직 없다</b><span>처음이면 ① <a href="#" onclick="setupSheet(false);return false">처음 설정</a>에서 폴더를 붙이고 ② <b>+ 새로</b>로 할 일을 적은 뒤 ③ 「세션 차례」로 두고 <b>시키기</b>를 누르면 그 폴더의 세션이 받아 간다. 세션이 스스로 할 일을 만들기도 한다(폴더의 CLAUDE.md 규칙).</span><button class="go primary" type="button" onclick="newTask()">+ 새 할 일</button></div>' : ''}
${view == 'board' ? boardHtml : listHtml}
<div id="back" onclick="closeSheet()"></div>
$newSheet
$projFolders
$sheets
$kDuoHtml
<div id="err"></div>
<script>
const SLASH = ${jsonEncode([for (final c in slashCommands) {'name': c.name, 'hint': c.hint}])};
$kTodoJs
$kChatJs</script></body></html>''';
}

Future<void> startHookServer(SessionStore store, Todos todos,
    ProjectStore projects, LimitStore limits, ProjectDb db, WorkLog work,
    SessionLog sessions) async {
  try {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, kPort);
    debugPrint('훅 서버 시작: http://127.0.0.1:$kPort');
    debugPrint('할 일 페이지: http://127.0.0.1:$kPort/todo');
    await for (final request in server) {
      final path = request.uri.path;
      // 할 일 페이지. **훅과 같은 서버를 쓴다** — 위젯이 이미 열어둔 포트라
      // 새로 띄울 것이 없다.
      if (path.startsWith('/todo')) {
        // 이쪽은 127.0.0.1에만 묶여 있으므로 열쇠를 묻지 않는다.
        await _handleTodoRequest(request, store, todos, projects, db, work, sessions,
            needsKey: false);
        continue;
      }
      // 훅에 돌려줄 답. 상태 코드를 정한 뒤에 쓴다 — 먼저 쓰면 헤더가 이미
      // 나가서 상태 코드를 못 바꾸고 예외가 난다(2026-09-14, 확인용 판에서 서버가 죽었다).
      var reply = '';
      if (request.method == 'POST') {
        try {
          final body = await utf8.decoder.bind(request).join();
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            // 한도는 훅이 아니라 상태줄이 보낸다. 세션 상태를 건드리지
            // 않으므로 handleEvent로 넘기지 않고 여기서 가른다.
            final rl = decoded['rate_limits'];
            if (decoded['hook_event_name'] == 'RateLimits' &&
                rl is Map<String, dynamic>) {
              limits.handle(rl);
            } else {
              FirstRun.lastHookAt = DateTime.now();
              store.handleEvent(decoded);
              final sid = decoded['session_id'] as String? ?? '';
              kOwnerNotices.see(sid);
              // ⚠️ **UserPromptSubmit에만 답을 싣는다.** 이 답은 그대로 세션의 맥락에
              // 들어간다. 다른 훅(특히 PreToolUse)은 답이 도구 실행을 바꿀 수 있어서
              // 절대 싣지 않는다 — 설정에서도 그 훅들은 답을 버린다.
              if (decoded['hook_event_name'] == 'UserPromptSubmit') {
                final text = kOwnerNotices.takeFor(
                    sid, decoded['cwd'] as String? ?? '', db.all);
                // 대표가 지어 준 이름 — 세션이 자기를 그 이름으로 알아듣게 한 번 알린다(9/18).
                // 폴더가 아니라 **그 세션**이 기준이라 session_id로 찾는다(하위 폴더에서 도구가 돌아도 안 갈린다).
                final s = store.byId(sid);
                final mine = s == null
                    ? ''
                    : kOffice.noticeFor(sid, s.cwdPath, s.folderName);
                reply = '$text$mine';
              }
            }
          }
        } catch (e) {
          debugPrint('페이로드 파싱 실패: $e');
        }
      }
      // ⚠️ 요청 하나가 실패해도 서버 루프는 살아 있어야 한다. 여기서 던지면
      // `await for`가 끝나 모든 캐릭터가 멈춘다.
      try {
        request.response.statusCode = 200;
        if (reply.isNotEmpty) {
          request.response.headers.contentType = ContentType.text;
          request.response.write(reply);
        }
        await request.response.close();
      } catch (e) {
        debugPrint('훅 답 쓰기 실패: $e');
      }
    }
  } catch (e) {
    debugPrint('훅 서버 시작 실패 (포트 $kPort 사용 중일 수 있음): $e');
  }
}

/// 할 일만 밖으로 여는 서버. **폰에서 보는 입구다.**
///
/// ⚠️ **훅 서버와 나눠 둔다.** 훅 쪽은 POST 하나로 캐릭터 상태를 지어낼 수
/// 있는 입구인데 인증이 없다(4-1절). 밖에서 볼 이유가 있는 것은 할 일뿐이라
/// 그것만 떼어내 따로 연다.
///
/// 집 밖에서는 테일스케일로 붙는다 — `0.0.0.0`이라 그쪽 인터페이스로도
/// 같이 열린다. 공유기에 포트를 뚫는 것과는 다른 이야기고, **그건 하지 않는다.**
Future<void> startTodoServer(
    SessionStore store, Todos todos, ProjectStore projects, ProjectDb db,
    WorkLog work, SessionLog sessions) async {
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, kTodoPort);
    debugPrint('폰에서 여는 할 일: http://<이 맥의 주소>:$kTodoPort'
        '/todo?k=${TodoKey.value}');
    await for (final request in server) {
      if (!request.uri.path.startsWith('/todo')) {
        request.response.statusCode = 404;
        await request.response.close();
        continue;
      }
      await _handleTodoRequest(request, store, todos, projects, db, work, sessions,
          needsKey: true);
    }
  } catch (e) {
    debugPrint('할 일 서버 시작 실패 (포트 $kTodoPort): $e');
  }
}

/// 폰이 붙을 수 있는 이 맥의 주소들 — 같은 와이파이(사설 대역)와 테일스케일(100.64/10).
///
/// ⚠️ [lanAddress]는 첫 주소 하나만 줘서 테일스케일·유선이 섞이면 엉뚱한 쪽을 줬다. 대시보드의
/// 「폰으로 보기」는 붙을 수 있는 것을 전부 보여 주고 사람이 고른다. 링크 로컬(169.254)·그 밖은 뺀다.
Future<List<({String label, String address})>> phoneAddresses() async {
  final out = <({String label, String address})>[];
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    for (final iface in list) {
      for (final a in iface.addresses) {
        final label = phoneAddressLabel(a.address);
        // 같은 쪽(와이파이·유선이 한 공유기)에 주소가 둘이면 첫 것만 — QR이 두 장 뜨면 어느 것을 찍을지 헷갈린다.
        if (label != null && !out.any((x) => x.label == label)) out.add((label: label, address: a.address));
      }
    }
  } catch (e) {
    debugPrint('주소 목록을 못 읽음: $e');
  }
  // 같은 와이파이가 먼저다 — 집에서 폰으로 볼 때가 대부분이다.
  out.sort((a, b) => (a.label == '같은 와이파이' ? 0 : 1).compareTo(b.label == '같은 와이파이' ? 0 : 1));
  return out;
}

/// 주소 하나가 폰에서 붙을 수 있는 쪽인지. 아니면 null.
String? phoneAddressLabel(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((x) => x == null)) return null;
  final a = p[0]!, b = p[1]!;
  if (a == 100 && b >= 64 && b <= 127) return '테일스케일';
  if (a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)) return '같은 와이파이';
  return null;
}

/// 글을 QR 그림(SVG)으로. 둘레에 네 칸 여백을 둔다(찍을 때 그래야 잘 읽힌다).
String qrSvg(String data) {
  final img = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
  final n = img.moduleCount;
  final d = StringBuffer();
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (img.isDark(y, x)) d.write('M${x + 4} ${y + 4}h1v1h-1z');
    }
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n + 8} ${n + 8}" shape-rendering="crispEdges">'
      '<rect width="100%" height="100%" fill="#fff"/><path fill="#111" d="$d"/></svg>';
}

/// 이 맥이 같은 망에서 어떤 주소로 보이나. 폰에 쳐 넣을 주소를 만드는 데 쓴다.
Future<String?> lanAddress() async {
  try {
    final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    for (final iface in list) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
  } catch (e) {
    debugPrint('랜 주소를 못 찾음: $e');
  }
  return null;
}

/// 브라우저에서 온 요청을 다룬다.
///
/// [needsKey]가 참이면 밖으로 열린 입구다 — 열쇠 없이는 아무것도 안 준다.
Future<void> _handleTodoRequest(HttpRequest request, SessionStore store,
    Todos todos, ProjectStore projects, ProjectDb db, WorkLog work,
    SessionLog sessions,
    {required bool needsKey}) async {
  final res = request.response;
  // ⚠️ 세션 API는 **이 맥 안(9876)에서만** 연다. 폰 입구(9878)로는 안 받는다 —
  // 열쇠가 있어도 cwd 하나로 남의 프로젝트를 흉내 낼 수 있어서다.
  if (request.uri.path.startsWith('/todo/api/')) {
    Map<String, dynamic> out;
    if (needsKey) {
      res.statusCode = 404;
      out = {'ok': false, 'error': '세션 API는 이 맥에서만 연다'};
    } else {
      try {
        final body = request.method == 'POST' ? await utf8.decoder.bind(request).join() : '';
        final data = body.isEmpty ? {} : jsonDecode(body);
        out = await handleTaskApi(request.method, request.uri.path,
            request.uri.queryParameters, data is Map ? data : {}, todos, db, sessions, kPendingMemo);
      } catch (e) {
        out = {'ok': false, 'error': '요청을 못 읽었다: $e'};
      }
    }
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(out));
    await res.close();
    return;
  }
  try {
    if (needsKey && !TodoKey.allows(request.uri, request.cookies)) {
      debugPrint('열쇠 없는 요청을 막았다: ${request.uri.path} '
          '← ${request.connectionInfo?.remoteAddress.address}');
      res.statusCode = 401;
      res.headers.contentType = ContentType.html;
      res.write('<!doctype html><meta charset="utf-8">'
          '<body style="background:#1A1A2E;color:#8b8ba7;'
          'font:14px -apple-system,sans-serif;padding:40px">'
          '열쇠가 없다. 위젯의 할 일 패널에서 <b>폰</b>을 눌러 주소를 받아온다.');
      await res.close();
      return;
    }
    // 열쇠를 들고 왔으면 쿠키로 바꿔 준다. 그래야 다음부터 짧은 주소로 열리고,
    // 페이지 안의 링크(보기 바꾸기)에 열쇠를 안 달고 다녀도 된다.
    if (needsKey && request.uri.queryParameters['k'] == TodoKey.value) {
      res.cookies.add(Cookie(TodoKey.cookieName, TodoKey.value)
        ..path = '/'
        ..httpOnly = true
        ..maxAge = 60 * 60 * 24 * 365);
    }
    // 폰으로 보기 — 폰에서 열 주소(열쇠 포함)와 QR. **이 맥 안에서만** 준다 — 열쇠를 밖으로 내주는 길이라서다.
    if (request.method == 'GET' && request.uri.path == '/todo/app/phone') {
      res.headers.contentType = ContentType.json;
      if (needsKey) {
        res.write(jsonEncode({'ok': false, 'error': '폰에서는 받을 수 없다'}));
      } else {
        final addrs = await phoneAddresses();
        res.write(jsonEncode({
          'ok': true,
          'urls': [
            for (final a in addrs)
              {
                'label': a.label,
                'url': 'http://${a.address}:$kTodoPort/todo?k=${TodoKey.value}',
                'svg': qrSvg('http://${a.address}:$kTodoPort/todo?k=${TodoKey.value}'),
              },
          ],
        }));
      }
      await res.close();
      return;
    }
    // 처음 설정 — 준비물·훅·폴더 점검. 이 맥의 설정을 읽는 일이라 폰에는 안 준다.
    if (request.method == 'GET' && request.uri.path == '/todo/app/setup') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(needsKey ? {'ok': false, 'error': '폰에서는 볼 수 없다'} : await FirstRun.status(projects)));
      await res.close();
      return;
    }
    // 쓰는 에이전트 — 대화 칸 「출근시키기」가 Claude/Codex 버튼을 몇 개 낼지 묻는다(가볍게: 저장값, 없으면 설치 여부).
    if (request.method == 'GET' && request.uri.path == '/todo/app/agents') {
      res.headers.contentType = ContentType.json;
      final home = Platform.environment['HOME'] ?? '';
      final a = FirstRun.savedAgents() ?? FirstRun.agentsOf(
          await FirstRun.which('claude', ['$home/.local/bin/claude', '$home/.claude/local/claude', '/opt/homebrew/bin/claude', '/usr/local/bin/claude']),
          await FirstRun.codexPath());
      res.write(jsonEncode({'ok': true, 'claude': a.claude, 'codex': a.codex}));
      await res.close();
      return;
    }
    // 켜는 모양 읽기 — ⚙ 「켜는 모양 바꾸기」가 지금 값을 묻는다.
    if (request.method == 'GET' && request.uri.path == '/todo/app/mode') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': true, 'mode': LaunchModeStore.load()}));
      await res.close();
      return;
    }
    // 비상구 — 워쳐의 할 일을 노션에 다시 넣을 수 있는 CSV로 내준다(대표 결정, 2026-09-14).
    if (request.method == 'GET' && request.uri.path == '/todo/export.csv') {
      final day = DateTime.now().toIso8601String().substring(0, 10);
      res.headers.set('Content-Type', 'text/csv; charset=utf-8');
      res.headers.set('Content-Disposition',
          'attachment; filename="watcher_tasks_$day.csv"');
      res.write(todosToCsv(todos.all, db));
      await res.close();
      return;
    }
    // ── 근무기록 읽기 (루트 세션용 JSON) ──
    // ⚠️ 정산 전에는 늘 현재 값을 다시 읽는다 — 이미 기록된 구간을 두 번 더하지 않게.
    if (request.method == 'GET' && request.uri.path.startsWith('/todo/work/')) {
      res.headers.contentType = ContentType.json;
      final q = request.uri.queryParameters;
      switch (request.uri.path) {
        case '/todo/work/day':
          final d = work.of(q['date'] ?? '');
          res.write(jsonEncode({'ok': d != null, 'day': d?.toJson(),
              if (d == null) 'error': '그 날짜 행이 없다'}));
        case '/todo/work/days':
          final month = q['month'] ?? '';
          res.write(jsonEncode({'ok': true,
              'days': [for (final d in work.all) if (d.date.startsWith(month)) d.toJson()]}));
        default:
          res.statusCode = 404;
      }
      await res.close();
      return;
    }
    // ── 대화 칸 (대시보드 오른쪽) ── 위젯의 메시지 탭과 같은 것을 JSON으로 준다.
    // 페이지 전체를 다시 그리지 않고 이 칸만 2초마다 받아 그린다.
    if (request.method == 'GET' && request.uri.path.startsWith('/todo/chat/')) {
      res.headers.contentType = ContentType.json;
      res.headers.set('Cache-Control', 'no-store');
      final q = request.uri.queryParameters;
      switch (request.uri.path) {
        case '/todo/chat/pane':
          res.write(jsonEncode(await chatPaneApi(store, q)));
        // `@`로 집어 넣을 파일 — 위젯 입력창과 같은 목록(git ls-files, 없으면 깊이 4).
        // 회의 — 사회자 세션이 쓰는 상태.json을 그대로 내준다. 대시보드 회의 화면이 3초마다 본다(9/17).
        case '/todo/chat/meeting':
          res.write(jsonEncode(meetingApi(q['folder'])));
        case '/todo/chat/meetings':
          res.write(jsonEncode(meetingListApi()));
        // 알림을 눌러 열어 달라는 대화 — 한 번 주고 비운다.
        case '/todo/chat/focus':
          final p = kPendingChatFocus;
          kPendingChatFocus = null;
          res.write(jsonEncode({'ok': true, if (p != null) 'path': p}));
        case '/todo/chat/files':
          final s = _sessionAt(store, q['path'] ?? '');
          res.write(jsonEncode(s == null
              ? {'ok': false, 'error': '그 세션이 지금 없다'}
              : {'ok': true, 'files': matchFiles(await FileIndex.list(s.cwdPath), q['q'] ?? '')}));
        default:
          res.write(jsonEncode(chatApi(store, todos, request.uri.path, q)));
      }
      await res.close();
      return;
    }
    // 사무실 얼굴·모자 그림. 대화 칸 목록이 준 주소로만 불린다.
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        request.uri.path.startsWith('/todo/art/')) {
      // 파비콘 — 대표가 그린 픽셀 아이콘(art/icon.png, 앱 아이콘과 같은 그림). 탭·북마크·폰 홈에 뜬다(9/17).
      if (request.uri.path == '/todo/art/icon.png') {
        final f = File('${kArtStore?.dirPath ?? ''}/icon.png');
        if (f.existsSync()) {
          res.headers.contentType = ContentType('image', 'png');
          res.headers.set('Cache-Control', 'max-age=3600');
          res.add(f.readAsBytesSync());
        } else {
          res.statusCode = 404;
        }
        await res.close();
        return;
      }
      // 사무실 층 규격 — 그림을 통째로 그려 올릴 수 있게, 서는 선·창문 자리를 `art/office/layout.json`에서 읽는다
      // (대표 결정 9/18 「이미지 통으로 올려도 괜찮게」). 파일이 없으면 기본값이고, 고쳐도 재빌드가 필요 없다.
      if (request.uri.path == '/todo/art/office-layout') {
        final dir = kArtStore?.dirPath ?? '';
        final out = <String, dynamic>{
          'height': 104,
          'floorLine': 78,
          // 책상 띠 높이 — **그림 아래에서부터** 잰다. 그림이 층보다 길면 위가 잘리므로
          // 위에서 잰 `floorLine`은 못 쓴다(대표 9/18 「높이를 길게 반복 패턴으로 그려 줄게」).
          'band': null,
          'charDrop': 12,
          'desk': {'h': 24},
          'window': {'w': 48, 'h': 28, 'right': 8, 'top': 14},
        };
        try {
          final f = File('$dir/office/layout.json');
          if (f.existsSync()) {
            final j = jsonDecode(f.readAsStringSync());
            if (j is Map) {
              for (final k in ['height', 'floorLine']) {
                if (j[k] is num) out[k] = (j[k] as num).round();
              }
              if (j['charDrop'] is num) out['charDrop'] = (j['charDrop'] as num).round();
              if (j['band'] is num) out['band'] = (j['band'] as num).round();
              if (j['desk'] is Map && (j['desk'] as Map)['h'] is num) {
                out['desk'] = {'h': ((j['desk'] as Map)['h'] as num).round()};
              }
              if (j['window'] is Map) {
                final w = <String, dynamic>{...out['window'] as Map<String, dynamic>};
                for (final k in ['w', 'h', 'right', 'top']) {
                  if ((j['window'] as Map)[k] is num) w[k] = ((j['window'] as Map)[k] as num).round();
                }
                out['window'] = w;
              }
            }
          }
        } catch (e) {
          debugPrint('office/layout.json 읽기 실패: $e');
        }
        // 띠 높이를 안 적었으면 옛 방식(위에서 잰 `floorLine`)으로 셈한다.
        out['band'] ??= (out['height'] as int) - (out['floorLine'] as int);
        // 어떤 그림이 들어와 있는지도 같이 준다 — 페이지가 코드로 그릴지 말지 여기서 가른다.
        bool has(String n) => File('$dir/office/$n').existsSync();
        out['art'] = {
          'wall': has('wall.png') || has('wall_morning.png') || has('wall_afternoon.png') || has('wall_evening.png'),
          'desk': has('desk.png') || has('desk_morning.png') || has('desk_afternoon.png') || has('desk_evening.png'),
          'base': has('base.png') || has('base_morning.png') || has('base_afternoon.png') || has('base_evening.png'),
          'floor': has('floor.png') || has('floor_morning.png') || has('floor_afternoon.png') || has('floor_evening.png'),
          'boss': has('boss.png') || has('boss_morning.png') || has('boss_afternoon.png') || has('boss_evening.png'),
          'window': has('window.png') || has('window_morning.png') || has('window_afternoon.png') || has('window_evening.png'),
        };
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(out));
        await res.close();
        return;
      }
      // 사무실 층 배경 — `art/office/<칸>_<시간대>.png`. 좁은 것부터 찾고, 하나도 없으면 404다
      // (그러면 페이지의 그라데이션만 남는다 — 그림을 안 그려도 화면이 멀쩡하다, 9/18).
      if (request.uri.path == '/todo/art/office') {
        final dir = kArtStore?.dirPath ?? '';
        final raw = request.uri.queryParameters['kind'] ?? 'floor';
        // 벽·책상·바닥·창문을 **따로 받는다**(대표 결정 9/18) — 그려서 갈아 끼우기 쉽고,
        // 책상은 자리마다 반복해 깔아야 해서 한 장으로는 안 된다.
        final kind = const {'boss', 'floor', 'window', 'wall', 'desk', 'base'}.contains(raw) ? raw : 'floor';
        const tods = {'morning', 'afternoon', 'evening'};
        final tod = tods.contains(request.uri.queryParameters['tod'] ?? '')
            ? request.uri.queryParameters['tod']
            : null;
        File? found;
        for (final name in [
          if (tod != null) '${kind}_$tod.png',
          '$kind.png',
          // 창문·책상은 벽으로 떨어지지 않는다 — 없으면 코드가 그린 것을 쓴다.
          if (kind != 'window' && kind != 'desk' && kind != 'wall' && kind != 'base') ...[
            if (tod != null) 'floor_$tod.png',
            'floor.png',
          ],
        ]) {
          final f = File('$dir/office/$name');
          if (f.existsSync()) {
            found = f;
            break;
          }
        }
        if (found == null) {
          res.statusCode = 404;
        } else {
          res.headers.contentType = ContentType('image', 'png');
          // 그림을 갈아 끼우고 ↺만 누르면 되게 오래 물고 있지 않는다.
          res.headers.set('Cache-Control', 'max-age=60');
          res.add(found.readAsBytesSync());
        }
        await res.close();
        return;
      }
      final q = request.uri.queryParameters;
      ui.Image? image;
      if (request.uri.path == '/todo/art/sprite') {
        final want = ProjectStore.composeHangul(q['path'] ?? '');
        for (final floor in store.floors) {
          for (final s in floor.sessions) {
            if (ProjectStore.composeHangul(s.cwdPath) != want) continue;
            final frames = kArtStore?.framesOf(s.folderName, s.artStatus,
                setName: s.project.charSet ?? floor.tierOf(s));
            if (frames != null && frames.isNotEmpty) image = frames.first.image;
          }
        }
      } else if (request.uri.path == '/todo/art/hat') {
        image = kArtStore?.hatOf(q['tier'] ?? '', q['st'] ?? 'idle')?.image;
      }
      final bytes = image == null ? null : await pngOf(image);
      if (bytes == null) {
        res.statusCode = 404;
      } else {
        res.headers.contentType = ContentType('image', 'png');
        res.headers.set('Cache-Control', 'max-age=300');
        res.add(bytes);
      }
      await res.close();
      return;
    }
    if (request.method == 'GET') {
      res.headers.contentType = ContentType.html;
      // 보기는 주소에 실려 온다. 새로고침이 주소를 그대로 들고 가므로
      // 따로 기억해 둘 것이 없다.
      final view = request.uri.queryParameters['view'];
      final recordRow = view == 'project' ? db.byId(request.uri.queryParameters['id'] ?? '') : null;
      res.write(recordRow != null
          ? projectRecordPageHtml(recordRow, db, todos, sessions.all, local: !needsKey)
          : view == 'work'
          ? workPageHtml(work, month: request.uri.queryParameters['month'])
          : view == 'meeting'
          ? meetingPageHtml()
          : view == 'usage'
          ? usagePageHtml(kUsage, kLimits)
          : view == 'chat'
          ? chatOnlyPageHtml()
          : view == 'projects'
          ? projectPageHtml(db, todos)
          : todoPageHtml(store, todos, db,
              // 옛 주소(?view=table)는 리스트로 연다.
              view: view == 'board' ? 'board' : 'list',
              showClosed: request.uri.queryParameters['closed'] == '1',
              scope: TodoScope.parse(request.uri.queryParameters['scope']),
              pick: request.uri.queryParameters['p'] ?? '',
              who: request.uri.queryParameters['who'] ?? '',
              query: request.uri.queryParameters['q'] ?? '',
              sessionRecords: sessions.all));
      await res.close();
      return;
    }
    // 대화 칸에 놓은 파일·붙여넣은 그림. 본문은 파일 그대로, 이름은 주소에 싣는다.
    if (request.method == 'POST' && request.uri.path == '/todo/chat/upload') {
      final s = _sessionAt(store, request.uri.queryParameters['path'] ?? '');
      final bytes = <int>[];
      var tooBig = false;
      await for (final chunk in request) {
        if (bytes.length + chunk.length > 20 * 1024 * 1024) { tooBig = true; continue; }
        bytes.addAll(chunk);
      }
      final saved = (s == null || tooBig) ? null : saveUpload(request.uri.queryParameters['name'] ?? 'file', bytes);
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(saved == null
          ? {'ok': false, 'error': s == null ? '그 세션이 지금 없다' : tooBig ? '20MB가 넘는다' : '파일을 못 받았다'}
          : {'ok': true, 'error': null, 'token': dropToken(saved, s!.cwdPath)}));
      await res.close();
      return;
    }
    if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body);
      if (data is! Map) throw const FormatException('본문이 객체가 아니다');
      final id = data['id'] as String? ?? '';
      String? error;
      String? newId;
      // ── 되돌리기(⌘Z) ── 칸 이동·완료·지우기만 담는다(대표 결정 9/16). 하기 **전** 모습을 떠 두고,
      // 끝난 뒤 모습과 함께 한 걸음으로 쌓는다. 여기 한 곳에서 잡아야 길마다 빠뜨리지 않는다.
      const undoable = {
        '/todo/remove': '지우기',
        '/todo/status': '칸 옮기기',
        '/todo/move': '칸 옮기기',
        '/todo/check': '완료 처리',
        '/todo/toggle': '체크',
      };
      final undoLabel = undoable[request.uri.path];
      final undoBefore = undoLabel == null ? null : todos.byId(id)?.toJson();
      final undoTitle = undoLabel == null ? '' : (todos.byId(id)?.text ?? '');
      switch (request.uri.path) {
        // 되돌리기·다시 실행 — 페이지의 ⌘Z / ⇧⌘Z.
        case '/todo/undo':
        case '/todo/redo':
          final back = request.uri.path == '/todo/undo';
          final step = back ? kUndo.popUndo() : kUndo.popRedo();
          if (step == null) {
            error = back ? '되돌릴 것이 없다' : '다시 실행할 것이 없다';
            break;
          }
          final want = back ? step.before : step.after;
          if (want == null) {
            // 지운 것을 「다시 실행」하면 다시 지운다.
            todos.quietly(() => todos.remove(step.id));
          } else if (!todos.restore(want)) {
            error = '되돌릴 모습을 못 읽었다';
          }
          if (error == null) {
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode({
              'ok': true,
              'error': null,
              'label': step.label,
              'canUndo': kUndo.canUndo,
              'canRedo': kUndo.canRedo,
            }));
            await res.close();
            return;
          }
          break;
        case '/todo/add':
          // 상세창의 「+ 하위 태스크」 — 프로젝트·담당은 상위를 따른다.
          if ((data['parentId'] as String? ?? '').isNotEmpty) {
            error = todos.addChild(data['parentId'] as String, data['text'] as String? ?? '',
                body: data['body'] as String? ?? '');
            break;
          }
          // 프로젝트 ID가 오면 폴더는 프로젝트 목록에서 찾는다.
          final row = db.byId(data['projectId'] as String? ?? '');
          newId = todos.add(row?.path ?? (data['project'] as String? ?? ''),
              data['text'] as String? ?? '',
              status: TaskStatus.parse(data['status']), projectId: row?.id,
              body: data['body'] as String? ?? '');
          if (newId == null) error = '이름이 비었거나 프로젝트가 없다';
          break;
        case '/todo/toggle':
          todos.toggle(id);
          break;
        case '/todo/remove':
          todos.remove(id);
          break;
        case '/todo/status':
          todos.setStatus(id, TaskStatus.parse(data['status']));
          break;
        // 끌어 옮기기 — 칸은 진행사항과 **담당을 함께** 정한다. 세션 담당 카드를 「오늘 할 일」에 놓았는데
        // 진행사항만 바꾸면 담당이 세션이라 세션 차례에 그대로 남는다.
        case '/todo/move':
          switch (data['who']) {
            case 'owner':
              todos.edit(id, assignee: kOwnerAssignee);
            case 'session':
              // 비우면 세션예정으로 옮길 때 그 프로젝트 세션이 담당으로 들어간다(TodoStore.assigned).
              if (todos.byId(id)?.assignee == kOwnerAssignee) todos.edit(id, clearAssignee: true);
          }
          todos.setStatus(id, TaskStatus.parse(data['status']));
          break;
        // 어제 못 한 오늘예정 — 「오늘 다시」는 옮긴 시각만 오늘로, 「백로그로」는 내린다.
        case '/todo/stale':
          final ids = [for (final x in (data['ids'] as List? ?? const [])) if (x is String) x];
          if (data['action'] == 'drop') {
            for (final x in ids) {
              todos.setStatus(x, TaskStatus.waiting);
            }
          } else {
            todos.touchStatus(ids);
          }
          break;
        // 근무기록 — 대표의 말이 트리거다. 시각은 부르는 쪽이 `date`로 확인해 보낸다.
        case '/todo/work/start':
          final date = data['date'] as String? ?? '';
          error = DateTime.tryParse(date) == null
              ? '날짜는 YYYY-MM-DD다'
              : work.apply(date, WorkLogStore.start(work.of(date), date, data['time'] as String? ?? ''));
          break;
        case '/todo/work/break-start':
          final date = data['date'] as String? ?? '';
          error = work.apply(date, WorkLogStore.breakStart(work.of(date),
              data['time'] as String? ?? '', note: data['note'] as String?));
          break;
        case '/todo/work/break-end':
          final date = data['date'] as String? ?? '';
          error = work.apply(date, WorkLogStore.breakEnd(work.of(date),
              data['time'] as String? ?? '', note: data['note'] as String?));
          break;
        case '/todo/work/end':
          final date = data['date'] as String? ?? '';
          error = work.apply(date, WorkLogStore.end(work.of(date), data['time'] as String? ?? ''));
          break;
        case '/todo/work/timeline':
          final date = data['date'] as String? ?? '';
          final d = work.of(date);
          error = d == null
              ? '그 날짜 행이 없다'
              : work.apply(date, (d.copyWith(timeline: WorkLogStore.appendTimeline(
                  d.timeline, data['text'] as String?)), null));
          break;
        case '/todo/work/edit':
          // 손으로 바로잡는 길. 준 칸만 바꾼다. 출근·퇴근·휴게가 바뀌면 실근무를 다시 센다.
          final date = data['date'] as String? ?? '';
          final d = work.of(date);
          if (d == null) {
            error = '그 날짜 행이 없다';
            break;
          }
          final bad = [
            for (final k in ['clockIn', 'clockOut'])
              if (data[k] != null && WorkLogStore.minutesOf(data[k] as String) == null) k,
          ];
          if (bad.isNotEmpty) {
            error = '시각은 HH:MM이다 (${bad.join(', ')})';
            break;
          }
          var next = d.copyWith(
            clockIn: data['clockIn'] as String?,
            clockOut: data['clockOut'] as String?,
            breakMin: (data['breakMin'] as num?)?.toInt(),
            state: data.containsKey('state') ? WorkState.parse(data['state']) : null,
            timeline: data['timeline'] as String?,
            intensity: WorkIntensity.parse(data['intensity']),
            muwidaraniHours: (data['muwidaraniHours'] as num?)?.toDouble(),
          );
          if (['clockIn', 'clockOut', 'breakMin'].any(data.containsKey)) {
            next = next.copyWith(actualHours: WorkLogStore.actualHoursOf(
                next.clockIn, next.clockOut, next.breakMin));
          }
          error = work.apply(date, (next, null));
          break;
        // 프로젝트 목록(노션이사 3/6).
        case '/todo/project/add':
          db.add(data['name'] as String? ?? '');
          break;
        case '/todo/project/edit':
          final rawPath = data['path'] as String?;
          db.edit(id,
              name: data['name'] as String?,
              client: data['client'] as String?,
              kind: data.containsKey('kind') ? ProjectKind.parse(data['kind']) : null,
              // 폴더는 빈 글자로 지운다.
              path: (rawPath == null || rawPath.trim().isEmpty) ? null : rawPath,
              clearPath: rawPath != null && rawPath.trim().isEmpty,
              state: data.containsKey('state') ? ProjectState.parse(data['state']) : null,
              favorite: data['favorite'] is bool ? data['favorite'] as bool : null);
          break;
        case '/todo/project/remove':
          db.remove(id);
          break;
        // 프로젝트 기록 — 사람이 쓰는 칸(소개·결정·보류·링크).
        case '/todo/project/note':
          db.setNote(id, (n) => n.copyWith(intro: (data['intro'] as String? ?? '').trim()));
          break;
        case '/todo/project/note-add':
          final kind = data['kind'] as String? ?? '';
          final text = (data['text'] as String? ?? '').trim();
          if (!ProjectNote.kinds.contains(kind) || text.isEmpty) {
            error = '무엇을 적을지 비었다';
            break;
          }
          final date = kind == 'links' ? '' : NoteEntry.dateOf(data['date'], DateTime.now().toIso8601String().substring(0, 10));
          if (date == null) {
            error = '날짜는 오늘까지만 적는다';
            break;
          }
          db.setNote(id, (n) => n.added(kind, NoteEntry(
              date: date, text: text, why: (data['why'] as String? ?? '').trim())));
          break;
        case '/todo/project/note-remove':
          db.setNote(id, (n) => n.removedAt(data['kind'] as String? ?? '', (data['index'] as num?)?.toInt() ?? -1));
          break;
        // 켜는 모양 · 브라우저로 열기 — 이 맥의 앱 창에 관한 것이라 폰에서는 받지 않는다.
        case '/todo/app/mode':
          final mode = data['mode'] as String? ?? '';
          if (needsKey) {
            error = '폰에서는 바꿀 수 없다';
          } else if (!kWidgetMode) {
            error = '이 판에는 바탕화면 위젯이 없다';
          } else if (mode != 'dashboard' && mode != 'widget') {
            error = 'mode는 dashboard 또는 widget이다';
          } else {
            LaunchModeStore.save(mode);
          }
          break;
        // 처음 설정 — 훅 연결 · 폴더 고르기. ~/.claude를 고치고 이 맥에 창을 띄우는 일이라 폰에서는 받지 않는다.
        case '/todo/app/setup-hooks':
          error = needsKey ? '폰에서는 바꿀 수 없다' : FirstRun.writeHooks(remove: data['remove'] == true);
          break;
        // 준비물 설치 버튼(대표 결정 9/17 — 게임의 DirectX처럼 앱이 깔아 준다). 이 맥에서만.
        case '/todo/app/install-claude':
          error = needsKey ? '폰에서는 없다' : await FirstRun.installClaude();
          break;
        case '/todo/app/install-git':
          error = needsKey ? '폰에서는 없다' : await FirstRun.installGit();
          break;
        // 코덱스(9/17) — 쓰는 에이전트 고르기 · 코덱스 설치 · 코덱스 훅
        case '/todo/app/agents':
          error = needsKey ? '폰에서는 바꿀 수 없다' : FirstRun.saveAgents(data['claude'] == true, data['codex'] == true);
          break;
        case '/todo/app/install-meeting':
          error = needsKey ? '폰에서는 없다' : FirstRun.installMeetingCommand();
          break;
        case '/todo/app/install-codex':
          error = needsKey ? '폰에서는 없다' : await FirstRun.installCodex();
          break;
        case '/todo/app/setup-codex-hooks':
          error = needsKey ? '폰에서는 바꿀 수 없다' : FirstRun.writeCodexHooks(remove: data['remove'] == true);
          break;
        case '/todo/app/add-folder':
          if (needsKey) {
            error = '폰에서는 고를 수 없다';
          } else {
            final path = await chooseFolder();
            if (path != null) {
              // 할 일 API가 이 폴더의 세션을 받아 주도록 프로젝트 줄도 같이 만든다.
              db.ensureFolder(path);
              if (!projects.add(path)) error = '이미 등록된 폴더다';
            }
          }
          break;
        // 출근·휴식·퇴근 — 이사 세션에 그 말을 보낸다. 꺼져 있으면 그 말을 첫 말로 켠다.
        case '/todo/app/clock':
          final base = ClockButtons.say[data['action']];
          // ⚠️ **날짜를 말에 실어 준다.** 자정을 넘겨 어제 근무를 이어가는 중이면 세션이 오늘 날짜로
          // 적어 버려서 어제 근무가 열린 채로 남는다(대표 제보 9/18).
          final day = ClockButtons.openDateNow(DateTime.now());
          final text = base == null
              ? null
              : (day == ClockButtons.ymd(DateTime.now())
                  ? base
                  : '$base — 어제($day) 근무를 이어서 한 것이다. 근무기록도 그 날짜($day)에 적는다');
          final boss = ClockButtons.director(store);
          if (!kWorkButtons) {
            error = '이 판에는 출퇴근 버튼이 없다';
          } else if (text == null) {
            error = 'action은 start · breakStart · breakEnd · end다';
          } else if (boss == null) {
            error = '이사 세션이 없다 — 가장 바깥 폴더를 먼저 등록한다';
          } else if (Tmux.binary == null) {
            error = 'tmux가 없다';
          } else if (!await Tmux.hasSession(Tmux.sessionName(boss.cwdPath))) {
            if (!await Tmux.startSession(Tmux.sessionName(boss.cwdPath), boss.cwdPath, firstPrompt: text)) {
              error = '이사 세션을 못 켰다';
            }
          } else {
            error = await sendToSession(store, boss.cwdPath, text);
          }
          break;
        // 하위 세션 추가 — 대화 칸 머리 「＋ 하위」. 지금 보는 세션 폴더 안에 만들거나 고른다.
        case '/todo/app/sub-folder':
          if (needsKey) {
            error = '폰에서는 만들 수 없다';
          } else {
            final parent = data['path'] as String? ?? '';
            if (_sessionAt(store, parent) == null) {
              error = '그 세션이 지금 없다';
            } else {
              final made = await FirstRun.subFolder(parent, pick: data['mode'] == 'pick');
              error = made.error;
              if (made.path != null) {
                if (!projects.add(made.path!)) error = '이미 등록된 폴더다';
                newId = made.path;
              }
            }
          }
          break;
        case '/todo/app/new-folder':
          if (needsKey) {
            error = '폰에서는 만들 수 없다';
          } else {
            final made = await FirstRun.newFolder();
            error = made.error;
            if (made.path != null) {
              db.ensureFolder(made.path!);
              projects.add(made.path!);
              newId = made.path;
            }
          }
          break;
        // 대시보드 앱(별도 프로세스)이 창 자리·크기를 적어 달라고 보낸다(1.88.2). 이 맥에서만.
        case '/todo/app/frame':
          if (needsKey) {
            error = '폰에서는 없다';
          } else {
            final x = (data['x'] as num?)?.toDouble(), y = (data['y'] as num?)?.toDouble(), w = (data['w'] as num?)?.toDouble(), h = (data['h'] as num?)?.toDouble();
            if (x == null || y == null || w == null || h == null) {
              error = 'x·y·w·h가 필요하다';
            } else {
              LaunchModeStore.saveFrame(Rect.fromLTWH(x, y, w, h));
            }
          }
          break;
        case '/todo/app/open-browser':
          if (needsKey) {
            error = '폰에서는 열 수 없다';
          } else {
            await Process.run('open', ['http://127.0.0.1:$kPort/todo']);
          }
          break;
        // 문서 열기 — **이 맥 안(9876)에서만.** 그 프로젝트 문서 목록에 있는 경로만 연다(아무 파일이나 열게 하지 않는다).
        case '/todo/project/open-doc':
          final row = db.byId(id);
          final want = ProjectStore.composeHangul(data['path'] as String? ?? '');
          if (needsKey) {
            error = '폰에서는 문서를 열 수 없다';
          } else if (row?.path == null ||
              !ProjectDocs.scan(row!.path!, otherProjects: [for (final x in db.all) if (x.path != null) x.path!])
                  .any((d) => d.path == want)) {
            error = '그 프로젝트의 문서가 아니다';
          } else {
            await Process.run('open', [want]);
          }
          break;
        // 노션의 ▶️ · ⏸️ · ✅.
        case '/todo/play':
          todos.play(id);
          break;
        case '/todo/pause':
          todos.pause(id);
          break;
        case '/todo/check':
          todos.check(id);
          break;
        case '/todo/edit' when data.containsKey('projectId'):
          final row = db.byId(data['projectId'] as String? ?? '');
          if (row == null) {
            error = '그 프로젝트가 없다';
          } else {
            todos.moveTo(id, row);
          }
          break;
        case '/todo/edit':
          // 마감일은 빈 글자로 지운다 — `<input type="date">`를 비우면 그렇게 온다.
          final rawDue = data['due'] as String?;
          todos.edit(id,
              text: data['text'] as String?,
              body: data['body'] as String?,
              content: data['content'] as String?,
              revisionNote: data['revisionNote'] as String?,
              project: data['project'] as String?,
              priority: data.containsKey('priority')
                  ? TaskPriority.parse(data['priority'])
                  : null,
              // 유형은 빈 글자로 비운다 — 고르는 칸의 `—`가 그렇게 온다.
              kind: TaskKind.parse(data['kind']),
              clearKind: data['kind'] == '',
              // 담당도 빈 글자로 비운다.
              assignee: (data['assignee'] as String?)?.isEmpty ?? true
                  ? null
                  : data['assignee'] as String,
              clearAssignee: data['assignee'] == '',
              due: (rawDue == null || rawDue.isEmpty)
                  ? null
                  : DateTime.tryParse(rawDue),
              clearDue: rawDue != null && rawDue.isEmpty);
          if (data['parentId'] is String) error = todos.setParent(id, data['parentId'] as String);
          break;
        // [임시 진단] 페이지가 보낸 한 줄을 로그에 남긴다(?dbg=scroll).
        case '/todo/debug':
          if (!needsKey) debugPrint('[dbg] ${data['t']}ms ${data['m']} | ${data['why']}');
          break;
        // 대화에 나온 경로를 파인더로 — 이 맥 안에서만(폰은 파인더가 없다).
        case '/todo/chat/reveal':
          if (needsKey) {
            error = '폰에서는 파인더를 열 수 없다';
            break;
          }
          final t = revealTarget(data['path'] as String? ?? '', data['cwd'] as String? ?? '',
              home: Platform.environment['HOME'] ?? '', block: BlockList.load());
          if (t.error != null) {
            error = t.error;
          } else {
            await Process.run('open', t.dir ? [t.path!] : ['-R', t.path!]);
          }
          break;
        // 대화 칸에서 친 말. 위젯 입력창과 같은 길(sendToSession)이라 승인 대기면 거절한다.
        // 회의 끝내기 — 사회자가 안 닫은 회의(테스트·중단)를 대표가 닫는다. 상태.json의 상태만 완료로 바꾼다(회의록은 그대로).
        // 회의실의 대표 의견 칸 — 「다음 회의 이어가기」는 의견을, 「회의 끝내기」는 「완료」를 사회자에게 보낸다(/회의 Step 6).
        case '/todo/chat/meeting-say':
          final m = kMeetings?.now;
          final text = (data['text'] as String? ?? '').trim();
          final finish = data['finish'] == true;
          if (needsKey) {
            error = '폰에서는 없다';
          } else if (m == null || m.done) {
            error = '도는 회의가 없다';
          } else if (!finish && text.isEmpty) {
            error = '의견이 비었다';
          } else {
            error = await sendToSession(store, MeetingStore.moderatorOf(m.folder),
                finish ? '완료${text.isEmpty ? '' : '\n마지막 의견: $text'}' : '의견: $text');
          }
          break;
        case '/todo/chat/meeting-end':
          if (needsKey) {
            error = '폰에서는 없다';
          } else {
            final m = kMeetings?.now;
            if (m == null) {
              error = '도는 회의가 없다';
            } else {
              try {
                final f = File('${m.folder}/상태.json');
                final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
                j['상태'] = '완료';
                j['갱신'] = DateTime.now().toIso8601String();
                if ((j['결론'] ?? '').toString().trim().isEmpty) j['결론'] = '(대시보드에서 끝냄 — 사회자가 결론을 적지 않았다)';
                f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j));
              } catch (e) {
                error = '상태 파일을 못 고쳤다: $e';
              }
            }
          }
          break;
        case '/todo/chat/send':
          final text = (data['text'] as String? ?? '').trim();
          error = text.isEmpty
              ? '보낼 말이 비었다'
              : await sendToSession(store, data['path'] as String? ?? '', text);
          break;
        // 선택 카드·멈추기·원본 — 위젯의 메시지 탭과 같은 동작([PaneActions]).
        case '/todo/chat/choose':
        case '/todo/chat/submit':
          final s = _sessionAt(store, data['path'] as String? ?? '');
          if (s == null) {
            error = '그 세션이 지금 없다';
            break;
          }
          final r = request.uri.path == '/todo/chat/submit'
              ? await PaneActions.submit(s.cwdPath)
              : await PaneActions.choose(s.cwdPath, (data['n'] as num?)?.toInt() ?? 0, text: data['text'] as String?);
          error = r.error;
          if (r.said != null) store.appendMine(s, r.said!, chose: true);
          break;
        case '/todo/chat/point':
          error = await PaneActions.point(data['path'] as String? ?? '', (data['n'] as num?)?.toInt() ?? 0,
              text: data['text'] as String?);
          break;
        case '/todo/chat/toggle':
          error = await PaneActions.toggle(data['path'] as String? ?? '', (data['n'] as num?)?.toInt() ?? 0,
              text: data['text'] as String?);
          break;
        // 세션 이름 바꾸기 — 보이는 이름만 바꾸고, 그 세션에도 알린다(9/18).
        case '/todo/chat/rename':
          final s = _sessionAt(store, data['path'] as String? ?? '');
          if (s == null) {
            error = '그 세션이 지금 없다';
            break;
          }
          final want = (data['name'] as String? ?? '');
          error = kOffice.rename(s.cwdPath, want);
          if (error != null) break;
          // **켜진 세션에는 그 자리에서 말한다.** 훅 답은 다음 말을 걸 때까지 안 가므로,
          // 일하는 중인 세션은 자기 이름이 바뀐 줄 모른 채 한참을 간다.
          // 승인 대기·꺼진 세션이면 보내지 못하는데, 그때는 훅 답이 첫 말에서 대신 알린다.
          final now = kOffice.nameOf(s.cwdPath);
          final say = now == null
              ? '[마당] 대표가 이 세션의 별명을 지웠다. 이제 폴더 이름 「${s.folderName}」으로 부른다.'
              : '[마당] 대표가 이 세션의 이름을 「$now」로 정했다. 앞으로 대표가 「$now」라고 부르면 이 세션을 말하는 것이다. 지금 하던 일은 그대로 이어서 한다.';
          await sendToSession(store, s.cwdPath, say);
          break;
        // 층 올리기·내리기 — 이사 층은 맨 위 고정이라 팀 층끼리만 자리를 바꾼다.
        case '/todo/chat/floor':
          final dir = (data['dir'] as String? ?? '') == 'up' ? -1 : 1;
          error = kOffice.move(store.floors, data['team'] as String? ?? '', dir);
          break;
        case '/todo/chat/slide':
          error = await PaneActions.slide(data['path'] as String? ?? '', (data['i'] as num?)?.toInt() ?? -1,
              label: data['label'] as String?);
          break;
        case '/todo/chat/key':
          final s = _sessionAt(store, data['path'] as String? ?? '');
          error = s == null ? '그 세션이 지금 없다' : await PaneActions.key(s.cwdPath, data['key'] as String? ?? '');
          break;
        // 떠 있는 세션이 없을 때 여기서 띄운다 — 위젯 원본 탭의 「여기서 기동」.
        case '/todo/chat/launch':
          final s = _sessionAt(store, data['path'] as String? ?? '');
          if (s == null) {
            error = '그 세션이 지금 없다';
          } else if (Tmux.binary == null) {
            error = 'tmux가 없다';
          } else if (!await Tmux.startSession(Tmux.sessionName(s.cwdPath), s.cwdPath,
              firstPrompt: FirstRun.needsGreeting(s.cwdPath) ? FirstRun.greeting : null,
              agent: const {'claude', 'codex'}.contains(data['agent']) ? data['agent'] as String : null)) {
            error = '세션을 못 띄웠다';
          }
          break;
        // 퇴근 — 켜진 tmux 세션을 내린다(「▶ 출근시키기」의 짝, 9/17). 사라진 세션은 30초 청소가 시계까지 멈춘다.
        case '/todo/chat/quit':
          final s = _sessionAt(store, data['path'] as String? ?? '');
          if (s == null) {
            error = '그 세션이 지금 없다';
          } else if (Tmux.binary == null) {
            error = 'tmux가 없다';
          } else if (!await Tmux.hasSession(Tmux.sessionName(s.cwdPath))) {
            error = '이미 퇴근한 세션이다';
          } else if (!await Tmux.killSession(Tmux.sessionName(s.cwdPath))) {
            error = '세션을 못 내렸다';
          }
          break;
        // 시키기 — 줄에 세우고, 세션이 쉬고 있으면 곧바로 보낸다([SendQueue]).
        case '/todo/send':
          error = kSendQueue == null ? '줄이 준비되지 않았다' : await kSendQueue!.submit(id);
          break;
        // 세션 차례 한 번에 시키기 — 하나씩 줄에 세운다. 같은 세션에 여러 장이면 차례로 나간다.
        case '/todo/send-many':
          final ids = [for (final x in (data['ids'] as List? ?? const [])) if (x is String) x];
          final fails = <String>[];
          for (final x in ids) {
            final e = kSendQueue == null ? '줄이 준비되지 않았다' : await kSendQueue!.submit(x);
            if (e != null) fails.add('「${todos.byId(x)?.text ?? x}」 $e');
          }
          if (fails.isNotEmpty) {
            error = '${ids.length}건 중 ${fails.length}건을 못 시켰다 — ${fails.take(3).join(' · ')}';
          }
          break;
        case '/todo/unqueue':
          todos.unqueue(id);
          break;
        default:
          res.statusCode = 404;
          await res.close();
          return;
      }
      // 잘 끝났으면 되돌리기 한 걸음으로 쌓는다. 지운 것은 「하고 난 모습」이 없다(다시 실행 = 다시 지우기).
      if (undoLabel != null && error == null && undoBefore != null) {
        final after = todos.byId(id)?.toJson();
        final short = undoTitle.length > 18 ? '${undoTitle.substring(0, 18)}…' : undoTitle;
        kUndo.push(UndoStep(
          label: short.isEmpty ? undoLabel : '「$short」 $undoLabel',
          id: id,
          before: undoBefore,
          after: after,
        ));
      }
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': error == null, 'error': error, if (newId != null) 'id': newId,
        if (undoLabel != null && error == null) 'undo': kUndo.nextLabel}));
      await res.close();
      return;
    }
    res.statusCode = 405;
    await res.close();
  } catch (e) {
    debugPrint('할 일 요청 실패: $e');
    try {
      res.statusCode = 400;
      await res.close();
    } catch (_) {}
  }
}

/// tmux 세션을 다루는 얇은 껍데기.
///
/// **PTY를 직접 소유하지 않는다.** 프로세스의 주인은 tmux이고 여기서는
/// CLI를 부르기만 한다. 이 전제를 깨면 터미널 에뮬레이터를 만들게 된다.
/// 선택창의 선택지 한 줄.
class PaneOption {
  const PaneOption({
    required this.number,
    required this.text,
    required this.selected,
    this.detail,
    this.checked,
  });

  final int number;
  final String text;

  /// 선택지 아래에 들여쓴 설명. 없으면 null.
  /// 이게 있어야 무엇을 고르는 건지 알 수 있는 창이 있다.
  final String? detail;

  /// 지금 커서(`❯`)가 이 줄에 있는지.
  final bool selected;

  /// 체크박스(`[ ]` · `[✔]`)가 붙은 줄인가. 안 붙었으면 null.
  ///
  /// ⚠️ **`false`와 `null`은 다르다.** `false`는 '체크할 수 있는데 안 켰다',
  /// `null`은 '체크박스가 없는 줄'이다. 다중 선택창에도 체크박스 없는 줄이
  /// 섞인다 — `Chat about this` 가 그렇다(실측 2026-08-11).
  final bool? checked;

  /// 눌러서 켜고 끌 수 있는 줄인가.
  bool get checkable => checked != null;
}

/// 화면에 떠 있는 번호 선택창.
///
/// ⚠️ **여기서 상태를 판정하지 않는다.** 지금이 승인 대기인지는 훅이 정하고,
/// 이 파서는 "그래서 무엇을 고르라는 건지"만 화면에서 떠온다.
/// 설계 원칙(터미널 출력으로 상태를 추측하지 않는다)을 넘지 않으려고 그은 선이다.
/// 그래서 호출부는 반드시 `status.waiting`일 때만 이걸 쓴다.
/// 여러 문항을 한 번에 물을 때 화면 맨 위에 서는 문항 표. `☐ 이름`(아직) · `☒ 이름`(답함).
class PaneTab {
  const PaneTab({required this.label, required this.done});
  final String label;
  final bool done;
  Map<String, dynamic> toJson() => {'label': label, 'done': done};

  /// 문항 표 한 줄을 읽는다. 문항 표가 아니면 빈 목록.
  static List<PaneTab> parseTabs(String line) {
    final l = line.trim();
    if (!l.startsWith('←')) return const [];
    final out = <PaneTab>[];
    for (final m in RegExp(r'([☐☑☒])\s*([^☐☑☒✔→]+)').allMatches(l)) {
      final label = m.group(2)!.trim();
      if (label.isEmpty) continue;
      out.add(PaneTab(label: label, done: m.group(1) != '☐'));
    }
    return out;
  }
}

class PaneChoice {
  const PaneChoice({
    required this.question,
    required this.options,
    this.hint,
    this.lead = const [],
    this.cursorRow,
    this.submitRow,
    this.submitLabel,
    this.preview = const [],
    this.tabs = const [],
  });

  /// 문항이 여럿일 때의 문항 표(`←  ☒ Fruit  ☐ Drink  ✔ Submit  →`).
  ///
  /// 이 줄이 앞말에 그대로 섞여 나가 **무엇을 묻는지 안 읽혔다**(대표 제보 9/16).
  /// 화살표·체크 기호를 그대로 두지 않고 문항 이름과 답했는지로 갈라 담는다.
  /// **지금 문항은 아직 답 안 한 첫 칸**이다 — 클로드 코드가 답한 칸을 ☒로 바꾸고 다음으로 넘어간다
  /// (실측 `docs/tmux_검증_20260831_문항두개/`: 01은 둘 다 ☐에 Q1, 03은 ☒ Fruit·☐ Drink에 Q2).
  final List<PaneTab> tabs;

  /// 지금 몇 번째 문항인가(1부터). 문항 표가 없으면 null.
  int? get tabAt {
    if (tabs.isEmpty) return null;
    final i = tabs.indexWhere((t) => !t.done);
    return (i < 0 ? tabs.length : i) + 1;
  }


  /// 커서가 놓인 선택지의 **미리보기**(AskUserQuestion의 preview). 없으면 빈 목록.
  ///
  /// 터미널은 선택지 목록(왼쪽) 오른쪽에 상자로 **커서가 놓인 선택지 하나의 것만** 그린다 —
  /// 커서를 옮기면 오른쪽만 바뀐다(실측 2026-09-15, `docs/tmux_검증_20260915_미리보기/`).
  /// 상자 테두리는 벗기고 안쪽 줄을 **모양 그대로** 담는다(표가 들어 있다).
  final List<String> preview;

  /// 여러 개를 고르는 창인가. 체크박스가 하나라도 있으면 그렇다.
  ///
  /// 이 창은 **숫자가 확정이 아니라 토글**이고, 확정은 선택지 아래 `Submit`
  /// 줄로 내려가 Enter를 쳐야 한다. 실측으로 확인했다(2026-08-11,
  /// `docs/tmux_검증_20260811_다중선택/`).
  bool get multi => options.any((o) => o.checkable);

  /// 켜져 있는 것들.
  List<PaneOption> get checkedOptions =>
      options.where((o) => o.checked == true).toList();

  /// 위아래로 오갈 수 있는 줄들의 차례. 선택지 + `Submit` 을 화면에 놓인
  /// 순서대로 센 것이다. `Submit` 이 선택지 사이에 낀 창이 실제로 있다 —
  /// `Type something` 다음이 `Submit` 이고 그 아래 `Chat about this` 가 또 있다.
  ///
  /// 커서를 몇 칸 옮겨야 하는지를 이 차례로 센다.
  final int? cursorRow;

  /// `Submit` 줄이 몇 번째 자리인가. 없으면 null.
  final int? submitRow;

  /// 그 줄에 적힌 말 — `Submit` 또는 `Next`.
  ///
  /// ⚠️ **문항이 여럿이면 그 자리가 `Next`다**(실측 2026-08-31,
  /// `docs/tmux_검증_20260831_문항두개/`). 마지막 문항에서만 `Submit`이 된다.
  /// `Submit`만 찾던 때는 문항이 둘 이상인 창에서 `toSubmit`이 통째로 null이라
  /// **체크는 되는데 넘어갈 수가 없었다.**
  final String? submitLabel;

  /// 눌러도 아직 안 끝난다 — 다음 문항이 있다.
  bool get isNext => submitLabel == 'Next';

  /// 커서를 `Submit`(또는 `Next`) 까지 옮기는 데 필요한 칸 수. 모르면 null.
  int? get toSubmit => (cursorRow == null || submitRow == null)
      ? null
      : submitRow! - cursorRow!;

  /// 묻기 **직전에 한 말**. 왜 이걸 묻는지가 여기 있다.
  ///
  /// 말풍선은 턴이 끝나야(`Stop`) 오르는데, 선택창이 뜨면 턴이 거기서 멈춘다.
  /// 그래서 물음만 덩그러니 뜨고 앞뒤 사정이 안 보였다 — 실제로 겪었다
  /// (2026-08-06). transcript도 턴이 끝나야 쓰이므로 화면에서 가져온다.
  final List<String> lead;

  /// 화면이 알려주는 조작법 (`Enter to select · ↑/↓ to navigate · Esc to cancel`).
  ///
  /// 창마다 먹는 키가 다르다. 어떤 창은 `↑/↓`, 어떤 창은 `←/→` 다.
  /// 위젯이 제멋대로 키를 내걸면 안 먹는 키를 누르게 된다 — 실제로 겪었다.
  final String? hint;

  /// 선택지 바로 위에 있던 물음. 못 찾으면 null.
  final String? question;
  final List<PaneOption> options;

  /// 커서가 놓인 번호. 못 찾으면 null.
  int? get cursor =>
      options.where((o) => o.selected).map((o) => o.number).firstOrNull;

  // `❯ 1. Yes, I trust this folder` / `  2. No, exit`
  static final RegExp optionLine = RegExp(r'^(❯|›|>)?\s*(\d{1,2})\.\s+(\S.*)$');
  // 다중 선택창의 체크박스. `1. [ ] 사과` / `1. [✔] 사과`
  static final RegExp checkBox = RegExp(r'^\[([ xX✔✓•*])\]\s*(.*)$');
  // 다중 선택창의 확정 줄. 번호가 없어서 선택지로는 안 잡힌다.
  // 문항이 여럿이면 마지막 문항 전까지 `Next`로 뜬다(실측 2026-08-31).
  static final RegExp submitLine = RegExp(r'^(❯|›|>)?\s*(Submit|Next)$');
  // 상자 테두리. 승인창은 네모 안에 들어 있어 옆선을 지워야 글이 나온다.
  static final RegExp boxSide = RegExp(r'[│┃║╎╏▌▏▎▍]');
  static final RegExp boxOnly =
      RegExp(r'^[─━═╌╍╭╮╰╯┌┐└┘├┤┬┴┼\s\-]*$');

  /// 앞말로 내걸 수 있는 줄 수. 표 하나가 들어갈 만큼은 돼야 한다.
  static const int _leadMax = 12;

  /// 확인 안내(`Enter to confirm`)가 선택지에서 이만큼 안에 있어야 인정한다.
  /// 화면 어디든 있으면 된다고 하면 위쪽 응답의 번호 목록까지 선택창이 된다.
  static const int _hintWithin = 5;

  /// 화면 텍스트에서 선택창을 읽는다. 없으면 null.
  ///
  /// 화면 **어디에나** 뜰 수 있다. 신뢰 확인창은 45줄짜리 화면의 17번째 줄에
  /// 뜨고 아래가 통째로 비어 있다(`docs/.../06_choice_live.txt`). 그래서
  /// "아래쪽만 본다" 같은 자리 규칙은 못 쓰고, **모양**으로 가려낸다 —
  /// 커서(`❯`)가 선택지에 붙어 있거나, 바로 뒤에 확인 안내가 있어야 한다.
  static PaneChoice? parse(String? pane) {
    if (pane == null || pane.isEmpty) return null;
    // ⚠️ **손대지 않은 원본을 따로 들고 있는다.** 앞말은 여기서 가져간다 —
    // `boxSide`를 지우고 `trim`한 것으로 앞말을 만들면, 클로드가 그려 준
    // 표가 통째로 무너진다. 세로줄이 사라지고 칸을 맞추던 공백도 날아가서
    // 표인지 아닌지도 알 수 없게 된다.
    final split = _splitPreview(pane.split('\n'));
    final src = split.left;
    final preview = split.preview;
    final wrapped = split.wrapped;
    final raw = src.map((l) => l.replaceAll(boxSide, ' ')).toList();
    final lines = raw.map((l) => l.trim()).toList();

    var options = <PaneOption>[];
    var cursorSeen = false;
    var lastOption = -1;
    String? question;
    String? lastPlain;
    String? hint;
    PaneChoice? found;

    // 위아래로 오갈 수 있는 줄의 차례. 선택지와 `Submit` 을 놓인 순서대로 센다.
    var rows = 0;
    int? cursorRow;
    int? submitRow;
    String? submitLabel;
    // 바로 앞 줄이 선택지(또는 그 설명)였는가. 다중 선택창은 설명을 선택지와
    // **같은 깊이(2칸)** 로 들여써서 들여쓰기만으로는 못 가른다(실측 2026-08-11).
    var afterOption = false;
    var sawCheckbox = false;

    var tabs = <PaneTab>[];
    var firstOption = -1;
    void commit() {
      if (options.length < 2) return;
      if (!cursorSeen && !_hasConfirmHint(lines, lastOption)) return;
      // 같은 화면에 여러 묶음이 있으면 **마지막 것**이 지금 물어보는 것이다.
      found = PaneChoice(
        tabs: tabs,
        question: question,
        options: options,
        hint: hint,
        lead: _lead(src, lines, firstOption, question),
        cursorRow: cursorRow,
        submitRow: submitRow,
        submitLabel: submitLabel,
        preview: preview,
      );
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty || boxOnly.hasMatch(line)) continue;
      // 문항 표(`←  ☒ Fruit  ☐ Drink  ✔ Submit  →`) — 화면마다 하나뿐이고, 새 묶음이 시작돼도 그대로다.
      final t = PaneTab.parseTabs(line);
      if (t.isNotEmpty) {
        tabs = t;
        continue;
      }
      final m = optionLine.firstMatch(line);
      if (m == null) {
        // 확정 줄(`Submit`)이 먼저다. 들여쓰기가 깊어서 설명으로 새기 쉽다 —
        // 실제 화면에서 `4. [ ] Type something` 아래에 5칸 들여써 붙어 있다.
        final sub = options.isNotEmpty ? submitLine.firstMatch(line) : null;
        if (sub != null) {
          if (line.startsWith('❯')) cursorRow = rows;
          submitRow = rows;
          submitLabel = sub.group(2);
          rows++;
          afterOption = false;
          continue;
        }
        // ⚠️ 조작법 줄이 먼저다. 다중 선택창은 마지막 선택지 바로 다음 줄이
        // 조작법인데, '바로 뒤에 붙은 줄은 설명'으로만 가르면 그걸 설명으로
        // 빨아들인다. 그러면 조작법이 카드 아래에 안 뜬다(그림으로 잡았다).
        if (_hintLine(line)) {
          hint = line;
          lastPlain = line;
          afterOption = false;
          continue;
        }
        // 선택지 바로 아래 줄은 그 선택지의 설명이다.
        // 한 단 더 들여썼거나, 다중 선택창이면 바로 뒤에 붙은 줄이 설명이다.
        // 미리보기 창에서 넘어간 긴 이름 — 이름에 잇는다.
        if (options.isNotEmpty && wrapped.contains(i)) {
          final last = options.removeLast();
          options.add(PaneOption(
            number: last.number,
            text: '${last.text} $line',
            selected: last.selected,
            checked: last.checked,
            detail: last.detail,
          ));
          continue;
        }
        if (options.isNotEmpty &&
            (_indented(raw[i]) || (sawCheckbox && afterOption))) {
          final last = options.removeLast();
          options.add(PaneOption(
            number: last.number,
            text: last.text,
            selected: last.selected,
            checked: last.checked,
            // ⚠️ 공백으로 이어 붙이지 않는다. 여러 줄로 적힌 설명이 한 줄이
            // 되어 버려서, 줄을 나눠 쓴 뜻도 표 모양도 다 무너진다.
            detail: last.detail == null ? line : '${last.detail}\n$line',
          ));
          continue;
        }
        if (_hintLine(line)) hint = line;
        lastPlain = line;
        afterOption = false;
        continue;
      }
      final number = int.parse(m.group(2)!);
      if (number == 1) {
        // 새 묶음이 시작됐다. 앞의 묶음은 여기서 매듭짓는다.
        commit();
        firstOption = i;
        options = <PaneOption>[];
        cursorSeen = false;
        rows = 0;
        cursorRow = null;
        submitRow = null;
        submitLabel = null;
        sawCheckbox = false;
        // 선택지 바로 위 줄을 물음으로 본다. 다만 **이름표는 거른다** —
        // 신뢰 확인창은 그 자리가 'Security guide'(링크 이름)라 그냥
        // 집어오면 엉뚱한 것을 물음이라고 내건다.
        //
        // 물음표·콜론으로 끝나거나, 짧지 않으면 문장으로 본다.
        // `?`만 받으면 '…봐주면 된다요.' 처럼 마침표로 끝나는 물음을 놓친다.
        question = (lastPlain != null &&
                (lastPlain.endsWith('?') ||
                    lastPlain.endsWith(':') ||
                    lastPlain.length >= 20))
            ? lastPlain
            : null;
      } else if (number != options.length + 1) {
        // 1부터 차례대로가 아니면 선택지가 아니다.
        continue;
      }
      final selected = m.group(1) != null;
      if (selected) cursorSeen = true;
      lastOption = i;
      // 체크박스가 붙어 있으면 떼어내고 켜짐 여부만 남긴다.
      var text = m.group(3)!.trim();
      bool? checked;
      final cb = checkBox.firstMatch(text);
      if (cb != null) {
        checked = cb.group(1)! != ' ';
        text = cb.group(2)!.trim();
        sawCheckbox = true;
      }
      if (selected) cursorRow = rows;
      rows++;
      afterOption = true;
      options.add(PaneOption(
        number: number,
        text: text,
        selected: selected,
        checked: checked,
      ));
    }
    commit();
    return found;
  }

  /// 선택지 오른쪽의 미리보기 상자를 떼어 낸다 — 왼쪽(선택지)과 오른쪽(미리보기)이 한 줄에 붙어 온다.
  ///
  /// ⚠️ **떼지 않으면 두 가지로 깨졌다**(대표 제보 9/15): 같은 줄 오른쪽 글자가 선택지 이름에 붙고
  /// (`상세 표 | 제목 | 상태 |`), 들여쓴 미리보기 줄이 선택지 설명으로 빨려 들어가 일반 글꼴로 무너졌다.
  ///
  /// 상자는 **선택지 줄에서 시작하는 `┌─…─┐`** 로 알아본다 — 앞말 속의 표와 헷갈리지 않게. 자르는 자리는
  /// 줄마다 **첫 상자 문자**다(한글이 섞이면 글자 수와 칸 수가 달라 칸 번호로 자를 수 없다). 상자 아래
  /// 「Notes: press n to add notes」는 조작 안내라 버린다.
  static ({List<String> left, List<String> preview, Set<int> wrapped}) _splitPreview(List<String> src) {
    final top = src.indexWhere((l) {
      final at = l.indexOf('┌');
      if (at < 0 || !RegExp(r'^┌─+┐\s*$').hasMatch(l.substring(at))) return false;
      final left = l.substring(0, at);
      return left.endsWith('  ') && optionLine.hasMatch(left.trim());
    });
    if (top < 0) return (left: src, preview: const [], wrapped: const <int>{});
    final left = [...src];
    final preview = <String>[];
    // 상자 안쪽 폭(칸). `┌───┐` 테두리 문자는 한 칸씩이라 글자 수가 곧 칸 수다. 테두리 둘 + 여백 둘을 뺀다.
    final boxLine = src[top].substring(src[top].indexOf('┌')).trimRight();
    final inner = boxLine.length - 4;
    for (var i = top; i < src.length; i++) {
      final l = src[i];
      // ⚠️ `├` 도 상자 테두리다 — 긴 미리보기는 터미널이 `├─── ✂ ─── 6 lines hidden ──┤`로 줄여 그린다(실측 9/15).
      // 빠뜨리면 거기서 자르기가 멈춰 그 줄·아래 테두리·「Notes」가 마지막 선택지 설명으로 새어 들었다.
      final at = l.indexOf(RegExp(r'[┌│└├]'));
      if (at < 0) break;
      left[i] = l.substring(0, at).trimRight();
      final box = l.substring(at);
      final cut = RegExp(r'✂\D*(\d+)\s*lines? hidden').firstMatch(box);
      if (box.startsWith('├') && cut != null) {
        preview.add('✂ ${cut.group(1)}줄 더 있다 — 터미널도 잘라서 보여 준다');
        continue;
      }
      if (box.startsWith('└')) {
        // 상자 바로 아래 조작 안내(Notes: …)도 오른쪽 칸에 있다 — 버린다.
        for (var k = i + 1; k < src.length && k <= i + 2; k++) {
          if (src[k].trim().toLowerCase().startsWith('notes:')) left[k] = '';
        }
        break;
      }
      if (box.startsWith('┌')) continue;
      // `│ 내용 │` — 앞 테두리와 한 칸 여백, 뒤 여백과 테두리를 벗긴다. 안쪽 칸 맞춤은 그대로 둔다.
      preview.add(box.replaceFirst(RegExp(r'^│ ?'), '').replaceFirst(RegExp(r'\s*│\s*$'), ''));
    }
    while (preview.isNotEmpty && preview.last.trim().isEmpty) {
      preview.removeLast();
    }
    // 넓은 표는 터미널이 상자 폭에서 **글자 단위로 접어** 그린다(실측 9/15, `04_wide_wrap.txt`) —
    // `| … | col09  |` 다음 줄에 ` col10  |`. 표 줄(`|`·`│`로 시작)이 상자를 꽉 채웠고 다음 줄이 표 줄로
    // 시작하지 않으면 접힌 이어짐이라 붙인다. 대시보드는 붙인 한 줄을 옆으로 밀어 보여 준다(대표 지적 「넓은 표가 넘어간다」).
    final joined = <String>[];
    for (final l in preview) {
      final prev = joined.isEmpty ? null : joined.last;
      if (prev != null && l.trim().isNotEmpty && !RegExp(r'^[|│┌├└]').hasMatch(l) &&
          RegExp(r'^[|│]').hasMatch(prev) && termCols(prev) >= inner - 1) {
        joined[joined.length - 1] = prev + l;
      } else {
        joined.add(l);
      }
    }
    preview
      ..clear()
      ..addAll(joined);
    // 미리보기가 있으면 왼쪽 선택지 칸이 좁아(34칸) 긴 이름이 다음 줄로 넘어간다 — 번호 없이 들여쓴 그 줄은
    // 설명이 아니라 **이름의 이어짐**이다(실측 9/15, `06_long_name.txt`). 이 창의 선택지에는 설명이 붙지 않는다.
    final wrapped = <int>{};
    for (var i = top + 1; i < left.length; i++) {
      final t = left[i].trim();
      if (t.isEmpty) break;
      if (optionLine.hasMatch(t)) continue;
      wrapped.add(i);
    }
    return (left: left, preview: preview, wrapped: wrapped);
  }

  /// 선택창 바로 위에 있던 말. 왜 묻는지가 여기 있다.
  ///
  /// **`⏺` 로 시작하는 줄까지만 올라간다.** 그게 답변이 시작된 자리다.
  /// 거기까지 못 가면 빈 목록을 준다 — 못 가르겠으면 안 보여주는 편이 낫다.
  ///
  /// ⚠️ 내가 친 말이 길면 줄바꿈되어 `❯` 없는 줄이 생긴다. '위로 가다가 `❯`를
  /// 만나면 멈춘다'로 하면 그 줄이 앞말에 섞인다. 실제로 겪었다(2026-08-06).
  /// ⚠️ **가릴 때는 다듬은 줄로, 담을 때는 원본 줄로 한다.** 무엇을 넣을지
  /// 고르는 데는 `trim`한 것이 편하지만, 그걸 그대로 담으면 표가 무너진다.
  /// 표는 세로줄과 자리를 맞춘 공백으로 서 있는 것이라 둘 다 지켜야 한다.
  static List<String> _lead(List<String> src, List<String> lines,
      int firstOption, String? question) {
    if (firstOption <= 0) return const [];
    final out = <String>[];
    var looked = 0;
    for (var i = firstOption - 1; i >= 0 && looked < 12; i--) {
      final l = lines[i];
      if (l.isEmpty) continue;
      looked++;
      // ⚠️ `boxOnly` 로 거르면 안 된다. 표의 가로줄까지 상자로 보고 버린다.
      if (_screenDivider(l)) continue;
      // 내가 친 말까지 왔다 = 답변 시작을 못 찾았다. 아무것도 안 보여준다.
      if (l.startsWith('❯')) return const [];
      // `☐ 머리표` 와 문항은 박스가 따로 내건다. 문항 표(`← ☒ … →`)도 카드가 따로 그린다.
      if (l.startsWith('☐') || l.startsWith('☑') || l.startsWith('←')) continue;
      // `✻ Cogitated for 7s` 같은 진행 표시는 앞말이 아니다.
      if (l.startsWith('✻') || l.startsWith('✽')) continue;
      // 자리로 세면 빈 줄이 끼었을 때 문항이 새어 들어온다. 글자로 견준다.
      if (question != null && l == question) continue;
      if (l.startsWith('⏺')) {
        // 답변이 시작된 자리다. 이 줄까지 넣고 멈춘다.
        // `⏺` 를 지우지 않고 **공백으로 바꾼다** — 아래 줄들이 그 폭만큼
        // 들여써 있어서, 떼어내면 첫 줄만 왼쪽으로 튀어나온다.
        out.insert(0, _railless(src[i]).replaceFirst('⏺', ' '));
        // ⚠️ 여섯 줄로 자르면 **표의 윗줄이 잘린다.** 표는 머리 + 구분선 +
        // 내용이 이미 대여섯 줄이라, 테두리가 날아가면 표로 안 보인다
        // (그림으로 잡았다, 2026-08-12). 열두 줄까지 받는다.
        final tail = out.length > _leadMax ? out.sublist(out.length - _leadMax) : out;
        return _dedent(tail);
      }
      out.insert(0, _railless(src[i]));
    }
    // `⏺` 를 못 찾았다. 어디부터가 답변인지 모르면 안 보여준다.
    return const [];
  }

  /// 화면을 가로지르는 구분선인가. 입력창 위아래에 늘 깔리는 그 줄이다.
  ///
  /// ⚠️ **표의 가로선과 가르는 것이 요점이다.** 둘 다 `─` 로 그리지만
  /// 표에는 모서리·이음매(`┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘`)가 섞여 있고, 화면 구분선은
  /// `─` 하나로만 되어 있다. 이걸 안 가르면 표의 가로줄이 통째로 버려져
  /// 세로줄만 남은 것이 된다 — 실제로 그렇게 짰다가 잡았다(2026-08-12).
  static bool _screenDivider(String trimmed) {
    if (trimmed.length < 40) return false;
    return RegExp(r'^[─━═╌╍\s]+$').hasMatch(trimmed);
  }

  /// 줄 끝에 붙은 **상자 옆선**만 떼어낸다.
  ///
  /// ⚠️ **표의 칸막이와 갈라야 한다.** 상자 옆선은 화면 오른쪽 끝에 붙어
  /// 있어 글자와 사이가 멀다(공백 셋 이상). 표의 칸막이는 글자에 붙는다.
  /// 이걸 안 가르면 표의 오른쪽 테두리가 잘려 나간다.
  static String _railless(String raw) {
    var s = raw.replaceFirst(RegExp(r'\s+$'), '');
    // 오른쪽 끝의 옆선: 앞에 공백이 셋 이상 있어야 상자로 본다.
    s = s.replaceFirst(RegExp(r'\s{3,}[│┃║╎╏▌▏▎▍]$'), '');
    return s.replaceFirst(RegExp(r'\s+$'), '');
  }

  /// 다 같이 들여쓴 만큼만 왼쪽으로 당긴다.
  ///
  /// 클로드가 한 말은 통째로 2칸 들여써 있다. 그 2칸을 그냥 두면 좁은
  /// 카드에서 자리만 먹는다. **모두에게서 같은 만큼만** 떼어내므로
  /// 줄끼리의 어긋남(=표의 칸)은 그대로 남는다.
  static List<String> _dedent(List<String> ls) {
    var min = 1 << 30;
    for (final l in ls) {
      if (l.trim().isEmpty) continue;
      final n = l.length - l.trimLeft().length;
      if (n < min) min = n;
    }
    if (min <= 0 || min == 1 << 30) return ls;
    return ls
        .map((l) => l.length >= min ? l.substring(min) : l.trimLeft())
        .toList();
  }

  /// 선택지 번호보다 더 들여쓴 줄인가. 설명은 늘 한 단 더 들어가 있다.
  static bool _indented(String rawLine) {
    final spaces = rawLine.length - rawLine.trimLeft().length;
    return spaces >= 4;
  }

  /// 조작법을 알려주는 줄인가.
  static bool _hintLine(String line) {
    final l = line.toLowerCase();
    return (l.contains('to select') ||
            l.contains('to navigate') ||
            l.contains('to confirm') ||
            l.contains('to cancel')) &&
        line.length < 90;
  }

  /// 마지막 선택지 바로 뒤에 확인 안내가 있는지.
  static bool _hasConfirmHint(List<String> lines, int lastOption) {
    if (lastOption < 0) return false;
    final end = (lastOption + 1 + _hintWithin).clamp(0, lines.length);
    final near =
        lines.sublist(lastOption + 1, end).join(' ').toLowerCase();
    return near.contains('to confirm') ||
        near.contains('to cancel') ||
        near.contains('to select');
  }

  /// 번호가 아니라 화살표로 옮기는 창인지. 그쪽은 키패드로 다뤄야 한다.
  static bool isCursorPrompt(String? pane) {
    if (pane == null) return false;
    final tail = pane.toLowerCase();
    return tail.contains('to adjust') || tail.contains('←/→');
  }

  /// 화면 맨 아래의 읽을 만한 줄들. 선택창을 못 읽어냈을 때 그대로 보여준다.
  static List<String> tail(String? pane, {int max = 6}) {
    if (pane == null) return const [];
    final lines = pane
        .split('\n')
        .map((l) => l.replaceAll(boxSide, ' ').trim())
        .where((l) => l.isNotEmpty && !boxOnly.hasMatch(l))
        .toList();
    return lines.length > max ? lines.sublist(lines.length - max) : lines;
  }
}

/// 터미널에서 차지하는 칸 수. 한글·한자·전각은 두 칸이다 — 글자 수로 재면 한글 줄이 상자를 채웠는지 못 가린다.
int termCols(String s) {
  var n = 0;
  for (final r in s.runes) {
    final wide = (r >= 0x1100 && r <= 0x115F) || (r >= 0x2E80 && r <= 0xA4CF) || (r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0xF900 && r <= 0xFAFF) || (r >= 0xFE30 && r <= 0xFE4F) || (r >= 0xFF00 && r <= 0xFF60) ||
        (r >= 0xFFE0 && r <= 0xFFE6) || (r >= 0x1F300 && r <= 0x1FAFF);
    n += wide ? 2 : 1;
  }
  return n;
}

/// 좌우로 옮겨 고르는 슬라이더 창 (`/effort` 같은 것).
///
/// 화면이 이렇게 생겼다.
/// ```
///    Effort
///                    Faster                          Smarter
///                    ─▲──────────────────────────┆──────────────
///                    low     medium     high     xhigh      max
///    ←/→ to adjust · Enter to confirm · Esc to cancel
/// ```
///
/// ⚠️ **창이 짧으면 옵션 줄이 잘려 안 보인다.** 45줄일 때 `Effort` 와
/// `Faster … Smarter` 만 보이고 정작 고를 것이 안 나왔다(2026-08-06).
/// 그래서 세션을 60줄로 만든다 — [Tmux.paneHeight].
class PaneSlider {
  const PaneSlider({
    required this.options,
    required this.current,
    this.title,
    this.hint,
  });

  /// 고를 수 있는 것들. 화면에 적힌 차례 그대로다.
  final List<String> options;

  /// 지금 `▲` 가 가리키는 자리.
  final int current;

  /// 슬라이더 이름 (`Effort`). 못 찾으면 null.
  final String? title;

  /// 화면이 알려주는 조작법.
  final String? hint;

  /// 눈금 줄. `─` 사이에 `▲` 가 박혀 있다.
  static final RegExp _track = RegExp(r'^[\s─━▲┆|]+$');

  static PaneSlider? parse(String? pane) {
    if (pane == null || pane.isEmpty) return null;
    final lines = pane.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final arrow = line.indexOf('▲');
      if (arrow < 0) continue;
      if (!_track.hasMatch(line)) continue;
      if ('─'.allMatches(line).length < 8) continue;

      // 눈금 바로 아래 첫 줄이 옵션 줄이다.
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isEmpty) {
        j++;
      }
      if (j >= lines.length) return null;
      final labels = _labels(lines[j]);
      if (labels.length < 2) return null;

      // `▲` 와 가운데가 가장 가까운 것이 지금 골라진 것이다.
      var best = 0;
      var bestGap = double.infinity;
      for (var k = 0; k < labels.length; k++) {
        final l = labels[k];
        final gap = ((l.start + l.text.length / 2) - arrow).abs();
        if (gap < bestGap) {
          bestGap = gap;
          best = k;
        }
      }

      // 눈금 위쪽에서 이름을, 아래쪽에서 조작법을 찾는다.
      String? title;
      for (var k = i - 1; k >= 0 && k >= i - 4; k--) {
        final t = lines[k].trim();
        if (t.isEmpty) continue;
        if (PaneChoice.boxOnly.hasMatch(t)) continue;
        // `Faster … Smarter` 같은 양끝 이름표는 건너뛴다.
        if (_labels(lines[k]).length >= 2) continue;
        title = t;
        break;
      }
      String? hint;
      for (var k = j + 1; k < lines.length && k <= j + 5; k++) {
        final t = lines[k].trim();
        if (t.isEmpty) continue;
        if (t.contains('to adjust') ||
            t.contains('to confirm') ||
            t.contains('to cancel')) {
          hint = t;
          break;
        }
      }
      return PaneSlider(
        options: labels.map((l) => l.text).toList(),
        current: best,
        title: title,
        hint: hint,
      );
    }
    return null;
  }

  /// 두 칸 이상 띄어 있는 것을 각각 한 덩어리로 본다.
  /// 한 칸짜리 띄어쓰기는 이름 안에 있는 것으로 친다 (`xhigh + workflows`).
  static List<_Label> _labels(String line) {
    final out = <_Label>[];
    var i = 0;
    while (i < line.length) {
      if (line[i] == ' ') {
        i++;
        continue;
      }
      final start = i;
      var end = i;
      var gap = 0;
      while (i < line.length) {
        if (line[i] == ' ') {
          gap++;
          if (gap >= 2) break;
        } else {
          gap = 0;
          end = i;
        }
        i++;
      }
      out.add(_Label(start, line.substring(start, end + 1)));
    }
    return out;
  }
}

class _Label {
  const _Label(this.start, this.text);
  final int start;
  final String text;
}

/// 화면에서 '지금 무슨 일을 하고 있는지'에 해당하는 줄만 추린다.
///
/// ⚠️ **상태를 판정하지 않는다.** 일하는 중인지는 훅이 정하고(`status.busy`),
/// 여기는 사람이 읽을 줄만 골라 준다. `PaneChoice`와 같은 선이다.
/// 화면에서 주워 온 것들. 훅이 알려주지 않는 것만 담는다.
class PaneSignals {
  const PaneSignals({
    this.shells = 0,
    this.agents = 0,
    this.compacting = false,
    this.retrying = false,
    this.spinning = false,
  });

  /// 백그라운드에서 도는 셸 개수 (`2 shells`).
  final int shells;

  /// 백그라운드 에이전트 개수 (`← 1 agent`).
  ///
  /// ⚠️ **1은 늘 떠 있다.** 실측한 여섯 세션 전부 `← 1 agent`였다.
  /// 그대로 내걸면 노이즈만 되므로 **2 이상일 때만** 뜻이 있다.
  final int agents;

  /// 대화를 압축하는 중. 몇 분씩 걸리는데 훅이 안 울린다.
  final bool compacting;

  /// API를 다시 부르는 중. 멈춘 것과 구분이 안 됐다.
  final bool retrying;

  /// 스피너가 돌고 있다. **동사가 무엇이든 상관없다.**
  ///
  /// ⚠️ `Hashing`은 상태가 아니라 낱말 하나다. 클로드 코드는 턴마다
  /// 200개 남짓한 목록에서 하나를 골라 쓴다 — `Hashing` `Canoodling`
  /// `Newspapering` `Baking`… 그래서 특정 낱말을 잡으려 들면 그 한 번만
  /// 맞고 나머지 199번은 놓친다(2026-09-09에 바이너리에서 목록을 확인했다).
  ///
  /// 대신 **줄 모양**을 본다. 실측한 것은 이렇다.
  /// `· Canoodling… (2m 21s · ↓ 7.2k tokens)`
  final bool spinning;

  /// 사람에게 내걸 만한 것이 하나라도 있나.
  bool get any => shells > 0 || agents > 1 || compacting || retrying;

  /// 훅이 조용해도 **일하는 중으로 봐야 하는가.**
  /// 셸·에이전트는 턴이 끝난 뒤에도 남을 수 있어 여기 넣지 않는다.
  bool get working => compacting || retrying || spinning;

  /// 말풍선에 내걸 한마디. 없으면 null.
  ///
  /// 스피너는 말을 붙이지 않는다 — 무엇을 하는 중인지는 이미 화면 꼬리가
  /// 보여주고, 낱말이 매번 바뀌어서 내걸어도 뜻이 없다.
  String? get label {
    if (compacting) return '대화를 줄이는 중';
    if (retrying) return '다시 부르는 중';
    return null;
  }
}

class PaneView {
  /// 화면 아래에 늘 붙어 있는 것들. 매 프레임 똑같아서 진행을 못 알려준다.
  /// 이걸 안 걷어내면 스트립이 상태바만 되풀이해 보여준다.
  static const List<String> _chrome = [
    'for shortcuts',
    'to interrupt',
    'shift+tab to cycle',
    'for agents',
    'permissions on',
    'accept edits on',
    'manual mode on',
    'plan mode on',
    'to save',
    'ctrl+o to see',
    'to confirm',
    'to cancel',
    // 화면 아래에서 계속 바뀌는 안내문. 진행과 무관한데 자리를 다 먹는다.
    'tip:',
  ];

  /// 남은 한도 상태줄(`5h 4% · 7d 63%`). 계정 값이라 **이 턴과 아무 상관이 없는데**
  /// 화면 맨 아래에 늘 있어서 「하는 일」 줄을 차지했다(UI 리뷰 9/18).
  /// 한도는 책상 왼쪽 아래와 크레딧 화면이 제대로 보여준다(15절).
  static final RegExp _limitLine = RegExp(r'^\s*\d+h\s+\d+%\s*[·|]\s*\d+d\s+\d+%');

  /// 빈 입력창. 클로드가 일하는 중에도 화면 아래에 그대로 있다.
  static final RegExp _emptyPrompt = RegExp(r'^[❯›>]\s*$');

  static final RegExp _dash = RegExp(r'[─━═╌╍]');

  /// 글자가 박힌 구분선인가. 입력창 위 테두리에 제목이 얹혀 오는데
  /// (`──── 프로젝트 세팅 요구사항 확인 ──`) 늘 같은 자리라 진행이 아니다.
  ///
  /// 전부 구분선인 줄은 boxOnly가 걸러 준다. 여기는 글자가 섞인 것을 보는데,
  /// **길이 비율만으로는 부족하다** — 제목이 길면 구분선이 절반 아래로 내려간다.
  /// 그래서 '구분선으로 시작하는가'를 함께 본다. 그게 이 줄의 실제 모양이다.
  static bool _isDivider(String line) =>
      line.startsWith('───') ||
      line.startsWith('━━━') ||
      _dash.allMatches(line).length * 2 > line.length;

  /// 입력창 줄. `❯` 로 시작하면 입력창이다 — **비어 있든 글자가 들어 있든** 그렇다.
  static final RegExp _inputLine = RegExp(r'^[❯›>](\s|$)');

  /// 화면 아래에서 입력창을 찾을 때 볼 줄 수.
  ///
  /// 화면 위쪽에도 `❯ 내가 친 말` 이 지난 대화로 남아 있다. 그걸 입력창으로
  /// 세면 무슨 창이 떠 있어도 '평소'가 되어 버린다. 입력창은 늘 맨 아래다.
  static const int _inputWithin = 6;

  /// 지금 화면이 **무언가 고르라고 묻고 있는가.**
  ///
  /// 화면 맨 아래에 입력창(`❯`)이 있으면 사람이 칠 수 있는 상태다 — 평소다.
  /// 입력창 자리를 다른 것이 차지하고 있으면 그게 묻는 창이다.
  ///
  /// ⚠️ **비어 있는지로 가르면 안 된다.** 입력창에 글자를 쳐 둔 것뿐인데
  /// 묻는 창으로 잡혀 박스가 뜬다. 실제로 겪었다(2026-08-06) —
  /// `❯ 클로드코드 재시작했어` 가 들어 있던 화면이 오탐이었다.
  ///
  /// ⚠️ 번호 선택창은 `❯ 1. Yes` 처럼 커서가 선택지에 붙는다. 그건 입력창이
  /// 아니므로 빼고 센다.
  ///
  /// ⚠️ **이걸로 `session.status`를 바꾸지 않는다.** 캐릭터 상태는 여전히
  /// 훅만 정한다. 이건 "메시지 탭에 무엇을 그릴까"를 정하는 화면 쪽 판단이다.
  /// 훅이 알려주지 않는 것들을 화면에서 주워 온다.
  ///
  /// ⚠️ **설계 원칙 2절의 예외다.** 원래 상태는 훅만 정하는데, 여기 있는
  /// 것들은 **훅이 아예 안 울린다.** 압축이 몇 분씩 돌아도, 백그라운드 셸이
  /// 남아 있어도 위젯은 '완료(초록)'로 굳어 멈춘 것처럼 보였다. 그래서
  /// 화면에서 읽어 보완한다(2026-08-07, 사용자 요청).
  ///
  /// 실측한 상태바는 이렇게 생겼다.
  /// `⏵⏵ bypass permissions on · 2 shells · ← 1 agent · ↓ to manage`
  static PaneSignals signals(String? pane) {
    if (pane == null) return const PaneSignals();
    final lines = const LineSplitter().convert(pane);
    var shells = 0;
    var agents = 0;
    var compacting = false;
    var retrying = false;
    var spinning = false;

    // 상태바는 맨 아래다. 지난 대화에 같은 글자가 남아 있을 수 있어 꼬리만 본다.
    for (var i = lines.length - 1; i >= 0 && i >= lines.length - 4; i--) {
      final line = lines[i];
      // `1 shell` · `2 shells`
      final shell = RegExp(r'(\d+)\s+shells?\b').firstMatch(line);
      if (shell != null) shells = int.tryParse(shell.group(1)!) ?? 0;
      // `← 1 agent` · `← 2 agents`
      final agent = RegExp(r'(\d+)\s+agents?\b').firstMatch(line);
      if (agent != null) agents = int.tryParse(agent.group(1)!) ?? 0;
    }
    // 압축·재시도는 상태바가 아니라 **스피너 자리**에 뜬다.
    //
    // ⚠️ **화면 아무 데서나 찾으면 안 된다.** 대화 본문에 그 단어가 나오면
    // 그대로 오탐이다 — 이 기능을 만드는 대화에서 `Compacting…`을 여러 번
    // 적었더니 제 화면에 그 글자가 남았다(2026-08-07).
    //
    // 스피너 줄은 모양이 뚜렷하다. `✽ Coalescing… (43s · ↓ 2.2k tokens)` 처럼
    // **기호 하나 + 공백 + 단어 + …** 로 시작한다. 그 자리만 본다.
    // ⚠️ 아포스트로피를 넣어야 한다. 낱말 목록에 `Beboppin'` 이 있는데
    // 그것만 빠져서 스피너로 안 잡혔다(2026-09-09, 테스트가 잡았다).
    final spinner = RegExp(r"^\s*[^\w\s]\s+([A-Za-z][\w'-]*)…");
    final tail = lines.length > 12 ? lines.sublist(lines.length - 12) : lines;
    for (final line in tail) {
      final word = spinner.firstMatch(line)?.group(1)?.toLowerCase();
      if (word == null) continue;
      // ⚠️ 실물을 못 떠왔다(재현이 어렵다). 어간으로 조금 넓게 잡되,
      // 자리가 스피너로 한정되어 있어 오탐이 나기는 어렵다.
      if (word.startsWith('compact')) compacting = true;
      if (word.startsWith('retry') || word.startsWith('retrying')) {
        retrying = true;
      }
      // ⚠️ **낱말로 가르지 않는다.** 어떤 동사든 스피너가 돌고 있으면
      // 일하는 중이다.
      //
      // 낱말 목록을 박아두거나 `-ing`로 끝나는지 보는 길도 있는데 둘 다
      // 좁다. 목록은 188개고 새 낱말이 늘면 못 잡으며, `-ing` 규칙은
      // `Beboppin'` 하나를 놓친다(2026-09-09에 목록을 세어 확인했다).
      // 낱말을 아예 안 보는 편이 넓고 안 깨진다.
      //
      // 대신 **줄 모양** 두 가지를 같이 본다. 실측한 것이다.
      // - 괄호에 경과·토큰이 붙는다 — `… (2m 21s · ↓ 7.2k tokens)`
      // - **왼쪽 끝에서 시작한다** (앞 공백 0칸)
      //
      // ⚠️ 앞 공백을 허용하면 대화 본문을 줍는다. 이 기능을 만드는 대화에서
      // 스피너 줄을 예시로 적었더니 **그 줄이 화면에 남아 잡혔다**
      // (2026-09-09, 앞 공백 2칸이었다). 압축·재시도 때 겪은 것과 같은 일이다.
      if (!line.startsWith(RegExp(r'\s')) &&
          line.contains('tokens') &&
          line.contains('(')) {
        spinning = true;
      }
    }
    return PaneSignals(
      shells: shells,
      agents: agents,
      compacting: compacting,
      retrying: retrying,
      spinning: spinning,
    );
  }

  /// 상태바에서 지금 권한 모드를 읽어낸다.
  ///
  /// 화면 맨 아래엔 늘 이런 줄이 붙어 있다.
  /// `⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← 1 agent`
  ///
  /// 이 세션이 승인을 건너뛰는 상태인지 계획 모드인지는 훅이 알려주지 않는다.
  /// 화면에만 있다. 실측한 세 세션 모두 이 모양이었다(2026-08-06).
  ///
  /// ⚠️ **말을 지어내지 않고 화면 글자를 그대로 옮긴다.** 한글로 바꿔 달면
  /// 매핑이 틀렸을 때 엉뚱한 모드를 내걸게 된다. 조작법을 화면에서 그대로
  /// 가져오는 것과 같은 이유다.
  ///
  /// 기본 모드에서는 이 줄이 아예 없다. 그때는 null이다.
  static String? mode(String? pane) {
    if (pane == null) return null;
    final lines = const LineSplitter().convert(pane);
    // 상태바는 늘 맨 아래다. 위쪽에 같은 글자가 지나갔을 수 있으니 꼬리만 본다.
    for (var i = lines.length - 1; i >= 0 && i >= lines.length - 4; i--) {
      var line = lines[i].trim();
      if (!line.startsWith('⏵⏵') && !line.startsWith('⏸')) continue;
      // 기호를 떼고 첫 칸막이(·)까지가 모드다.
      line = line.replaceFirst(RegExp(r'^(⏵⏵|⏸)\s*'), '');
      final bar = line.indexOf('·');
      if (bar >= 0) line = line.substring(0, bar);
      // `(shift+tab to cycle)` 같은 안내는 모드 이름이 아니다.
      line = line.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
      // 끝의 `on`은 켜졌다는 뜻이라 칩에서는 군더더기다.
      line = line.replaceFirst(RegExp(r'\s+on$'), '').trim();
      if (line.isEmpty) continue;
      return line;
    }
    return null;
  }

  static bool awaitingChoice(String? pane) {
    if (pane == null || pane.isEmpty) return false;
    final lines = pane
        .split('\n')
        .map((l) => l.replaceAll(PaneChoice.boxSide, ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return false;
    final from = lines.length > _inputWithin ? lines.length - _inputWithin : 0;
    for (var i = from; i < lines.length; i++) {
      final l = lines[i];
      if (!_inputLine.hasMatch(l)) continue;
      // `❯ 1. Yes` 는 선택지에 커서가 붙은 것이지 입력창이 아니다.
      if (PaneChoice.optionLine.hasMatch(l)) continue;
      // ⚠️ `❯    Submit` / `❯    Next` 도 커서가 그 줄에 놓인 것이다.
      // 이걸 입력창으로 세면 **확정 줄로 내려간 순간 카드가 통째로 사라진다** —
      // 다중 선택창에서 확정 직전에 늘 지나는 자리다(실측 2026-08-31).
      if (PaneChoice.submitLine.hasMatch(l)) continue;
      return false; // 입력창이 살아 있다 = 평소
    }
    return true;
  }

  /// 화면 꼬리에서 읽을 만한 줄 `max`개. 새것이 아래로 온다.
  static List<String> activity(String? pane, {int max = 5}) {
    if (pane == null || pane.isEmpty) return const [];
    final out = <String>[];
    for (final raw in pane.split('\n')) {
      final line = raw.replaceAll(PaneChoice.boxSide, ' ').trim();
      if (line.isEmpty) continue;
      if (PaneChoice.boxOnly.hasMatch(line)) continue;
      if (_emptyPrompt.hasMatch(line)) continue;
      if (_isDivider(line)) continue;
      final low = line.toLowerCase();
      if (_chrome.any(low.contains)) continue;
      if (_limitLine.hasMatch(line)) continue;
      out.add(line);
    }
    return out.length > max ? out.sublist(out.length - max) : out;
  }
}

// ── 회의실 ──────────────────────────────────────────────
//
// 여러 폴더의 클로드 세션이 한 주제로 라운드 토론을 한다. 진행은 **사회자
// 세션**이 한다(터미널의 `/회의`). **위젯은 읽기만 한다** — 여기서 회의를
// 굴리려 들면 위젯이 세션을 부리는 물건이 되어 설계가 뒤집힌다.
//
// ⚠️ **회의록 마크다운을 파싱하지 않는다.** 사회자가 같은 폴더에 `상태.json`을
// 따로 쓰고 위젯은 그것만 읽는다. 사람이 읽는 글과 기계가 읽는 값을 한 파일에
// 겹쳐 두면, 회의록 문장을 다듬는 순간 화면이 깨진다.

class MeetingSpeaker {
  const MeetingSpeaker({
    required this.name,
    required this.path,
    required this.state,
    required this.say,
    required this.summary,
    this.role = '',
  });

  final String name;

  /// `진행자`면 회의를 굴리는 루트 세션이 제 의견을 낸 자리다(9/17 — 이사↔마당 1:1 회의). 비면 참석자.
  final String role;
  bool get moderator => role == '진행자';

  /// 등록된 프로젝트 경로. 있으면 그 프로젝트의 캐릭터 그림을 그대로 쓴다.
  final String? path;

  /// `발언완료` · `대기중` · `무응답`
  final String state;
  final String say;
  final String summary;

  bool get spoke => say.trim().isNotEmpty;
  bool get silent => state == '무응답';

  /// 말풍선에 띄울 한 줄. 요약이 없으면 발언 첫 줄을 쓴다.
  String get line {
    // 사회자가 요약 칸에 발언 머리(「**이름 (R1)**」)를 그대로 넣은 적이 있다 — 그런 요약은 버리고 발언에서 뽑는다.
    final sm = summary.trim();
    if (sm.isNotEmpty && !(sm.startsWith('**') && sm.endsWith('**')) && !sm.startsWith('#')) return sm.replaceAll('**', '');
    // 발언 파일 첫 줄이 「# 이름 (R1)」「**이름 (R1)**」 같은 머리일 때가 많다 — 머리·꾸밈표는 건너뛴다.
    for (final l in say.split('\n')) {
      final t = l.trim().replaceAll(RegExp(r'^[#>\-*\s]+'), '').replaceAll('**', '').trim();
      if (t.isEmpty || l.trim().startsWith('#')) continue;
      if (l.trim().startsWith('**') && l.trim().endsWith('**')) continue;
      return t;
    }
    return '';
  }

  static MeetingSpeaker? parse(Object? raw) {
    if (raw is! Map) return null;
    final name = (raw['이름'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final path = (raw['경로'] ?? '').toString().trim();
    return MeetingSpeaker(
      name: name,
      path: path.isEmpty ? null : ProjectStore.normalize(path),
      state: (raw['상태'] ?? '대기중').toString().trim(),
      say: (raw['발언'] ?? '').toString(),
      summary: (raw['요약'] ?? '').toString(),
      role: (raw['역할'] ?? '').toString().trim(),
    );
  }
}

class Meeting {
  const Meeting({
    required this.folder,
    required this.topic,
    required this.round,
    required this.state,
    required this.speakers,
    required this.userNotes,
    required this.draft,
    required this.conclusion,
  });

  /// 회의 폴더 절대경로.
  final String folder;
  final String topic;
  final int round;

  /// `발언중` · `정리중` · `의견대기` · `완료`
  final String state;
  final List<MeetingSpeaker> speakers;
  final List<String> userNotes;

  /// 이번 라운드까지의 잠정 결론. 사회자가 적는다.
  final String draft;

  /// 최종 결론. 회의가 끝나야 찬다.
  final String conclusion;

  bool get done => state == '완료';
  bool get needsUser => state == '의견대기';
  String get logPath => '$folder/회의록.md';

  /// 화면을 다시 그릴지 가르는 값.
  ///
  /// ⚠️ 3초마다 무조건 다시 그리면 스크롤이 매번 처음으로 돌아간다.
  /// 할 일 브라우저에서 겪은 것과 같은 문제라 같은 방식으로 막는다.
  String get signature => [
        folder,
        topic,
        round,
        state,
        draft,
        conclusion,
        userNotes.length,
        for (final s in speakers) '${s.name}/${s.state}/${s.say.length}',
      ].join('|');

  static Meeting? parse(String folder, String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      final topic = (j['주제'] ?? '').toString().trim();
      if (topic.isEmpty) return null;
      final speakers = <MeetingSpeaker>[];
      final rawSpeakers = j['참석자'];
      if (rawSpeakers is List) {
        for (final item in rawSpeakers) {
          final one = MeetingSpeaker.parse(item);
          if (one != null) speakers.add(one);
        }
      }
      final notes = <String>[];
      final rawNotes = j['사용자의견'];
      if (rawNotes is List) {
        for (final n in rawNotes) {
          final t = n.toString().trim();
          if (t.isNotEmpty) notes.add(t);
        }
      }
      return Meeting(
        folder: folder,
        topic: topic,
        round: j['라운드'] is num ? (j['라운드'] as num).toInt() : 1,
        state: (j['상태'] ?? '발언중').toString().trim(),
        speakers: speakers,
        userNotes: notes,
        draft: (j['잠정결론'] ?? '').toString().trim(),
        conclusion: (j['결론'] ?? '').toString().trim(),
      );
    } catch (e) {
      debugPrint('회의 상태 읽기 실패($folder): $e');
      return null;
    }
  }
}

/// 등록된 프로젝트 아래 `.claude/회의록/`을 훑어 **가장 최근 회의 하나**를 든다.
///
/// 회의는 한 번에 하나만 본다. 여럿을 늘어놓으면 상판에 들어가지도 않고,
/// 두 회의를 동시에 굴릴 일도 아직 없다.
class MeetingStore extends ChangeNotifier {
  MeetingStore(this._projects);

  final ProjectStore _projects;
  Timer? _timer;
  Meeting? _now;
  String? _sig;

  /// 이번 라운드 발언 파일이 모두 들어왔다 — 사회자(두 번째 인자: 그 세션 폴더)를 깨운다.
  /// 사회자는 발언을 부탁한 뒤 자기 차례를 끝내 버려 라운드가 멈췄다(9/17 첫 실전).
  void Function(Meeting m, String moderator)? onAllSpoke;
  final _nudged = <String>{};

  /// 회의 폴더(`<뿌리>/.claude/회의록/<이름>`)에서 사회자 세션 폴더를 뽑는다.
  static String moderatorOf(String folder) => folder.split('/.claude/회의록/').first;

  /// 상태.json에 아직 안 옮긴 발언을 `발언/<이름>_r<N>.md`에서 채운다 — 사회자가 정리하기 전에도 말풍선이 뜬다.
  /// 두 번째 값은 모든 참석자의 이번 라운드 파일이 있는지, 세 번째는 그중 가장 최근 수정 시각이다.
  static (Meeting, bool, DateTime?) _withFiles(Meeting m) {
    var all = m.speakers.isNotEmpty;
    DateTime? latest;
    final speakers = <MeetingSpeaker>[];
    for (final sp in m.speakers) {
      final f = File('${m.folder}/발언/${sp.name}_r${m.round}.md');
      String text = '';
      try {
        if (f.existsSync()) {
          text = f.readAsStringSync().trim();
          final at = f.lastModifiedSync();
          if (latest == null || at.isAfter(latest)) latest = at;
        }
      } catch (_) {}
      // 진행자 파일은 깨우기 조건에서 뺀다 — 진행자는 깨워야 쓰는 쪽이라 기다리면 영영 안 깨어난다.
      if (text.isEmpty && !sp.spoke && !sp.silent && !sp.moderator) all = false;
      speakers.add(sp.spoke || text.isEmpty
          ? sp
          : MeetingSpeaker(name: sp.name, path: sp.path, state: '발언완료', say: text, summary: sp.summary, role: sp.role));
    }
    return (
      Meeting(folder: m.folder, topic: m.topic, round: m.round, state: m.state, speakers: speakers,
          userNotes: m.userNotes, draft: m.draft, conclusion: m.conclusion),
      all,
      latest,
    );
  }

  Meeting? get now => _now;
  bool get has => _now != null;

  void start() {
    _scan();
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => _scan());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 훑을 뿌리. 프로젝트 루트와 등록된 폴더들이다.
  ///
  /// 회의록이 어디에 생길지는 사회자 세션이 열린 폴더가 정한다. 한 곳만
  /// 박아두면 다른 폴더에서 연 회의가 통째로 안 보인다.
  Iterable<String> get _roots sync* {
    yield* kConfigRoots;
    for (final p in _projects.projects) {
      yield p.path;
    }
  }

  /// 훑어 찾은 회의 폴더 전부(최근 것부터). 회의실 「지난 회의」가 쓴다.
  List<(String, DateTime)> _all = const [];
  List<(String, DateTime)> get all => _all;

  /// 그 폴더의 회의를 읽는다 — 훑은 목록에 있는 폴더만(아무 경로나 열지 않게).
  Meeting? load(String folder) {
    if (!_all.any((e) => e.$1 == folder)) return null;
    try {
      final m = Meeting.parse(folder, File('$folder/상태.json').readAsStringSync());
      return m == null ? null : _withFiles(m).$1;
    } catch (_) {
      return null;
    }
  }

  /// 끝난 회의의 결론 문서 `결론.md` — 회의마다 한 장(대표 기획 9/17). 상태.json이 더 새로우면 다시 쓴다.
  /// 회의록.md는 사회자가 라운드마다 이어 붙이는 긴 기록이고, 이건 끌어서 세션에 넘길 짧은 문서다.
  static String? writeDoc(Meeting m) {
    if (!m.done) return null;
    final doc = File('${m.folder}/결론.md');
    try {
      final stateAt = File('${m.folder}/상태.json').lastModifiedSync();
      if (doc.existsSync() && !doc.lastModifiedSync().isBefore(stateAt)) return doc.path;
      final name = m.folder.split('/').last;
      final date = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(name);
      final b = StringBuffer()
        ..writeln('# 회의 결론 — ${m.topic}')
        ..writeln()
        ..writeln('- 날짜: ${date == null ? stateAt.toIso8601String().substring(0, 10) : '${date[1]}-${date[2]}-${date[3]}'}')
        ..writeln('- 라운드: ${m.round}')
        ..writeln('- 참석: ${m.speakers.map((s) => s.name).join(', ')}')
        ..writeln('- 진행: ${moderatorOf(m.folder).split('/').last}')
        ..writeln()
        ..writeln('## 결론')
        ..writeln()
        ..writeln(m.conclusion.isEmpty ? '(결론이 적히지 않았다)' : m.conclusion);
      if (m.draft.isNotEmpty) {
        b
          ..writeln()
          ..writeln('## 마지막 라운드 정리')
          ..writeln()
          ..writeln(m.draft);
      }
      if (m.userNotes.isNotEmpty) {
        b
          ..writeln()
          ..writeln('## 대표 의견');
        for (final n in m.userNotes) {
          b.writeln('- $n');
        }
      }
      b
        ..writeln()
        ..writeln('---')
        ..writeln('전체 기록: ${m.logPath}');
      doc.writeAsStringSync(b.toString());
      return doc.path;
    } catch (e) {
      debugPrint('결론 문서 쓰기 실패(${m.folder}): $e');
      return null;
    }
  }

  void _scan() {
    String? newest;
    DateTime? newestAt;
    final seen = <String>{};
    final found = <(String, DateTime)>[];
    for (final root in _roots) {
      final dir = Directory('$root/.claude/회의록');
      if (!seen.add(dir.path)) continue;
      if (!dir.existsSync()) continue;
      try {
        for (final entry in dir.listSync()) {
          if (entry is! Directory) continue;
          final state = File('${entry.path}/상태.json');
          if (!state.existsSync()) continue;
          final at = state.lastModifiedSync();
          found.add((entry.path, at));
          if (newestAt == null || at.isAfter(newestAt)) {
            newestAt = at;
            newest = entry.path;
          }
        }
      } catch (e) {
        debugPrint('회의록 폴더 훑기 실패(${dir.path}): $e');
      }
    }
    _all = found..sort((a, b) => b.$2.compareTo(a.$2));
    if (newest == null) {
      if (_now == null) return;
      _now = null;
      _sig = null;
      notifyListeners();
      return;
    }
    Meeting? next;
    try {
      next =
          Meeting.parse(newest, File('$newest/상태.json').readAsStringSync());
    } catch (e) {
      debugPrint('회의 상태 파일 읽기 실패: $e');
      return;
    }
    // 반쯤 쓰이던 파일이면 그냥 다음 차례에 다시 본다.
    if (next == null) return;
    final (filled, allSpoke, latest) = _withFiles(next);
    next = filled;
    writeDoc(next);
    // 발언중인데 파일이 다 들어왔으면 사회자를 한 번 깨운다. 앱을 다시 켰을 때 오래된 회의를 멋대로 되살리지 않게
    // 마지막 발언이 10분 안인 것만.
    if (next.state == '발언중' && allSpoke && latest != null &&
        DateTime.now().difference(latest) < const Duration(minutes: 10) &&
        _nudged.add('${next.folder}|${next.round}')) {
      onAllSpoke?.call(next, moderatorOf(next.folder));
    }
    if (next.signature == _sig) return;
    _sig = next.signature;
    _now = next;
    notifyListeners();
  }
}

// ── 토큰 사용량 ──────────────────────────────────────────
//
// `~/.claude/projects/<폴더>/*.jsonl` 의 `message.usage`를 프로젝트·날짜·모델로
// 모은다. 새로 뚫는 배관은 없다 — 위젯이 이미 읽고 있는 그 파일이다.
//
// ⚠️ **"크레딧"이 아니다.** 구독제라 로컬 어디에도 잔액이 없다. 여기서 나오는
// 것은 토큰이고, 돈은 API 정가를 곱한 **추정치**다. 화면에도 그렇게 적는다.

/// 토큰 다섯 갈래. 캐시는 쓰기(5분/1시간)와 읽기의 단가가 서로 다르다.
class UsageTally {
  UsageTally([
    this.input = 0,
    this.output = 0,
    this.write5m = 0,
    this.write1h = 0,
    this.read = 0,
    this.calls = 0,
  ]);

  int input;
  int output;
  int write5m;
  int write1h;
  int read;
  int calls;

  bool get isEmpty => calls == 0;

  /// 캐시 읽기까지 다 더한 값. 크기를 견줄 때만 쓴다.
  int get total => input + output + write5m + write1h + read;

  void add(UsageTally o, {int sign = 1}) {
    input += o.input * sign;
    output += o.output * sign;
    write5m += o.write5m * sign;
    write1h += o.write1h * sign;
    read += o.read * sign;
    calls += o.calls * sign;
  }

  List<int> toList() => [input, output, write5m, write1h, read, calls];

  static UsageTally fromList(Object? raw) {
    if (raw is! List || raw.length < 6) return UsageTally();
    int at(int i) => raw[i] is num ? (raw[i] as num).toInt() : 0;
    return UsageTally(at(0), at(1), at(2), at(3), at(4), at(5));
  }
}

/// 모델 하나의 100만 토큰당 단가(달러).
///
/// ⚠️ **API 정가다.** 구독으로 쓰는 이 환경의 실제 청구액이 아니다.
/// 캐시 쓰기는 입력의 1.25배(5분)·2배(1시간), 캐시 읽기는 0.1배가 규칙이라
/// 입력·출력만 적고 나머지는 계산한다. 규칙에서 벗어나는 모델만 따로 적는다.
class ModelPrice {
  const ModelPrice(this.input, this.output, {double? read})
      : _read = read;

  final double input;
  final double output;
  final double? _read;

  double get write5m => input * 1.25;
  double get write1h => input * 2;
  double get read => _read ?? input * 0.1;

  /// 모델 이름 → 단가. 앞부분만 맞으면 되게 접두어로 찾는다.
  ///
  /// 여기 없는 모델은 **비용을 셈하지 않는다.** 아무 값이나 끼워 넣으면
  /// 틀린 금액이 맞는 척 나온다.
  static const Map<String, ModelPrice> table = {
    'claude-fable-5-1': ModelPrice(10, 50, read: 0.25),
    'claude-fable-5': ModelPrice(10, 50),
    'claude-opus-5': ModelPrice(5, 25),
    'claude-opus-4-8': ModelPrice(5, 25),
    'claude-opus-4-7': ModelPrice(5, 25),
    'claude-opus-4-6': ModelPrice(5, 25),
    'claude-sonnet-5': ModelPrice(2, 10),
    'claude-sonnet-4-6': ModelPrice(3, 15),
    'claude-haiku-4-5': ModelPrice(1, 5),
  };

  static ModelPrice? of(String model) {
    ModelPrice? best;
    var bestLen = 0;
    for (final e in table.entries) {
      if (model.startsWith(e.key) && e.key.length > bestLen) {
        best = e.value;
        bestLen = e.key.length;
      }
    }
    return best;
  }

  /// 이 모델로 쓴 만큼의 달러. 단가를 모르는 모델이면 null.
  static double? cost(String model, UsageTally t) {
    // `<synthetic>`은 클로드 코드가 스스로 지어낸 줄이지 API 호출이 아니다.
    // 모르는 모델로 두면 화면에 쓸데없이 '뺐다' 딱지가 붙는다.
    if (model.startsWith('<')) return 0;
    final p = of(model);
    if (p == null) return null;
    return (t.input * p.input +
            t.output * p.output +
            t.write5m * p.write5m +
            t.write1h * p.write1h +
            t.read * p.read) /
        1000000;
  }
}

/// 한 칸 = 프로젝트(cwd) × 날짜 × 모델.
class UsageCell {
  const UsageCell(this.cwd, this.day, this.model, this.tally);

  final String cwd;
  final String day;
  final String model;
  final UsageTally tally;
}

/// transcript를 훑어 사용량을 모은다.
///
/// ⚠️ **매번 다 읽지 않는다.** 전부 합쳐 500MB가 넘어서 그렇게 하면 위젯이
/// 몇십 초씩 멈춘다. 파일마다 어디까지 읽었는지를 기억해 **늘어난 만큼만**
/// 읽고, 그 훑기는 아이솔레이트에서 돌려 화면을 막지 않는다.
class UsageStore extends ChangeNotifier {
  Timer? _timer;
  bool _busy = false;

  /// cwd → 칸들. 화면이 이걸 잘라 쓴다.
  final List<UsageCell> cells = [];

  /// 마지막으로 다 훑은 시각. 아직 한 번도 못 훑었으면 null.
  DateTime? scannedAt;

  /// 첫 훑기가 끝났는지. 500MB를 처음 읽을 때는 몇십 초가 걸린다.
  bool get ready => scannedAt != null;

  static String get cachePath => resolveConfigPath('usage_cache.json');

  void start() {
    unawaited(refresh());
    // 1분이면 충분하다. 훑는 것은 늘어난 몇 KB뿐이다.
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;
      final started = DateTime.now();
      final out = await Isolate.run(() => scanUsage(
            root: '$home/.claude/projects',
            cachePath: cachePath,
          ));
      _apply(out);
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (ms > 1500) debugPrint('사용량 훑기 ${ms}ms');
    } catch (e) {
      debugPrint('사용량 훑기 실패: $e');
    } finally {
      _busy = false;
    }
  }

  void _apply(Map<String, dynamic> out) {
    final raw = out['칸'];
    if (raw is! Map) return;
    cells
      ..clear()
      ..addAll([
        for (final e in raw.entries)
          if (e.key is String && (e.key as String).split('\t').length == 3)
            () {
              final parts = (e.key as String).split('\t');
              return UsageCell(
                  parts[0], parts[1], parts[2], UsageTally.fromList(e.value));
            }()
      ]);
    scannedAt = DateTime.now();
    notifyListeners();
  }

  /// 오늘 날짜 문자열. 칸의 `day`와 같은 규칙(현지 시각)이다.
  static String dayOf(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// `since` 이후(포함)의 칸만 골라 프로젝트별로 합친다.
  ///
  /// `match`는 cwd를 프로젝트 이름으로 바꾸는 함수다. null을 주면 그 칸은 버린다 —
  /// 등록되지 않은 폴더까지 세면 '누가 얼마나 썼나'가 흐려진다.
  Map<String, UsageTally> byProject(
      String? Function(String cwd) match, String since) {
    final out = <String, UsageTally>{};
    for (final c in cells) {
      if (c.day.compareTo(since) < 0) continue;
      final name = match(c.cwd);
      if (name == null) continue;
      (out[name] ??= UsageTally()).add(c.tally);
    }
    return out;
  }

  /// 한 프로젝트의 날짜별 합. 막대 그림에 쓴다.
  Map<String, UsageTally> daysOf(
      bool Function(String cwd) keep, String since) {
    final out = <String, UsageTally>{};
    for (final c in cells) {
      if (c.day.compareTo(since) < 0) continue;
      if (!keep(c.cwd)) continue;
      (out[c.day] ??= UsageTally()).add(c.tally);
    }
    return out;
  }

  /// 한 프로젝트의 모델별 합. 비용 추정이 모델을 알아야 셈해진다.
  Map<String, UsageTally> modelsOf(
      bool Function(String cwd) keep, String since) {
    final out = <String, UsageTally>{};
    for (final c in cells) {
      if (c.day.compareTo(since) < 0) continue;
      if (!keep(c.cwd)) continue;
      (out[c.model] ??= UsageTally()).add(c.tally);
    }
    return out;
  }

  /// 모델별 합에서 달러를 셈한다. 단가를 모르는 모델이 섞여 있으면 `exact`가
  /// false다 — 그때는 화면에 '일부 모델 제외'라고 적어야 한다.
  static (double, bool) costOf(Map<String, UsageTally> byModel) {
    var sum = 0.0;
    var exact = true;
    for (final e in byModel.entries) {
      final c = ModelPrice.cost(e.key, e.value);
      if (c == null) {
        exact = false;
        continue;
      }
      sum += c;
    }
    return (sum, exact);
  }
}

/// transcript를 훑어 캐시를 갱신하고 모아둔 칸을 돌려준다.
///
/// **아이솔레이트에서 돈다.** 화면이 쓰는 것은 손대지 않고 파일만 읽는다.
///
/// 캐시(`usage_cache.json`)가 들고 있는 것:
/// - `파일`: 경로 → 어디까지 읽었는지(`오프셋`)와 **마지막 줄의 흔적**
/// - `칸`: `cwd\t날짜\t모델` → 토큰 여섯 개
///
/// 마지막 줄의 흔적을 남기는 이유가 있다. `usage`가 달린 줄의 3분의 1이
/// **바로 앞줄과 같은 `message.id`** 다(스트리밍 조각). 실측으로 확인했다
/// (2026-09-03, 30,312줄 중 12,693건이 전부 간격 1). 앞의 것을 빼고 뒤의 것을
/// 더해야 하는데, 그 '앞의 것'이 지난번 훑기의 마지막 줄일 수 있다.
Map<String, dynamic> scanUsage({
  required String root,
  required String cachePath,
}) {
  Map<String, dynamic> cache = {};
  try {
    final f = File(cachePath);
    if (f.existsSync()) {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) cache = decoded;
    }
  } catch (_) {
    // 캐시가 깨졌으면 처음부터 다시 센다. 잘못된 값을 이어받는 것보다 낫다.
  }

  var files = <String, dynamic>{};
  var cells = <String, dynamic>{};
  if (cache['버전'] == 1) {
    if (cache['파일'] is Map<String, dynamic>) {
      files = Map<String, dynamic>.from(cache['파일'] as Map);
    }
    if (cache['칸'] is Map<String, dynamic>) {
      cells = Map<String, dynamic>.from(cache['칸'] as Map);
    }
  }

  final dir = Directory(root);
  if (!dir.existsSync()) return {'칸': cells};

  final paths = <String>[];
  try {
    for (final d in dir.listSync()) {
      if (d is! Directory) continue;
      for (final f in d.listSync()) {
        if (f is File && f.path.endsWith('.jsonl')) paths.add(f.path);
      }
    }
  } catch (_) {
    return {'칸': cells};
  }

  // ⚠️ **파일이 줄었으면 통째로 다시 센다.** 늘어난 만큼만 읽는 방식은
  // 파일이 앞에서부터 다시 쓰이면 무너진다. 되돌릴 방법이 없으므로 처음부터
  // 다시 세는 쪽이 맞다. transcript는 덧붙이기만 하므로 거의 일어나지 않는다.
  var restart = false;
  for (final path in paths) {
    final saved = files[path];
    if (saved is! Map) continue;
    final off = saved['오프셋'];
    if (off is! num) continue;
    try {
      if (File(path).lengthSync() < off.toInt()) {
        restart = true;
        break;
      }
    } catch (_) {}
  }
  if (restart) {
    files = {};
    cells = {};
  }

  void bump(String key, UsageTally t, int sign) {
    final cur = UsageTally.fromList(cells[key]);
    cur.add(t, sign: sign);
    if (cur.calls <= 0) {
      cells.remove(key);
    } else {
      cells[key] = cur.toList();
    }
  }

  for (final path in paths) {
    final file = File(path);
    int size;
    try {
      size = file.lengthSync();
    } catch (_) {
      continue;
    }
    final saved = files[path] is Map
        ? Map<String, dynamic>.from(files[path] as Map)
        : <String, dynamic>{};
    var offset = saved['오프셋'] is num ? (saved['오프셋'] as num).toInt() : 0;
    if (offset >= size) continue;

    String chunk;
    try {
      final raf = file.openSync();
      raf.setPositionSync(offset);
      final bytes = raf.readSync(size - offset);
      raf.closeSync();
      chunk = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      continue;
    }

    // 마지막 줄바꿈까지만 먹는다. 지금 쓰이는 중이라 반 토막일 수 있다.
    final cut = chunk.lastIndexOf('\n');
    if (cut < 0) continue;
    final consumed = utf8.encode(chunk.substring(0, cut + 1)).length;
    chunk = chunk.substring(0, cut);

    var lastId = saved['마지막ID'] as String?;
    var lastKey = saved['마지막칸'] as String?;
    var lastTally = UsageTally.fromList(saved['마지막값']);
    var lastCwd = saved['마지막cwd'] as String? ?? '';

    for (final line in chunk.split('\n')) {
      // 값싼 거르기가 먼저다. usage 없는 줄이 훨씬 많고 JSON 파싱은 비싸다.
      if (!line.contains('"output_tokens"')) continue;
      Map<String, dynamic> j;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        j = decoded;
      } catch (_) {
        continue;
      }
      final cwdRaw = j['cwd'];
      if (cwdRaw is String && cwdRaw.isNotEmpty) {
        lastCwd = ProjectStore.normalize(cwdRaw);
      }
      final m = j['message'];
      if (m is! Map) continue;
      final u = m['usage'];
      if (u is! Map) continue;
      final ts = j['timestamp'];
      if (ts is! String) continue;
      DateTime at;
      try {
        at = DateTime.parse(ts).toLocal();
      } catch (_) {
        continue;
      }
      if (lastCwd.isEmpty) continue;

      int num_(Object? v) => v is num ? v.toInt() : 0;
      final creation = u['cache_creation'];
      var w5 = 0, w1 = 0;
      if (creation is Map) {
        w5 = num_(creation['ephemeral_5m_input_tokens']);
        w1 = num_(creation['ephemeral_1h_input_tokens']);
      }
      // 갈래가 안 나오는 옛 줄은 통째로 5분 쓰기로 본다. 기본 TTL이 그것이다.
      final wTotal = num_(u['cache_creation_input_tokens']);
      if (w5 + w1 == 0) w5 = wTotal;

      final tally = UsageTally(
        num_(u['input_tokens']),
        num_(u['output_tokens']),
        w5,
        w1,
        num_(u['cache_read_input_tokens']),
        1,
      );
      final key = '$lastCwd\t${UsageStore.dayOf(at)}\t'
          '${m['model'] is String ? m['model'] : '알수없음'}';
      final id = m['id'] is String ? m['id'] as String : null;

      // 바로 앞줄과 같은 응답이면 앞의 것을 물린다. 스트리밍 조각이라
      // 뒤에 온 것이 더 온전하다.
      if (id != null && id == lastId && lastKey != null) {
        bump(lastKey, lastTally, -1);
      }
      bump(key, tally, 1);
      lastId = id;
      lastKey = key;
      lastTally = tally;
    }

    offset += consumed;
    files[path] = {
      '오프셋': offset,
      if (lastId != null) '마지막ID': lastId,
      if (lastKey != null) '마지막칸': lastKey,
      '마지막값': lastTally.toList(),
      '마지막cwd': lastCwd,
    };
  }

  try {
    final f = File(cachePath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
        jsonEncode({'버전': 1, '파일': files, '칸': cells}));
  } catch (_) {
    // 캐시를 못 써도 이번 값은 살아 있다. 다음 번에 다시 훑을 뿐이다.
  }

  return {'칸': cells};
}

// ── 남은 한도 ────────────────────────────────────────────
//
// 5시간 창·7일 창을 얼마나 썼고 언제 초기화되는지.
//
// **크레딧 탭과 다른 것을 답한다.** 크레딧 탭은 로컬 transcript를 세서
// '누가 얼마나 썼나'를 프로젝트별로 답하고, 이쪽은 서버가 알려주는 실제
// 한도라 '지금 얼마 남았나'를 답한다. 계정 전체 값이라 프로젝트별로 못 쪼갠다.
//
// ⚠️ **이 값은 상태줄로만 들어온다.** 클로드 코드가 상태줄 명령에 stdin으로
// 물려주는 JSON의 `rate_limits`가 유일한 출처다 — 로컬 파일 어디에도 없고
// transcript에도 없다. `scripts/statusline_limits.py`가 그것을 떠서 훅 서버로
// 넘긴다. 그래서 **상태줄이 걸려 있지 않으면 이 화면은 뜨지 않는다.**

class LimitWindow {
  const LimitWindow(this.percent, this.resetsAt);

  /// 0~100. 한도를 넘기면 100을 넘을 수도 있다.
  final double percent;
  final DateTime resetsAt;

  Duration get left => resetsAt.difference(DateTime.now());

  /// 초기화까지 남은 시간. `2시간 14분` · `3일 5시간`
  String get leftText {
    final d = left;
    if (d.isNegative) return '곧';
    if (d.inDays > 0) return '${d.inDays}일 ${d.inHours % 24}시간';
    if (d.inHours > 0) return '${d.inHours}시간 ${d.inMinutes % 60}분';
    return '${d.inMinutes}분';
  }

  static LimitWindow? parse(Object? raw) {
    if (raw is! Map) return null;
    final pct = raw['사용률'] ?? raw['used_percentage'];
    final at = raw['초기화'] ?? raw['resets_at'];
    if (pct is! num || at is! num) return null;
    return LimitWindow(
      pct.toDouble(),
      DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000),
    );
  }
}

class LimitStore extends ChangeNotifier {
  LimitWindow? fiveHour;
  LimitWindow? sevenDay;
  LimitWindow? spend;
  DateTime? at;

  /// 뭐라도 받아본 적이 있는지. 없으면 화면에 아무것도 안 낸다 —
  /// **0%로 보이면 안 된다.** 안 쓴 것과 모르는 것은 다르다.
  bool get has => fiveHour != null || sevenDay != null || spend != null;

  /// 값이 너무 오래됐는지. 상태줄은 턴마다 도니까, 한참 소식이 없으면
  /// 세션이 다 닫혔거나 상태줄이 빠진 것이다.
  bool get stale =>
      at == null || DateTime.now().difference(at!) > const Duration(hours: 2);

  /// 두 창 중 더 급한 쪽. 책상에는 한 줄만 낼 자리라 이걸 고른다.
  LimitWindow? get worst {
    LimitWindow? best;
    for (final w in [fiveHour, sevenDay, spend]) {
      if (w == null) continue;
      if (best == null || w.percent > best.percent) best = w;
    }
    return best;
  }

  void handle(Map<String, dynamic> raw) {
    final five = LimitWindow.parse(raw['five_hour']);
    final seven = LimitWindow.parse(raw['seven_day']);
    final sp = LimitWindow.parse(raw['spend_limit']);
    if (five == null && seven == null && sp == null) return;
    // ⚠️ **온 것만 갈아끼운다.** 한 창의 `resets_at`이 지나면 그 창은 아예
    // 빠져서 온다. 통째로 덮어쓰면 멀쩡한 다른 창까지 사라진다.
    if (five != null) fiveHour = five;
    if (seven != null) sevenDay = seven;
    if (sp != null) spend = sp;
    at = DateTime.now();
    notifyListeners();
  }
}

class Tmux {
  // GUI에서 띄운 프로세스는 PATH가 얕다. 절대경로로 찾는다.
  static const List<String> _candidates = [
    '/opt/homebrew/bin/tmux',
    '/usr/local/bin/tmux',
    '/usr/bin/tmux',
  ];

  static String? _binary;
  static bool _looked = false;

  static String? get binary {
    if (_looked) return _binary;
    _looked = true;
    // 확인용 — 시스템 tmux가 있는 맥에서도 「아무것도 안 깐 사람」처럼 앱 안 tmux만 보게 한다.
    final onlyBundled = Platform.environment['CLAUDE_WATCHER_BUNDLED_TMUX_ONLY'] == '1';
    for (final path in [if (!onlyBundled) ..._candidates, bundledPath]) {
      if (File(path).existsSync()) {
        _binary = path;
        break;
      }
    }
    return _binary;
  }

  /// 배포 zip의 앱 안에 넣은 tmux(`scripts/build_tmux.sh` → `release.py`가 `Contents/MacOS/tmux`로 넣는다).
  /// **시스템 tmux가 있으면 그쪽을 먼저 쓴다** — 터미널에서 `tmux attach`로 붙는 것과 같은 판이어야 서버가 안 갈린다.
  /// 받은 사람이 아무것도 안 깔았을 때만 이것이 쓰인다(대표 결정 2026-09-17, 게임의 DirectX처럼).
  static String get bundledPath => '${File(Platform.resolvedExecutable).parent.path}/tmux';

  static bool get isBundled => binary != null && binary == bundledPath;

  /// 경로에서 세션 이름을 만든다.
  ///
  /// **`scripts/tmux_up.py`의 `session_name`과 같은 결과여야 한다.**
  /// 한쪽만 고치면 위젯이 엉뚱한 세션을 보게 된다.
  static String sessionName(String path) {
    const forbidden = '.: \t\n/';
    var p = ProjectStore.normalize(path);
    final base = p.split('/').where((s) => s.isNotEmpty).lastOrNull ?? p;
    final name = base.split('').map((c) => forbidden.contains(c) ? '_' : c).join();
    final cut = name.length > 60 ? name.substring(0, 60) : name;
    return cut.isEmpty ? 'project' : cut;
  }

  /// 지금 살아 있는 세션 이름 전부. tmux가 없거나 서버가 안 떠 있으면 null.
  ///
  /// null과 빈 집합은 뜻이 다르다. null은 "모른다"(판단 근거 없음)이고,
  /// 빈 집합은 "tmux는 도는데 세션이 하나도 없다"이다.
  static Future<Set<String>?> liveSessions() async {
    final bin = binary;
    if (bin == null) return null;
    try {
      // ⚠️ **utf8로 읽어야 한다.** `Process.run`의 기본은 시스템 인코딩인데, 파인더·독에서 띄운 앱은
      // `LANG`이 없어 그것이 latin1로 떨어진다 — 한글 세션 이름이 깨져 목록에 없는 것이 되고,
      // 그 세션이 **살아 있는데 「퇴근했다」로 흐려졌다**(대표 제보 2026-09-20).
      // 영문 이름만 멀쩡해서 한참 안 드러났다.
      final r = await Process.run(bin, ['list-sessions', '-F', '#{session_name}'],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      if (r.exitCode != 0) {
        final err = (r.stderr as String);
        // 서버가 아예 안 떠 있으면 세션이 없는 것이 맞다.
        if (err.contains('no server running')) return <String>{};
        return null;
      }
      return (r.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toSet();
    } catch (e) {
      debugPrint('tmux list-sessions 실패: $e');
      return null;
    }
  }

  /// 세션을 내린다(퇴근). 위젯이 스스로 세션을 죽이는 유일한 길 — 대화 칸 「퇴근」을 두 번 눌렀을 때만(9/17).
  static Future<bool> killSession(String name) async {
    final bin = binary;
    if (bin == null) return false;
    try {
      final r = await Process.run(bin, ['kill-session', '-t', '=$name']);
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('tmux kill-session 실패: $e');
      return false;
    }
  }

  static Future<bool> hasSession(String name) async {
    final bin = binary;
    if (bin == null) return false;
    try {
      final r = await Process.run(bin, ['has-session', '-t', '=$name']);
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('tmux has-session 실패: $e');
      return false;
    }
  }

  /// 지금 화면을 텍스트로 떠온다.
  ///
  /// 전체 로그가 아니다. 클로드 코드는 alternate screen에서 돌아 스크롤백이
  /// 없으므로 **보이는 화면이 전부**다. 근거는 `docs/tmux_검증_20260804/`.
  static Future<String?> capturePane(String name) async {
    final bin = binary;
    if (bin == null) return null;
    try {
      final r = await Process.run(bin, ['capture-pane', '-p', '-t', name],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      if (r.exitCode != 0) return null;
      return (r.stdout as String).trimRight();
    } catch (e) {
      debugPrint('tmux capture-pane 실패: $e');
      return null;
    }
  }

  // 세션을 만들 때 잡아둘 화면 크기. scripts/tmux_up.py와 같은 값이어야 한다.
  // capture-pane은 '보이는 화면'만 주므로 기본 80×24로 만들면 그만큼 잘린다.
  static const int paneWidth = 120;
  /// 세션을 만들 때 잡아둘 세로 크기.
  ///
  /// **45줄로는 슬라이더 창(`/effort`)의 옵션 줄이 잘린다.** capture-pane은
  /// 보이는 화면만 주므로, 잘리면 위젯이 고를 것을 아예 못 읽는다. 60줄이면
  /// 다 들어온다 — 2026-08-06 실측.
  static const int paneHeight = 60;

  /// 세션 안에서 칠 기본 명령.
  ///
  /// **`scripts/tmux_up.py`의 `LAUNCH_COMMAND`와 같아야 한다.** 위젯에서 띄운
  /// 세션과 `cw`로 띄운 세션이 다르게 굴면 어느 쪽에서 띄웠는지를 기억해야 한다.
  /// 그 규칙은 테스트로 굳혀 두었다.
  ///
  /// ⚠️ **승인창을 받는 쪽이 기본이다.** 예전에는 반대였다 —
  /// `--dangerously-skip-permissions`가 기본이고 안전한 쪽이 옵트인이었다.
  /// "지켜보는 폴더가 전부 본인 것"이라는 전제로 그렇게 뒀는데, 남이 받아
  /// 쓰는 도구가 되면 그 전제가 깨진다. 받자마자 도구 승인이 전부 통과되는
  /// 기본값은 한 번 사고가 나면 그것으로 끝이다. 그래서 뒤집었다(2026-09-09).
  static const String launchCommand = 'claude';

  /// 승인을 생략하고 띄우는 명령. **고르는 사람이 켜야 한다.**
  static const String skipCommand = 'claude --dangerously-skip-permissions';

  /// 승인 생략으로 띄울지. **두 가지로 켠다.**
  ///
  /// | 어떻게 | 어디에 쓰나 |
  /// |---|---|
  /// | `CLAUDE_WATCHER_YOLO=1` | 터미널에서 띄울 때 |
  /// | 설정 자리에 `yolo` 파일 | **파인더에서 띄울 때** |
  ///
  /// ⚠️ **환경변수만 두면 안 된다.** 파인더에서 더블클릭하면 환경변수를
  /// 줄 방법이 없어서, 위젯의 `여기서 기동`으로 띄운 세션만 승인창을 받는
  /// 반쪽 상태가 된다. 실제로 그랬다(2026-09-09) — `cw`는 승인을 생략하는데
  /// 위젯에서 띄운 세션만 달라서 왜 그런지 알기 어려웠다.
  ///
  /// ⚠️ **기본은 여전히 꺼져 있다.** 파일이 있어야 켜지므로 남이 받아
  /// 그냥 띄우면 승인창을 받는다.
  ///
  /// **폴더 신뢰 확인창은 어느 쪽으로 켜도 안 사라진다.** 2026-08-05에 실제로
  /// 띄워 확인했다 — `1. Yes, I trust this folder`가 그대로 나온다.
  /// 그래서 선택 카드는 어느 쪽으로 띄우든 쓸모가 있다.
  static bool get yolo => yoloByEnv || yoloByFile;

  /// 환경변수로 켜져 있는가. **파일로 끌 수 없는 상태다.**
  static bool get yoloByEnv =>
      Platform.environment['CLAUDE_WATCHER_YOLO'] == '1';

  /// 승인 생략 표식이 사는 자리. **설치 자리와 상관없이 한 곳이다.**
  ///
  /// ⚠️ `resolveConfigPath`를 쓰면 안 된다. 그건 설치본마다 다른 자리를
  /// 주는데, 이 표식은 *이 사람이 승인창을 받을 것인가* 하는 취향이라
  /// 설치본마다 달라야 할 이유가 없다. 실제로 갈렸다(2026-09-09) —
  /// 위젯은 설치본 옆을 보고 `cw`는 저장소를 봐서, 책상은 🔓인데
  /// `cw yolo`는 꺼짐이라고 했다.
  ///
  /// **`tmux_up.py`의 `YOLO_FILE`과 같은 경로여야 한다.**
  static String get yoloPath => '${_supportDir()}/yolo';

  static File get yoloFile => File(yoloPath);

  static bool get yoloByFile => yoloFile.existsSync();

  /// 표식 파일을 만들거나 지운다. 지금 상태를 돌려준다.
  ///
  /// ⚠️ **이미 떠 있는 세션은 안 바뀐다.** 플래그는 클로드가 시작할 때
  /// 정해지므로 다음에 띄우는 세션부터 적용된다. 부르는 쪽이 그걸 알린다.
  static bool setYolo(bool on) {
    try {
      final f = yoloFile;
      if (on) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(
            '이 파일이 있으면 세션을 승인 생략으로 띄운다.\n'
            '지우면 승인창을 받는다. 위젯 책상의 자물쇠 버튼이 이 파일을 다룬다.\n');
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (e) {
      debugPrint('승인 생략 표식 바꾸기 실패: $e');
    }
    return yolo;
  }

  static String get launch => yolo ? skipCommand : launchCommand;

  // 한글 입력 상태에서는 d가 ㅇ으로 들어가 detach가 먹지 않는다.
  static const Map<String, String> hangulKeys = {
    'ㅇ': 'detach-client',
    'ㅊ': 'new-window',
    'ㅌ': 'kill-pane',
    'ㅈ': 'list-sessions',
  };

  /// 세션을 새로 띄우고 그 안에서 클로드를 실행한다.
  ///
  /// 이미 있으면 아무것도 하지 않는다 — 사람이 쓰고 있는 세션을 건드리면 안 된다.
  /// 코덱스로 켤 때의 명령. 승인 생략(yolo)은 코덱스에 옮기지 않는다 — 코덱스는 자기 승인 설정(/approvals)을 따른다.
  static const String codexCommand = 'codex';

  static Future<bool> startSession(String name, String path, {String? firstPrompt, String? agent}) async {
    final bin = binary;
    if (bin == null) return false;
    if (await hasSession(name)) return true;
    try {
      final made = await Process.run(bin, [
        'new-session', '-d', '-s', name, '-c', path,
        '-x', '$paneWidth', '-y', '$paneHeight',
      ]);
      if (made.exitCode != 0) {
        debugPrint('tmux new-session 실패: ${made.stderr}');
        return false;
      }
      for (final entry in hangulKeys.entries) {
        await Process.run(bin, ['bind-key', '-T', 'prefix', entry.key, entry.value]);
      }
      // 첫 말은 `claude "…"`로 같이 넘긴다 — 세션이 뜨자마자 그 말에 답한다(처음 설정의 새 폴더).
      // `-l`로 글자 그대로 보낸다. 작은따옴표로 감싸 셸이 풀지 않게 한다.
      final base = (agent ?? FirstRun.defaultAgent()) == 'codex' ? codexCommand : launch;
      final cmd = firstPrompt == null ? base : "$base '${firstPrompt.replaceAll("'", "'\\''")}'";
      await Process.run(bin, ['send-keys', '-t', name, '-l', cmd]);
      await Process.run(bin, ['send-keys', '-t', name, 'Enter']);
      return true;
    } catch (e) {
      debugPrint('tmux 기동 실패: $e');
      return false;
    }
  }

  /// 특수 키 하나를 보낸다 (`Up` `Down` `Left` `Right` `Enter` `Escape` 등).
  ///
  /// 클로드 코드의 선택창은 숫자로 고르는 것도 있고 화살표로 옮기는 것도 있다.
  /// 글자만 보낼 수 있으면 후자를 못 다룬다.
  static Future<bool> sendKey(String name, String key) async {
    final bin = binary;
    if (bin == null) return false;
    try {
      final r = await Process.run(bin, ['send-keys', '-t', name, key]);
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('tmux send-keys($key) 실패: $e');
      return false;
    }
  }

  /// 세션에 한 줄 넣고 실행시킨다.
  ///
  /// 문자열과 Enter를 **따로** 보내야 한다. 붙여 보내면 입력만 되고 제출이 안 된다.
  /// (BRIEF 3단계 검증에서 확인)
  /// 사람이 친 말을 세션에 넣고 제출한다.
  ///
  /// ⚠️ **`send-keys`로 문자열을 그대로 보내면 안 된다.** tmux가 그걸 키 이름과
  /// 명령으로 해석한다. 실측으로 확인했다(2026-08-06) — `send-keys … 'Enter'`는
  /// 글자 `Enter`를 치는 대신 **엔터 키를 눌렀다.** 세미콜론은 명령 구분자다.
  ///
  /// 그래서 버퍼에 담아 **bracketed paste**(`-p`)로 붙여넣는다. 글자가 그대로
  /// 가고, **여러 줄도 한 프롬프트로** 들어간다. 사람이 손으로 붙여넣는 것과
  /// 같은 경로다.
  ///
  /// 인자로 넘기지 않고 파일을 거치는 이유는 길이 제한 때문이다. 긴 글을
  /// 통째로 넘기면 인자 한도에 걸린다.
  static Future<bool> sendLine(String name, String line) async {
    final bin = binary;
    if (bin == null || line.trim().isEmpty) return false;
    const buffer = 'claude_watcher';
    File? scratch;
    try {
      scratch = File('${Directory.systemTemp.path}/cw_send_${name.hashCode}.txt');
      scratch.writeAsStringSync(line);
      final load =
          await Process.run(bin, ['load-buffer', '-b', buffer, scratch.path]);
      if (load.exitCode != 0) return false;
      // -p: bracketed paste · -d: 붙여넣은 뒤 버퍼를 지운다
      final paste = await Process.run(
          bin, ['paste-buffer', '-b', buffer, '-t', name, '-p', '-d']);
      if (paste.exitCode != 0) return false;
      // 붙여넣은 것이 입력창에 자리를 잡은 뒤 제출한다.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final entered = await Process.run(bin, ['send-keys', '-t', name, 'Enter']);
      if (entered.exitCode != 0) return false;

      // ⚠️ **보냈다고 믿지 않고 화면으로 확인한다.** 세션이 일하는 중이면 Enter가 삼켜져
      // 글이 입력창에 그대로 남는 일이 있었다 — 대표는 보냈다고 알고 있는데 세션은 못 받았다
      // (대표 제보 2026-09-17). 조용히 잃는 것이 가장 나쁘다.
      //
      // 입력창에 방금 그 글이 아직 앉아 있으면 Enter를 한 번 더 친다. 그래도 남아 있으면
      // 실패로 돌려 화면이 알리게 한다(대화에 남긴 「내 말」은 부르는 쪽이 거둬들인다).
      final head = line.trim().split('\n').first;
      final probe = head.length > 12 ? head.substring(0, 12) : head;
      for (var tries = 0; tries < 2 && probe.isNotEmpty; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        final pane = await capturePane(name);
        if (pane == null) return true; // 화면을 못 보면 판단하지 않는다(보낸 것으로 친다)
        final tail = pane.split('\n').reversed.take(8).join('\n');
        if (!tail.contains(probe)) return true; // 입력창에서 사라졌다 = 들어갔다
        debugPrint('보낸 말이 입력창에 남아 있다 — Enter를 다시 친다 ($name)');
        await Process.run(bin, ['send-keys', '-t', name, 'Enter']);
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final last = await capturePane(name);
      final stuck = last != null &&
          last.split('\n').reversed.take(8).join('\n').contains(probe);
      if (stuck) debugPrint('보낸 말이 끝내 안 들어갔다 ($name)');
      return !stuck;
    } catch (e) {
      debugPrint('tmux 붙여넣기 실패: $e');
      return false;
    } finally {
      // 사람이 친 말이 임시 파일에 남지 않게 한다.
      try {
        scratch?.deleteSync();
      } catch (_) {}
    }
  }
}

/// 선택창에 답하는 동작. **위젯의 선택 카드와 대시보드 대화 칸이 같은 것을 쓴다.**
///
/// 답은 `(error, said)` — `said`는 대화에 「내가 한 말」로 남길 글이다.
///
/// ⚠️ **누른 사람이 본 화면과 지금 화면이 같은지 먼저 본다.** 대시보드는 화면을
/// 1~2초 늦게 받으므로, 그 사이 창이 바뀌었으면 같은 번호가 다른 선택지일 수 있다.
/// 그래서 번호와 함께 **선택지 글자**를 받아 지금 화면에서 다시 찾는다.
class PaneActions {
  static Future<String?> _missing(String name) async =>
      Tmux.binary == null ? 'tmux가 없다' : (await Tmux.hasSession(name) ? null : '세션이 없다 ($name)');

  static Future<PaneOption?> _find(String name, int number, String? text) async {
    final now = PaneChoice.parse(await Tmux.capturePane(name));
    final o = now?.options.where((x) => x.number == number).firstOrNull;
    if (o == null || (text != null && o.text != text)) return null;
    return o;
  }

  /// 번호 하나를 고른다(한 개 고르는 창).
  ///
  /// 숫자를 치면 그 자리에서 확정되는 창이 대부분이지만 커서만 옮기고 마는
  /// 창도 있다. 그래서 보낸 뒤 화면을 다시 떠와 **아직 남아 있을 때만** Enter를
  /// 더 보낸다. 무턱대고 붙이면 이미 확정된 뒤의 입력창에 빈 줄이 들어간다.
  static Future<({String? error, String? said})> choose(String cwdPath, int number, {String? text}) async {
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return (error: miss, said: null);
    final o = await _find(name, number, text);
    if (o == null) return (error: '선택창이 바뀌었다 — 다시 보고 고른다', said: null);
    await Tmux.sendKey(name, '$number');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final still = PaneChoice.parse(await Tmux.capturePane(name));
    // ⚠️ 다중 선택창에서는 Enter가 확정이 아니라 **커서 줄 토글**이다.
    // 여기서 덧붙이면 방금 고른 것이 도로 꺼진다. 그쪽은 [submit]이 맡는다.
    if (still != null && !still.multi && still.cursor == number) {
      await Tmux.sendKey(name, 'Enter');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return (error: null, said: '$number. ${o.text}');
  }

  /// 터미널 커서만 그 선택지로 옮긴다 — **고르지 않는다.** 미리보기가 붙은 창에서 오른쪽 미리보기를
  /// 그 선택지 것으로 바꾸려고 쓴다(↑/↓ 는 터미널에서 커서만 옮긴다, 실측 9/15). 옮긴 뒤 커서를 다시 읽어 확인한다.
  static Future<String?> point(String cwdPath, int number, {String? text}) async {
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return miss;
    final now = PaneChoice.parse(await Tmux.capturePane(name));
    final o = now?.options.where((x) => x.number == number).firstOrNull;
    if (now == null || o == null || (text != null && o.text != text)) return '선택창이 바뀌었다 — 다시 보고 고른다';
    final cur = now.cursor;
    if (cur == null) return '커서를 못 읽었다 — 터미널 원본에서 옮긴다';
    final delta = number - cur;
    final key = delta > 0 ? 'Down' : 'Up';
    for (var i = 0; i < delta.abs(); i++) {
      await Tmux.sendKey(name, key);
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return null;
  }

  /// 체크박스 하나를 켜고 끈다. **숫자를 보내면 토글된다** (실측 2026-08-11).
  /// 켜졌는지는 따로 기억하지 않는다 — 화면을 다시 떠서 읽는다.
  static Future<String?> toggle(String cwdPath, int number, {String? text}) async {
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return miss;
    final o = await _find(name, number, text);
    if (o == null || !o.checkable) return '선택창이 바뀌었다 — 다시 보고 고른다';
    await Tmux.sendKey(name, '$number');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return null;
  }

  /// 다중 선택창을 확정한다 — `Submit`(또는 `Next`) 줄까지 커서를 옮기고 Enter다.
  ///
  /// ⚠️ **몇 칸 옮겼는지를 믿지 않는다.** 옮긴 뒤 화면을 다시 떠서 커서가
  /// 정말 그 줄에 있을 때만 Enter를 친다. 한 칸이라도 어긋나면 엉뚱한
  /// 것을 켜거나 `Chat about this` 로 새어 나간다(실측 2026-08-11).
  static Future<({String? error, String? said})> submit(String cwdPath) async {
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return (error: miss, said: null);
    final before = PaneChoice.parse(await Tmux.capturePane(name));
    final delta = before?.toSubmit;
    if (before == null || delta == null) {
      return (error: '확정할 자리를 못 찾았다 — 터미널 원본에서 해달라', said: null);
    }
    final picked = before.checkedOptions;
    // 문항이 여럿인 창이면 어느 문항의 답인지도 같이 남긴다.
    final asked = before.isNext ? before.question : null;
    final key = delta > 0 ? 'Down' : 'Up';
    for (var i = 0; i < delta.abs(); i++) {
      await Tmux.sendKey(name, key);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final after = PaneChoice.parse(await Tmux.capturePane(name));
    if (after == null || after.submitRow == null || after.cursorRow != after.submitRow) {
      return (error: '커서가 확정 줄에 못 갔다 — 터미널 원본에서 해달라', said: null);
    }
    await Tmux.sendKey(name, 'Enter');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final answer = picked.isEmpty ? '(아무것도 안 고름)' : picked.map((o) => o.text).join(', ');
    return (error: null, said: asked == null ? answer : '$asked → $answer');
  }

  /// 슬라이더를 고른 자리까지 옮긴다. **Enter는 안 보낸다** — 옮긴 결과를 보고
  /// 사람이 확정한다(화살표 수는 칸 계산으로 어림잡는 것이라 어긋날 수 있다).
  static Future<String?> slide(String cwdPath, int target, {String? label}) async {
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return miss;
    final sl = PaneSlider.parse(await Tmux.capturePane(name));
    if (sl == null || target < 0 || target >= sl.options.length ||
        (label != null && sl.options[target] != label)) {
      return '고르는 창이 바뀌었다 — 다시 보고 고른다';
    }
    final delta = target - sl.current;
    final key = delta > 0 ? 'Right' : 'Left';
    for (var i = 0; i < delta.abs(); i++) {
      await Tmux.sendKey(name, key);
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return null;
  }

  /// 대시보드가 보낼 수 있는 키. **멈추기(esc)와 확정(Enter)뿐이다** — 대화 칸은
  /// 키패드가 아니다. 글자는 [Tmux.sendLine]으로만 간다.
  static const Set<String> allowedKeys = {'Escape', 'Enter'};

  static Future<String?> key(String cwdPath, String key) async {
    if (!allowedKeys.contains(key)) return '보낼 수 없는 키다 ($key)';
    final name = Tmux.sessionName(cwdPath);
    final miss = await _missing(name);
    if (miss != null) return miss;
    return await Tmux.sendKey(name, key) ? null : '키를 못 보냈다 ($name)';
  }
}

/// 처음 설정 — 받은 사람이 명령어를 치지 않고 마당을 붙이게 한다 (2026-09-16 프로그램화).
///
/// 대시보드가 켜질 때 네 가지를 본다: tmux · claude · 훅 · 등록한 폴더. 하나라도 비면 ⚙ 「처음 설정」 창이 뜬다.
/// 훅은 `scripts/setup_hooks.py`와 **같은 줄**을 넣는다 — 둘이 다르면 스크립트의 `--remove`가 못 알아보고,
/// 한쪽이 넣은 것을 다른 쪽이 또 넣어 이벤트마다 curl이 두 번 돈다. 테스트가 줄 모양을 붙잡고 있다.
///
/// ⚠️ **추가만 한다.** 남의 훅·이미 있는 우리 훅은 건드리지 않는다. 답 넘김 모양을 고치는 일은 스크립트 몫이다.
class FirstRun {
  // ── 쓰는 에이전트 (9/17 대표 결정 — Claude Code / Codex, 둘 다 고를 수 있다) ──
  // 코덱스만 쓰는 사람도 처음 설정이 「준비 안 됨」에 멈추지 않고, 「출근시키기」가 코덱스를 켜게 한다.
  static String get agentsPath => resolveConfigPath('agents.json');

  /// 저장된 선택. 없으면 null — 그때는 설치된 쪽으로 정한다([agentsOf]).
  static ({bool claude, bool codex})? savedAgents() {
    try {
      final f = File(agentsPath);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return null;
      final c = j['claude'] == true, x = j['codex'] == true;
      return (c || x) ? (claude: c, codex: x) : null;
    } catch (_) {
      return null;
    }
  }

  static String? saveAgents(bool claude, bool codex) {
    if (!claude && !codex) return '하나는 골라야 한다';
    try {
      File(agentsPath).writeAsStringSync(jsonEncode({'claude': claude, 'codex': codex}));
      return null;
    } catch (e) {
      return '저장을 못 했다: $e';
    }
  }

  /// 저장된 것이 없으면 설치된 쪽 — 둘 다 없거나 클로드가 있으면 클로드, 코덱스가 있으면 코덱스도.
  static ({bool claude, bool codex}) agentsOf(String? claudePath, String? codexPath) =>
      savedAgents() ?? (claude: claudePath != null || codexPath == null, codex: codexPath != null);

  /// 켤 때 쓸 에이전트 — 부른 쪽이 고르지 않았으면 클로드가 켜져 있으면 클로드, 아니면 코덱스.
  static String defaultAgent() {
    final a = savedAgents();
    if (a == null) return 'claude';
    return a.claude ? 'claude' : 'codex';
  }

  static Future<String?> codexPath() {
    final home = Platform.environment['HOME'] ?? '';
    return which('codex', ['/opt/homebrew/bin/codex', '/usr/local/bin/codex', '$home/.local/bin/codex', '$home/.npm-global/bin/codex']);
  }

  /// 코덱스 훅 이벤트 — 0.154.0 실측(9/17). 이름·칸이 클로드 코드 훅과 같다.
  static const List<String> codexEvents = [
    'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'Interrupt', 'SessionEnd',
  ];
  static String get codexHooksPath =>
      Platform.environment['CLAUDE_WATCHER_CODEX_HOOKS'] ?? '${Platform.environment['HOME'] ?? ''}/.codex/hooks.json';

  static String codexHookCommand(int port) =>
      "curl -s -m 2 -X POST http://127.0.0.1:$port/ -H 'Content-Type: application/json' --data-binary @- > /dev/null || true  # $_mark";

  static List<String> missingCodexHooks(Map settings, int port) => missingHooksFor(settings, port, codexEvents);

  static List<String> missingHooksFor(Map settings, int port, List<String> events) {
    final hooks = settings['hooks'] is Map ? settings['hooks'] as Map : const {};
    bool ours(Object? g) => g is Map && g['hooks'] is List && (g['hooks'] as List).any((h) => _isOurs(h, port));
    return [
      for (final e in events)
        if (hooks[e] == null || (hooks[e] is List && !(hooks[e] as List).any(ours))) e,
    ];
  }

  /// ~/.codex/hooks.json에 빠진 이벤트만 덧붙인다(백업·남의 훅 그대로). remove면 우리 줄만 뺀다.
  /// ⚠️ 코덱스는 새 훅을 **사용자가 /hooks에서 신뢰해야** 돌린다 — 여기서 대신 신뢰하지 않는다.
  static String? writeCodexHooks({bool remove = false}) {
    if (kIsDevInstance && Platform.environment['CLAUDE_WATCHER_CODEX_HOOKS'] == null) {
      return '확인용 판에서는 코덱스 훅을 넣지 않는다 (CLAUDE_WATCHER_CODEX_HOOKS로 다른 파일을 가리킬 때만)';
    }
    final f = File(codexHooksPath);
    Map settings;
    try {
      final text = f.existsSync() ? f.readAsStringSync().trim() : '';
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is! Map) return 'hooks.json 모양이 객체가 아니다 — 덮어쓰지 않는다';
      settings = decoded;
    } catch (_) {
      return 'hooks.json이 깨져 있다 — 손대지 않는다';
    }
    final next = jsonDecode(jsonEncode(settings)) as Map<String, dynamic>;
    final hooks = (next['hooks'] ??= <String, dynamic>{});
    if (hooks is! Map) return 'hooks.json의 hooks 모양이 객체가 아니다 — 덮어쓰지 않는다';
    if (remove) {
      for (final e in codexEvents) {
        final groups = hooks[e];
        if (groups is! List) continue;
        groups.removeWhere((g) => g is Map && g['hooks'] is List && (g['hooks'] as List).any((h) => _isOurs(h, kPort)));
        if (groups.isEmpty) hooks.remove(e);
      }
    } else {
      for (final e in missingCodexHooks(next, kPort)) {
        ((hooks[e] ??= <dynamic>[]) as List).add({
          if (const {'PreToolUse', 'PostToolUse', 'PermissionRequest'}.contains(e)) 'matcher': '.*',
          // 코덱스는 SessionEnd·Interrupt 제한 시간을 3초로 자른다 — 경고가 안 뜨게 처음부터 3초.
          'hooks': [{'type': 'command', 'command': codexHookCommand(kPort), 'timeout': 3}],
        });
      }
    }
    if (jsonEncode(next) == jsonEncode(settings)) return null;
    try {
      f.parent.createSync(recursive: true);
      if (f.existsSync()) {
        final t = DateTime.now();
        String two(int n) => n.toString().padLeft(2, '0');
        final stem = '${f.path}.bak-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
        var bak = stem;
        for (var n = 2; File(bak).existsSync(); n++) {
          bak = '$stem-$n';
        }
        f.copySync(bak);
      }
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(next)}\n');
      tmp.renameSync(f.path);
    } catch (e) {
      return '코덱스 훅을 못 넣었다: $e';
    }
    return null;
  }

  /// `/회의` 명령 파일 — Claude Code가 읽는 자리(~/.claude/commands/회의.md). DMG로 받은 사람은 저장소가 없어 앱 안의 사본을 깐다(9/17).
  static String get meetingCommandPath => '${Platform.environment['HOME'] ?? ''}/.claude/commands/회의.md';

  static String? meetingCommandSource() {
    final exe = File(Platform.resolvedExecutable).parent.parent.path; // Contents
    for (final c in [
      // 앱 안 사본은 영문 이름이다 — DMG(HFS+)가 한글 파일 이름을 풀어 써서 서명 봉인이 깨졌다(9/17 공증 Invalid).
      '$exe/Resources/commands/meeting.md',
      for (final root in kConfigRoots) '$root/.claude/commands/회의.md',
      for (final root in kConfigRoots) '$root/docs/commands/회의.md',
    ]) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 없으면 깐다. 이미 있으면 사용자가 고쳐 쓴 것일 수 있어 덮지 않는다.
  static String? installMeetingCommand() {
    final dest = File(meetingCommandPath);
    if (dest.existsSync()) return null;
    final src = meetingCommandSource();
    if (src == null) return '앱 안에 회의 명령 사본이 없다 — README의 안내대로 직접 복사한다';
    try {
      dest.parent.createSync(recursive: true);
      File(src).copySync(dest.path);
      return null;
    } catch (e) {
      return '회의 명령을 못 넣었다: $e';
    }
  }

  /// Codex CLI — Homebrew가 있으면 `brew install --cask codex`, 없으면 npm. 로그인은 사람이 `codex`를 켜서 한다.
  static Future<String?> installCodex() async {
    if (await codexPath() != null) return null;
    final brew = await which('brew', ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']);
    final npm = await which('npm', ['/opt/homebrew/bin/npm', '/usr/local/bin/npm']);
    final cmd = brew != null ? '$brew install --cask codex' : npm != null ? '$npm i -g @openai/codex' : null;
    if (cmd == null) return 'Homebrew도 npm도 없다 — 아래 명령을 터미널에서 직접 붙여 넣는다';
    try {
      final r = await Process.run('/bin/bash', ['-lc', cmd]).timeout(const Duration(minutes: 5));
      if (r.exitCode == 0 && await codexPath() != null) return null;
      final out = '${r.stdout}\n${r.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      return '설치가 안 끝났다(${r.exitCode}) — ${out.length > 3 ? out.sublist(out.length - 3).join(' / ') : out.join(' / ')}';
    } on TimeoutException {
      return '5분이 지나도 안 끝났다 — 인터넷을 확인하고 다시 누른다';
    } catch (e) {
      return '설치를 못 돌렸다: $e';
    }
  }

  static const List<String> hookEvents = [
    'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
    'Notification', 'Stop', 'StopFailure', 'SessionEnd',
  ];
  static const Set<String> _matched = {'PreToolUse', 'PostToolUse'};
  static const Set<String> _passOutput = {'UserPromptSubmit'};
  static const String _mark = 'claude-watcher';

  /// 마지막으로 훅 신호가 온 때. 처음 설정이 「연결은 됐는데 신호가 오나」를 보여 준다 — 켜 둔 세션은 다시 켜야 훅이 붙는다.
  static DateTime? lastHookAt;

  static String hookCommand(int port, String event) {
    final sink = _passOutput.contains(event) ? '2>/dev/null' : '> /dev/null 2>&1';
    return "cat | curl -s -m 2 -X POST http://127.0.0.1:$port/ "
        "-H 'Content-Type: application/json' --data-binary @- $sink || true  # $_mark";
  }

  static bool _isOurs(Object? hook, int port) {
    if (hook is! Map) return false;
    final cmd = '${hook['command'] ?? ''}';
    return cmd.contains(_mark) || cmd.contains('127.0.0.1:$port');
  }

  /// 우리 훅이 빠진 이벤트들. 모양이 배열이 아닌 이벤트는 손대지 않으므로 빠진 것으로도 안 센다.
  static List<String> missingHooks(Map settings, int port) {
    final hooks = settings['hooks'] is Map ? settings['hooks'] as Map : const {};
    bool ours(Object? g) => g is Map && g['hooks'] is List && (g['hooks'] as List).any((h) => _isOurs(h, port));
    return [
      for (final e in hookEvents)
        if (hooks[e] == null || (hooks[e] is List && !(hooks[e] as List).any(ours))) e,
    ];
  }

  /// 우리 훅만 뺀 새 설정. 남의 훅은 그대로 두고, 비게 된 이벤트·hooks 칸은 지운다(`setup_hooks.py --remove`와 같다).
  static Map<String, dynamic> withoutHooks(Map settings, int port) {
    final out = jsonDecode(jsonEncode(settings)) as Map<String, dynamic>;
    final hooks = out['hooks'];
    if (hooks is! Map) return out;
    for (final e in hookEvents) {
      final groups = hooks[e];
      if (groups is! List) continue;
      groups.removeWhere((g) => g is Map && g['hooks'] is List && (g['hooks'] as List).any((h) => _isOurs(h, port)));
      if (groups.isEmpty) hooks.remove(e);
    }
    if (hooks.isEmpty) out.remove('hooks');
    return out;
  }

  /// 빠진 이벤트에만 우리 줄을 덧붙인 새 설정. 원본은 건드리지 않는다.
  static Map<String, dynamic> withHooks(Map settings, int port) {
    final out = jsonDecode(jsonEncode(settings)) as Map<String, dynamic>;
    final missing = missingHooks(out, port);
    if (missing.isEmpty) return out;
    final hooks = (out['hooks'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    for (final e in missing) {
      ((hooks[e] ??= <dynamic>[]) as List).add({
        if (_matched.contains(e)) 'matcher': '*',
        'hooks': [{'type': 'command', 'command': hookCommand(port, e)}],
      });
    }
    return out;
  }

  /// 클로드 설정 파일 자리. 확인용으로 남의 파일을 가리킬 수 있게 환경변수를 먼저 본다.
  static String get settingsPath =>
      Platform.environment['CLAUDE_WATCHER_CLAUDE_SETTINGS'] ??
      '${Platform.environment['HOME'] ?? ''}/.claude/settings.json';

  /// GUI 앱은 PATH가 얕다 — 흔한 자리를 먼저 보고, 없으면 로그인 셸에 묻는다.
  static Future<String?> which(String name, List<String> candidates) async {
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    try {
      final r = await Process.run('/bin/zsh', ['-lc', 'command -v $name']);
      final out = '${r.stdout}'.trim();
      return r.exitCode == 0 && out.startsWith('/') ? out : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> status(ProjectStore projects) async {
    final home = Platform.environment['HOME'] ?? '';
    final tmux = Tmux.binary;
    final git = await which('git', ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git']);
    final brew = await which('brew', ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']);
    final claude = await which('claude', [
      '$home/.local/bin/claude', '$home/.claude/local/claude',
      '/opt/homebrew/bin/claude', '/usr/local/bin/claude',
    ]);
    final codex = await codexPath();
    final agents = agentsOf(claude, codex);
    // 로그인 — `claude auth status`(JSON)의 loggedIn만 본다. 메일·조직은 읽어도 화면에 올리지 않는다.
    // 로그아웃 상태는 빈 HOME으로 흉내 내 `loggedIn: false`가 나오는 것을 봤다(9/16, 실제 로그아웃은 안 했다).
    bool? loggedIn;
    String loginDetail = 'Claude Code가 없어 볼 수 없다';
    if (claude != null && agents.claude) {
      try {
        final r = await Process.run(claude, ['auth', 'status', '--json']).timeout(const Duration(seconds: 8));
        final j = jsonDecode('${r.stdout}');
        if (j is Map && j['loggedIn'] is bool) {
          loggedIn = j['loggedIn'] as bool;
          final plan = '${j['subscriptionType'] ?? ''}';
          loginDetail = loggedIn ? '로그인됨${plan.isEmpty ? '' : ' · $plan'}' : '로그인 안 됨';
        } else {
          loginDetail = '상태를 못 읽었다';
        }
      } catch (_) {
        loginDetail = '상태를 못 읽었다 — 오래된 Claude Code일 수 있다';
      }
    }
    List<String> missing;
    String? broken;
    try {
      final f = File(settingsPath);
      final text = f.existsSync() ? f.readAsStringSync().trim() : '';
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      missing = decoded is Map ? missingHooks(decoded, kPort) : hookEvents;
    } catch (e) {
      missing = hookEvents;
      broken = '$settingsPath 를 못 읽었다 — JSON이 깨져 있다. 고친 뒤 다시 본다';
    }
    // 화면에는 홈 폴더를 ~로 줄여 보인다 — 스크린샷·화면 공유에 사용자 이름이 찍히지 않게(9/16 촬영 때 찍혔다).
    String short(String? p) => p == null ? '없다' : (home.isNotEmpty && p.startsWith('$home/') ? '~${p.substring(home.length)}' : p);
    // 코덱스 — 로그인은 `codex login status`의 글자(「Logged in」)만 본다. 계정 이름은 읽어도 올리지 않는다.
    bool codexIn = false;
    String codexLoginDetail = 'Codex가 없어 볼 수 없다';
    List<String> codexMissing = codexEvents;
    String? codexBroken;
    if (agents.codex) {
      if (codex != null) {
        try {
          final r = await Process.run(codex, ['login', 'status']).timeout(const Duration(seconds: 8));
          final out = '${r.stdout}\n${r.stderr}';
          codexIn = r.exitCode == 0 && out.contains('Logged in');
          codexLoginDetail = codexIn ? (out.contains('ChatGPT') ? '로그인됨 · ChatGPT' : '로그인됨') : '로그인 안 됨';
        } catch (_) {
          codexLoginDetail = '상태를 못 읽었다';
        }
      }
      try {
        final f = File(codexHooksPath);
        final text = f.existsSync() ? f.readAsStringSync().trim() : '';
        final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
        codexMissing = decoded is Map ? missingCodexHooks(decoded, kPort) : codexEvents;
      } catch (_) {
        codexBroken = '~/.codex/hooks.json 을 못 읽었다 — JSON이 깨져 있다';
      }
    }
    final items = [
      {'key': 'tmux', 'ok': tmux != null, 'detail': tmux == null ? '없다' : Tmux.isBundled ? '앱에 들어 있는 tmux를 쓴다 — 따로 깔 것 없음' : short(tmux)},
      {'key': 'git', 'ok': git != null, 'detail': short(git)},
      if (agents.claude) ...[
        {'key': 'claude', 'ok': claude != null, 'detail': short(claude)},
        {'key': 'login', 'ok': loggedIn == true, 'detail': loginDetail},
        {'key': 'hooks', 'ok': missing.isEmpty, 'detail': broken ??
            (missing.isEmpty ? '${hookEvents.length}개 모두 연결됨' : '빠진 것 ${missing.length}개 — ${missing.join(' · ')}')},
      ],
      if (agents.codex) ...[
        {'key': 'codex', 'ok': codex != null, 'detail': short(codex)},
        {'key': 'codexLogin', 'ok': codexIn, 'detail': codexLoginDetail},
        {'key': 'codexHooks', 'ok': codexBroken == null && codexMissing.isEmpty, 'detail': codexBroken ??
            (codexMissing.isEmpty ? '${codexEvents.length}개 연결됨 — 코덱스 안 /hooks 에서 신뢰해야 돈다' : '빠진 것 ${codexMissing.length}개')},
      ],
      {'key': 'folder', 'ok': projects.projects.isNotEmpty, 'detail': '${projects.projects.length}개 등록됨'},
      // 회의는 선택 기능이라 「다 됐다」 판정에서는 뺀다(아래 done). Claude Code 전용.
      if (agents.claude)
        {'key': 'meeting', 'ok': File(meetingCommandPath).existsSync(), 'optional': true,
          'detail': File(meetingCommandPath).existsSync() ? '~/.claude/commands/회의.md 있음' : '없다 — 회의실을 쓰려면 넣는다'},
    ];
    final last = lastHookAt;
    return {
      'ok': true, 'done': items.every((i) => i['ok'] == true || i['optional'] == true), 'items': items, 'broken': broken != null,
      'agents': {'claude': agents.claude, 'codex': agents.codex},
      'installed': {'claude': claude != null, 'codex': codex != null},
      'brew': brew != null,
      'hookAgo': last == null ? null : DateTime.now().difference(last).inSeconds,
    };
  }

  /// 새로 만든 폴더에 두는 시작용 `CLAUDE.md`. 앞은 사람이 채울 안내, 뒤는 마당 할 일 규칙이다(대표 결정 2026-09-16).
  ///
  /// ⚠️ 할 일 규칙은 **API가 실제로 받는 모양**과 같아야 한다(`handleTaskApi`) — 경로·칸 이름을 바꾸면 여기도 고친다.
  static String starterClaudeMd(String name, int port) => '''# $name

이 파일은 이 폴더에서 일하는 Claude Code가 먼저 읽는 규칙이다. 아래 빈칸부터 채운다.

## 처음 대화

아래 「이 폴더는 무엇을 하는 곳인가」가 비어 있으면, 사용자의 첫 말이 무엇이든 먼저 짧게 인사하고
**「무엇을 도와드릴까요?」**라고 묻는다. 답을 들으면 그 내용으로 아래 세 칸을 채우고, 채운 내용을 사용자에게 보여 준다.
칸이 채워진 뒤로는 이 절을 따르지 않는다.

## 이 폴더는 무엇을 하는 곳인가

- 무엇을 만드는가:
- 누가 쓰는가:
- 지금 가장 먼저 할 일:

## 작업 규칙

- 말투·산출물 형식 같은 바람을 여기에 적는다
- 건드리면 안 되는 파일·폴더가 있으면 여기에 적는다

## 마당(Madang) 할 일

이 폴더는 마당에 등록되어 있다. 할 일은 마당 대시보드와 같은 목록을 쓴다.
주소는 `http://127.0.0.1:$port`이고, **모든 요청에 `cwd`로 이 폴더 경로를 준다.**
마당이 꺼져 있어 요청이 실패하면 실패를 숨기지 말고 사용자에게 알린다. 답이 `ok: false`면 `error`를 그대로 전한다.

```bash
M=http://127.0.0.1:$port/todo/api; CWD="\$(pwd)"
curl -s -G \$M/tasks --data-urlencode "cwd=\$CWD"                                   # 목록
curl -s -G \$M/tasks --data-urlencode "cwd=\$CWD" --data-urlencode "id=<id>"          # 하나
curl -s -X POST \$M/tasks/add   -d "{\\"cwd\\":\\"\$CWD\\",\\"text\\":\\"제목\\"}"            # 만들기
curl -s -X POST \$M/tasks/start -d "{\\"cwd\\":\\"\$CWD\\",\\"id\\":\\"<id>\\"}"               # 시작(시계)
curl -s -X POST \$M/tasks/stop  -d "{\\"cwd\\":\\"\$CWD\\",\\"id\\":\\"<id>\\",\\"memo\\":\\"한 일\\"}"  # 손 떼기
curl -s -X POST \$M/tasks/update -d "{\\"cwd\\":\\"\$CWD\\",\\"id\\":\\"<id>\\",\\"content\\":\\"작업 내용\\"}"
```

1. **일을 시작하기 전에 할 일부터 붙는다.** 목록에서 찾고, 없으면 만든 뒤 시작한다. 이미 진행중이면 다시 시작하지 않는다
2. **손을 떼면 멈춘다**(`stop`). 확인필요로 넘어가고 걸린 시간이 저절로 남는다. 시간을 직접 계산하지 않는다
3. **완료는 사용자가 완료하라고 할 때만** 한다 — `POST tasks/status {"status":"done","ownerConfirmed":true}`
4. **왜 그렇게 했는지를 `content`(작업 내용)에 남긴다.** 한 줄 요약만으로는 나중에 이유를 못 찾는다. 고칠 때는 지금 값을 읽고 끝에 덧붙인다
5. 대화에 `[태스크 <id>] 「제목」`이 붙어 오면 목록을 훑지 않고 그 id 하나만 읽는다
6. 수정요청은 `revision` 상태와 `revisionNote`(수정사항)로 온다
7. 사용자가 화면에서 일시정지(`paused`)로 옮긴 것은 임의로 되돌리지 않고 이어서 할지 묻는다
8. 그 자리에서 끝나는 질문·논의는 할 일로 만들지 않는다
''';

  /// 코덱스를 쓰면 같은 규칙을 `AGENTS.md`로도 둔다 — 코덱스는 CLAUDE.md가 아니라 AGENTS.md를 읽는다(9/17). 있으면 안 덮는다.
  static void writeAgentsMd(String path) {
    if (savedAgents()?.codex != true) return;
    try {
      final f = File('$path/AGENTS.md');
      if (f.existsSync()) return;
      f.writeAsStringSync(starterClaudeMd(path.split('/').last, kPort)
          .replaceFirst('이 파일은 이 폴더에서 일하는 Claude Code가 먼저 읽는 규칙이다.', '이 파일은 이 폴더에서 일하는 Codex가 먼저 읽는 규칙이다(Claude Code는 CLAUDE.md를 읽는다 — 둘을 같이 고친다).'));
    } catch (_) {}
  }

  /// 시작용 CLAUDE.md의 칸이 아직 비어 있는가 — 그러면 세션을 켤 때 첫 말을 같이 넘겨 세션이 먼저 묻게 한다.
  static bool needsGreeting(String folder) {
    try {
      final f = File('$folder/CLAUDE.md');
      return f.existsSync() && f.readAsStringSync().contains('\n- 무엇을 만드는가:\n');
    } catch (_) {
      return false;
    }
  }

  /// 켤 때 넘기는 첫 말. 무엇을 할지는 CLAUDE.md의 「처음 대화」 절이 정한다 — 대화 칸에 사용자 말로 보이므로 짧게 둔다.
  static const String greeting = '처음 시작합니다';

  /// 새 프로젝트 폴더 — 저장 창으로 자리·이름을 받아 폴더와 시작용 CLAUDE.md를 만든다.
  /// (만든 경로, 오류). 취소하면 둘 다 null. ⚠️ **이미 있는 CLAUDE.md는 덮어쓰지 않는다.**
  static Future<({String? path, String? error})> newFolder() async {
    if (!Platform.isMacOS) return (path: null, error: 'macOS에서만 된다');
    final res = await Process.run('osascript', [
      '-e',
      'POSIX path of (choose file name with prompt "새 프로젝트 폴더의 자리와 이름을 정하세요" default name "내 프로젝트" default location (path to home folder))',
    ]);
    if (res.exitCode != 0) return (path: null, error: null); // 취소
    var path = ProjectStore.normalize('${res.stdout}'.trim());
    if (path.isEmpty) return (path: null, error: null);
    try {
      final dir = Directory(path);
      if (File(path).existsSync()) return (path: null, error: '같은 이름의 파일이 이미 있다');
      dir.createSync(recursive: true);
      final md = File('$path/CLAUDE.md');
      if (!md.existsSync()) md.writeAsStringSync(starterClaudeMd(path.split('/').last, kPort));
      writeAgentsMd(path);
    } catch (e) {
      return (path: null, error: '폴더를 못 만들었다: $e');
    }
    return (path: path, error: null);
  }

  /// 하위 세션 폴더 — 등록된 프로젝트 [parent] 안에 새로 만들거나(`pick: false`, 이름을 묻는다) 있는 것을 고른다(`pick: true`).
  /// 시작용 CLAUDE.md는 새 폴더와 같은 전체본이고 **있으면 안 덮는다**(대표 결정 2026-09-16). (경로, 오류) · 취소면 둘 다 null.
  ///
  /// 할 일 API 줄(`ensureFolder`)은 만들지 않는다 — 하위 폴더의 세션은 접두어로 상위 프로젝트 범위에 들어가
  /// 상위의 할 일을 같이 쓴다(`ApiScope.of`). 줄을 따로 만들면 상위가 「모든 폴더의 조상」이 되어 전체 범위로 바뀐다.
  static Future<({String? path, String? error})> subFolder(String parent, {required bool pick}) async {
    if (!Platform.isMacOS) return (path: null, error: 'macOS에서만 된다');
    final base = ProjectStore.normalize(parent);
    if (!Directory(base).existsSync()) return (path: null, error: '그 세션의 폴더가 없다');
    String? path;
    if (pick) {
      final esc = base.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final res = await Process.run('osascript', [
        '-e',
        'POSIX path of (choose folder with prompt "하위 세션으로 쓸 폴더를 고르세요" default location (POSIX file "$esc"))',
      ]);
      if (res.exitCode != 0) return (path: null, error: null);
      path = ProjectStore.normalize('${res.stdout}'.trim());
      if (!path.startsWith('$base/')) return (path: null, error: '이 프로젝트 안의 폴더만 고른다');
    } else {
      final res = await Process.run('osascript', [
        '-e',
        'text returned of (display dialog "새 하위 세션 폴더 이름" default answer "" with title "하위 세션 추가")',
      ]);
      if (res.exitCode != 0) return (path: null, error: null);
      final name = '${res.stdout}'.trim();
      if (name.isEmpty) return (path: null, error: null);
      if (name.contains('/') || name == '.' || name == '..' || name.startsWith('.')) {
        return (path: null, error: '폴더 이름에 / 나 앞 점(.)은 쓸 수 없다');
      }
      path = ProjectStore.normalize('$base/$name');
      if (File(path).existsSync()) return (path: null, error: '같은 이름의 파일이 이미 있다');
    }
    try {
      Directory(path).createSync(recursive: true);
      final md = File('$path/CLAUDE.md');
      if (!md.existsSync()) md.writeAsStringSync(starterClaudeMd(path.split('/').last, kPort));
      writeAgentsMd(path);
    } catch (e) {
      return (path: null, error: '폴더를 못 만들었다: $e');
    }
    return (path: path, error: null);
  }

  /// Claude Code를 공식 설치 스크립트로 깐다(`curl -fsSL https://claude.ai/install.sh | bash`) — 관리자 암호가 필요 없는 사용자 폴더 설치.
  /// 오류 글자 또는 null. 이미 있으면 안 깐다. 로그인은 브라우저에서 사람이 한다(그다음 줄).
  static Future<String?> installClaude() async {
    final home = Platform.environment['HOME'] ?? '';
    final cands = ['$home/.local/bin/claude', '$home/.claude/local/claude', '/opt/homebrew/bin/claude', '/usr/local/bin/claude'];
    if (await which('claude', cands) != null) return null;
    try {
      final r = await Process.run('/bin/bash', ['-lc', 'curl -fsSL https://claude.ai/install.sh | bash'])
          .timeout(const Duration(minutes: 4));
      if (r.exitCode == 0 && await which('claude', cands) != null) return null;
      final out = '${r.stdout}\n${r.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      final tail = out.length > 3 ? out.sublist(out.length - 3).join(' / ') : out.join(' / ');
      return '설치가 안 끝났다(${r.exitCode}) — $tail';
    } on TimeoutException {
      return '4분이 지나도 안 끝났다 — 인터넷을 확인하고 다시 누른다';
    } catch (e) {
      return '설치 스크립트를 못 돌렸다: $e';
    }
  }

  /// git — 애플 명령줄 도구 설치 창(`xcode-select --install`)을 띄운다. 「설치」는 그 창에서 사람이 누른다.
  static Future<String?> installGit() async {
    if (await which('git', ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git']) != null) return null;
    try {
      final r = await Process.run('xcode-select', ['--install']);
      // 이미 깔려 있으면 exit 1 — 그때는 PATH 문제일 수 있으니 그대로 알린다.
      if (r.exitCode == 0) return null;
      final msg = '${r.stderr}'.trim();
      return msg.contains('already installed') ? '이미 깔려 있다고 한다 — 「다시 보기」를 누른다' : '설치 창을 못 띄웠다: $msg';
    } catch (e) {
      return '설치 창을 못 띄웠다: $e';
    }
  }

  /// 훅을 넣는다. 오류 글자 또는 null. 백업을 남기고 임시 파일에 쓴 뒤 옮긴다(쓰다 죽어도 원본이 남는다).
  static String? writeHooks({bool remove = false}) {
    // 확인용 판(9877…)이 제 포트를 사용자 설정에 박으면 본 판과 훅이 두 벌이 된다.
    if (kIsDevInstance && Platform.environment['CLAUDE_WATCHER_CLAUDE_SETTINGS'] == null) {
      return '확인용 판에서는 훅을 넣지 않는다 (CLAUDE_WATCHER_CLAUDE_SETTINGS로 다른 파일을 가리킬 때만)';
    }
    final f = File(settingsPath);
    Map settings;
    try {
      final text = f.existsSync() ? f.readAsStringSync().trim() : '';
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is! Map) return '설정 파일 모양이 객체가 아니다 — 덮어쓰지 않는다';
      if (decoded['hooks'] != null && decoded['hooks'] is! Map) return '설정 파일의 hooks 모양이 객체가 아니다 — 덮어쓰지 않는다';
      settings = decoded;
    } catch (e) {
      return '설정 파일 JSON이 깨져 있다 — 덮어쓰면 남은 설정까지 잃으므로 손대지 않는다';
    }
    final next = remove ? withoutHooks(settings, kPort) : withHooks(settings, kPort);
    if (jsonEncode(next) == jsonEncode(settings)) return null;
    try {
      f.parent.createSync(recursive: true);
      if (f.existsSync()) {
        final t = DateTime.now();
        String two(int n) => n.toString().padLeft(2, '0');
        // 같은 초에 두 번 쓰면(연결 직후 빼기) 이름이 겹쳐 첫 백업이 덮인다 — 겹치면 번호를 붙인다.
        final stem = '${f.path}.bak-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
        var bak = stem;
        for (var n = 2; File(bak).existsSync(); n++) {
          bak = '$stem-$n';
        }
        f.copySync(bak);
      }
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(next)}\n');
      tmp.renameSync(f.path);
    } catch (e) {
      return '훅을 못 넣었다: $e';
    }
    return null;
  }
}

/// macOS 폴더 선택창. 취소하면 null.
Future<String?> chooseFolder() async {
  if (!Platform.isMacOS) return null;
  try {
    final res = await Process.run('osascript', [
      '-e',
      'POSIX path of (choose folder with prompt "지켜볼 프로젝트 폴더를 고르세요" default location (path to home folder))',
    ]);
    if (res.exitCode != 0) return null; // 사용자가 취소
    final path = (res.stdout as String).trim();
    return path.isEmpty ? null : path;
  } catch (e) {
    debugPrint('폴더 선택 실패: $e');
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ⚠️ 저장소 build/의 앱이 스포트라이트로 켜지는 일이 두 번 있었다(9/15 23:13, 9/16 00:03) — 같은 번들이라 이름으로 찾으면
  // 이쪽이 먼저 걸린다. 이 앱은 저장소의 옛 데이터를 읽고, 설치본 창을 화면 가득 키우는 문제까지 냈다.
  // 그래서 **기본 포트로 빌드 트리에서 켜졌고 설치본이 있으면** 설치본을 대신 열고 스스로 끝낸다. 확인용 판(포트 지정)은 그대로 뜬다.
  // 이름을 마당으로 바꾸면서 설치 자리도 옮겼다 — 아직 안 옮긴 기계에서는 옛 자리도 본다.
  final home = Platform.environment['HOME'] ?? '';
  final installed = [
    '$home/Applications/Madang/Madang.app',
    '$home/Applications/ClaudeWatcher/claude_watcher.app',
  ].firstWhere((p) => Directory(p).existsSync(), orElse: () => '');
  if (!kIsDevInstance && _buildTreeRoot() != null && installed.isNotEmpty &&
      Platform.environment['CLAUDE_WATCHER_CONFIG_DIR'] == null) {
    await Process.run('open', [installed]);
    exit(0);
  }
  await windowManager.ensureInitialized();

  final dashboardMode = LaunchModeStore.load() == 'dashboard';
  // 대시보드는 별도 앱(Contents/Helpers/MadangDashboard.app)이 띄운다(1.88.2) — 이 프로세스는 창 없이 서버·시계만 돈다.
  // ⚠️ 예전에 Flutter 창 안에 WKWebView를 얹었을 때 같은 프로세스의 Flutter 엔진 때문에 한글이 자모로 갈라졌다(2026-09-17).
  if (dashboardMode) {
    // Flutter 창은 띄우지 않는다. 자리는 예전과 같은 규칙으로 정해 네이티브 창에 넘긴다.
    final frame = LaunchModeStore.loadFrame();
    final ok = frame != null && frame.width < 5000 && await WindowStateStore.isOnScreen(frame.topLeft, frame.size);
    kDashIntended = ok ? frame : null;
    await _startEverything(dashboardMode);
    return;
  }
  await _showWidgetWindow();
  await _startEverything(dashboardMode);
}

Future<void> _showWidgetWindow() async {
  const options = WindowOptions(
    size: kCollapsedSize,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    // 창 자체를 투명하게 둔다. 그려지는 건 책상과 캐릭터뿐이고
    // 나머지는 바탕화면이 그대로 비친다.
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setHasShadow(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setResizable(false);

    // 저장된 자리가 아직 화면 안이면 거기로 되돌린다. 아니면 가운데로 둔다.
    //
    // ⚠️ **고정해 둔 모니터가 있으면 그쪽이 먼저다.** 저장된 좌표가 우연히
    // 다른 모니터 안에 들어가는 일이 있는데(모니터를 뺐다 꽂으면 좌표계가
    // 통째로 밀린다), 그러면 '화면 안'이라는 이유로 엉뚱한 데서 뜬다.
    final saved = WindowStateStore.load();
    final pin = WindowStateStore.loadPin();
    var placed = false;
    if (pin != null) {
      try {
        final target = pin.find(await screenRetriever.getAllDisplays());
        if (target != null) {
          final origin = target.visiblePosition ?? Offset.zero;
          final visible = target.visibleSize ?? target.size;
          final onPin = saved != null &&
              Rect.fromLTWH(
                      origin.dx, origin.dy, visible.width, visible.height)
                  .contains(saved);
          // 그 모니터 안에 있던 자리면 그대로 되찾는다. 아니면 오른쪽 아래.
          await windowManager.setPosition(onPin
              ? saved
              : Offset(
                  origin.dx + visible.width - kCollapsedSize.width,
                  origin.dy + visible.height - kCollapsedSize.height,
                ));
          placed = true;
          debugPrint('고정한 모니터에 띄운다: ${target.name ?? target.id}');
        } else {
          debugPrint('고정한 모니터(${pin.label})가 안 보인다 — 기록은 그대로 둔다');
        }
      } catch (e) {
        debugPrint('고정 모니터 확인 실패: $e');
      }
    }
    if (!placed) {
      if (saved != null &&
          await WindowStateStore.isOnScreen(saved, kCollapsedSize)) {
        await windowManager.setPosition(saved);
        debugPrint('창 위치 복원: ${saved.dx}, ${saved.dy}');
      } else {
        if (saved != null) debugPrint('저장된 창 위치가 화면 밖이라 가운데로 띄운다');
        await windowManager.center();
      }
    }

    await windowManager.show();
  });
}

Future<void> _startEverything(bool dashboardMode) async {
  // 알림을 누르면 네이티브가 이리로 알린다 — 페이지가 2초 안에 `/todo/chat/focus`로 집어 가 그 대화를 연다.
  kNotify.setMethodCallHandler((call) async {
    if (call.method == 'clicked') {
      final a = call.arguments;
      final p = a is Map ? a['path'] : null;
      if (p is String && p.isNotEmpty) kPendingChatFocus = p;
    }
    return null;
  });
  // 이 맥에 깔린 슬래시 명령을 훑는다 — 대화 칸의 `/` 목록에 플러그인 명령까지 뜬다(대표 제보 9/16).
  loadSlashCommands();
  final projects = ProjectStore()..load();
  final store = SessionStore(projects);
  // 위젯과 브라우저가 같은 할 일을 보게 한 곳에 둔다.
  final todos = Todos();
  // 프로젝트 목록(노션이사 3/6). 아직 캐릭터·할 일과 잇지 않고 따로 든다.
  final projectDb = ProjectDb();
  // 근무기록(노션이사). 루트 세션이 API로 출퇴근·휴게를 찍는다.
  final workLog = WorkLog();
  kWorkLog = workLog;
  // 세션 기록 — 할 일의 시계가 멈출 때마다 한 구간씩 쌓는다(노션 세션 기록 DB 자리).
  final sessionLog = SessionLog();
  todos.onOwnerChange = (before, after) {
    final text = TodoStore.describeOwnerChange(before, after);
    if (text != null) kOwnerNotices.add((after ?? before)!, text);
  };
  todos.onInterval = (before, after) {
    final r = SessionLogStore.fromStop(before, after);
    if (r == null) return;
    final memo = kPendingMemo.remove(Todos.idOf(after)) ?? '';
    sessionLog.add(SessionRecord(
        id: r.id, start: r.start, end: r.end, taskId: r.taskId,
        taskText: r.taskText, projectId: r.projectId, memo: memo));
  };
  // 턴이 끝나면 재던 시계를 멈추고 확인필요로 넘긴다. 소요시간을 손으로
  // 재지 않아도 되는 것이 노션과 다른 점이다.
  // 그다음 줄에 선 시키기를 보낸다 — 정산이 먼저여야 시간이 앞 태스크에 붙는다.
  final sendQueue = kSendQueue = SendQueue(store, todos);
  store.onTurnEnd = (path) {
    todos.stopFor(path);
    sendQueue.turnEnded(path);
  };
  // 세션이 끝나면 API로 시작한 시계까지 멈춘다 — 세션이 stop을 잊어도 밤새 돌지 않게.
  store.onSessionGone = (path) => todos.stopFor(path, gone: true);
  // 남은 한도. 상태줄 스크립트가 훅 서버로 넘겨준다(새 포트를 열지 않는다).
  final limits = kLimits = LimitStore();
  unawaited(startHookServer(store, todos, projects, limits, projectDb, workLog, sessionLog));
  unawaited(startTodoServer(store, todos, projects, projectDb, workLog, sessionLog));

  final art = kArtStore = ArtStore();
  await art.reload();

  // 회의는 파일로만 들어온다. 훅도 포트도 새로 열지 않는다 —
  // 사회자 세션이 쓰는 `상태.json`을 3초마다 들여다보는 것이 전부다.
  final meetings = kMeetings = MeetingStore(projects)..start();
  meetings.onAllSpoke = (m, moderator) => unawaited(sendToSession(store, moderator,
      '[마당] 회의 R${m.round} 발언 파일이 모두 들어왔다 — /회의 Step 5 마무리(회의록.md·상태.json 정리) 뒤 Step 6(의견대기)로 간다.'));
  // 사용량도 파일만 읽는다. 첫 훑기는 transcript 전체라 몇십 초 걸릴 수 있어
  // 아이솔레이트에서 돌린다 — 그동안 화면은 그대로 움직인다.
  final usage = kUsage = UsageStore()..start();

  if (dashboardMode) {
    runApp(const NativeDashHost());
    return;
  }
  runApp(WatcherApp(
      store: store,
      art: art,
      projects: projects,
      todos: todos,
      meetings: meetings,
      usage: usage,
      limits: limits));
}

/// 앱 창 안의 대시보드 — 이 앱이 띄운 할 일 서버(`127.0.0.1:kPort/todo`)를 WKWebView로 연다.
///
/// - 같은 서버 주소만 창 안에서 연다. 바깥 링크(대화의 주소·프로젝트 링크)와 CSV 내보내기는 기본 브라우저로 넘긴다
///   — WKWebView는 새 창(`target=_blank`)과 내려받기를 스스로 다루지 않는다
/// - 서버가 아직 안 열렸거나 끊기면 잠깐 뒤 다시 부른다
/// - 붙여넣기·복사는 앱의 편집 메뉴(MainMenu.xib)가 WKWebView로 넘긴다 — PlatformMenuBar로 메뉴를
///   갈아 끼우면 ⌘V가 죽는다(편집 항목을 만들 수 없다)
/// 대시보드가 읽는 사용량·남은 한도. 위젯이 이미 재고 있는 값을 그대로 쓴다(따로 훑지 않는다).
UsageStore? kUsage;
LimitStore? kLimits;
/// 알림 채널. 네이티브가 알림을 띄우고, 눌리면 'clicked' {path}로 되돌려 준다 — 그 경로를 [kPendingChatFocus]에 두면 페이지가 집어 간다.
const MethodChannel kNotify = MethodChannel('cw/notify');
String? kPendingChatFocus;
/// 대시보드 회의 화면이 읽는 회의 상태. 위젯 원탁과 같은 파일(상태.json)을 같은 저장소가 든다(9/17).
MeetingStore? kMeetings;

/// 켤 때 정한 대시보드 창 자리. 켠 직후 누가 창을 화면 가득 키우면 이리로 되돌린다([_DashboardAppState]).
Rect? kDashIntended;

/// 네이티브 대시보드 창의 Dart 쪽 — 창은 Swift가 띄우고, 여기서는 열라고 부르고 자리·크기 저장만 받는다(1.88.0).
class NativeDashHost extends StatefulWidget {
  const NativeDashHost({super.key});

  @override
  State<NativeDashHost> createState() => _NativeDashHostState();
}

class _NativeDashHostState extends State<NativeDashHost> {
  static const _dash = MethodChannel('cw/dash');

  @override
  void initState() {
    super.initState();
    // 창 자리·크기는 그 앱이 서버(`/todo/app/frame`)에 바로 적는다 — 채널로 되돌려 받지 않는다.
    final f = kDashIntended;
    unawaited(_dash.invokeMethod('open', {
      'url': 'http://127.0.0.1:$kPort/todo',
      'title': 'Madang $kVersion',
      if (f != null) 'frame': [f.left, f.top, f.width, f.height],
    }));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}


/// 지금 그려진 화면을 그대로 떠오기 위한 표식.
///
/// 고친 것이 화면에 어떻게 나오는지는 눈으로 봐야 아는데, 사람을 부르지 않고
/// 확인하려면 앱이 제 그림을 내놓아야 한다. `saveShot()`이 이걸 쓴다.
final GlobalKey shotKey = GlobalKey();

/// 지금 화면을 PNG로 저장한다. 성공하면 그 경로를, 못 하면 null.
///
/// 창이 아직 안 그려졌으면 실패한다 — 부르기 전에 한 프레임은 지나야 한다.
Future<String?> saveShot(String path, {double scale = 2.0}) async {
  try {
    final obj = shotKey.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) {
      debugPrint('화면 뜨기 실패: 아직 안 그려졌다');
      return null;
    }
    final image = await obj.toImage(pixelRatio: scale);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes.buffer.asUint8List());
    debugPrint('화면 떠옴: $path (${image.width}x${image.height})');
    return path;
  } catch (e) {
    debugPrint('화면 뜨기 실패: $e');
    return null;
  }
}

class WatcherApp extends StatelessWidget {
  const WatcherApp({
    super.key,
    required this.store,
    required this.art,
    required this.projects,
    required this.todos,
    required this.meetings,
    required this.usage,
    required this.limits,
  });

  final SessionStore store;
  final ArtStore art;
  final ProjectStore projects;
  final Todos todos;
  final MeetingStore meetings;
  final UsageStore usage;
  final LimitStore limits;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 글꼴은 할 일 페이지와 같은 Pretendard다(2026-09-14 대표 결정).
      // 설치되어 있지 않은 맥에서는 시스템 글꼴로 내려간다. 터미널 칸은 Menlo를 따로 쓴다.
      theme: ThemeData(fontFamily: 'Pretendard'),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        // 자기 화면을 스스로 떠올 수 있게 감싼다.
        // 화면 기록 권한(screencapture)은 프로세스마다 따로 받아야 하고
        // 바탕화면까지 찍힌다. 앱이 제 그림만 내놓는 쪽이 깨끗하다.
        body: RepaintBoundary(
          key: shotKey,
          child: WatcherPanel(
              store: store,
              art: art,
              projects: projects,
              todos: todos,
              meetings: meetings,
              usage: usage,
              limits: limits),
        ),
      ),
    );
  }
}

class WatcherPanel extends StatefulWidget {
  const WatcherPanel({
    super.key,
    required this.store,
    required this.art,
    required this.projects,
    required this.todos,
    required this.meetings,
    required this.usage,
    required this.limits,
  });

  final SessionStore store;
  final ArtStore art;
  final ProjectStore projects;
  final Todos todos;
  final MeetingStore meetings;
  final UsageStore usage;
  final LimitStore limits;

  @override
  State<WatcherPanel> createState() => _WatcherPanelState();
}

class _WatcherPanelState extends State<WatcherPanel> with WindowListener {
  Timer? _tick;
  Timer? _saveDebounce;
  int _frame = 0;
  bool _deskView = true;
  /// 책상 자리에 회의 원탁을 띄우고 있는지.
  bool _meetingOpen = false;
  /// 펼침 패널에서 회의 탭을 보고 있는지.
  bool _meetingTab = false;
  /// 펼침 패널에서 크레딧 탭을 보고 있는지.
  bool _usageTab = false;
  bool _expanded = false;
  // 펼침 패널에서 터미널 원본을 보고 있는지. 두 소스는 탭으로 나눈다 —
  // transcript(메시지)와 capture-pane(화면 스냅샷)은 성격이 달라 섞지 않는다.
  bool _rawTab = false;
  String? _selectedPath;
  Offset? _lastSavedPosition;
  // 펼치기 전 자리. 접을 때 이리로 되돌린다.
  Offset? _collapsedPosition;
  String _lastFloorCount = '';
  final TextEditingController _commandInput = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  // 대화가 바뀌었는지 재는 표식. 새 줄이 붙거나 마지막 줄이 갈리면 값이 달라진다.
  // 180ms 타이머로 build가 계속 도니까 이걸로 걸러야 매 프레임 스크롤하지 않는다.
  String? _lastChatSig;
  // 터미널 원본 탭 상태. 어느 프로젝트의 화면을 들고 있는지 함께 기억한다.
  String? _paneSession;
  /// 지금 화면 떠오기 타이머가 물고 있는 세션. 캐릭터를 옮기면 갈아탄다.
  String? _paneOwner;
  /// 선택지를 보낸 직후. 화면이 아직 안 바뀐 사이 두 번 누르는 것을 막는다.
  bool _answering = false;
  /// 멈추기를 보내는 중. 연타로 esc가 여러 번 가지 않게 막는다.
  bool _stopping = false;
  /// 권한 모드를 돌리는 중. 연타로 여러 단계가 훌쩍 넘어가지 않게 막는다.
  bool _cycling = false;
  /// 되돌리기를 겨눈 상태. 한 번 더 눌러야 실제로 간다.
  bool _rewindArmed = false;
  Timer? _rewindDisarm;
  /// 슬래시 목록이 지금 떠 있는지. 평소 타이핑에서 setState를 안 하려고 든다.
  bool _slashShown = false;
  /// 파일을 끌고 입력창 위에 들어와 있는지. 놓아도 되는 자리라고 알린다.
  bool _dropping = false;
  /// 할 일 패널을 펴 두었는지. 켠 채로 두는 사람이 많을 테니 기억한다.
  bool _todoOpen = TodoOpenStore.load();
  final TextEditingController _todoInput = TextEditingController();
  /// 새 할 일을 어느 프로젝트에 적을지. 비면 지금 고른 캐릭터.
  String? _todoTarget;
  /// 파일을 놓은 뒤 바로 이어 쓸 수 있게 초점을 옮기려고 든다.
  final FocusNode _commandFocus = FocusNode();
  /// `@` 목록이 떠 있는지.
  bool _atShown = false;
  /// 지금 들고 있는 파일 목록과, 그게 어느 세션 것인지.
  List<String> _atFiles = const [];
  String? _atLoadedFor;

  /// 히스토리를 몇 번째까지 거슬러 올라갔는지. -1이면 뒤지고 있지 않다.
  int _histIndex = -1;
  /// 뒤지기 전에 쓰던 글. 아래 끝까지 내려오면 이걸로 돌려준다.
  String _histDraft = '';
  /// 어느 세션의 히스토리를 뒤지던 중인지. 캐릭터를 옮기면 처음으로 돌린다.
  String? _histSession;
  /// 위젯이 입력창을 갈아끼우는 중. 사람이 친 것과 구분하려고 든다.
  bool _fillingInput = false;
  /// 한 번 눌러 겨눠 둔 선택지 번호. 같은 것을 한 번 더 눌러야 넘어간다.
  ///
  /// 한 번에 확정되면 스치듯 눌린 것도 그대로 답이 된다. 승인·신뢰 확인처럼
  /// 되돌리기 어려운 것이 섞여 있어 한 번 더 묻는다.
  int? _armedOption;
  String? _paneText;
  bool _paneMissing = false;
  bool _starting = false;
  Timer? _paneTimer;

  @override
  void initState() {
    // 슬래시 목록은 입력창 글자를 따라간다. 목록이 떠 있지도, 뜰 일도
    // 없을 때는 setState를 아예 안 해서 평소 타이핑이 무거워지지 않게 한다.
    _commandInput.addListener(_onInputChanged);
    super.initState();
    windowManager.addListener(this);
    _lastSavedPosition = WindowStateStore.load();
    _pin = WindowStateStore.loadPin();
    _startPinTimer();
    final mode = Platform.environment['CLAUDE_WATCHER_SELFTEST'];
    if (mode == '1') _selfTest();
    // 회의 원탁을 편 채로 띄운다. 9·10번으로 그림을 뜰 때 쓴다 —
    // 회의는 파일이 있어야 열리므로 버튼을 눌러줄 사람이 없으면 못 본다.
    // 남은 한도 칩을 가짜 값으로 채워 그림으로 확인한다. 진짜 값은
    // 상태줄이 붙은 세션이 한 턴 돌아야 오므로 그림을 뜰 때는 못 기다린다.
    if (Platform.environment['CLAUDE_WATCHER_LIMITS'] == '1') {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      widget.limits.handle({
        'five_hour': {'used_percentage': 73.5, 'resets_at': now + 8040},
        'seven_day': {'used_percentage': 41.0, 'resets_at': now + 277200},
      });
    }
    // 크레딧 탭을 펴 둔다. 9·10번으로 그림을 뜰 때 쓴다.
    if (Platform.environment['CLAUDE_WATCHER_USAGE'] == '1') {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        final first = widget.store.sessions
            .where((x) => x.name == Platform.environment['CLAUDE_WATCHER_SELECT'])
            .firstOrNull ??
            widget.store.sessions.firstOrNull;
        if (first == null) return;
        setState(() {
          _selectedPath = first.cwdPath;
          _usageTab = true;
        });
        _setExpanded(true);
      });
    }
    // 1이면 원탁, 2면 펼침 패널의 회의 탭을 열어 둔다.
    final meetingMode = Platform.environment['CLAUDE_WATCHER_MEETING'];
    if (meetingMode == '1' || meetingMode == '2') {
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (!mounted || !widget.meetings.has) return;
        if (meetingMode == '1') {
          _toggleMeeting();
          return;
        }
        final first = widget.store.sessions.firstOrNull;
        if (first == null) return;
        setState(() {
          _selectedPath = first.cwdPath;
          _meetingTab = true;
        });
        _setExpanded(true);
      });
    }
    // 3번은 위젯에서 세션을 띄워본다 (⑭ 확인용).
    //
    // **아직 안 떠 있는 프로젝트**를 골라야 한다. 첫 프로젝트를 그냥 집으면
    // 이미 떠 있을 때 startSession이 곧바로 되돌아와 아무것도 확인하지 못한다.
    if (mode == '3') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        AgentSession? target;
        for (final s in widget.store.sessions) {
          if (!await Tmux.hasSession(Tmux.sessionName(s.cwdPath))) {
            target = s;
            break;
          }
        }
        if (target == null || !mounted) {
          debugPrint('[selftest] 전부 떠 있어 기동을 확인할 수 없다');
          return;
        }
        final name = Tmux.sessionName(target.cwdPath);
        debugPrint('[selftest] 기동 대상=$name · 명령=${Tmux.launch}');
        await _startSession(target);
        debugPrint('[selftest] 기동 후 존재=${await Tmux.hasSession(name)}');
        // 클로드가 뜰 때까지 기다렸다가 승인 모드를 확인한다.
        await Future<void>.delayed(const Duration(seconds: 10));
        final pane = await Tmux.capturePane(name);
        debugPrint('[selftest] 승인 생략=${pane?.contains("bypass permissions") ?? false} · '
            '떠온 화면 ${pane?.length ?? 0}자');
      });
    }
    // 4번은 펼친 채로 메시지 탭을 열어 둔다.
    if (mode == '4') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final first = widget.store.sessions.firstOrNull;
        if (first == null || !mounted) return;
        setState(() {
          _selectedPath = first.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
      });
    }
    // 5번은 메시지 탭에서 실제로 한 마디 보내본다 (⑳ 확인용).
    if (mode == '5') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final first = widget.store.sessions.firstOrNull;
        if (first == null || !mounted) return;
        setState(() {
          _selectedPath = first.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
        await Future<void>.delayed(const Duration(seconds: 2));
        await _sendCommand(first, '안녕? 한 문장으로만 답해줘.');
        debugPrint('[selftest] 보낸 뒤 대화 ${first.chat.length}줄 · '
            '메시지탭=${!_rawTab}');
      });
    }
    // 6번은 지금 떠 있는 선택창을 위젯이 제대로 읽는지 본다 (㉑ 확인용).
    // 세션 하나를 승인 대기 상태로 만들어 두고 띄우면 된다.
    if (mode == '6') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        for (final s in widget.store.sessions) {
          final name = Tmux.sessionName(s.cwdPath);
          final pane = await Tmux.capturePane(name);
          final c = PaneChoice.parse(pane);
          debugPrint('[selftest] $name 상태=${s.shownStatus.label} '
              '선택창=${c == null ? "없음" : "${c.options.length}개 커서=${c.cursor}"}'
              '${c == null && PaneChoice.isCursorPrompt(pane) ? " (화살표형)" : ""}');
          if (c != null) {
            for (final o in c.options) {
              debugPrint('[selftest]   ${o.selected ? "❯" : " "} '
                  '${o.number}. ${o.text}');
            }
          }
        }
        if (!mounted) return;
        final waiting = widget.store.sessions
            .where((x) => x.status == AgentStatus.waiting)
            .firstOrNull;
        if (waiting == null) {
          debugPrint('[selftest] 승인 대기인 세션이 없다 — 카드는 안 뜬다');
          return;
        }
        setState(() {
          _selectedPath = waiting.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
      });
    }
    // 12번은 링크 열기가 실제로 도는지 본다. 브라우저가 뜨면 성공이다.
    //
    //   CLAUDE_WATCHER_SELFTEST=12 CLAUDE_WATCHER_URL=<주소> <실행파일>
    if (mode == '12') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        const cases = [
          'https://example.com',
          'file:///etc/passwd',
          'ftp://example.com',
          'notaurl',
        ];
        for (final u in cases) {
          // example.com 만 실제로 연다. 나머지는 막히는지만 본다.
          final ok = u.startsWith('https://')
              ? await openUrl(u)
              : await openUrl(u);
          debugPrint('[selftest] $u → ${ok ? "열림" : "막힘"}');
        }
      });
    }
    // 13번은 클립보드의 그림을 실제로 떠오는지 본다.
    //
    // ⌘V를 대신 눌러줄 방법이 없어서 **떠오는 부분만** 따로 돌린다.
    // 클립보드에 그림을 담아 두고 띄운다.
    //
    //   CLAUDE_WATCHER_SELFTEST=13 <실행파일>
    if (mode == '13') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final path = await ClipboardImage.save();
        if (path == null) {
          debugPrint('[selftest] 클립보드에 그림이 없다 (글자만 있으면 이게 맞다)');
          return;
        }
        final file = File(path);
        debugPrint('[selftest] 떠왔다: $path (${file.lengthSync()} bytes)');
        // 세션 폴더 밖이므로 절대경로로 박혀야 한다.
        debugPrint('[selftest] 입력창에 박힐 모양: '
            '${dropToken(path, '/Users/me/proj')}');
      });
    }
    // 11번은 창의 **오른쪽 끝**을 되풀이해 찍는다.
    // 책상은 오른쪽 아래 고정이므로 이 값이 흔들리면 책상이 옮겨간 것이다.
    if (mode == '11') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        for (var i = 1; i <= 14; i++) {
          final size = await windowManager.getSize();
          final pos = await windowManager.getPosition();
          debugPrint('[selftest] $i 오른쪽끝=${(pos.dx + size.width).toStringAsFixed(0)} '
              '(pos=${pos.dx.toStringAsFixed(0)} w=${size.width.toStringAsFixed(0)}) '
              '칸=${widget.store.floors.length} 펼침=$_expanded');
          if (i == 3 && mounted) {
            final first = widget.store.sessions.firstOrNull;
            if (first != null) {
              setState(() => _selectedPath = first.cwdPath);
              await _setExpanded(true);
            }
          }
          if (i == 5) await _setExpanded(false);
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      });
    }
    // 10번은 책상만 되풀이해 떠온다. 그 사이에 훅을 쏴서 상태를 바꾸면
    // 상태별 캐릭터가 어떻게 보이는지 한 번에 견줄 수 있다.
    //
    //   CLAUDE_WATCHER_SHOT=<폴더> CLAUDE_WATCHER_SELFTEST=10 <실행파일>
    //   그 사이 curl 로 UserPromptSubmit(생각) · PreToolUse(작업) 등을 쏜다
    if (mode == '10') {
      final dir = Platform.environment['CLAUDE_WATCHER_SHOT'] ??
          '${Directory.systemTemp.path}/cw_shots';
      final pick = Platform.environment['CLAUDE_WATCHER_SELECT'];
      Future<void>.delayed(const Duration(seconds: 3), () async {
        // 이름을 주면 그 캐릭터를 펼쳐 둔다. 펼친 화면째로 떠오게 된다.
        if (pick != null && pick.isNotEmpty && mounted) {
          final t = widget.store.sessions
              .where((x) => x.name.contains(pick))
              .firstOrNull;
          if (t != null) {
            setState(() {
              _selectedPath = t.cwdPath;
              _rawTab = false;
            });
            await _setExpanded(true);
          }
        }
        // 입력창을 미리 채워 둔다. 슬래시 목록처럼 **글자를 쳐야 뜨는 것**은
        // 이게 없으면 그림으로 확인할 방법이 없다.
        final typed = Platform.environment['CLAUDE_WATCHER_INPUT'];
        if (typed != null && typed.isNotEmpty && mounted) {
          _fillInput(typed);
        }
        for (var i = 1; i <= 8; i++) {
          await saveShot('$dir/책상_$i.png');
          final names = widget.store.sessions
              .map((s) => '${s.name}:${s.shownStatus.label}')
              .join(' ');
          debugPrint('[selftest] $i번째 — $names');
          await Future<void>.delayed(const Duration(seconds: 4));
        }
        debugPrint('[selftest] 책상 다 떴다 → $dir');
      });
    }
    // 14번은 **떠 둔 화면 파일**을 그대로 물려 선택 카드를 그려 본다.
    //
    // 선택창은 사람이 물어봐 줘야 뜨는 것이라, 그때마다 세션을 만들어
    // 물어보게 하면 확인이 매번 멈춘다. 실측해 둔 화면(`docs/tmux_검증_*`)을
    // 그대로 물리면 카드 모양만 따로 떼어 볼 수 있다.
    //
    //   CLAUDE_WATCHER_SELFTEST=14 CLAUDE_WATCHER_PANE=<화면.txt> \
    //   CLAUDE_WATCHER_SHOT=<폴더> <실행파일>
    if (mode == '14') {
      final dir = Platform.environment['CLAUDE_WATCHER_SHOT'] ??
          '${Directory.systemTemp.path}/cw_shots';
      final paneFile = Platform.environment['CLAUDE_WATCHER_PANE'];
      Future<void>.delayed(const Duration(seconds: 3), () async {
        final first = widget.store.sessions.firstOrNull;
        if (first == null || paneFile == null || !mounted) {
          debugPrint('[selftest] 캐릭터나 화면 파일이 없다');
          return;
        }
        final text = await File(paneFile).readAsString();
        setState(() {
          _selectedPath = first.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
        // ⚠️ 떠오기 타이머가 돌면 방금 물린 화면을 바로 덮어쓴다.
        // 한 번 끄는 것으로는 모자란다 — 180ms 틱이 곧바로 다시 켠다.
        _paneFrozen = true;
        _stopPaneTimer();
        setState(() {
          _paneSession = first.cwdPath;
          _paneText = text;
          _paneMissing = false;
        });
        final c = PaneChoice.parse(text);
        debugPrint('[selftest] 다중=${c?.multi} · 선택지=${c?.options.length} · '
            '켜진 것=${c?.checkedOptions.map((o) => o.text).join(",")} · '
            'Submit자리=${c?.submitRow} · 커서=${c?.cursorRow} · '
            '옮길 칸=${c?.toSubmit}');
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await saveShot('$dir/선택카드.png');
        debugPrint('[selftest] 카드 떴다 → $dir/선택카드.png');
      });
    }
    // 9번은 화면을 단계별로 PNG로 떠온다. 모양은 눈으로 봐야 아는데,
    // 사람을 부르지 않고 확인하려면 앱이 제 그림을 내놓아야 한다.
    //
    //   CLAUDE_WATCHER_SELFTEST=9 CLAUDE_WATCHER_SHOT=<폴더> <실행파일>
    if (mode == '9') {
      final dir = Platform.environment['CLAUDE_WATCHER_SHOT'] ??
          '${Directory.systemTemp.path}/cw_shots';
      Future<void>.delayed(const Duration(seconds: 3), () async {
        Future<void> shot(String name) async {
          // 한 프레임 지나야 방금 바뀐 것이 그림에 들어온다.
          await Future<void>.delayed(const Duration(milliseconds: 700));
          await saveShot('$dir/$name.png');
        }

        await shot('01_접힘');

        final list = widget.store.sessions;
        if (list.isEmpty || !mounted) {
          debugPrint('[selftest] 캐릭터가 없어 펼침은 못 떴다');
          return;
        }
        setState(() {
          _selectedPath = list.first.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
        await shot('02_펼침_메시지');

        setState(() => _rawTab = true);
        _startPaneTimer(list.first);
        await Future<void>.delayed(const Duration(seconds: 2));
        await shot('03_펼침_터미널원본');

        setState(() => _rawTab = false);
        await shot('04_다시_메시지');

        if (list.length > 1) {
          setState(() => _selectedPath = list[1].cwdPath);
          await shot('05_다른_캐릭터');
        }

        await _setExpanded(false);
        await shot('06_다시_접힘');
        debugPrint('[selftest] 화면 다 떴다 → $dir');
      });
    }
    // 8번은 캐릭터를 눌러 펴고, 같은 것을 다시 눌러 접히는지 본다 (㉒ 확인용).
    if (mode == '8') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final list = widget.store.sessions;
        if (list.length < 2 || !mounted) {
          debugPrint('[selftest] 캐릭터가 2개는 있어야 옮겨 다니는 것까지 본다');
          return;
        }
        final a = list[0], b = list[1];

        Future<void> tap(AgentSession s) async {
          // _characterCell의 onTap과 같은 판단을 그대로 따라간다.
          final same = _expanded && _selectedPath == s.cwdPath;
          if (same) {
            await _setExpanded(false);
          } else {
            setState(() => _selectedPath = s.cwdPath);
            if (!_expanded) await _setExpanded(true);
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
          debugPrint('[selftest] ${s.name} 누름 → 펼침=$_expanded '
              '선택=${_selectedPath?.split("/").last}');
        }

        debugPrint('[selftest] 시작 펼침=$_expanded');
        await tap(a); // 펴진다
        await tap(b); // 다른 캐릭터 — 펼친 채로 옮겨간다
        await tap(b); // 같은 캐릭터 — 접힌다
        await tap(b); // 다시 펴진다
        debugPrint('[selftest] 끝 펼침=$_expanded (true여야 한다)');
      });
    }
    // 7번은 일하는 중인 세션을 찾아 펼쳐 둔다. 진행 스트립을 눈으로 볼 때 쓴다.
    if (mode == '7') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        for (final s in widget.store.sessions) {
          final pane = await Tmux.capturePane(Tmux.sessionName(s.cwdPath));
          final lines = PaneView.activity(pane, max: 4);
          debugPrint('[selftest] ${s.name} 상태=${s.shownStatus.label} '
              'busy=${s.status.busy} 진행 ${lines.length}줄');
          for (final l in lines) {
            debugPrint('[selftest]   │ $l');
          }
        }
        if (!mounted) return;
        final busy = widget.store.sessions
            .where((x) => x.status.busy)
            .firstOrNull;
        if (busy == null) {
          debugPrint('[selftest] 일하는 중인 세션이 없다 — 스트립은 안 뜬다');
          return;
        }
        setState(() {
          _selectedPath = busy.cwdPath;
          _rawTab = false;
        });
        await _setExpanded(true);
      });
    }
    // 2번은 펼친 채로 터미널 원본 탭을 열어 둔다. 눈으로 확인할 때 쓴다.
    if (mode == '2') {
      Future<void>.delayed(const Duration(seconds: 2), () async {
        final first = widget.store.sessions.firstOrNull;
        if (first == null || !mounted) return;
        setState(() {
          _selectedPath = first.cwdPath;
          _rawTab = true;
        });
        await _setExpanded(true);
        _startPaneTimer(first);
      });
    }
    // 스프라이트 프레임 + 깜빡임 + 경과시간을 한 타이머로 굴린다.
    _tick = Timer.periodic(const Duration(milliseconds: 180), (_) {
      if (mounted) setState(() => _frame++);
      // 이동 이벤트를 놓쳤을 때를 대비해 가끔 직접 확인한다 (약 10초마다).
      if (_frame % 56 == 0) _saveIfMoved();
      // 화면 떠오기를 켜고 끄는 건 build가 아니라 여기서 한다.
      // build 중에 타이머를 만들면 setState가 프레임 안으로 들어온다.
      if (mounted && _expanded) {
        final s = widget.store.sessions
            .where((x) => x.cwdPath == _selectedPath)
            .firstOrNull;
        if (s != null) _syncPaneTimer(s);
      }
    });
  }

  @override
  void dispose() {
    // 창을 닫으면 SessionStore.dispose 가 안 돌 수 있다. 여기서 한 번 더 쓴다.
    widget.store.saveChatNow();
    _rewindDisarm?.cancel();
    _tick?.cancel();
    _saveDebounce?.cancel();
    _todoInput.dispose();
    _commandFocus.dispose();
    _commandInput.removeListener(_onInputChanged);
    _commandInput.dispose();
    _chatScroll.dispose();
    _paneTimer?.cancel();
    _pinTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 화면 캡처·보조 접근 권한 없이 펼침 동작을 확인하려고 둔 자가 점검.
  /// CLAUDE_WATCHER_SELFTEST=1 로 띄웠을 때만 돈다.
  Future<void> _selfTest() async {
    Future<void> report(String label) async {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      debugPrint('[selftest] $label size=${size.width}x${size.height} '
          'pos=${pos.dx},${pos.dy}');
    }

    await Future<void>.delayed(const Duration(seconds: 2));
    await report('시작');
    final first = widget.store.sessions.firstOrNull;
    if (first != null) setState(() => _selectedPath = first.cwdPath);
    await _setExpanded(true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await report('펼침');
    await _setExpanded(false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await report('접힘');

    // tmux 배선(⑦⑧) 점검. 세션이 없으면 그렇다고만 남기고 지나간다.
    if (first == null) return;
    final name = Tmux.sessionName(first.cwdPath);
    debugPrint('[selftest] 세션이름=$name tmux=${Tmux.binary}');
    if (!await Tmux.hasSession(name)) {
      debugPrint('[selftest] 세션 없음 — capture/send 점검 건너뜀');
      return;
    }
    final before = await Tmux.capturePane(name);
    debugPrint('[selftest] capture-pane ${before?.length ?? 0}자');
    debugPrint('[selftest] 세션 크기 = '
        '${Tmux.paneWidth}x${Tmux.paneHeight} (tmux_up.py와 같아야 한다)');
    final sent = await Tmux.sendLine(name, 'echo 위젯에서_보냄');
    debugPrint('[selftest] send-keys ${sent ? "성공" : "실패"}');
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await Tmux.capturePane(name);
    debugPrint('[selftest] 보낸 내용이 화면에 보이나: '
        '${after != null && after.contains("위젯에서_보냄") ? "예" : "아니오"}');
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  /// 이동이 끝난 뒤 한 번만 쓴다. 끄는 동안 매 프레임 저장하지 않는다.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), _saveIfMoved);
  }

  Future<void> _saveIfMoved() async {
    try {
      final pos = await windowManager.getPosition();
      if (_lastSavedPosition == pos) return;
      _lastSavedPosition = pos;
      WindowStateStore.save(pos);
    } catch (e) {
      debugPrint('창 위치 확인 실패: $e');
    }
  }

  // 4프레임(약 0.72초)마다 뒤집힌다.
  bool get _pulseOn => (_frame ~/ 4) % 2 == 0;

  /// 지금 그릴 프레임 번호.
  ///
  /// 반복 구간 앞의 프레임은 상태에 들어온 직후 한 번만 지나가고,
  /// 그 뒤로는 구간 안에서만 순환한다.
  int _frameIndex(AgentSession s, int frameCount) {
    if (frameCount <= 1) return 0;
    // 퇴근한 세션은 첫 프레임에 멈춘다 — 위젯 책상도 대시보드 사무실과 같다(대표 요청 9/17).
    if (s.ended) return 0;
    // ⚠️ **반복 구간은 지금 그리는 그림 것을 써야 한다.** 완료 몸짓이 끝나
    // 대기 그림으로 바뀌었는데 완료의 구간(2-4)을 그대로 쓰면 대기 4프레임 중
    // 뒤쪽만 돌아 어색해진다.
    final range = widget.art.loopRangeOf(s.artStatus.artKey, frameCount);
    final start = range[0], end = range[1];
    final since = s.statusSince;
    final ticks = since == null
        ? _frame
        : DateTime.now().difference(since).inMilliseconds ~/ 180;
    if (ticks < start) return ticks;
    final loopLen = end - start + 1;
    return loopLen <= 0 ? start : start + ((ticks - start) % loopLen);
  }

  String _elapsed(DateTime from) {
    final d = DateTime.now().difference(from);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 11)),
          duration: const Duration(milliseconds: 1600),
          backgroundColor: bgMid,
        ),
      );
  }

  Future<void> _reloadArt() async {
    await widget.art.reload();
    if (!mounted) return;
    final art = widget.art;
    _toast(art.error != null
        ? '아트 로드 실패: ${art.error}'
        : '아트 새로고침 — 상태 ${art.loadedStateCount}/7'
            '${art.hasBase ? ' · base 있음' : ''}'
            '${art.desk != null ? ' · 배경 있음' : ' · 배경 없음'}');
  }

  Future<void> _addProject() async {
    final path = await chooseFolder();
    if (path == null || !mounted) return;

    // 상위/하위 관계를 미리 알려준다. 모르고 등록하면
    // "등록 안 한 폴더인데 다른 캐릭터가 움직인다"로 보인다.
    final swallow = widget.projects.wouldSwallow(path);
    final parent = widget.projects.swallowedBy(path);

    final added = widget.projects.add(path);
    if (!added) {
      _toast('이미 등록된 폴더다');
      return;
    }
    final name = ProjectStore.normalize(path).split('/').last;
    if (swallow.isNotEmpty) {
      _toast('등록: $name — 주의: 하위의 ${swallow.join(", ")}까지 이 캐릭터로 잡힌다');
    } else if (parent != null) {
      _toast('등록: $name — 상위 ${parent.name}보다 이쪽이 우선한다');
    } else {
      _toast('등록: $name');
    }
  }

  /// 등록 안 된 폴더에서 이벤트가 온 것들을 목록으로 띄워 바로 등록시킨다.
  Future<void> _showUnwatched(Offset position) async {
    final paths = widget.store.unwatched.toList();
    if (paths.isEmpty) return;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, 0, 0),
      color: bgMid,
      items: [
        const PopupMenuItem<String>(
          enabled: false,
          height: 26,
          child: Text('등록 안 된 폴더에서 온 신호',
              style: TextStyle(color: textDim, fontSize: 10)),
        ),
        for (final p in paths)
          PopupMenuItem<String>(
            value: p,
            height: 30,
            child: Text(p.split('/').last,
                style: const TextStyle(color: textPrimary, fontSize: 11)),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    widget.projects.add(picked);
    widget.store.unwatched.remove(picked);
    _toast('등록: ${picked.split('/').last}');
  }

  Future<void> _removeProject(AgentSession s, Offset position) async {
    // 임시(하위) 세션은 등록된 것이 아니라 손댈 것이 없다.
    if (s.temporary) {
      _toast('${s.name}은 ${s.project.name} 아래의 임시 세션이다');
      return;
    }
    final sets = widget.art.setNames;
    final current = s.project.charSet ?? '기본';

    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, 0, 0),
      color: bgMid,
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 26,
          child: Text(s.project.name,
              style: const TextStyle(color: textDim, fontSize: 10)),
        ),
        for (final name in sets)
          PopupMenuItem<String>(
            value: 'set:$name',
            height: 28,
            child: Row(
              children: [
                Icon(
                  name == current ? Icons.check : Icons.person_outline,
                  size: 12,
                  color: name == current ? accent : textDim,
                ),
                const SizedBox(width: 6),
                Text(name,
                    style: const TextStyle(color: textPrimary, fontSize: 11)),
              ],
            ),
          ),
        const PopupMenuDivider(height: 6),
        const PopupMenuItem<String>(
          value: 'remove',
          height: 28,
          child: Text('등록 해제',
              style: TextStyle(color: textPrimary, fontSize: 11)),
        ),
      ],
    );
    if (picked == null || !mounted) return;

    if (picked.startsWith('set:')) {
      final name = picked.substring(4);
      widget.projects
          .setCharSet(s.project.path, name == '기본' ? null : name);
      _toast('${s.name} → $name');
      return;
    }
    if (picked == 'remove') {
      if (_selectedPath == s.project.path) _selectedPath = null;
      widget.projects.remove(s.project.path);
      _toast('등록 해제: ${s.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 창 배경은 투명이다. 그려지는 건 책상과 그 위의 것들뿐이다.
    // 목록뷰와 펼침 패널만은 바탕이 있어야 글자가 읽히므로 자기 판을 따로 깐다.
    return AnimatedBuilder(
      // 할 일도 여기 넣는다 — **브라우저에서 고친 것이 위젯에 바로 뜬다.**
      animation: Listenable.merge([
        widget.store,
        widget.art,
        widget.projects,
        widget.todos,
        widget.meetings,
        widget.usage,
        widget.limits,
      ]),
      builder: (context, _) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _syncCollapsedHeight());
        final sessions = widget.store.sessions;
        if (_expanded) {
          final s = sessions
              .where((x) => x.cwdPath == _selectedPath)
              .firstOrNull;
          if (s != null) {
            // 책상은 그대로 두고 그 위에 패널을 올린다.
            // 펼친 채로 다른 캐릭터를 눌러 옮겨 다닐 수 있게 하려는 것이다.
            return Column(
              children: [
                Expanded(
                  // ⚠️ **펼쳐도 할 일이 안 사라지게 한다.** 접힘 화면에만
                  // 붙여놔서 펴는 순간 통째로 없어졌던 적이 있다(2026-08-10).
                  //
                  // ⚠️ **메시지 폭을 뺏지 않는다.** 오른쪽 절반을 떼어 줬더니
                  // 메시지가 좁아져 읽기 나빠졌다. 대신 **창을 왼쪽으로
                  // 늘리고** 그 자리에 붙인다 — 책상은 오른쪽 아래 고정이라
                  // 왼쪽으로 자라는 것이 원래 이 창이 커지는 방향이다.
                  child: _todoOpen
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                                width: kTodoPanelWidth, child: _todoPanel()),
                            Expanded(child: _panel(s)),
                          ],
                        )
                      : _panel(s),
                ),
                SizedBox(
                  height: kDeskAreaHeight,
                  // 책상은 제 폭을 지키고 **오른쪽에 붙는다.**
                  // 창이 왼쪽으로 자라므로 펼쳐도 책상이 제자리에 남는다.
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: _deskWidth,
                      child: _desk(sessions, stretch: false),
                    ),
                  ),
                ),
              ],
            );
          }
          // 보고 있던 것이 사라졌으면 도로 접는다.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _setExpanded(false));
        }
        // 회의 원탁은 책상 자리를 그대로 쓴다. 창이 하나뿐인 위젯이라
        // 새 창을 띄우면 '책상 위 물건'이라는 느낌이 깨진다.
        final meeting = _meeting;
        if (_meetingOpen && meeting != null) return _meetingTable(meeting);
        if (!_deskView) return _list(sessions);
        // 할 일 패널은 책상 **왼쪽**에 붙는다. 책상은 오른쪽 아래 고정이라
        // 창이 왼쪽으로 자라야 책상이 제자리를 지킨다.
        if (!_todoOpen) return _desk(sessions);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: kTodoPanelWidth, child: _todoPanel()),
            Expanded(child: _desk(sessions)),
          ],
        );
      },
    );
  }

  /// 접힌 창 크기. 구역이 늘면 **옆으로** 길어진다. 높이는 책상 한 줄로 고정.
  Size get _collapsedSize {
    // 회의 원탁은 128px 상판에 안 들어간다. 회의를 보는 동안만 키우고
    // 닫으면 도로 상판 한 줄로 돌아온다.
    final base = _meetingShown ? _meetingWidth : _deskWidth;
    return Size(
      base + (_todoOpen ? kTodoPanelWidth : 0),
      (_meetingShown ? kMeetingAreaHeight : kDeskAreaHeight) + 16,
    );
  }

  /// 캐릭터가 늘거나 줄면 창 너비를 맞춘다. 펼친 상태에서는 건드리지 않는다.
  ///
  /// **아래를 고정한다.** 높이가 바뀌면 책상이 화면 밖으로 밀려나기 때문이다.
  Future<void> _syncCollapsedHeight() async {
    if (_expanded) return;
    final next = _collapsedSize;
    // ⚠️ **폭만 보면 안 된다.** 회의 원탁은 높이가 바뀌는데 폭은 그대로일
    // 수 있어서, 폭만 열쇠로 쓰면 창이 안 커진 채 원탁이 잘렸다.
    final key = '${next.width.round()}x${next.height.round()}';
    if (key == _lastFloorCount) return;
    _lastFloorCount = key;

    final before = await windowManager.getSize();
    final pos = await windowManager.getPosition();
    await windowManager.setSize(next);
    // **오른쪽 아래 모서리를 붙잡는다.** 책상이 그 모서리에 붙어 있으므로
    // 폭이나 높이가 바뀌어도 책상은 제자리에 남아야 한다.
    //
    // 예전에는 세로만 맞추고 가로는 그대로 뒀다. 그래서 캐릭터가 하나
    // 늘거나 줄 때마다 책상이 그 폭만큼 옆으로 옮겨 다녔다.
    // 펼친 사이에 임시 세션이 사라지면 접었을 때 왼쪽으로 밀린다 — 실제로 겪었다.
    await windowManager.setPosition(Offset(
      pos.dx - (next.width - before.width),
      pos.dy - (next.height - before.height),
    ));
    await _clampIntoScreen(next);
  }

  /// 같은 창을 키웠다 줄인다. 새 창을 띄우지 않는다 —
  /// 그래야 '책상 위 위젯'이라는 느낌이 유지된다.
  // 마지막으로 쓴 펼침 크기. 접을 때 위치를 되돌리는 계산에 쓴다.
  Size _expandedSize = kExpandedSize;

  /// 펼친 창 크기를 지금 화면에 맞춰 정한다.
  ///
  /// 메시지를 읽는 화면이라 넓을수록 좋다. 다만 화면을 다 덮지는 않는다 —
  /// 위젯이지 창이 아니라는 느낌은 남겨 둔다.
  Future<Size> _computeExpandedSize() async {
    var width = kExpandedSize.width;
    var height = kExpandedSize.height;
    try {
      final displays = await screenRetriever.getAllDisplays();
      final pos = await windowManager.getPosition();
      for (final d in displays) {
        final origin = d.visiblePosition ?? Offset.zero;
        final visible = d.visibleSize ?? d.size;
        final rect =
            Rect.fromLTWH(origin.dx, origin.dy, visible.width, visible.height);
        if (!rect.contains(pos)) continue;
        width =
            (rect.width * kExpandRatioW).clamp(kExpandedSize.width, kExpandMaxW);
        height =
            (rect.height * kExpandRatioH).clamp(kExpandedSize.height, kExpandMaxH);
        break;
      }
    } catch (e) {
      debugPrint('화면 크기 확인 실패: $e');
    }
    // 책상이 그보다 길면 책상에 맞춘다. 잘려 보이면 안 된다.
    if (_deskWidth > width) width = _deskWidth;
    return Size(width, height);
  }

  /// 할 일 패널을 펴고 접는다. **창 폭이 그만큼 바뀐다.**
  ///
  /// ⚠️ 펼친 채로 토글할 때 `_setExpanded(true)`를 다시 부르면 안 된다 —
  /// 그러면 지금 자리(펼친 자리)를 '접었을 때 자리'로 기억해 버려서, 나중에
  /// 접었을 때 엉뚱한 데로 간다.
  Future<void> _toggleTodoPanel() async {
    final delta = _todoOpen ? -kTodoPanelWidth : kTodoPanelWidth;
    setState(() => _todoOpen = !_todoOpen);
    TodoOpenStore.save(_todoOpen);

    if (!_expanded) {
      // 접힘 크기는 _collapsedSize 가 이미 패널 폭을 셈한다.
      _lastFloorCount = '';
      await _syncCollapsedHeight();
      return;
    }
    // 펼친 채로는 여기서 직접 넓힌다. **오른쪽 아래를 붙잡고 왼쪽으로** 자란다.
    _expandedSize =
        Size(_expandedSize.width + delta, _expandedSize.height);
    final before = await windowManager.getPosition();
    await windowManager.setSize(_expandedSize);
    await windowManager.setPosition(Offset(before.dx - delta, before.dy));
    await _clampIntoScreen(_expandedSize);
  }

  Future<void> _setExpanded(bool on) async {
    // 상태를 **먼저** 바꾼다.
    // 창 크기를 재는 동안에도 build가 돈다. 그 사이 캐릭터가 늘거나 줄면
    // _syncCollapsedHeight가 접힌 크기로 되돌려 방금 편 창을 덮어쓴다.
    if (mounted) setState(() => _expanded = on);

    final collapsed = _collapsedSize;
    if (on) _expandedSize = await _computeExpandedSize();
    // 할 일을 펴 두었으면 그 폭만큼 창이 더 넓어야 메시지가 안 좁아진다.
    if (on && _todoOpen) {
      _expandedSize =
          Size(_expandedSize.width + kTodoPanelWidth, _expandedSize.height);
    }
    final expanded = _expandedSize;
    final before = await windowManager.getPosition();
    if (on) {
      // 접었을 때 자리를 기억해 뒀다가 그대로 돌려준다.
      _collapsedPosition = before;
      await windowManager.setSize(expanded);
      // 오른쪽 아래 모서리를 고정하고 왼쪽·위로 자란다.
      // 책상이 그 모서리에 붙어 있으므로 펼쳐도 자리가 그대로다.
      await windowManager.setPosition(Offset(
        before.dx - (expanded.width - collapsed.width),
        before.dy - (expanded.height - collapsed.height),
      ));
      await _clampIntoScreen(expanded);
    } else {
      _stopPaneTimer();
      // 접으면 목록이 사라져 스크롤 자리가 0으로 돌아간다.
      // 표식을 지워 두어야 다시 펼쳤을 때 맨 아래에서 시작한다.
      _lastChatSig = null;
      await windowManager.setSize(collapsed);
      // 기억해 둔 자리로. 없으면 아래를 고정한 채 줄인 자리로 되돌린다.
      await windowManager.setPosition(_collapsedPosition ??
          Offset(
            before.dx + (expanded.width - collapsed.width),
            before.dy + (expanded.height - collapsed.height),
          ));
      await _clampIntoScreen(collapsed);
    }
  }

  /// 커진 창이 화면 밖으로 나가지 않게 위치를 당겨 온다.
  Future<void> _clampIntoScreen(Size size) async {
    try {
      final pos = await windowManager.getPosition();
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return;

      Rect? area;
      for (final d in displays) {
        final origin = d.visiblePosition ?? Offset.zero;
        final visible = d.visibleSize ?? d.size;
        final rect =
            Rect.fromLTWH(origin.dx, origin.dy, visible.width, visible.height);
        if (rect.contains(pos)) {
          area = rect;
          break;
        }
        area ??= rect; // 못 찾으면 첫 디스플레이를 쓴다
      }
      if (area == null) return;

      final maxX = (area.right - size.width).clamp(area.left, double.infinity);
      final maxY = (area.bottom - size.height).clamp(area.top, double.infinity);
      final next = Offset(
        pos.dx.clamp(area.left, maxX),
        pos.dy.clamp(area.top, maxY),
      );
      if (next != pos) await windowManager.setPosition(next);
    } catch (e) {
      debugPrint('창 위치 보정 실패: $e');
    }
  }

  Widget _emptyState() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        '+ 를 눌러 폴더를 고르면\n그 폴더의 클로드만 지켜본다',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textPrimary,
          fontSize: 10,
          height: 1.6,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
    );
  }

  /// 책상 위에 얹는 조작 버튼들. 예전 타이틀바를 대신한다.
  // ── 모니터 고정 ───────────────────────────────────────────────
  //
  // 지금까지는 창 자리를 x·y 두 값으로만 기억했다. 모니터를 뺐다 꽂거나
  // 맥을 재우고 깨우면 그 좌표가 다른 화면을 가리키게 되어, 위젯이 엉뚱한
  // 모니터에 가 있었다. 그래서 **어느 모니터인지**를 따로 기억한다.

  /// 붙여 둔 모니터. 안 정했으면 null.
  DisplayPin? _pin;

  /// 모니터를 지켜보는 시계. **고정을 안 했어도 돈다** — 몇 대가 붙어
  /// 있는지를 알아야 조작줄에 모니터 버튼을 낼지 말지 정할 수 있다.
  Timer? _pinTimer;

  /// 지금 붙어 있는 모니터 수. 한 대뿐이면 고를 것이 없다.
  int _displayCount = 1;

  /// 창이 지금 놓여 있는 디스플레이. 어디에도 안 걸치면 null.
  Display? _displayAt(Offset pos, List<Display> displays) {
    for (final d in displays) {
      final origin = d.visiblePosition ?? Offset.zero;
      final visible = d.visibleSize ?? d.size;
      if (Rect.fromLTWH(origin.dx, origin.dy, visible.width, visible.height)
          .contains(pos)) {
        return d;
      }
    }
    return null;
  }

  /// 그 모니터의 **오른쪽 아래**로 옮긴다.
  ///
  /// 책상은 오른쪽 아래 고정이고 창은 왼쪽·위로 자란다(설계 원칙). 그러니
  /// 모니터를 옮길 때도 같은 자리에 앉히는 것이 자연스럽다.
  Future<void> _moveToDisplay(Display d) async {
    final origin = d.visiblePosition ?? Offset.zero;
    final visible = d.visibleSize ?? d.size;
    final size = await windowManager.getSize();
    final pos = Offset(
      origin.dx + visible.width - size.width,
      origin.dy + visible.height - size.height,
    );
    await windowManager.setPosition(pos);
    _lastSavedPosition = pos;
    WindowStateStore.save(pos);
  }

  /// 모니터 구성을 살피고, 고정한 모니터에서 벗어났으면 되돌린다.
  ///
  /// ⚠️ **그 모니터 안에서 끌어다 놓은 것은 건드리지 않는다.** 고정은 '이
  /// 모니터에 있어라'이지 '이 자리에 있어라'가 아니다. 안에서 옮긴 것까지
  /// 되돌리면 창을 아예 못 옮기게 된다.
  Future<void> _watchDisplays() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (!mounted) return;
      if (displays.length != _displayCount) {
        setState(() => _displayCount = displays.length);
      }
      final pin = _pin;
      if (pin == null) return;
      final target = pin.find(displays);
      // 고정한 모니터가 지금 안 붙어 있다. **기록은 지우지 않는다** —
      // 다시 꽂으면 제자리로 돌아가야 한다.
      if (target == null) return;
      final pos = await windowManager.getPosition();
      if (_displayAt(pos, displays)?.id == target.id) return;
      await _moveToDisplay(target);
      debugPrint('고정한 모니터로 되돌림: ${target.name ?? target.id}');
    } catch (e) {
      debugPrint('모니터 확인 실패: $e');
    }
  }

  void _startPinTimer() {
    _pinTimer?.cancel();
    // 모니터 구성은 자주 바뀌는 것이 아니다. 5초면 사람이 알아채기 전에
    // 제자리로 돌아가면서도 하는 일이 없다시피 하다.
    _pinTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _watchDisplays());
    unawaited(_watchDisplays());
  }

  /// 모니터 목록을 띄워 고르게 한다.
  Future<void> _pickDisplay(Offset position) async {
    List<Display> displays;
    Display primary;
    Offset pos;
    try {
      displays = await screenRetriever.getAllDisplays();
      primary = await screenRetriever.getPrimaryDisplay();
      pos = await windowManager.getPosition();
    } catch (e) {
      _toast('모니터 목록을 못 읽었다');
      return;
    }
    if (!mounted || displays.isEmpty) return;
    final here = _displayAt(pos, displays);
    final pinned = _pin;

    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, 0, 0),
      color: bgMid,
      items: [
        const PopupMenuItem<String>(
          enabled: false,
          height: 26,
          child: Text('어느 모니터에 둘까',
              style: TextStyle(color: textDim, fontSize: 10)),
        ),
        for (final d in displays)
          PopupMenuItem<String>(
            value: 'pin:${d.id}',
            height: 34,
            child: Row(
              children: [
                Icon(
                  pinned != null && pinned.isSame(d)
                      ? Icons.push_pin
                      : Icons.desktop_windows_outlined,
                  size: 12,
                  color: pinned != null && pinned.isSame(d) ? gold : textDim,
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      (d.name?.isEmpty ?? true) ? '모니터 ${d.id}' : d.name!,
                      style: const TextStyle(color: textPrimary, fontSize: 11),
                    ),
                    // 이름이 비슷한 모니터를 두 대 쓰면 이름만으로는 못 가른다.
                    // 크기와 '지금 여기'가 그걸 갈라 준다.
                    Text(
                      [
                        '${d.size.width.round()}×${d.size.height.round()}',
                        if (primary.id == d.id) '주 모니터',
                        if (here?.id == d.id) '지금 여기',
                      ].join(' · '),
                      style: const TextStyle(color: textDim, fontSize: 9),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const PopupMenuDivider(height: 6),
        PopupMenuItem<String>(
          value: 'unpin',
          height: 28,
          enabled: pinned != null,
          child: Text(
            pinned == null ? '고정 안 함 (지금 상태)' : '고정 풀기',
            style: TextStyle(
                color: pinned == null ? textDim : textPrimary, fontSize: 11),
          ),
        ),
      ],
    );
    if (picked == null || !mounted) return;

    if (picked == 'unpin') {
      setState(() => _pin = null);
      WindowStateStore.savePin(null);
      _toast('모니터 고정을 풀었다');
      return;
    }
    final id = picked.substring(4);
    final target = displays.where((d) => d.id == id).firstOrNull;
    if (target == null) return;
    final pin = DisplayPin.of(target);
    setState(() => _pin = pin);
    WindowStateStore.savePin(pin);
    await _moveToDisplay(target);
    _startPinTimer();
    _toast('${pin.label}에 고정했다');
  }

  Widget _deskControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 확인용으로 띄운 판이면 표를 단다. 본 판과 나란히 떠 있으므로
        // 어느 쪽을 보고 있는지 알 수 없으면 엉뚱한 창을 만지게 된다.
        if (kIsDevInstance) _devBadge(),
        _iconButton(icon: Icons.add, tooltip: '프로젝트 폴더 추가', onTap: _addProject),
        _iconButton(icon: Icons.refresh, tooltip: '아트 새로고침', onTap: _reloadArt),
        // 할 일의 본 자리는 이제 **브라우저**다. 210px 패널로는 다섯 필드를
        // 다 못 담으므로, 누르면 제대로 보는 쪽이 열리는 것이 맞다.
        // 옆에 붙이는 패널(한눈에 보는 용도)은 우클릭으로 남겨 둔다 —
        // 캐릭터 우클릭이 등록 해제인 것과 같은 결이다.
        _iconButton(
          icon: _todoOpen ? Icons.checklist : Icons.checklist_outlined,
          tooltip: '할 일 열기 (우클릭: 옆에 ${_todoOpen ? '접기' : '펴기'})',
          onTap: _openTodoPage,
          onSecondaryTap: _toggleTodoPanel,
        ),
        // 모니터가 여럿일 때만 낸다. 한 대뿐이면 고를 것이 없어 자리만 먹는다.
        if (_displayCount > 1)
          Builder(
            builder: (btn) => _iconButton(
              icon: _pin == null
                  ? Icons.desktop_windows_outlined
                  : Icons.push_pin,
              tooltip: _pin == null
                  ? '모니터 고르기'
                  : '${_pin!.label}에 고정됨 (눌러서 바꾸기)',
              onTap: () {
                final box = btn.findRenderObject() as RenderBox?;
                final at = box?.localToGlobal(Offset.zero) ?? Offset.zero;
                _pickDisplay(at + const Offset(0, 22));
              },
            ),
          ),
        // 승인 생략을 여기서 켜고 끈다. 예전에는 yolo 파일을 손으로
        // 만들고 지워야 했다 — 터미널로 가야 하고 지금 어느 쪽인지도 안 보였다.
        _iconButton(
          icon: Tmux.yolo ? Icons.lock_open : Icons.lock_outline,
          tooltip: _yoloTooltip,
          onTap: _toggleYolo,
        ),
        // 회의가 돌 때만 낸다. 늘 있으면 눌러도 아무 일이 없는 버튼이 된다.
        if (widget.meetings.has)
          _iconButton(
            icon: _meetingOpen ? Icons.groups : Icons.groups_outlined,
            tooltip: _meetingOpen ? '책상으로' : '회의 보기',
            onTap: _toggleMeeting,
          ),
        _iconButton(
          icon: _deskView ? Icons.list : Icons.weekend,
          tooltip: _deskView ? '목록으로' : '책상으로',
          onTap: () => setState(() => _deskView = !_deskView),
        ),
        _iconButton(
          icon: Icons.close,
          tooltip: '닫기',
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }

  String get _yoloTooltip {
    if (Tmux.yoloByEnv) {
      return '승인 생략 — 환경변수로 켜져 있다\n'
          '(CLAUDE_WATCHER_YOLO=1). 여기서는 못 끈다';
    }
    return Tmux.yolo
        ? '승인 생략 중 — 눌러서 승인창을 받는다\n다음에 띄우는 세션부터 바뀐다'
        : '승인창을 받는 중 — 눌러서 생략한다\n다음에 띄우는 세션부터 바뀐다';
  }

  /// 승인 생략을 켜고 끈다.
  ///
  /// ⚠️ **이미 떠 있는 세션은 안 바뀐다는 것을 반드시 알린다.** 플래그는
  /// 클로드가 시작할 때 정해진다. 안 알리면 '눌렀는데 왜 그대로지'가 된다.
  void _toggleYolo() {
    if (Tmux.yoloByEnv) {
      _toast('환경변수(CLAUDE_WATCHER_YOLO=1)로 켜져 있어 여기서는 못 끈다');
      return;
    }
    final now = Tmux.setYolo(!Tmux.yoloByFile);
    setState(() {});
    final live = widget.store.sessions.where((x) => !x.ended).length;
    final tail = live > 0 ? ' · 떠 있는 $live개는 그대로다' : '';
    _toast(now ? '승인 생략으로 띄운다$tail' : '승인창을 받고 띄운다$tail');
  }

  /// 확인용 판이라는 표. 포트를 같이 적어 어느 판인지 바로 알게 한다.
  Widget _devBadge() {
    return Tooltip(
      message: '확인용으로 띄운 판이다 (포트 $kPort).\n'
          '동현동현이 쓰는 위젯은 포트 $kDefaultPort 쪽이다.',
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: danger.withValues(alpha: 0.25),
          border: Border.all(color: danger),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text('확인용 $kPort',
            style: const TextStyle(
                color: textPrimary, fontSize: 9, fontWeight: FontWeight.w700)),
      ),
    );
  }

  /// 등록 안 된 폴더에서 신호가 오면 책상 위쪽에 띄운다.
  /// 버튼들 사이에 끼워 두니 눈에 안 띈다는 지적이 있어 따로 뺐다.
  Widget _unwatchedChip() {
    final n = widget.store.unwatched.length;
    if (n == 0) return const SizedBox.shrink();
    return Builder(
      builder: (chipContext) => InkWell(
        onTap: () {
          final box = chipContext.findRenderObject() as RenderBox?;
          final pos = box?.localToGlobal(Offset.zero) ?? const Offset(80, 26);
          _showUnwatched(pos + const Offset(0, 22));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: gold,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
          ),
          child: Text(
            '＋ 미등록 $n곳 — 눌러서 등록',
            style: const TextStyle(
              color: Color(0xFF3a2f00),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    VoidCallback? onSecondaryTap,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        onSecondaryTap: onSecondaryTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Icon(
            icon,
            size: 13,
            color: textPrimary,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
          ),
        ),
      ),
    );
  }

  // ── 펼침 패널 (720×520) ─────────────────────────────────

  Widget _panel(AgentSession s) {
    return Container(
      decoration: BoxDecoration(
        color: bgDark,
        border: Border.all(color: borderCol, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelHeader(s),
          _panelTabs(s),
          Expanded(child: _panelBody(s)),
          // ⚠️ 일하는 중인 것은 **말풍선**으로 대화 안에 넣는다(_busyBubble).
          // 예전에는 여기에 띠로 따로 붙였는데, 점 세 개는 말풍선이고 도구
          // 쓸 때는 띠라서 같은 것이 두 모양으로 갈렸다(2026-08-07 QA).
          // 선택지는 놓치면 안 되는 것이라 그대로 아래에 붙여 둔다.
          if (!_rawTab && !_meetingTab && !_usageTab) _choiceCard(s),
          if (!_rawTab && !_meetingTab && !_usageTab) _slashMenu(s),
          if (!_rawTab && !_meetingTab && !_usageTab) _atMenu(s),
          // 회의·크레딧 탭에서는 입력칸을 감춘다. 여기서 친 말은 펴 둔
          // 캐릭터의 세션으로 가는데, 보고 있는 화면과 상관없는 곳이다.
          if (!_meetingTab && !_usageTab) _commandBar(s),
        ],
      ),
    );
  }

  /// 마지막 신호가 등록 폴더보다 깊은 곳에서 왔으면 그 하위 경로를 돌려준다.
  String? _deeperCwd(AgentSession s) {
    final cwd = s.lastCwd;
    if (cwd == null) return null;
    final base = s.project.path;
    if (cwd == base || !cwd.startsWith('$base/')) return null;
    return cwd.substring(base.length + 1);
  }

  Widget _panelHeader(AgentSession s) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 12, right: 6),
        color: bgMid,
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: s.shownStatus.color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.name,
              style: const TextStyle(
                color: textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.ended
                  ? '세션 없음'
                  : (s.tool != null
                      ? '${s.shownStatus.label} · ${s.tool}'
                      : s.shownStatus.label),
              style: TextStyle(color: s.shownStatus.color, fontSize: 10),
            ),
            // 신호가 등록 폴더보다 깊은 데서 왔으면 어디서 왔는지 밝힌다.
            if (_deeperCwd(s) != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '← ${_deeperCwd(s)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: textDim, fontSize: 10),
                ),
              ),
            ],
            const Spacer(),
            _signalChip(s),
            // 멈추기는 진행 스트립에 있었는데, 그 띠를 말풍선으로 옮기면서
            // 여기로 왔다. 되돌리기 옆이라 '되돌리는 것들'이 한자리에 모인다.
            // 멈출 수 있을 때만 뜬다.
            if (s.status.busy) ...[
              _stopButton(s),
              const SizedBox(width: 6),
            ],
            _rewindButton(s),
            _modeChip(s),
            _iconButton(
              icon: Icons.close_fullscreen,
              tooltip: '접기',
              onTap: () => _setExpanded(false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelTabs(AgentSession s) {
    Widget tab(String label, bool active, VoidCallback onTap) {
      return InkWell(
        // ⚠️ **순서가 있다.** 어느 탭을 누르든 회의 탭을 먼저 내리고,
        // 그 다음 눌린 탭이 제 값을 올린다. 뒤집으면 회의 탭에서 못 나온다.
        onTap: () {
          setState(() {
            _meetingTab = false;
            _usageTab = false;
          });
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? textPrimary : textDim,
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return Container(
      color: bgMid.withValues(alpha: 0.5),
      child: Row(
        children: [
          tab('메시지', !_rawTab, () {
            setState(() => _rawTab = false);
            // 메시지 탭에서도 승인 대기면 화면을 계속 떠온다 — 선택창을 보여줘야 한다.
            _syncPaneTimer(s);
          }),
          tab('터미널 원본', _rawTab, () {
            setState(() => _rawTab = true);
            _startPaneTimer(s);
          }),
          // 회의 탭도 회의가 돌 때만 낸다.
          if (widget.meetings.has)
            tab('회의', _meetingTab, () {
              setState(() {
                _rawTab = false;
                _meetingTab = true;
              });
            }),
          tab('크레딧', _usageTab, () {
            setState(() {
              _rawTab = false;
              _usageTab = true;
            });
            // 열 때 한 번 더 훑는다. 1분 타이머를 기다리면 방금 쓴 것이 안 보인다.
            unawaited(widget.usage.refresh());
          }),
          const Spacer(),
          if (_rawTab)
            _iconButton(
              icon: Icons.refresh,
              tooltip: '지금 화면 다시 떠오기',
              onTap: () => _refreshPane(s),
            ),
        ],
      ),
    );
  }

  Widget _panelBody(AgentSession s) {
    // 회의 탭은 어느 캐릭터를 펴 뒀든 같은 것을 보여준다. 회의는 세션
    // 하나의 것이 아니라 여럿이 함께 하는 것이라서다.
    if (_meetingTab) {
      _lastChatSig = null;
      return _meetingBody();
    }
    if (_usageTab) {
      _lastChatSig = null;
      return _usageBody(s);
    }
    // 원본 탭에 가 있는 동안 목록이 사라지므로 표식도 지운다.
    // 메시지 탭으로 돌아오면 다시 맨 아래에서 시작한다.
    if (_rawTab) {
      _lastChatSig = null;
      return _rawBody(s);
    }
    // 메시지 탭은 주고받은 것을 대화처럼 쌓아 보여준다.
    // 보낸 말이 어디로 갔는지 보이지 않으면 위젯에서 시킬 마음이 안 든다.
    // 일하는 동안에는 그 말풍선을 맨 아래에 붙인다.
    // ⚠️ 압축·재시도는 훅이 안 울려 status가 '완료'로 굳어 있다. 그때도
    // 멈춘 것처럼 보이지 않게 화면 신호로 띄운다(설계 원칙 2절의 예외).
    final thinking = s.status.busy || _signalsOf(s).working;
    if (s.chat.isEmpty && !thinking) {
      _lastChatSig = null;
      return _placeholderBody(
        '아직 주고받은 것이 없다',
        '작업이 한 번 끝나면 여기 올라오고,\n아래에 쳐서 보낸 말도 여기 남는다.',
      );
    }
    // 답변이 오면 맨 아래로 따라 내려간다. 마지막 줄의 객체가 바뀌는 것까지 보므로
    // 재시도로 본문이 갈리거나 도구 요약이 늦게 얹힐 때도 다시 맞춘다.
    // 점이 새로 붙을 때도 아래로 따라 내려간다. 그래야 생각 중인 것이 보인다.
    // ⚠️ 점의 **깜빡임**까지 넣으면 안 된다 — 360ms마다 스크롤이 튄다.
    final sig = '${s.cwdPath}|${s.chat.length}|$thinking|'
        '${s.chat.isEmpty ? 0 : identityHashCode(s.chat.last)}';
    if (sig != _lastChatSig) {
      _lastChatSig = sig;
      _scrollChatToEnd();
    }
    return Scrollbar(
      controller: _chatScroll,
      child: ListView.builder(
        controller: _chatScroll,
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
        itemCount: s.chat.length + (thinking ? 1 : 0),
        itemBuilder: (context, i) => i < s.chat.length
            ? _chatRow(s, s.chat[i])
            : _busyBubble(s),
      ),
    );
  }

  /// 지금 펼쳐 둔 세션의 화면에서 주운 신호. 다른 세션 것이면 빈 값이다.
  ///
  /// ⚠️ **펼쳐 있는 동안만 화면을 떠온다.** 접힌 상태에서는 늘 빈 값이라
  /// 여기 기대는 표시는 접었을 때 안 보인다.
  PaneSignals _signalsOf(AgentSession s) =>
      _paneSession == s.cwdPath && !_paneMissing
          ? PaneView.signals(_paneText)
          // 접혀 있거나 다른 캐릭터를 보고 있으면 30초 주기로 담아둔 것을 쓴다.
          : s.signals;

  /// 백그라운드 셸·서브에이전트처럼 **턴이 끝난 뒤에도 남는 것**을 헤더에 건다.
  ///
  /// 말풍선에 넣지 않는 이유는 이것들이 '지금 하는 일'이 아니기 때문이다.
  /// 턴은 끝났는데(초록) 셸은 계속 돌 수 있다.
  Widget _signalChip(AgentSession s) {
    final sig = _signalsOf(s);
    final tokens = s.contextTokens;
    final parts = [
      // 컨텍스트는 transcript에서 읽어 **접혀 있어도** 최신이다.
      if (tokens != null) formatTokens(tokens),
      if (sig.shells > 0) '셸 ${sig.shells}',
      // ⚠️ 1은 늘 떠 있다. 2 이상만 뜻이 있다.
      if (sig.agents > 1) '에이전트 ${sig.agents}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: '컨텍스트 크기와 백그라운드에서 도는 것\n'
            '⚠️ 한도는 모델 이름으로 알 수 없어 비율은 내지 않는다',
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: textDim.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            parts.join(' · '),
            style: const TextStyle(
                color: textDim, fontSize: 9, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  /// 일하는 중인 것을 대화 흐름 안에 **말풍선으로** 보여준다.
  ///
  /// 예전에는 화면 아래에 띠(진행 스트립)로 따로 붙였는데, 점 세 개는
  /// 말풍선이고 도구 쓸 때는 띠라서 같은 '지금 뭐 하는 중'이 두 모양으로
  /// 갈렸다. 하나로 합친다(2026-08-07 QA 지적).
  ///
  /// ⚠️ **화면을 읽어 추측하지 않는다.** 띄울지 말지는 훅이 정한
  /// `status.busy`가 정하고, 화면(`capture-pane`)은 "그래서 무엇을 하고
  /// 있는지"만 채운다 — 설계 원칙 2절 그대로다.
  Widget _busyBubble(AgentSession s) {
    // 180ms 틱을 그대로 쓴다. 애니메이션 하나 때문에 타이머를 더 만들지 않는다.
    // 두 틱(360ms)마다 한 칸씩 옮겨 붙어 느긋하게 뛴다.
    final lit = (_frame ~/ 2) % 3;
    // 화면에서 떠온 꼬리. 말풍선 안이라 띠였을 때(4줄)보다 짧게 둔다.
    final lines = _paneSession == s.cwdPath && !_paneMissing
        ? PaneView.activity(_paneText, max: 2)
        : const <String>[];
    // ⚠️ **도구 실행 중과 답 쓰는 중을 가른다.** 둘 다 훅 상태로는 `working`
    // 이라, 도구가 끝난 뒤에도 `작업 중 · Bash`로 굳어 멈춘 것처럼 보였다.
    // 그 구간에도 터미널 스피너(`Newspapering…`)는 계속 돈다.
    //
    // ⚠️ **바로 바꾸지 않고 잠깐 기다린다.** 도구를 연달아 쓰면 그 사이가
    // 아주 짧은데, 그때마다 글자가 바뀌면 깜빡이는 것처럼 보인다.
    final done = s.toolDoneAt;
    final writing = done != null &&
        DateTime.now().difference(done) > const Duration(milliseconds: 700);
    // 화면에서 주운 것이 가장 구체적이다 — 압축·재시도는 훅이 안 울린다.
    final signals = _signalsOf(s);
    final label = signals.label ??
        (writing
            ? '답을 쓰는 중'
            : (s.tool != null ? '${s.shownStatus.label} · ${s.tool}' : s.shownStatus.label));

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(s),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: const TextStyle(color: textDim, fontSize: 9)),
                const SizedBox(height: 3),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  decoration: BoxDecoration(
                    color: bgMid.withValues(alpha: 0.55),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(3),
                      topRight: Radius.circular(10),
                      bottomLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
                    border: Border.all(color: borderCol.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < 3; i++) ...[
                            if (i > 0) const SizedBox(width: 5),
                            // 켜진 점만 위로 살짝 떠오른다. 크기까지 바꾸면
                            // 줄 높이가 흔들려 말풍선이 들썩인다.
                            Transform.translate(
                              offset: Offset(0, i == lit ? -2 : 0),
                              child: Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: accent.withValues(
                                      alpha: i == lit ? 1.0 : 0.35),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                          // 도구를 쓰기 시작하면 무엇을 쓰는지 옆에 붙인다.
                          // 생각 중일 때는 점만 둔다 — 붙일 말이 없다.
                          if (s.status == AgentStatus.working ||
                              writing ||
                              signals.label != null) ...[
                            const SizedBox(width: 9),
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: accent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                          if (s.statusSince != null) ...[
                            const SizedBox(width: 9),
                            Text(_elapsed(s.statusSince!),
                                style: const TextStyle(
                                    color: textDim, fontSize: 9)),
                          ],
                        ],
                      ),
                      // 화면에서 떠온 것. 훅이 못 주는 '진행'이 여기 있다.
                      if (lines.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        for (final line in lines)
                          Text(
                            line,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: textPrimary,
                              fontSize: 10,
                              height: 1.5,
                              fontFamily: 'Menlo',
                              fontFamilyFallback: ['Monaco', 'Courier New'],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 대화 한 줄. 내 말은 오른쪽, 상대 말은 아바타와 함께 왼쪽.
  Widget _chatRow(AgentSession s, ChatEntry e) {
    // 도구 줄은 말풍선이 아니다. 말풍선으로 그리면 도구 열 번 쓴 턴이
    // 화면을 다 먹어서 정작 응답이 안 보인다. 왼쪽에 붙는 얇은 한 줄로 둔다.
    if (e.kind == ChatKind.tool) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5, left: 34, right: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 7),
              child: Text('⏺',
                  style: TextStyle(
                      color: accent.withValues(alpha: 0.75), fontSize: 8)),
            ),
            Expanded(
              child: Text(
                e.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: textDim,
                  fontSize: 10,
                  height: 1.4,
                  fontFamily: 'Menlo',
                  fontFamilyFallback: ['Monaco', 'Courier New'],
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (e.mine) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 60),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.22),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    topRight: Radius.circular(3),
                    bottomLeft: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
                child: _linked(
                  e.text,
                  const TextStyle(
                      color: textPrimary, fontSize: 12, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(s),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: const TextStyle(color: textDim, fontSize: 9)),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  decoration: BoxDecoration(
                    color: bgMid.withValues(alpha: 0.55),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(3),
                      topRight: Radius.circular(10),
                      bottomLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
                    border:
                        Border.all(color: borderCol.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (e.turn != null && e.turn!.toolCounts.isNotEmpty)
                        _workSummary(e.turn!),
                      ..._renderReport(e.text),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 말풍선 옆 아바타. 그 프로젝트의 캐릭터를 그대로 쓴다.
  Widget _avatar(AgentSession s) {
    final frames = widget.art.framesOf(
      s.folderName,
      s.artStatus,
      setName: s.temporary ? null : s.project.charSet,
    );
    return SizedBox(
      width: 34,
      height: 34,
      child: frames != null && frames.isNotEmpty
          ? CustomPaint(
              painter: _SpritePainter(frames[_frameIndex(s, frames.length)]))
          : Container(
              decoration: BoxDecoration(
                color: s.shownStatus.color.withValues(alpha: 0.2),
                border: Border.all(color: s.shownStatus.color),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
    );
  }

  /// 링크가 눌리는 글. 링크가 없으면 예전 그대로 [SelectableText]다.
  ///
  /// 손가락 모양·밑줄로 "눌린다"를 보여준다. 표시가 없으면 눌러볼 생각을 안 한다.
  Widget _linked(String text, TextStyle style) {
    final pieces = parseLinks(text);
    if (!pieces.any((p) => p.isLink)) {
      return SelectableText(text, style: style);
    }
    // ⚠️ `SelectableText.rich` 로는 **눌리지 않는다.** 글자 선택 제스처가 탭을
    // 먼저 먹어서 span 의 recognizer 까지 오지 않는다. 그려지기만 하고 눌러도
    // 아무 일이 안 난다 — 실제로 겪었다(2026-08-06).
    //
    // `SelectionArea` + `Text.rich` 로 두면 둘 다 산다. 끌어서 복사도 되고
    // 링크도 눌린다.
    return SelectionArea(
      child: Text.rich(
      TextSpan(
        style: style,
        children: [
          for (final p in pieces)
            if (p.isLink)
              TextSpan(
                text: p.text,
                style: style.copyWith(
                  color: accent,
                  decoration: TextDecoration.underline,
                  decorationColor: accent.withValues(alpha: 0.6),
                ),
                mouseCursor: SystemMouseCursors.click,
                recognizer: TapGestureRecognizer()
                  ..onTap = () async {
                    final ok = await openUrl(p.url!);
                    if (!ok && mounted) _toast('열지 못했다: ${p.url}');
                  },
              )
            else
              TextSpan(text: p.text),
        ],
      ),
      ),
    );
  }

  /// 응답 본문을 읽기 좋게 그린다.
  ///
  /// 마크다운 전체를 구현하지 않는다. 화면에서 무너져 보이던 것 —
  /// **표와 코드블록** — 만 고정폭으로 세우고, 제목·목록은 살짝 다듬는다.
  List<Widget> _renderReport(String report) {
    const body = TextStyle(color: textPrimary, fontSize: 12, height: 1.6);
    const mono = TextStyle(
      color: textPrimary,
      fontSize: 11,
      height: 1.45,
      fontFamily: 'Menlo',
      fontFamilyFallback: ['Monaco', 'Courier New'],
    );

    final out = <Widget>[];
    final lines = report.split('\n');
    final buffer = <String>[];
    var mode = 'text'; // text | code | table

    Widget block(List<String> ls, String kind) {
      final text = ls.join('\n');
      if (kind == 'text') {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _linked(text, body),
        );
      }
      // 표와 코드는 고정폭으로. 폭이 모자라면 가로로 밀어서 본다.
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          border: Border.all(color: borderCol.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(text, style: mono),
          ),
        ),
      );
    }

    void flush() {
      if (buffer.isEmpty) return;
      if (mode == 'table') {
        out.add(_markdownTable(List.of(buffer)));
      } else {
        out.add(block(List.of(buffer), mode == 'text' ? 'text' : 'mono'));
      }
      buffer.clear();
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      final isFence = line.trimLeft().startsWith('```');
      final isTable = line.trimLeft().startsWith('|');

      if (mode == 'code') {
        if (isFence) {
          flush();
          mode = 'text';
        } else {
          buffer.add(raw);
        }
        continue;
      }
      if (isFence) {
        flush();
        mode = 'code';
        continue;
      }
      if (isTable) {
        if (mode != 'table') {
          flush();
          mode = 'table';
        }
        buffer.add(raw);
        continue;
      }
      if (mode == 'table') {
        flush();
        mode = 'text';
      }
      // 제목은 한 줄짜리로 떼어 굵게 세운다.
      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        flush();
        out.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: SelectableText(
            heading.group(2)!,
            style: TextStyle(
              color: textPrimary,
              fontSize: heading.group(1)!.length <= 2 ? 14 : 12.5,
              height: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ));
        continue;
      }
      buffer.add(line.replaceFirst(RegExp(r'^\s*[-*]\s+'), '· '));
    }
    flush();
    return out;
  }

  /// 마크다운 표를 진짜 표로 그린다.
  ///
  /// 고정폭으로만 두면 `| 항목 | 값 |` 같은 원문이 그대로 보여서 표로 안 읽힌다.
  /// 칸을 갈라 테두리를 두르면 그제서야 표가 된다.
  Widget _markdownTable(List<String> lines) {
    final rows = parseMarkdownTable(lines);
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);

    // 표 칸에도 링크가 들어온다. 노션 주소를 표로 정리해 주는 일이 흔하다.
    Widget cell(String text, {required bool head}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: _linked(
            text,
            TextStyle(
              color: head ? textPrimary : textPrimary.withValues(alpha: 0.9),
              fontSize: 11,
              height: 1.4,
              fontWeight: head ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: borderCol),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.symmetric(
          inside: BorderSide(color: borderCol.withValues(alpha: 0.6)),
        ),
        children: [
          for (var i = 0; i < rows.length; i++)
            TableRow(
              decoration: i == 0
                  ? BoxDecoration(color: bgMid.withValues(alpha: 0.7))
                  : null,
              children: [
                for (var c = 0; c < columns; c++)
                  cell(c < rows[i].length ? rows[i][c] : '', head: i == 0),
              ],
            ),
        ],
      ),
    );
  }

  /// 무슨 일을 했는지. 응답 본문만으로는 이게 남지 않는다 —
  /// 도구를 열 번 쓰고 마지막에 한 줄만 말하는 턴이 흔하기 때문이다.
  Widget _workSummary(TurnReport turn) {
    final files = turn.files;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(9, 6, 9, 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        border: const Border(left: BorderSide(color: accent, width: 2)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(3),
          bottomRight: Radius.circular(3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이번에 한 일',
              style: TextStyle(color: textDim, fontSize: 9, letterSpacing: 1)),
          const SizedBox(height: 3),
          SelectableText(
            turn.toolLine ?? '',
            style: const TextStyle(color: textPrimary, fontSize: 11),
          ),
          if (files.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              '건드린 파일 ${files.length}개\n'
              '${files.take(8).map((f) => '· ${f.split('/').last}').join('\n')}'
              '${files.length > 8 ? '\n· … 외 ${files.length - 8}개' : ''}',
              style: const TextStyle(
                  color: textDim, fontSize: 10, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// 터미널 원본 — tmux가 지금 보여주고 있는 화면 그대로.
  Widget _rawBody(AgentSession s) {
    if (Tmux.binary == null) {
      return _placeholderBody(
        'tmux가 없다',
        'brew install tmux 로 설치하면 이 탭이 동작한다.',
      );
    }
    if (_paneSession != s.cwdPath) {
      // 다른 프로젝트를 열었으면 새로 떠온다.
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPane(s));
    }
    if (_paneMissing) {
      return _placeholderBody(
        '떠 있는 세션이 없다',
        '세션 이름: ${Tmux.sessionName(s.cwdPath)}\n'
            '터미널에서 cw 로 띄워도 되고, 아래 버튼으로 여기서 띄워도 된다.',
        action: _starting
            ? const Text('띄우는 중…',
                style: TextStyle(color: textDim, fontSize: 11))
            : OutlinedButton(
                onPressed: () => _startSession(s),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: const BorderSide(color: accent),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('여기서 기동', style: TextStyle(fontSize: 11)),
              ),
      );
    }
    final pane = _paneText;
    if (pane == null) {
      return _placeholderBody('불러오는 중', '');
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            pane,
            // 고정폭이 아니면 칸이 전부 어긋난다.
            style: const TextStyle(
              color: textPrimary,
              fontSize: 11,
              height: 1.35,
              fontFamily: 'Menlo',
              fontFamilyFallback: ['Monaco', 'Courier New'],
            ),
          ),
        ),
      ),
    );
  }

  /// 화면을 떠올 이유가 있는지.
  ///
  /// **펼쳐 있으면 늘 떠온다.** 예전에는 원본 탭·승인 대기·작업 중일 때만
  /// 떠왔는데, 그러면 `/effort` 처럼 훅이 안 울리는 창이 떴을 때 메시지 탭에
  /// 아무것도 못 보여준다. 실제로 "화살표 같은 게 안 뜬다"는 지적을 받았다.
  /// 펼친 창은 사람이 보고 있는 동안만 떠 있으므로 이 정도는 치러도 된다.
  bool _wantsPane(AgentSession s) => _expanded;

  /// 자가 점검(14번)이 화면을 물려 둔 동안이다. 떠오기가 돌면 방금 물린
  /// 화면을 바로 덮어써서 확인할 것이 사라진다.
  bool _paneFrozen = false;

  /// 지금 상황에 맞춰 화면 떠오기를 켜고 끈다. 매 틱마다 부른다.
  void _syncPaneTimer(AgentSession s) {
    if (_paneFrozen) return;
    final want = _wantsPane(s);
    if (want && (_paneTimer == null || _paneOwner != s.cwdPath)) {
      _startPaneTimer(s);
    } else if (!want && _paneTimer != null) {
      _stopPaneTimer();
    }
  }

  /// 탭이 열려 있는 동안만 돌린다. 닫으면 멈춘다 — 안 보는 화면을 계속 뜰 이유가 없다.
  void _startPaneTimer(AgentSession s) {
    _paneTimer?.cancel();
    _paneOwner = s.cwdPath;
    _refreshPane(s);
    // 진행을 보여주는 화면이라 2초는 굼떠 보인다. 1.2초면 사람이 살아 있다고 느낀다.
    _paneTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (_wantsPane(s)) {
        _refreshPane(s);
      } else {
        _stopPaneTimer();
      }
    });
  }

  void _stopPaneTimer() {
    _paneTimer?.cancel();
    _paneTimer = null;
    _paneOwner = null;
  }

  /// 지금 화면을 떠온다.
  ///
  /// 세션 이름은 **`cwdPath`로 뽑는다.** 보내는 쪽(`_sendCommand`·`_sendKey`)도
  /// 그렇다. 임시 세션은 등록 폴더(`project.path`)와 실제 폴더가 다르므로
  /// 한쪽만 다르게 잡으면 읽는 세션과 답하는 세션이 어긋난다.
  Future<void> _refreshPane(AgentSession s) async {
    final name = Tmux.sessionName(s.cwdPath);
    final alive = await Tmux.hasSession(name);
    if (!mounted) return;
    if (!alive) {
      setState(() {
        _paneSession = s.cwdPath;
        _paneMissing = true;
        _paneText = null;
      });
      return;
    }
    final text = await Tmux.capturePane(name);
    if (!mounted) return;
    setState(() {
      _paneSession = s.cwdPath;
      _paneMissing = false;
      _paneText = text;
    });
  }

  Widget _placeholderBody(String title, String detail, {Widget? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(color: textDim, fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: textDim, fontSize: 10, height: 1.7),
            ),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
  }

  /// 위젯에서 바로 세션을 띄운다. 터미널로 갈 필요가 없다.
  Future<void> _startSession(AgentSession s) async {
    setState(() => _starting = true);
    final name = Tmux.sessionName(s.cwdPath);
    final ok = await Tmux.startSession(name, s.cwdPath);
    if (!mounted) return;
    setState(() => _starting = false);
    if (!ok) {
      _toast('띄우지 못했다 ($name)');
      return;
    }
    _toast('기동: $name');
    // 클로드가 뜰 때까지 잠깐 기다렸다가 화면을 떠온다.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (mounted) _refreshPane(s);
  }

  /// 입력창에 친 것을 그 프로젝트의 tmux 세션에 넣는다.
  ///
  /// 실제 클로드 세션이 진짜로 움직인다. 세션이 없으면 아무 데도 보내지 않는다.
  Future<void> _sendCommand(AgentSession s, String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    if (Tmux.binary == null) {
      _toast('tmux가 없다 — brew install tmux 후에 쓸 수 있다');
      return;
    }
    final name = Tmux.sessionName(s.cwdPath);
    if (!await Tmux.hasSession(name)) {
      _toast('세션이 없다 ($name) — 터미널에서 cw 로 먼저 기동한다');
      return;
    }
    final ok = await Tmux.sendLine(name, line);
    if (!mounted) return;
    if (!ok) {
      _toast('보내지 못했다 ($name)');
      return;
    }
    _commandInput.clear();
    // 보낸 말을 대화에 남긴다. 탭을 옮기지 않는다 —
    // 메시지 탭에서 주고받는 것이 이 화면의 목적이다.
    widget.store.appendMine(s, line);
    // 보냈으면 뒤지던 자리는 없던 일이 된다. 다음 위 화살표는 방금 보낸
    // 말부터다.
    _histIndex = -1;
    setState(() => _rawTab = false);
    _scrollChatToEnd();
  }

  /// 선택창을 다루는 키들. 숫자 선택은 입력창에 그냥 치면 되고,
  /// 화살표로 옮기는 창은 이 버튼들이 필요하다.
  /// 새 말이 붙으면 아래로 따라 내려간다.
  ///
  /// 한 번으로는 끝까지 못 간다. ListView.builder는 아직 안 그린 줄의 높이를
  /// 어림잡아 두므로 내려가는 동안 maxScrollExtent가 계속 늘어난다.
  /// 그래서 애니메이션이 끝난 뒤 한 번 더 확인하고 남은 만큼 붙인다.
  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_chatScroll.hasClients) return;
      // 그리는 도중 탭을 옮기면 목록이 사라진다. 그때 나는 예외는 삼킨다.
      try {
        await _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        for (var i = 0; i < 3; i++) {
          if (!mounted || !_chatScroll.hasClients) return;
          final end = _chatScroll.position.maxScrollExtent;
          if (_chatScroll.offset >= end - 1) return;
          _chatScroll.jumpTo(end);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      } catch (_) {
        // 목록이 사라진 뒤였다 — 다음 줄이 붙을 때 다시 맞춘다.
      }
    });
  }

  /// 고를 것이 떠 있으면 메시지 아래에 **테두리 있는 박스**로 붙인다.
  ///
  /// 박스로 두르는 이유가 있다. 말풍선과 같은 바탕에 얹으면 대화의 일부처럼
  /// 읽혀서 "지금 내가 답해야 한다"가 안 보인다. 테두리와 머리글이 있어야
  /// 눈이 먼저 간다.
  ///
  /// ⚠️ **캐릭터 상태는 여전히 훅이 정한다.** 여기서 `session.status`를
  /// 건드리지 않는다. 다만 **무엇을 그릴지**는 화면을 봐야 안다 — 슬래시
  /// 명령으로 뜨는 창은 훅이 아예 울리지 않기 때문이다.
  Widget _choiceCard(AgentSession s) {
    if (_paneSession != s.cwdPath || _paneMissing) {
      return const SizedBox.shrink();
    }
    final asking = PaneView.awaitingChoice(_paneText);
    final choice = PaneChoice.parse(_paneText);
    // 승인 대기(훅)거나 화면이 묻고 있으면 띄운다. 둘 다 아니면 안 그린다.
    if (!asking && s.status != AgentStatus.waiting) {
      // 창이 닫혔으면 겨눠 둔 것도 푼다. 다음 창에서 한 번만 눌러도
      // 넘어가 버리면 두 번 묻는 뜻이 없다.
      if (_armedOption != null) {
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => mounted ? setState(() => _armedOption = null) : null);
      }
      return const SizedBox.shrink();
    }
    // 번호 선택창이면 골드, 그 밖에는 보라. 눌러 고를 수 있는지를 색으로 가른다.
    final tone = choice != null ? gold : accent;

    Widget frame(String title, List<Widget> children) => Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.08),
            border: Border.all(color: tone, width: 1.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          color: tone,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  InkWell(
                    onTap: _answering ? null : () => _sendKey(s, 'Escape'),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text('취소 (esc)',
                          style: TextStyle(color: textDim, fontSize: 10)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              ...children,
            ],
          ),
        );

    Widget mono(String line) => Text(
          line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: textPrimary,
            fontSize: 10,
            height: 1.55,
            fontFamily: 'Menlo',
            fontFamilyFallback: ['Monaco', 'Courier New'],
          ),
        );

    // ── 번호로 고르는 창 — 버튼으로 눌러 고른다 ──
    if (choice != null) {
      final multi = choice.multi;
      return frame(
          multi ? '고를 것이 있다 — 여러 개 고를 수 있다' : '고를 것이 있다 — 두 번 눌러서 고른다', [
        // 왜 묻는지가 먼저다. 말풍선은 턴이 끝나야 오르는데 선택창이 뜨면
        // 턴이 거기서 멈춘다 — 이게 없으면 물음만 덩그러니 뜬다.
        if (choice.lead.isNotEmpty) ...[
          _leadText(choice.lead),
          const SizedBox(height: 7),
        ],
        // 무엇을 고르라는 건지가 맨 위에 있어야 한다.
        // 선택지만 늘어놓으면 뭘 묻는 건지 모른 채 누르게 된다.
        if (choice.question != null) ...[
          Text(choice.question!,
              style: const TextStyle(
                  color: textPrimary,
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 9),
        ],
        _choiceGrid(s, choice),
        // 다중 선택창은 숫자가 토글이라 확정을 따로 눌러야 끝난다.
        if (multi) ...[
          const SizedBox(height: 3),
          _submitButton(s, choice),
        ],
        // 창마다 먹는 키가 다르다. 화면이 알려주는 대로 그대로 옮긴다.
        if (choice.hint != null) ...[
          const SizedBox(height: 8),
          Text(choice.hint!,
              style: const TextStyle(color: textDim, fontSize: 10)),
        ],
      ]);
    }

    // ── 좌우로 옮겨 고르는 창 — 눌러서 옮기고, 확정은 따로 ──
    final slider = PaneSlider.parse(_paneText);
    if (slider != null) return _sliderBox(s, slider, frame);

    // ── 그 밖 — 화면만 보여준다. 눌러 고를 것이 없다 ──
    final lines = PaneView.activity(_paneText, max: 5);
    if (lines.isEmpty) return const SizedBox.shrink();
    return frame('고를 것이 있다 — 터미널 원본 탭에서 고른다', [
      for (final line in lines) mono(line),
    ]);
  }

  /// 선택지를 **가로로 편다.** 폭이 남으면 두세 개씩 한 줄에 놓는다.
  ///
  /// ⚠️ **세로로만 쌓으면 앞말이 화면 밖으로 밀린다.** 앞말에는 클로드가 그려 준
  /// 표가 들어 있는 일이 잦은데(무엇을 고를지 판단하는 근거가 거기 있다),
  /// 선택지 다섯 개가 한 줄씩 차지하면 카드가 세로로 길어져 그 표가 안 보였다 —
  /// 동현동현이 지적한 자리다(2026-08-31). 펼침 패널은 가로가 넉넉하다.
  ///
  /// ⚠️ **한 줄 안에서는 키를 맞춘다**(`IntrinsicHeight`). 설명 길이가 제각각이라
  /// 그냥 두면 카드 아래가 들쭉날쭉해서 표처럼 안 읽힌다.
  Widget _choiceGrid(AgentSession s, PaneChoice c) {
    return LayoutBuilder(builder: (context, box) {
      // 좁은 창(접힘·작은 화면)에서는 예전처럼 한 줄에 하나다. 억지로 나누면
      // 글자가 두 자마다 잘려서 무엇을 고르는 건지 알 수 없다.
      final cols = box.maxWidth >= 1080 ? 3 : (box.maxWidth >= 640 ? 2 : 1);
      if (cols == 1) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final o in c.options) _choiceButton(s, o)],
        );
      }
      final rows = <Widget>[];
      for (var i = 0; i < c.options.length; i += cols) {
        final slice = c.options.skip(i).take(cols).toList();
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) const SizedBox(width: 6),
                // 마지막 줄이 덜 찼으면 빈 자리로 둔다. 남은 것을 늘려
                // 채우면 같은 선택지가 줄마다 다른 크기로 보인다.
                Expanded(
                  child: j < slice.length
                      ? _choiceButton(s, slice[j], wide: true)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      );
    });
  }

  /// 묻기 직전에 한 말. **터미널에 있던 모양 그대로 그린다.**
  ///
  /// ⚠️ **고정폭 글꼴이라야 표가 선다.** 앞말은 터미널 화면에서 떠온 것이고,
  /// 거기서 표는 글자 폭이 모두 같다는 전제로 공백을 세어 칸을 맞춘 것이다.
  /// 일반 글꼴로 그리면 공백을 아무리 지켜도 칸이 어긋난다.
  ///
  /// ⚠️ **줄바꿈하지 않고 옆으로 넘긴다.** 표 한 줄이 접히면 아래 줄과
  /// 어긋나서 표가 아니게 된다. 넘치면 가로로 미는 편이 읽을 수 있다.
  Widget _leadText(List<String> lead) {
    return ScrollConfiguration(
      // 가로 스크롤바가 늘 떠 있으면 두 줄짜리 앞말에도 자리를 먹는다.
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          lead.join('\n'),
          softWrap: false,
          style: const TextStyle(
            color: textBody,
            fontSize: 11,
            height: 1.45,
            fontFamily: 'Menlo',
            // ⚠️ **한글 칸은 딱 맞지 않는다.** 터미널은 한글을 두 칸으로 세는데
            // macOS에 기본으로 깔린 고정폭 글꼴에는 한글이 없어, 한글은 다른
            // 글꼴로 떨어지면서 딱 두 칸이 아닌 폭으로 그려진다. 숫자·영문
            // 칸은 정확히 맞고 한글이 든 칸만 조금 밀린다.
            // `D2Coding`을 깔면 그때는 딱 맞는다 — 미리 적어 둔다.
            fontFamilyFallback: [
              'D2Coding',
              'NanumGothicCoding',
              'Monaco',
              'Courier New',
            ],
          ),
        ),
      ),
    );
  }

  Widget _choiceButton(AgentSession s, PaneOption o, {bool wide = false}) {
    // 한 번 눌러 겨눈 것. 한 번 더 눌러야 실제로 넘어간다.
    final armed = _armedOption == o.number;
    // ⚠️ **터미널 커서(`❯ 1.`) 자리는 칠하지 않는다.**
    //
    // 예전에는 커서가 놓인 것을 골드로 칠했다. 화살표로 옮기던 때는 그게
    // 화면과 눈을 맞추는 표시였는데, 눌러서 고르는 지금은 **이미 하나가
    // 골라진 것처럼** 보인다. 게다가 겨눈 것(보라)과 표시가 둘로 갈려
    // 어느 쪽이 내 선택인지 헷갈린다.
    //
    // 숫자를 보내면 커서 자리와 상관없이 그 번호가 골라지므로, 커서 자리는
    // 누르는 사람에게 아무 뜻이 없다.
    // 체크박스가 붙은 줄은 **한 번 누르면 바로 켜고 꺼진다.**
    // 겨누기-확정을 두는 이유는 되돌리기 어려워서인데, 토글은 다시 누르면
    // 그만이다. 되돌릴 수 없는 자리는 그 다음의 `확정`(+ 검토 화면)이다.
    final line = armed ? accent : (o.checked == true ? gold : borderCol);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: InkWell(
        onTap: _answering
            ? null
            : () => o.checkable ? _toggleOption(s, o) : _tapOption(s, o),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: armed ? accent.withValues(alpha: 0.25) : bgMid,
            border: Border.all(color: line, width: armed ? 1.5 : 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text('${o.number}',
                    style: TextStyle(
                        color: armed ? accent : textDim,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 9),
              // 켜진 것을 글자 색만으로 가르지 않는다 — 색을 잘 못 가리는
              // 눈에는 안 켜진 것과 다를 바가 없다. 모양으로도 갈라준다.
              if (o.checkable) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(o.checked! ? '☑' : '☐',
                      style: TextStyle(
                          color: o.checked! ? gold : textDim, fontSize: 12)),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.text,
                        // 가로로 놓이면 한 칸이 좁아진다. 두 줄로 자르면
                        // 무엇을 고르는 건지 앞머리만 보인다.
                        maxLines: wide ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: textPrimary, fontSize: 11.5, height: 1.3)),
                    // 설명이 있어야 무엇을 고르는 건지 알 수 있는 창이 있다.
                    if (o.detail != null) ...[
                      const SizedBox(height: 3),
                      Text(o.detail!,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: textBody, fontSize: 10.5, height: 1.4)),
                    ],
                  ],
                ),
              ),
              if (armed) ...[
                const SizedBox(width: 8),
                const Text('한 번 더',
                    style: TextStyle(
                        color: accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 좌우 슬라이더를 버튼으로 그린다.
  ///
  /// **누르면 옮기기만 하고 확정은 따로 한다.** 화살표를 몇 번 보내는지는
  /// 칸 계산으로 어림잡는 것이라 어긋날 수 있다. 옮긴 결과가 화면에 다시
  /// 떠오르므로, 사람이 `▲` 가 제대로 갔는지 보고 확정하는 편이 안전하다.
  Widget _sliderBox(AgentSession s, PaneSlider sl,
      Widget Function(String, List<Widget>) frame) {
    return frame(
      sl.title == null ? '고를 것이 있다' : '고를 것이 있다 — ${sl.title}',
      [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < sl.options.length; i++)
              _sliderOption(s, sl, i),
          ],
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            InkWell(
              onTap: _answering ? null : () => _sendKey(s, 'Enter'),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.3),
                  border: Border.all(color: accent),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('이걸로 확정',
                    style: TextStyle(
                        color: textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                sl.hint ?? '눌러서 옮기고 확정한다',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: textDim, fontSize: 10),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sliderOption(AgentSession s, PaneSlider sl, int i) {
    final here = i == sl.current;
    return InkWell(
      onTap: _answering || here ? null : () => _slideTo(s, sl, i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: here ? accent.withValues(alpha: 0.3) : bgMid,
          border: Border.all(color: here ? accent : borderCol),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          sl.options[i],
          style: TextStyle(
            color: here ? textPrimary : textDim,
            fontSize: 11,
            fontWeight: here ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 고른 자리까지 화살표를 대신 보낸다. **Enter는 안 보낸다.**
  Future<void> _slideTo(AgentSession s, PaneSlider sl, int target) async {
    if (target == sl.current || !mounted) return;
    setState(() => _answering = true);
    String? error;
    try {
      error = await PaneActions.slide(s.cwdPath, target, label: sl.options[target]);
    } finally {
      if (mounted) setState(() => _answering = false);
    }
    if (error != null) _toast(error);
    if (mounted) _refreshPane(s);
  }

  /// 다중 선택창의 확정 버튼.
  ///
  /// ⚠️ **여기서 겨누기-확정을 두지 않는다.** 누르면 곧바로 터미널의
  /// `Review your answers` 화면이 뜨고, 그게 `1. Submit answers / 2. Cancel`
  /// 이라 선택 카드에 그대로 다시 뜬다 — 되돌릴 수 없는 자리는 거기다.
  /// 여기까지 두 번 누르게 하면 한 번 고르는 데 네 번을 눌러야 한다.
  ///
  /// **문항이 여럿이면 이 버튼이 `다음 문항으로`가 된다**(실측 2026-08-31).
  /// 화면의 그 줄이 `Submit`이 아니라 `Next`이고, 눌러도 안 끝나고 다음 문항이
  /// 뜬다. 끝나는 것처럼 적어 두면 누르기 전에 무슨 일이 일어날지 알 수 없다.
  Widget _submitButton(AgentSession s, PaneChoice c) {
    final n = c.checkedOptions.length;
    // 커서가 어디 있는지 못 읽으면 몇 칸 내려야 할지도 모른다. 그때는
    // 엉뚱한 줄에서 Enter를 치느니 안 눌리게 두고 원본 탭으로 보낸다.
    final can = c.toSubmit != null && !_answering;
    return InkWell(
      onTap: can ? () => _submitMulti(s) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: can ? gold.withValues(alpha: 0.18) : bgMid,
          border: Border.all(color: can ? gold : borderCol, width: 1.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          c.toSubmit == null
              ? '확정은 터미널 원본 탭에서 (커서를 못 읽었다)'
              : c.isNext
                  ? (n == 0 ? '아무것도 안 고르고 다음 문항으로' : '다음 문항으로 · $n개')
                  : n == 0
                      ? '아무것도 안 고르고 넘기기'
                      : '이걸로 확정 · $n개',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: can ? gold : textDim,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// 체크박스 하나를 켜고 끈다. **숫자를 보내면 토글된다** (실측 2026-08-11).
  ///
  /// 켜졌는지는 앱이 따로 기억하지 않고 **화면을 다시 떠와서** 읽는다.
  /// 터미널에서 직접 누른 것도 있을 수 있어, 화면이 늘 진짜다.
  Future<void> _toggleOption(AgentSession s, PaneOption o) async {
    if (!mounted) return;
    // 다른 것을 겨눠 뒀다면 푼다. 체크는 겨누기 없이 바로 먹는다.
    setState(() {
      _armedOption = null;
      _answering = true;
    });
    String? error;
    try {
      error = await PaneActions.toggle(s.cwdPath, o.number, text: o.text);
    } finally {
      if (mounted) setState(() => _answering = false);
    }
    if (error != null) _toast(error);
    if (mounted) _refreshPane(s);
  }

  /// 다중 선택창을 확정한다 — `Submit` 줄까지 커서를 옮기고 Enter다.
  ///
  /// **문항이 여럿이면 이 한 번으로 안 끝난다.** 그 줄이 `Next`라 Enter를 치면
  /// 다음 문항이 뜨고, 카드가 그걸 다시 그린다. 마지막 문항에서만 `Submit`이다.
  ///
  /// ⚠️ **몇 칸 옮겼는지를 믿지 않는다.** 옮긴 뒤 화면을 다시 떠서 커서가
  /// 정말 그 줄에 있을 때만 Enter를 친다. 한 칸이라도 어긋나면 엉뚱한
  /// 것을 켜거나(선택지 위에서 Enter는 토글이다) `Chat about this` 로
  /// 새어 나간다 — 바로 아래에 그게 있다(실측 2026-08-11).
  Future<void> _submitMulti(AgentSession s) async {
    if (!mounted) return;
    setState(() => _answering = true);
    ({String? error, String? said}) r;
    try {
      r = await PaneActions.submit(s.cwdPath);
    } finally {
      if (mounted) setState(() => _answering = false);
    }
    if (r.error != null) _toast(r.error!);
    if (!mounted || r.said == null) return;
    // 무엇을 골랐는지 대화에도 남긴다. 나중에 되짚을 수 있어야 한다.
    widget.store.appendMine(s, r.said!, chose: true);
    _refreshPane(s);
  }

  /// 선택지를 누른다. **한 번은 겨누기, 두 번째가 확정이다.**
  ///
  /// 한 번에 확정되면 스치듯 눌린 것도 그대로 답이 된다. 승인·신뢰 확인처럼
  /// 되돌리기 어려운 것이 섞여 있어 한 번 더 묻는다.
  /// 겹쳐 누르면(더블클릭) 두 번으로 세어 그대로 넘어간다.
  void _tapOption(AgentSession s, PaneOption o) {
    if (_armedOption != o.number) {
      setState(() => _armedOption = o.number);
      return;
    }
    setState(() => _armedOption = null);
    _answerChoice(s, o);
  }

  /// 선택지 하나를 고른다.
  ///
  /// 숫자를 치면 그 자리에서 확정되는 창이 대부분이지만 커서만 옮기고 마는
  /// 창도 있다. 그래서 보낸 뒤 화면을 다시 떠와 **아직 남아 있을 때만** Enter를
  /// 더 보낸다. 무턱대고 붙이면 이미 확정된 뒤의 입력창에 빈 줄이 들어간다.
  Future<void> _answerChoice(AgentSession s, PaneOption o) async {
    if (!mounted) return;
    setState(() => _answering = true);
    ({String? error, String? said}) r;
    try {
      r = await PaneActions.choose(s.cwdPath, o.number, text: o.text);
    } finally {
      if (mounted) setState(() => _answering = false);
    }
    if (r.error != null) _toast(r.error!);
    if (!mounted || r.said == null) return;
    // 고른 것을 대화에도 남긴다. 나중에 무엇을 승인했는지 되짚을 수 있어야 한다.
    widget.store.appendMine(s, r.said!, chose: true);
    _refreshPane(s);
  }

  /// 선택창용 키 한 번. 누른 뒤 화면을 바로 떠와 결과를 보여준다.
  ///
  /// ⚠️ **탭을 옮기지 않는다.** 예전에는 누를 때마다 원본 탭으로 끌고 갔는데,
  /// 보내기(`⏎`)를 누른 것뿐인데 화면이 통째로 바뀌어 읽던 자리를 잃는다.
  /// 결과는 화면을 다시 떠오는 것으로 충분하다 — 선택 카드가 그걸 읽고,
  /// 원본 탭에 가면 이미 최신이다.
  Future<void> _sendKey(AgentSession s, String key) async {
    final name = Tmux.sessionName(s.cwdPath);
    if (!await Tmux.hasSession(name)) {
      _toast('세션이 없다 ($name)');
      return;
    }
    await Tmux.sendKey(name, key);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) _refreshPane(s);
  }

  /// 돌아가는 작업을 멈춘다 — 터미널의 `esc` 다.
  ///
  /// 엉뚱한 걸 시켰을 때 터미널로 건너가야 했던 것이 이걸로 없어진다.
  /// 작업 중일 때만 보인다(스트립 자체가 그렇다).
  ///
  /// ⚠️ **겨누기-확정을 두지 않는다.** 선택 카드가 두 번 눌러 고르게 하는
  /// 것은 승인처럼 되돌리기 어려운 것이 섞여 있기 때문이다. 멈추기는
  /// 되돌릴 수 없는 일이 아니고(다시 시키면 된다), 멈추고 싶을 때는
  /// 급한 법이라 두 번 누르게 하면 그게 더 답답하다.
  ///
  /// ⚠️ **키를 늘어놓지 않는다.** 메시지 탭은 누를 수 있는 것만 누르는
  /// 자리다. `esc`가 아니라 '멈추기'라는 행동 하나로만 드러낸다.
  Widget _stopButton(AgentSession s) {
    final busy = _stopping;
    return MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: busy ? null : () => _stop(s),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(
                color: danger.withValues(alpha: busy ? 0.3 : 0.75), width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            busy ? '멈추는 중' : '멈추기',
            style: TextStyle(
              color: danger.withValues(alpha: busy ? 0.4 : 1.0),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// 직전 턴으로 되돌린다 — 터미널의 `Esc` 두 번이다.
  ///
  /// ⚠️ **한 번은 겨누기, 두 번째가 확정이다.** 선택 카드와 같은 규칙을 쓴다.
  /// 되돌리기는 방금 한 일을 무르는 것이라 스치듯 눌린 것이 그대로 실행되면
  /// 곤란하다. 멈추기(A2)가 한 번에 먹는 것과는 성격이 다르다 — 멈추기는
  /// 다시 시키면 그만이지만 이건 되짚어 가는 것이다.
  ///
  /// 겨눈 채로 4초가 지나면 저절로 풀린다. 눌러 놓고 잊어버린 것이
  /// 한참 뒤에 확정되면 안 된다.
  Widget _rewindButton(AgentSession s) {
    final armed = _rewindArmed;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: armed ? '한 번 더 누르면 되돌린다' : '직전 턴으로 되돌리기 (esc esc)',
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _rewind(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: armed ? accent.withValues(alpha: 0.25) : null,
                border: Border.all(
                    color: armed ? accent : textDim.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                armed ? '↶ 한 번 더' : '↶ 되돌리기',
                style: TextStyle(
                  color: armed ? textPrimary : textDim,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rewind(AgentSession s) async {
    if (!_rewindArmed) {
      setState(() => _rewindArmed = true);
      _rewindDisarm?.cancel();
      _rewindDisarm = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _rewindArmed = false);
      });
      return;
    }
    _rewindDisarm?.cancel();
    setState(() => _rewindArmed = false);

    final name = Tmux.sessionName(s.cwdPath);
    if (!await Tmux.hasSession(name)) {
      _toast('세션이 없다 ($name)');
      return;
    }
    // 두 번을 잇달아 보낸다. 붙여서 보내면 한 번으로 먹힐 수 있어 사이를 둔다.
    await Tmux.sendKey(name, 'Escape');
    await Future<void>.delayed(const Duration(milliseconds: 140));
    await Tmux.sendKey(name, 'Escape');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) _refreshPane(s);
  }

  /// 지금 권한 모드를 내걸고, 눌러서 돌린다 — 터미널의 `shift+tab` 이다.
  ///
  /// 이 세션이 승인을 건너뛰는 상태인지 계획 모드인지는 훅이 알려주지 않는다.
  /// 화면에만 있으므로 상태바에서 읽는다([PaneView.mode]).
  ///
  /// ⚠️ **키를 늘어놓는 것이 아니라 상태를 눌러 바꾸는 모양이다.** 메시지
  /// 탭에 `shift+tab` 버튼을 두면 키보드 흉내가 되지만, 지금 모드를 내걸고
  /// 그걸 누르게 하면 읽는 것과 바꾸는 것이 한자리에 있다.
  ///
  /// 겨누기-확정을 두지 않는다. 잘못 눌러도 다시 눌러 돌리면 되고, 바뀐
  /// 결과가 곧바로 이 칩에 나타난다.
  Widget _modeChip(AgentSession s) {
    final mode = _paneSession == s.cwdPath && !_paneMissing
        ? PaneView.mode(_paneText)
        : null;
    // 기본 모드에서는 상태바에 아무것도 없다. 없는 것을 지어내지 않는다.
    if (mode == null) return const SizedBox.shrink();

    final plan = mode.contains('plan');
    final color = plan ? accent : gold;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: '눌러서 권한 모드를 돌린다 (shift+tab)',
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _cycling ? null : () => _cycleMode(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(
                    color: color.withValues(alpha: _cycling ? 0.3 : 0.7)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                mode,
                style: TextStyle(
                  color: color.withValues(alpha: _cycling ? 0.4 : 1.0),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cycleMode(AgentSession s) async {
    if (_cycling) return;
    setState(() => _cycling = true);
    try {
      // tmux는 shift+tab을 BTab(back-tab)이라 부른다.
      await _sendKey(s, 'BTab');
    } finally {
      if (mounted) setState(() => _cycling = false);
    }
  }

  /// 전에 보낸 말을 입력창에 도로 꺼낸다 — 터미널의 위 화살표다.
  ///
  /// **따로 히스토리를 들지 않는다.** 대화에 쌓인 `[나]` 말풍선이 곧
  /// 히스토리다. 디스크에도 남으므로 앱을 껐다 켜도 이어지고, 터미널에서
  /// 친 말(A1)까지 함께 나온다 — 실제로 내가 보낸 말이니 그게 맞다.
  ///
  /// [delta]가 -1이면 과거로, 1이면 현재로 온다.
  bool _stepHistory(AgentSession s, int delta) {
    // 캐릭터를 옮겼으면 그 세션의 처음부터 뒤진다.
    if (_histSession != s.cwdPath) {
      _histIndex = -1;
      _histSession = s.cwdPath;
    }
    final items = [
      for (final e in s.chat)
        if (e.mine && e.text.trim().isNotEmpty) e.text
    ];
    if (items.isEmpty) return false;

    var index = _histIndex;
    if (index < 0) {
      // 뒤지기 시작한다. 쓰던 글을 챙겨 두고 목록 끝(=현재)에 선다.
      _histDraft = _commandInput.text;
      index = items.length;
    }
    final next = index + delta;
    if (next < 0) return true; // 맨 위. 더 갈 데가 없어도 키는 먹은 것으로 둔다
    if (next >= items.length) {
      // 끝까지 내려왔다. 뒤지기 전에 쓰던 글로 돌려준다.
      setState(() => _histIndex = -1);
      _fillInput(_histDraft);
      return true;
    }
    setState(() => _histIndex = next);
    _fillInput(items[next]);
    return true;
  }

  /// 입력창을 갈아끼우고 커서를 맨 뒤에 둔다.
  ///
  /// ⚠️ 이건 **위젯이** 갈아끼우는 것이라 히스토리 자리를 흐트러뜨리지 않는다.
  /// 사람이 직접 친 것과 구분하려고 잠깐 표시를 세운다.
  void _fillInput(String text) {
    _fillingInput = true;
    _commandInput.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _fillingInput = false;
  }

  Future<void> _stop(AgentSession s) async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await _sendKey(s, 'Escape');
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  /// 입력창에 `/`를 치면 자주 쓰는 명령을 추려 내건다.
  ///
  /// 슬래시 명령은 지금도 쳐서 보낼 수 있었다. 다만 무엇이 있는지 모르고,
  /// 오타가 나면 그 글자가 그냥 프롬프트로 들어간다.
  ///
  /// 고르면 입력창에 채우기만 하고 **보내지는 않는다.** 인자를 더 붙일
  /// 것이 있고(`/model opus`), 무엇이 들어갈지 눈으로 보고 Enter를 치는
  /// 편이 안전하다.
  Widget _slashMenu(AgentSession s) {
    final items = matchSlash(_commandInput.text);
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 190),
      decoration: BoxDecoration(
        color: bgMid,
        border: Border.all(color: accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final c in items)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _fillInput('${c.name} '),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Row(
                    children: [
                      Text(c.name,
                          style: const TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Menlo',
                          )),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(c.hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: textDim, fontSize: 10)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _onInputChanged() {
    // ⚠️ **사람이 직접 고치면 히스토리에서 빠져나온다.** 뒤지다 만 자리가
    // 남아 있으면, 그 뒤에 새로 쓴 글에서 위 화살표를 눌렀을 때 커서가
    // 움직이지 않고 히스토리로 들어간다. 실제로 걸렸다(2026-08-07 QA).
    if (!_fillingInput && _histIndex >= 0) _histIndex = -1;
    final text = _commandInput.text;
    final show = matchSlash(text).isNotEmpty;
    final token = atToken(text);
    if (token != null) _ensureFiles();
    if (show || _slashShown || token != null || _atShown) {
      if (mounted) {
        setState(() {
          _slashShown = show;
          _atShown = token != null;
        });
      }
    }
  }

  /// 지금 펼쳐 둔 세션의 파일 목록을 챙긴다. 캐시가 살아 있으면 곧 돌아온다.
  Future<void> _ensureFiles() async {
    final path = _selectedPath;
    if (path == null || _atLoadedFor == path) return;
    final files = await FileIndex.list(path);
    if (!mounted) return;
    setState(() {
      _atFiles = files;
      _atLoadedFor = path;
    });
  }

  /// `@`를 치면 그 세션 폴더의 파일을 추려 내건다.
  ///
  /// 터미널은 `@`로 파일을 골라 넣는데 위젯은 경로를 통째로 외워 쳐야 했다.
  ///
  /// 고르면 `@경로 `로 채우기만 하고 보내지 않는다 — 파일을 집은 뒤에
  /// 무엇을 시킬지 마저 써야 한다.
  Widget _atMenu(AgentSession s) {
    final token = atToken(_commandInput.text);
    if (token == null) return const SizedBox.shrink();
    final items = matchFiles(_atFiles, token);
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 190),
      decoration: BoxDecoration(
        color: bgMid,
        border: Border.all(color: gold.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final f in items)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  final text = _commandInput.text;
                  final at = text.lastIndexOf('@');
                  _fillInput('${text.substring(0, at)}@$f ');
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Text(
                    f,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 끌어다 놓은 파일을 `@경로`로 입력창에 박는다.
  ///
  /// `@`를 치고 목록에서 고르는 것(A8)보다 손이 덜 간다. 파인더에서 보고
  /// 있는 것을 그대로 끌어다 놓으면 된다.
  ///
  /// 커서는 **박은 것 뒤에** 둔다. 그래야 `@lib/main.dart 이거 고쳐줘`처럼
  /// 바로 이어 쓸 수 있다 — 파일만 넣고 끝낼 일은 거의 없다.
  /// 클립보드의 그림을 파일로 떠서 `@경로`로 박는다.
  ///
  /// 스크린샷을 찍어 저장하고 파인더에서 끌어다 놓는 세 번의 손이 한 번이 된다.
  /// 화면을 두고 이야기할 일이 잦아서 이 차이가 크다.
  ///
  /// 끌어다 놓기와 **같은 자리로 들어간다**(`_dropFiles`) — 커서도 박은 것 뒤에
  /// 오므로 `@그림 이거 봐줘`처럼 바로 이어 쓸 수 있다.
  Future<void> _pasteImage(AgentSession s) async {
    final path = await ClipboardImage.save();
    // 그림이 아니면 아무 일도 안 한다. 글자는 기본 붙여넣기가 이미 넣었다.
    if (path == null || !mounted) return;
    _dropFiles(s, [path]);
    _toast('그림을 붙였다');
  }

  void _dropFiles(AgentSession s, List<String> paths) {
    if (paths.isEmpty) return;
    final tokens = paths.map((p) => dropToken(p, s.cwdPath)).join(' ');
    final before = _commandInput.text;
    // 이미 쓰던 글이 있으면 그 뒤에 띄어서 붙인다. 지우지 않는다.
    final joined = before.isEmpty
        ? '$tokens '
        : (before.endsWith(' ') ? '$before$tokens ' : '$before $tokens ');
    _fillInput(joined);
    // 놓자마자 이어 쓸 수 있게 입력창으로 초점을 옮긴다.
    _commandFocus.requestFocus();
  }

  Widget _commandBar(AgentSession s) {
    return DropTarget(
      onDragDone: (detail) =>
          _dropFiles(s, detail.files.map((f) => f.path).toList()),
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      child: Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
      decoration: BoxDecoration(
        // 끌고 들어오면 여기 놓으라고 알려준다. 아무 표시가 없으면 놓아도
        // 되는 자리인지 몰라 도로 가져간다.
        color: _dropping ? accent.withValues(alpha: 0.15) : null,
        border: Border(
          top: BorderSide(color: _dropping ? accent : borderCol),
        ),
      ),
      child: Row(
        children: [
          const Text('나', style: TextStyle(color: textDim, fontSize: 9)),
          const SizedBox(width: 8),
          Expanded(
            // ⚠️ `onSubmitted`는 여러 줄 입력창에서 불리지 않는다. 그래서 Enter를
            // 여기서 직접 가른다 — 그냥 Enter는 보내기, Shift+Enter는 줄바꿈이다.
            // 터미널에서 몸에 밴 것과 같은 손이라 따로 배울 것이 없다.
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                // ⌘V — 클립보드에 그림이 있으면 파일로 떠서 경로를 박는다.
                //
                // ⚠️ **막지 않고 지나 보낸다.** 클립보드를 읽는 것은 비동기인데
                // 여기서는 바로 답해야 한다. 그림만 들어 있으면 기본 붙여넣기가
                // 넣을 글자가 없어 아무 일도 안 일어나고, 글자가 들어 있으면
                // 평소대로 붙는다. 어느 쪽이든 어긋나지 않는다.
                if (event.logicalKey == LogicalKeyboardKey.keyV &&
                    HardwareKeyboard.instance.isMetaPressed) {
                  unawaited(_pasteImage(s));
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey != LogicalKeyboardKey.enter &&
                    event.logicalKey != LogicalKeyboardKey.numpadEnter) {
                  return KeyEventResult.ignored;
                }
                // Shift를 잡고 있으면 줄바꿈이다. 기본 동작에 맡긴다.
                if (HardwareKeyboard.instance.isShiftPressed) {
                  return KeyEventResult.ignored;
                }
                _sendCommand(s, _commandInput.text);
                return KeyEventResult.handled;
              },
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent &&
                      event is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
                  final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
                  if (!up && !down) return KeyEventResult.ignored;
                  // ⚠️ **여러 줄이면 위아래는 커서 이동이다.** 쓰던 글 안에서
                  // 못 다니면 A3(여러 줄)이 무용지물이 된다.
                  //
                  // 예전에는 '글자가 있으면 히스토리로 안 간다'로 갈랐는데,
                  // 그러면 한 줄만 쳐 둔 흔한 경우에도 히스토리를 못 쓴다.
                  // 터미널은 그때 히스토리로 간다. 가를 것은 글자의 유무가
                  // 아니라 **여러 줄인가**다.
                  if (_commandInput.text.contains('\n')) {
                    return KeyEventResult.ignored;
                  }
                  // 아래 화살표는 뒤지던 중일 때만 뜻이 있다. 그냥 누르면
                  // 커서가 움직여야 한다.
                  if (down && _histIndex < 0) return KeyEventResult.ignored;
                  return _stepHistory(s, up ? -1 : 1)
                      ? KeyEventResult.handled
                      : KeyEventResult.ignored;
              },
              child: TextField(
                controller: _commandInput,
                focusNode: _commandFocus,
                style: const TextStyle(color: textPrimary, fontSize: 12),
                cursorColor: accent,
                // 여러 줄을 받되 끝없이 자라지 않게 한다. 넘으면 안에서 스크롤된다.
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '메시지 보내기 · 줄바꿈은 Shift+Enter',
                  hintStyle: TextStyle(color: textDim, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: '보내기',
            waitDuration: const Duration(milliseconds: 400),
            child: InkWell(
              onTap: () => _sendCommand(s, _commandInput.text),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.25),
                  border: Border.all(color: accent),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text('↩',
                    style: TextStyle(color: textPrimary, fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ── 책상뷰 ──────────────────────────────────────────────

  // 캐릭터 한 칸의 폭. 구역 폭을 계산할 때도 이 값을 쓴다.
  static const double kSlotWidth = 66;
  /// 접힌 화면에서 할 일 패널 폭. 좁게 둔다 — 위젯이지 할 일 앱이 아니다.
  static const double kTodoPanelWidth = 210;

  // 구역 사이 칸막이 두께(여백 포함).
  static const double kPartition = 14;

  /// 창을 몇 칸으로 넓혀야 하는지. 구역이 늘면 옆으로 길어진다.
  double get _deskWidth {
    final groups = widget.store.floors;
    if (groups.isEmpty) return kCollapsedSize.width;
    var w = 16.0;
    for (final g in groups) {
      w += g.sessions.length * kSlotWidth + kPartition;
    }
    return w.clamp(kCollapsedSize.width, 900.0).toDouble();
  }

  // ── 할 일 패널 ──────────────────────────────────────────
  //
  // 노션을 부르지 않는다. 로컬 JSON 하나라 배포해도 그대로 돈다.
  //
  // ⚠️ **할 일 앱을 만드는 게 아니다.** 그런 건 세상에 널렸고 이 위젯이
  // 그걸로는 못 이긴다. 이 앱만 할 수 있는 것은 **적어둔 할 일을 그
  // 프로젝트의 클로드에게 바로 시키는 것**이다. 그래서 [시키기]가 중심이고,
  // 나머지(기한·태그·정렬)는 일부러 안 붙인다.

  /// 지금 책상에 선 순서대로 묶는다.
  ///
  /// ⚠️ **등록이 풀린 프로젝트의 할 일은 그리지 않되 파일에서 지우지도
  /// 않는다.** 잠깐 빼둔 것뿐일 수 있는데 적어둔 것까지 날리면 곤란하다.
  List<MapEntry<String, List<TodoItem>>> get _todoGroups {
    final out = <MapEntry<String, List<TodoItem>>>[];
    for (final s in widget.store.sessions) {
      final items = widget.todos.of(s.cwdPath);
      if (items.isEmpty) continue;
      out.add(MapEntry(s.cwdPath, items));
    }
    return out;
  }

  String _todoName(String cwdPath) => widget.store.sessions
      .where((s) => s.cwdPath == cwdPath)
      .map((s) => s.name)
      .firstOrNull ??
      cwdPath.split('/').last;


  Widget _todoPanel() {
    final groups = _todoGroups;
    final left = widget.todos.remaining;
    return Container(
      decoration: BoxDecoration(
        color: bgDark.withValues(alpha: 0.92),
        border: Border(right: BorderSide(color: borderCol.withValues(alpha: 0.8))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                const Text('할 일',
                    style: TextStyle(
                        color: textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                if (left > 0)
                  Text('$left',
                      style: const TextStyle(color: accent, fontSize: 10)),
                const Spacer(),
                // 폰에서 열 주소를 넘겨준다. 열쇠가 붙은 긴 주소라 사람이
                // 옮겨 적을 수 없으므로 복사해 준다.
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _copyPhoneUrl,
                    child: Tooltip(
                      message: '폰에서 열 주소를 복사한다',
                      child: Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: borderCol.withValues(alpha: 0.9)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('폰',
                            style:
                                TextStyle(color: textDim, fontSize: 9)),
                      ),
                    ),
                  ),
                ),
                // 좁은 패널에서 다 못 보는 것을 넓게 펴 본다. 여기서 창을
                // 만들지 않고 브라우저에게 맡긴다 — 창 관리가 공짜다.
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _openTodoPage,
                    child: Tooltip(
                      message: '브라우저에서 넓게 보기',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: borderCol.withValues(alpha: 0.9)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('넓게',
                            style:
                                TextStyle(color: textDim, fontSize: 9)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: groups.isEmpty
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(10, 4, 10, 0),
                    child: Text(
                      '아래에 적으면\n여기 쌓인다.\n\n적어둔 것은\n눌러서 바로\n시킬 수 있다.',
                      style: TextStyle(
                          color: textDim, fontSize: 10, height: 1.6),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 6),
                    children: [
                      for (final g in groups) ...[
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(10, 6, 8, 3),
                          child: Text(
                            _todoName(g.key),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: textDim,
                                fontSize: 9,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        for (final item in g.value) _todoRow(g.key, item),
                      ],
                    ],
                  ),
          ),
          _todoComposer(),
        ],
      ),
    );
  }

  Widget _todoRow(String cwdPath, TodoItem item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 6, 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 체크는 되돌리기 쉬우므로 한 번에 먹는다. 겨누기를 두지 않는다.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _toggleTodo(cwdPath, item),
              child: Padding(
                padding: const EdgeInsets.only(top: 1, right: 5),
                child: Text(item.done ? '☑' : '☐',
                    style: TextStyle(
                        color: item.done ? textDim : accent, fontSize: 11)),
              ),
            ),
          ),
          // ⚠️ 210px에 다섯 필드를 다 밀어 넣지 않는다. 여기는 **한눈에**
          // 보는 자리라 작업명이 먼저고, 상태·시간은 안 붙어 있으면 뜻이
          // 달라지는 것(진행중·확인필요)만 꼬리표로 붙인다. 프로젝트는
          // 이미 위에 이름표가 서 있고, 본문은 브라우저에서 본다.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.urgent ? '🔥 ${item.text}' : item.text,
                  style: TextStyle(
                    color: item.done ? textDim : textPrimary,
                    fontSize: 10,
                    height: 1.4,
                    decoration: item.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                Builder(builder: (_) {
                  final now = DateTime.now();
                  final marks = [
                    if (item.status != TaskStatus.waiting) item.status.label,
                    if (item.due != null) formatDue(item.due!, now),
                    if (item.spentAt(now) > 0) formatSpent(item.spentAt(now)),
                  ];
                  if (marks.isEmpty) return const SizedBox.shrink();
                  // 지난 마감이 가장 급한 소식이라 색을 가져간다.
                  return Text(
                    marks.join(' · '),
                    style: TextStyle(
                      color: item.overdue(now)
                          ? const Color(0xFFE74C3C)
                          : (item.status == TaskStatus.review
                              ? gold
                              : (item.ticking ? accent : textDim)),
                      fontSize: 8,
                      height: 1.3,
                    ),
                  );
                }),
              ],
            ),
          ),
          // ⚠️ 이게 이 패널의 이유다 — 적은 자리에서 바로 시킨다.
          if (!item.done && item.assignee != kOwnerAssignee)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _sendTodo(cwdPath, item),
                child: Container(
                  margin: const EdgeInsets.only(left: 4, top: 1),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: accent.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text('시키기',
                      style: TextStyle(color: accent, fontSize: 8)),
                ),
              ),
            ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _removeTodo(cwdPath, item),
              child: const Padding(
                padding: EdgeInsets.only(left: 4, top: 1),
                child: Text('✕',
                    style: TextStyle(color: textDim, fontSize: 9)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 어느 프로젝트에 적을지 고르고, 한 줄 적는다.
  Widget _todoComposer() {
    final target = _todoTarget ?? _selectedPath;
    final name = target == null ? '고르기' : _todoName(target);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 6, 7),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: borderCol.withValues(alpha: 0.8))),
      ),
      child: Row(
        children: [
          // 어디에 적을지 먼저 정한다. 안 정하면 어느 캐릭터 일인지 모른다.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTapDown: (d) => _pickTodoTarget(d.globalPosition),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 74),
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: borderCol),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: target == null ? textDim : accent,
                        fontSize: 9)),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: TextField(
              controller: _todoInput,
              style: const TextStyle(color: textPrimary, fontSize: 10),
              cursorColor: accent,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '할 일 적기',
                hintStyle: TextStyle(color: textDim, fontSize: 10),
              ),
              onSubmitted: (_) => _addTodo(),
            ),
          ),
        ],
      ),
    );
  }

  /// 할 일 페이지를 브라우저로 연다.
  ///
  /// 이 맥에서 여는 것이므로 훅 서버의 `/todo`를 쓴다 — 열쇠가 필요 없고,
  /// 밖으로 열린 포트를 굳이 안 거친다.
  void _openTodoPage() => openUrl('http://127.0.0.1:$kPort/todo');

  /// 폰에서 열 주소를 복사한다.
  ///
  /// ⚠️ 열쇠가 붙어 32자가 더 달리므로 **눈으로 보고 옮겨 적을 수 없다.**
  /// 복사해서 폰으로 보내는 것(에어드롭·메모) 말고는 길이 없다.
  Future<void> _copyPhoneUrl() async {
    final host = await lanAddress();
    if (host == null) {
      _toast('망에 안 붙어 있다');
      return;
    }
    final url = 'http://$host:$kTodoPort/todo?k=${TodoKey.value}';
    await Clipboard.setData(ClipboardData(text: url));
    _toast('폰 주소를 복사했다 ($host)');
  }

  Future<void> _pickTodoTarget(Offset at) async {
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, 0, 0),
      color: bgMid,
      items: [
        for (final s in widget.store.sessions)
          PopupMenuItem<String>(
            value: s.cwdPath,
            height: 28,
            child: Text(s.name,
                style: const TextStyle(color: textPrimary, fontSize: 11)),
          ),
      ],
    );
    if (picked != null && mounted) setState(() => _todoTarget = picked);
  }

  void _addTodo() {
    final text = _todoInput.text.trim();
    final target = _todoTarget ?? _selectedPath;
    if (text.isEmpty) return;
    if (target == null) {
      _toast('어느 프로젝트 일인지 먼저 고른다');
      return;
    }
    widget.todos.add(target, text);
    setState(_todoInput.clear);
  }

  void _toggleTodo(String cwdPath, TodoItem item) =>
      widget.todos.toggle(Todos.idOf(item));

  void _removeTodo(String cwdPath, TodoItem item) =>
      widget.todos.remove(Todos.idOf(item));

  /// 적어둔 할 일을 그 프로젝트의 클로드에게 보낸다.
  ///
  /// 메시지 탭에서 보내는 것과 **같은 경로**다(`_sendCommand`). 그래야 내가
  /// 보낸 말로 대화에도 남고, 붙여넣기 방식도 그대로 탄다.
  Future<void> _sendTodo(String cwdPath, TodoItem item) async {
    // 담당 세션이 먼저다 — 캐릭터 칸에 적힌 할 일이라도 담당이 다르면 그쪽으로 간다.
    final target = TodoStore.sendTargetOf(item);
    cwdPath = target.isEmpty ? cwdPath : target;
    final want = ProjectStore.composeHangul(cwdPath);
    final session = widget.store.sessions
        .where((s) => ProjectStore.composeHangul(s.cwdPath) == want)
        .firstOrNull;
    if (session == null) {
      _toast('그 캐릭터가 지금 없다');
      return;
    }
    // ⚠️ 브라우저와 **같은 줄**을 탄다([SendQueue]). 세션이 일하는 중이면 줄에 서고,
    // 앞 턴이 끝나면 보낸다. 바로 보내면 앞 태스크의 상태·시간이 어긋난다.
    final queue = kSendQueue;
    if (queue == null) {
      _toast('줄이 준비되지 않았다');
      return;
    }
    final ready = TodoStore.readyToSend(session.status);
    final error = await queue.submit(Todos.idOf(item));
    if (!mounted) return;
    if (error != null) {
      _toast(error);
      return;
    }
    final line = TodoStore.queueFor(widget.todos.all, cwdPath);
    final pos = line.indexWhere((t) => Todos.idOf(t) == Todos.idOf(item));
    if (pos >= 0) {
      _toast('${session.name}이(가) ${ready ? '보내는 중' : '일하는 중'}이라 줄에 세웠다 — ${pos + 1}번째');
      return;
    }
    // 보낸 뒤 그 세션을 펴 준다 — 시켰으면 결과를 보게 되는 것이 자연스럽다.
    setState(() {
      _selectedPath = cwdPath;
      _rawTab = false;
    });
    if (!_expanded) await _setExpanded(true);
  }

  Widget _desk(List<AgentSession> sessions, {bool stretch = true}) {
    final art = widget.art;
    final groups = widget.store.floors;

    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            // 창을 옮기는 손잡이. 타이틀바가 없어졌으니 책상을 잡고 끈다.
            onPanStart: (_) => windowManager.startDragging(),
            child: SizedBox(
              height: kDeskAreaHeight,
              // 펼친 창은 패널에 맞춰 넓다. 책상까지 늘리면 상판만 길어져 허전하다.
              width: stretch ? double.infinity : _deskWidth,
              child: Stack(
                children: [
                  // 책상은 하나로 길게 이어진다. 구역은 칸막이로만 나눈다.
                  Positioned.fill(
                    child: art.desk != null
                        ? Image.memory(
                            art.desk!,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                            gaplessPlayback: true,
                          )
                        : const _PlaceholderDesk(),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    top: 0,
                    child: groups.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: kDeskPlank),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: _emptyState(),
                            ),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < groups.length; i++) ...[
                                  if (i > 0) const _Partition(),
                                  _booth(groups[i]),
                                ],
                              ],
                            ),
                          ),
                  ),
                  // 조작 버튼은 상판 오른쪽에 놓인 물건처럼.
                  Positioned(right: 3, bottom: 3, child: _deskControls()),
                  // 남은 한도는 **왼쪽 아래**다. 오른쪽 버튼들과 자리를
                  // 다투지 않고, 창이 왼쪽으로 자라도 상판에 얹힌 채 남는다.
                  Positioned(left: 4, bottom: 3, child: _limitChip()),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 1,
                    child: Center(child: _unwatchedChip()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 구역 하나 — 같은 계층에 있는 캐릭터들이 한 칸에 모여 앉는다.
  ///
  /// 이름표를 따로 달지 않는다. 칸막이가 경계를 말해주고,
  /// 캐릭터마다 제 이름을 머리에 이고 있어서 팻말은 군더더기가 된다.
  Widget _booth(Floor group) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 칸막이는 칸과 칸 사이에만 선다. 한 칸 안에서는 부모와 그
            // 하위 세션이 나란히 붙어 한 덩어리로 보여야 한다.
            for (final s in group.sessions)
              _character(s, kSlotWidth, tier: group.tierOf(s)),
          ],
        ),
        // 상판 안쪽으로 조금 밀어 넣어 걸터앉은 느낌을 없앤다.
        const SizedBox(height: kDeskPlank - kFootInset),
      ],
    );
  }

  Widget _character(AgentSession s, double width,
      {String tier = kManagerCharSet}) {
    // 계층을 **그림으로** 가른다. 크기를 키우는 것보다 이쪽이 낫다 —
    // 자리 계산이 흔들리지 않고, 테마를 만들 때 '이사·팀장·사원' 한 벌이
    // 들어가는 모양이 되어 파는 단위와도 맞는다.
    //
    // ⚠️ **사람이 고른 세트가 이긴다.** 자동 규칙이 선택을 덮으면 안 된다.
    final frames = widget.art.framesOf(
      s.folderName,
      s.artStatus,
      setName: s.project.charSet ?? tier,
    );
    final isSelected = s.cwdPath == _selectedPath;
    // 승인 대기만 깜빡인다. 나머지는 스프라이트 프레임이 움직임을 맡는다.
    // 세션이 끝난 캐릭터는 흐리게 그려 '살아 있는데 조용한 것'과 구분한다.
    final waiting = s.status == AgentStatus.waiting;
    final blink = waiting && !_pulseOn ? 0.45 : 1.0;
    final opacity = s.ended ? blink * 0.4 : blink;

    return Builder(
      builder: (charContext) => GestureDetector(
        // 캐릭터를 누르면 그 프로젝트를 펼친다. **같은 캐릭터를 다시 누르면 접는다.**
        //
        // 편 것과 접는 것이 같은 자리여야 한다. 펼 때는 캐릭터를 누르는데
        // 접을 때만 패널 구석의 ✕를 찾아가야 하면, 눌렀던 손이 갈 곳을 잃는다.
        onTap: () {
          final same = _expanded && _selectedPath == s.cwdPath;
          if (same) {
            _setExpanded(false);
            return;
          }
          // 다른 캐릭터면 패널 내용만 갈아 끼운다. 펼친 채로 옮겨 다니는 것이
          // 이 화면의 쓸모라 여기서 접히면 안 된다.
          setState(() => _selectedPath = s.cwdPath);
          if (!_expanded) _setExpanded(true);
        },
        onSecondaryTapDown: (d) => _removeProject(s, d.globalPosition),
        onLongPress: () {
          final box = charContext.findRenderObject() as RenderBox?;
          _removeProject(s, box?.localToGlobal(Offset.zero) ?? Offset.zero);
        },
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          decoration: BoxDecoration(
            color: isSelected ? Colors.black.withValues(alpha: 0.35) : null,
            // ⚠️ **승인 대기만 테두리를 두른다.** 사람을 기다리는 유일한
            // 상태라 놓치면 세션이 멈춰 선다. 깜빡임만으로는 정지된 순간에
            // 그냥 흐릿해 보여서, 여럿이 서 있으면 눈에 안 들어왔다.
            // 깜빡이되 **가장 어두울 때도 보이게** 최소 밝기를 남긴다.
            border: waiting
                ? Border.all(
                    color: gold.withValues(alpha: _pulseOn ? 0.95 : 0.45),
                    width: 1.5)
                : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 이름은 캐릭터 머리 위에 둔다. 발밑에 두면 상판·버튼과 겹치고,
              // 캐릭터 키가 그림마다 달라지면 자리가 흔들린다.
              Text(
                s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: s.ended ? textDim : textPrimary,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
              const SizedBox(height: 3),
              Opacity(
                opacity: opacity,
                child: SizedBox(
                  // 여백만큼 내려 그리므로 상자를 조금 키워 잘리지 않게 한다.
                  // 대표는 크게 그린다. Row 가 아래 정렬이라 발은 그대로 맞는다.
                  height: 60,
                  width: width,
                  child: Stack(
                    // 모자가 칸 위로 조금 올라갈 수 있다 — 자르지 않는다.
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: frames != null && frames.isNotEmpty
                      ? CustomPaint(
                          painter: _SpritePainter(
                              frames[_frameIndex(s, frames.length)],
                              hat: widget.art.hatOf(tier, s.artStatus.artKey)),
                        )
                      : _PlaceholderChar(status: s.status),
                      ),
                      // 상태 점. **이름 옆이 아니라 캐릭터 위에 얹는다** —
                      // 한 칸이 66px뿐이라 이름 줄에 넣으면 이름이 더 잘린다.
                      Positioned(top: 1, right: 9, child: _statusDot(s)),
                      // 경과 시간도 겹쳐 놓는다. 줄을 하나 더 두면 창이
                      // 세로로 길어지고, 그러면 책상이 화면 밖으로 밀린다.
                      if (s.status.busy && s.statusSince != null)
                        Positioned(top: 2, left: 6, child: _elapsedTag(s)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 캐릭터 어깨 위의 경과 시간.
  ///
  /// 방금 시작한 것과 10분째 물고 있는 것이 책상에서 똑같아 보였다.
  /// 오래 걸리는 것을 알아차려야 가서 볼 수 있다.
  ///
  /// ⚠️ **일하는 중일 때만 띄운다.** 늘 보이면 일곱 칸이 전부 숫자를 이고
  /// 있어 그림이 죽는다. 대기·완료는 시간이 궁금한 상태가 아니다.
  Widget _elapsedTag(AgentSession s) {
    return Text(
      _elapsed(s.statusSince!),
      style: const TextStyle(
        color: textPrimary,
        fontSize: 8,
        height: 1.0,
        fontWeight: FontWeight.w600,
        // 바탕이 투명이라 밝은 배경에서는 글자가 묻힌다.
        shadows: [Shadow(color: Colors.black, blurRadius: 3)],
      ),
    );
  }

  // ── 회의실 화면 ─────────────────────────────────────────
  //
  // 두 자리에서 본다. **책상 자리의 원탁**은 지금 누가 말하는지(분위기),
  // **펼침 패널의 회의 탭**은 발언 전문(내용)이다. 둘 다 같은 `상태.json`을
  // 본다 — 화면마다 다른 것을 읽으면 두 화면이 어긋난다.
  //
  // ⚠️ **여기서 회의를 굴리지 않는다.** 이 화면은 읽기 전용이다. 회의는
  // 터미널의 `/회의`가 시작하고 사회자 세션이 진행한다.

  /// 원탁이 들어갈 만한 높이. 상판(128)으로는 캐릭터를 둘러 앉힐 수 없다.
  static const double kMeetingAreaHeight = 200;

  /// 원탁 화면의 최소 폭.
  static const double kMeetingMinWidth = 380;

  /// 원탁 폭은 **참석자 수**를 따라간다.
  ///
  /// ⚠️ 책상 폭(`_deskWidth`)을 쓰면 안 된다. 등록된 캐릭터가 열이면
  /// 넷이 앉은 원탁이 850px로 벌어져 서로 남남처럼 보인다 — 실제로 그랬다.
  double get _meetingWidth {
    final n = _meeting?.speakers.length ?? 0;
    return (n * 104.0 + 60).clamp(kMeetingMinWidth, 720.0);
  }

  Meeting? get _meeting => widget.meetings.now;

  /// 지금 원탁을 그리고 있는지. 창 크기 계산이 이 값을 따라간다.
  bool get _meetingShown => _meetingOpen && _meeting != null;

  Future<void> _toggleMeeting() async {
    setState(() => _meetingOpen = !_meetingOpen);
    if (_expanded) return;
    // 높이가 바뀌므로 열쇠를 비워 다시 맞추게 한다.
    _lastFloorCount = '';
    await _syncCollapsedHeight();
  }

  /// 책상 자리의 원탁.
  Widget _meetingTable(Meeting m) {
    final talkers = [for (final one in m.speakers) if (one.spoke) one];
    // 말풍선은 발언한 사람을 돌아가며 하나씩 띄운다. 넷을 한꺼번에 띄우면
    // 이 크기에서는 글자가 아무것도 안 읽힌다.
    final speaking =
        talkers.isEmpty ? null : talkers[(_frame ~/ 22) % talkers.length];
    return GestureDetector(
      // 책상과 마찬가지로 여기를 잡고 창을 끈다.
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: bgDark.withValues(alpha: 0.94),
          border: Border.all(color: accent.withValues(alpha: 0.65), width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            _meetingHeader(m),
            Expanded(child: _meetingSeats(m, speaking)),
            _meetingBanner(m, speaking),
          ],
        ),
      ),
    );
  }

  Widget _meetingHeader(Meeting m) {
    return Container(
      height: 22,
      padding: const EdgeInsets.only(left: 8, right: 2),
      color: bgMid.withValues(alpha: 0.7),
      child: Row(
        children: [
          const Icon(Icons.groups, size: 12, color: accent),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              m.topic,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: textPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'R${m.round} · ${m.state}',
            style: TextStyle(
              color: m.needsUser ? gold : textDim,
              fontSize: 9,
              fontWeight: m.needsUser ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
          _iconButton(
            icon: Icons.close,
            tooltip: '책상으로 돌아가기',
            onTap: _toggleMeeting,
          ),
        ],
      ),
    );
  }

  /// 원탁에 둘러앉은 참석자들.
  ///
  /// 자리는 타원 위에 고르게 놓는다. 줄로 세우면 책상뷰와 똑같아져서
  /// '모여 있다'는 것이 안 보인다.
  Widget _meetingSeats(Meeting m, MeetingSpeaker? speaking) {
    return LayoutBuilder(
      builder: (context, box) {
        final n = m.speakers.length;
        if (n == 0) {
          return const Center(
            child: Text('참석자가 없다',
                style: TextStyle(color: textDim, fontSize: 10)),
          );
        }
        // 자리 상자는 스프라이트에 바짝 맞춘다. 헐거우면 말하는 사람의
        // 금색 테두리가 캐릭터가 아니라 빈칸을 두른 것처럼 보인다.
        const slotW = 48.0;
        const slotH = 58.0;
        final cx = box.maxWidth / 2;
        final cy = box.maxHeight / 2;
        final rx = (box.maxWidth / 2 - slotW / 2 - 4).clamp(24.0, 420.0);
        final ry = (box.maxHeight / 2 - slotH / 2 - 2).clamp(10.0, 200.0);
        final seats = <Widget>[];
        for (var i = 0; i < n; i++) {
          // 첫 자리를 위쪽에 두고 시계 방향으로 돈다. 참석자 순서는
          // 사회자가 정한 순서 그대로다 — 상태로 정렬하면 자리가 튄다.
          final a = -pi / 2 + 2 * pi * i / n;
          seats.add(Positioned(
            left: cx + rx * cos(a) - slotW / 2,
            top: cy + ry * sin(a) - slotH / 2,
            width: slotW,
            height: slotH,
            child: _meetingChar(m.speakers[i], identical(m.speakers[i], speaking)),
          ));
        }
        return Stack(
          children: [
            // 가운데 탁자. 비워두면 캐릭터들이 그냥 흩어져 보인다.
            Positioned(
              // 탁자는 자리 안쪽까지 넉넉히 채운다. 좁으면 캐릭터가 탁자에
              // 앉은 것이 아니라 멀찍이 떨어져 선 것처럼 보인다.
              left: cx - rx * 0.74,
              top: cy - ry * 0.5,
              width: rx * 1.48,
              height: ry,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: bgMid,
                  border: Border.all(color: borderCol),
                  borderRadius:
                      BorderRadius.all(Radius.elliptical(rx * 0.74, ry / 2)),
                ),
              ),
            ),
            ...seats,
          ],
        );
      },
    );
  }

  /// 참석자 하나. 등록된 프로젝트면 그 캐릭터 그림을 그대로 쓴다.
  ///
  /// 말하는 사람만 금색 테두리를 두른다. 책상에서 승인 대기를 가르는
  /// 방식과 같다 — 이 크기에서는 스프라이트만으로 구분이 안 된다.
  Widget _meetingChar(MeetingSpeaker sp, bool talking) {
    final proj = sp.path == null
        ? null
        : widget.projects.projects
            .where((one) => one.path == sp.path)
            .firstOrNull;
    final status = sp.silent
        ? AgentStatus.bored
        : (talking ? AgentStatus.thinking : AgentStatus.idle);
    final frames = widget.art
        .framesOf(proj?.name ?? sp.name, status, setName: proj?.charSet);
    return Column(
      children: [
        Text(
          sp.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: talking ? gold : (sp.spoke ? textPrimary : textDim),
            fontSize: 9,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Opacity(
            // 아직 말하지 않은 사람은 흐리게. 누구를 기다리는지 한눈에 보인다.
            opacity: sp.spoke ? 1.0 : 0.45,
            child: Container(
              decoration: talking
                  ? BoxDecoration(
                      border: Border.all(
                        color: gold.withValues(alpha: _pulseOn ? 0.95 : 0.5),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    )
                  : null,
              // ⚠️ **`SizedBox.expand`가 있어야 한다.** CustomPaint는 제
              // 크기가 없어서 그냥 두면 0으로 줄고, 금색 테두리가 세로선
              // 하나로 그려진다.
              child: SizedBox.expand(
                child: frames != null && frames.isNotEmpty
                    ? CustomPaint(
                        painter: _SpritePainter(
                            frames[(_frame ~/ 4) % frames.length]),
                      )
                    : _PlaceholderChar(status: status),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 원탁 아래 한 줄. 지금 무슨 일이 벌어지는지를 글로 말한다.
  ///
  /// 캐릭터만 서 있으면 예쁘긴 해도 아무것도 알 수 없다. 사람이 볼 것은
  /// 결국 '누가 무슨 말을 했나'와 '지금 뭘 기다리나'다.
  Widget _meetingBanner(Meeting m, MeetingSpeaker? speaking) {
    String text;
    Color color;
    if (m.done) {
      text = m.conclusion.isEmpty ? '회의가 끝났다' : m.conclusion;
      color = success;
    } else if (m.needsUser) {
      text = m.draft.isEmpty ? '의견을 기다리는 중' : '잠정 결론 · ${m.draft}';
      color = gold;
    } else if (speaking != null) {
      text = '${speaking.name} · ${speaking.line}';
      color = textPrimary;
    } else {
      final left = m.speakers.where((one) => !one.spoke && !one.silent).length;
      text = left > 0 ? '$left명이 아직 말하지 않았다' : '모으는 중';
      color = textDim;
    }
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bgMid.withValues(alpha: 0.75),
        border: Border(top: BorderSide(color: borderCol.withValues(alpha: 0.6))),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 10, height: 1.35),
      ),
    );
  }

  // ── 회의 탭 (발언 전문) ─────────────────────────────────

  Widget _meetingBody() {
    final m = _meeting;
    if (m == null) {
      return _placeholderBody(
        '도는 회의가 없다',
        '터미널에서 /회의 로 시작하면\n여기에 발언이 올라온다.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      children: [
        Text(
          m.topic,
          style: const TextStyle(
            color: textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${m.round}라운드 · ${m.state} · 참석 ${m.speakers.length}명',
          style: const TextStyle(color: textDim, fontSize: 10),
        ),
        const SizedBox(height: 14),
        for (final one in m.speakers) _meetingSay(one),
        if (m.userNotes.isNotEmpty) ...[
          const SizedBox(height: 6),
          _meetingBlock('내 의견', m.userNotes.join('\n\n'), accent),
        ],
        if (m.draft.isNotEmpty) _meetingBlock('잠정 결론', m.draft, gold),
        if (m.conclusion.isNotEmpty)
          _meetingBlock('최종 결론', m.conclusion, success),
        const SizedBox(height: 10),
        // 회의록 원본이 어디 있는지 적어 둔다. 화면이 줄여 보여주는 것이라
        // 전체를 읽고 싶을 때 갈 곳이 있어야 한다.
        Text(
          m.logPath,
          style: const TextStyle(color: textDim, fontSize: 9),
        ),
      ],
    );
  }

  Widget _meetingSay(MeetingSpeaker sp) {
    final empty = !sp.spoke;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: sp.silent
                      ? danger
                      : (empty ? textDim : success),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                sp.name,
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                sp.state,
                style: const TextStyle(color: textDim, fontSize: 9),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 13),
            child: Text(
              empty ? '(아직 없다)' : sp.say.trim(),
              style: TextStyle(
                color: empty ? textDim : textBody,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _meetingBlock(String label, String body, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: bgMid.withValues(alpha: 0.55),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(color: textBody, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── 크레딧 탭 ───────────────────────────────────────────
  //
  // 직원(프로젝트)별로 토큰을 얼마나 썼는지 본다.
  //
  // ⚠️ **"크레딧"은 말이 그렇다는 것이고 실제로는 토큰이다.** 구독제라
  // 로컬 어디에도 잔액이 없다. 돈은 API 정가를 곱한 추정치일 뿐이라
  // 화면에도 그렇게 적는다 — 실제 청구액인 척하면 안 된다.

  /// 크레딧 탭에서 보는 기간. 눌러서 바꾼다.
  int _usageDays = 7;

  String _sinceDay(int days) => UsageStore.dayOf(
      DateTime.now().subtract(Duration(days: days - 1)));

  /// 큰 수를 읽기 좋게. 1_234_567 → `1.2M`
  static String _short(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}억';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  Widget _usageBody(AgentSession s) {
    final u = widget.usage;
    if (!u.ready) {
      return _placeholderBody(
        '사용량을 읽는 중',
        'transcript 전체를 처음 한 번 훑는다.\n한참 걸릴 수 있고, 다음부터는 금방이다.',
      );
    }
    final since = _sinceDay(_usageDays);
    // ⚠️ **아래 목록과 같은 규칙으로 갈라야 한다.** 접두어로 품게 했더니
    // 위에는 otaku_log가 1.7M, 아래 목록에는 1.2M으로 나왔다 — titles·marketing이
    // 위에서만 딸려 들어간 것이다. 같은 화면에서 같은 이름이 두 값을 가지면
    // 어느 쪽이 맞는지 알 수 없다. `match`는 더 깊은 등록이 이기므로
    // titles는 titles로만 센다.
    bool mine(String cwd) =>
        widget.projects.match(cwd)?.path == s.project.path;
    final mineDays = u.daysOf(mine, since);
    final mineModels = u.modelsOf(mine, since);
    final mineTotal = UsageTally();
    for (final t in mineModels.values) {
      mineTotal.add(t);
    }
    final ranks = u.byProject(
        (cwd) => widget.projects.match(cwd)?.name, since)
      ..removeWhere((_, t) => t.isEmpty);
    final sorted = ranks.entries.toList()
      ..sort((a, b) => b.value.output.compareTo(a.value.output));

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      children: [
        _usageRange(),
        const SizedBox(height: 14),
        Text(
          s.name,
          style: const TextStyle(
            color: textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        _usageNumbers(mineTotal, mineModels),
        const SizedBox(height: 16),
        _usageLabel('날짜별 출력 토큰'),
        const SizedBox(height: 6),
        _usageBars(mineDays),
        const SizedBox(height: 18),
        _usageLabel('직원별 (출력 토큰 순)'),
        const SizedBox(height: 6),
        for (final e in sorted)
          _usageRow(e.key, e.value, sorted.first.value.output,
              here: e.key == s.project.name),
        if (sorted.isEmpty)
          const Text('이 기간에 쓴 것이 없다',
              style: TextStyle(color: textDim, fontSize: 11)),
        const SizedBox(height: 16),
        // ⚠️ 이 문장을 빼지 않는다. 숫자만 있으면 실제 청구액으로 읽힌다.
        const Text(
          '구독제라 실제 크레딧 잔액은 여기서 알 수 없다. '
          '금액은 API 정가를 곱한 참고값이고 실제로 나간 돈이 아니다.',
          style: TextStyle(color: textDim, fontSize: 10, height: 1.5),
        ),
      ],
    );
  }

  Widget _usageLabel(String t) => Text(
        t,
        style: const TextStyle(
            color: textDim, fontSize: 10, fontWeight: FontWeight.w600),
      );

  Widget _usageRange() {
    Widget one(int days, String label) {
      final on = _usageDays == days;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          onTap: () => setState(() => _usageDays = days),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: on ? accent.withValues(alpha: 0.28) : bgMid,
              border: Border.all(color: on ? accent : borderCol),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: on ? textPrimary : textDim,
                fontSize: 10,
                fontWeight: on ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: [
      one(1, '오늘'),
      one(7, '7일'),
      one(30, '30일'),
      one(3650, '전체'),
    ]);
  }

  /// 토큰 네 갈래와 비용 추정.
  ///
  /// ⚠️ **캐시 읽기를 다른 것과 같은 줄에 뭉뚱그리지 않는다.** 8월 이후
  /// 캐시 읽기가 62억인데 출력은 1,400만이다. 합쳐 놓으면 무슨 숫자를 보는지
  /// 알 수 없고, 단가도 10분의 1이라 크기가 곧 비용도 아니다.
  Widget _usageNumbers(UsageTally t, Map<String, UsageTally> byModel) {
    final (cost, exact) = UsageStore.costOf(byModel);
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: textDim, fontSize: 9)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                    color: color ?? textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          cell('출력', _short(t.output), color: accent),
          cell('입력', _short(t.input)),
          cell('캐시 쓰기', _short(t.write5m + t.write1h)),
          cell('캐시 읽기', _short(t.read)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text(
            '\$${cost.toStringAsFixed(2)}',
            style: const TextStyle(
                color: gold, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              exact
                  ? 'API 정가 환산 (참고)'
                  : 'API 정가 환산 (참고) · 단가를 모르는 모델은 뺐다',
              style: const TextStyle(color: textDim, fontSize: 9),
            ),
          ),
          Text('${t.calls}회',
              style: const TextStyle(color: textDim, fontSize: 9)),
        ]),
      ],
    );
  }

  /// 날짜별 막대. 빈 날도 자리를 지킨다 — 안 그러면 쉰 날이 안 보인다.
  Widget _usageBars(Map<String, UsageTally> days) {
    final n = _usageDays > 30 ? 30 : _usageDays;
    final labels = [
      for (var i = n - 1; i >= 0; i--)
        UsageStore.dayOf(DateTime.now().subtract(Duration(days: i)))
    ];
    var top = 1;
    for (final d in labels) {
      final v = days[d]?.output ?? 0;
      if (v > top) top = v;
    }
    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in labels)
            Expanded(
              child: Tooltip(
                message: '$d · ${_short(days[d]?.output ?? 0)}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        // 0인 날도 1px은 남긴다. 아무것도 없으면 그날이
                        // 있었다는 것조차 안 보인다.
                        height: (44 * (days[d]?.output ?? 0) / top)
                            .clamp(1.0, 44.0),
                        decoration: BoxDecoration(
                          color: (days[d]?.output ?? 0) == 0
                              ? borderCol
                              : accent,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        d.substring(8),
                        style: const TextStyle(color: textDim, fontSize: 7),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 직원 한 줄. 막대 길이는 1등 대비다.
  Widget _usageRow(String name, UsageTally t, int top, {bool here = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: here ? accent : textBody,
                fontSize: 10,
                fontWeight: here ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 10,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: top <= 0 ? 0 : (t.output / top).clamp(0.02, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: here ? accent : accent.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 46,
            child: Text(
              _short(t.output),
              textAlign: TextAlign.right,
              style: const TextStyle(color: textPrimary, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  // ── 남은 한도 칩 (책상 왼쪽 아래) ───────────────────────
  //
  // 5시간·7일 창을 얼마나 썼고 언제 초기화되는지. 곁눈으로 보는 자리라
  // 두 줄에 막대 하나씩만 둔다.
  //
  // ⚠️ **모르면 아무것도 안 낸다.** 상태줄이 안 걸려 있거나 아직 첫 응답 전이면
  // 값이 없는데, 그때 0%로 그리면 '많이 남았다'는 거짓말이 된다.

  /// 사용률에 따른 색. 초록 → 노랑 → 빨강.
  ///
  /// 여기서만 색을 정한다. 두 줄이 서로 다른 기준으로 물들면 견줄 수가 없다.
  static Color _limitColor(double pct) {
    if (pct >= 90) return danger;
    if (pct >= 70) return gold;
    return success;
  }

  Widget _limitChip() {
    final l = widget.limits;
    if (!l.has) return const SizedBox.shrink();
    final rows = <Widget>[];
    void add(String label, LimitWindow? w) {
      if (w != null) rows.add(_limitRow(label, w, dim: l.stale));
    }

    add('5h', l.fiveHour);
    add('7d', l.sevenDay);
    add('\$', l.spend);
    if (rows.isEmpty) return const SizedBox.shrink();

    return Tooltip(
      message: l.stale
          ? '한도 소식이 끊긴 지 오래됐다.\n'
              '세션이 다 닫혔거나 상태줄이 빠졌을 수 있다.'
          : '5h·7d는 클로드 코드가 상태줄로 알려주는 실제 한도다.\n'
              '막대는 쓴 만큼이고, 옆의 시간은 초기화까지 남은 시간이다.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _limitRow(String label, LimitWindow w, {bool dim = false}) {
    final pct = w.percent.clamp(0.0, 100.0);
    final color = _limitColor(w.percent);
    return Opacity(
      // 오래된 값은 흐리게. 지우지는 않는다 — 마지막으로 알던 값도 쓸모가 있다.
      opacity: dim ? 0.45 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              child: Text(
                label,
                style: const TextStyle(
                  color: textDim,
                  fontSize: 8,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
            ),
            // 막대. 좁아도 색이 먼저 눈에 들어오라고 테두리를 두른다.
            Container(
              width: 46,
              height: 7,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                border: Border.all(color: borderCol.withValues(alpha: 0.8)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: pct / 100,
                  child: Container(color: color),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${w.percent.round()}%',
              style: TextStyle(
                color: color,
                fontSize: 8,
                height: 1.0,
                fontWeight: FontWeight.w700,
                shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              w.leftText,
              style: const TextStyle(
                color: textDim,
                fontSize: 8,
                height: 1.0,
                shadows: [Shadow(color: Colors.black, blurRadius: 3)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 캐릭터 어깨 위의 상태 점.
  ///
  /// 스프라이트가 상태마다 다르지만 66px 안에서는 구분이 잘 안 된다. 실제로
  /// 작업 중·승인 대기·완료를 섞어 찍어보니 일곱이 거의 똑같아 보였다
  /// (2026-08-07). 펼침 패널 헤더에 있는 그 점을 책상에도 둔다.
  ///
  /// 색은 `shownStatus` 를 쓴다 — 훅이 준 상태에 화면 신호(압축·재시도)를
  /// 얹은 값이라, 접어둔 사이에 압축이 돌아도 일하는 색으로 보인다.
  Widget _statusDot(AgentSession s) {
    final status = s.shownStatus;
    final waiting = status == AgentStatus.waiting;
    // 승인 대기는 조금 크게, 그리고 **느낌표를 넣는다.** 색만으로 가르면
    // 색을 잘 못 가리는 눈에는 회색 점 여럿과 다를 바가 없다.
    final size = waiting ? 12.0 : 8.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: status.color,
        shape: BoxShape.circle,
        // 바탕이 투명이라 밝은 배경에서는 점이 묻힌다. 테두리로 띄운다.
        border: Border.all(color: Colors.black.withValues(alpha: 0.55)),
      ),
      child: waiting
          ? const Text('!',
              style: TextStyle(
                color: Colors.black,
                fontSize: 9,
                height: 1.0,
                fontWeight: FontWeight.w900,
              ))
          : null,
    );
  }

  // ── 목록뷰 (아트 없이 상태만 확인할 때) ───────────────────

  Widget _list(List<AgentSession> sessions) {
    // 목록은 글자가 주인공이라 자기 바탕을 깐다. 투명 위에서는 안 읽힌다.
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        decoration: BoxDecoration(
          color: bgDark,
          border: Border.all(color: borderCol, width: 2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Container(
              height: 24,
              padding: const EdgeInsets.only(left: 8, right: 3),
              color: bgMid,
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'CLAUDE',
                      style: TextStyle(
                        color: textDim,
                        fontSize: 9,
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _deskControls(),
                ],
              ),
            ),
            Expanded(
              child: sessions.isEmpty
                  ? const Center(
                      child: Text(
                        '등록된 프로젝트가 없다',
                        style: TextStyle(color: textDim, fontSize: 11),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: sessions.length,
                      itemBuilder: (context, i) => _row(sessions[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(AgentSession s) {
    final dotOpacity = s.status.pulses && !_pulseOn ? 0.25 : 1.0;
    final detail = s.ended
        ? '세션 없음'
        : (s.tool != null ? '${s.shownStatus.label} · ${s.tool}' : s.shownStatus.label);

    return GestureDetector(
      onSecondaryTapDown: (d) => _removeProject(s, d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Opacity(
              opacity: dotOpacity,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: s.shownStatus.color,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: s.shownStatus.color, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              s.updatedAt != null ? _elapsed(s.updatedAt!) : '—',
              style: const TextStyle(color: textDim, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// 스프라이트 한 칸을 잘라 그린다.
///
/// 세로를 칸 높이에 맞추고 가로 비율을 유지한다.
/// 확대는 [FilterQuality.none] — 픽셀이 뭉개지지 않고 각지게 커진다.
class _SpritePainter extends CustomPainter {
  const _SpritePainter(this.frame, {this.hat});

  final SpriteFrame frame;

  /// 계층 모자. 머리 윗줄(프레임의 [SpriteFrame.contentTop])에 모자 그림의 아랫줄을 맞춰 얹는다.
  final SpriteFrame? hat;

  /// 모자를 그릴 자리. 캐릭터와 같은 배율로 키우고, 가로 가운데를 캐릭터 칸 가운데에 맞춘다.
  /// 머리 높이를 못 쟀으면 `null` — 엉뚱한 데 뜨느니 안 그린다.
  static Rect? hatRect(SpriteFrame frame, SpriteFrame hat, Rect spriteDst) {
    final top = frame.contentTop;
    if (top == null || frame.src.height <= 0) return null;
    final scale = spriteDst.height / frame.src.height;
    final headY = spriteDst.top + top * scale;
    final hatBottom = (hat.contentBottom ?? hat.src.height) * scale;
    final w = hat.src.width * scale, h = hat.src.height * scale;
    final cx = frame.headCenterX == null ? spriteDst.center.dx : spriteDst.left + frame.headCenterX! * scale;
    return Rect.fromLTWH(cx - w / 2, headY - hatBottom, w, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.src.height <= 0) return;
    final scale = size.height / frame.src.height;
    final w = frame.src.width * scale;
    // 아래 투명 여백만큼 더 내려 그린다. 발이 상판에 붙는다.
    final drop = frame.bottomPadding * scale;
    final dst = Rect.fromLTWH((size.width - w) / 2, drop, w, size.height);
    canvas.drawImageRect(
      frame.image,
      frame.src,
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );
    final h = hat;
    final hr = h == null ? null : hatRect(frame, h, dst);
    if (h != null && hr != null) {
      canvas.drawImageRect(h.image, h.src, hr, Paint()..filterQuality = FilterQuality.none);
    }
  }

  @override
  bool shouldRepaint(covariant _SpritePainter old) =>
      old.hat?.image != hat?.image ||
      old.frame.image != frame.image ||
      old.frame.src != frame.src ||
      old.frame.contentBottom != frame.contentBottom;
}

/// 구역 사이 칸막이. 사무실 파티션처럼 상판에서 위로 올라온다.
class _Partition extends StatelessWidget {
  const _Partition();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            width: 4,
            height: 62,
            decoration: BoxDecoration(
              // 위로 갈수록 옅어져 칸막이 천 같은 느낌을 준다.
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33808a99), Color(0xCC5a6472)],
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: kDeskPlank - kFootInset),
        ],
      ),
    );
  }
}

/// art/desk/background.png가 없을 때 대신 그리는 임시 책상.
///
/// 상판만 그린다. 위쪽은 투명으로 비워 바탕화면이 그대로 보이게 한다.
class _PlaceholderDesk extends StatelessWidget {
  const _PlaceholderDesk();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Expanded(child: SizedBox.shrink()),
        Container(height: 2, color: const Color(0xFF6b5a4a)),
        Container(
          height: kDeskPlank - 2,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF4a3728), Color(0xFF2f231a)],
            ),
          ),
        ),
      ],
    );
  }
}

/// 해당 상태의 캐릭터 그림이 아직 없을 때 자리를 잡아두는 사각형.
class _PlaceholderChar extends StatelessWidget {
  const _PlaceholderChar({required this.status});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 56,
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.18),
        border: Border.all(color: status.color, width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.center,
      child: Text(
        status.label,
        textAlign: TextAlign.center,
        style: TextStyle(color: status.color, fontSize: 8),
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
