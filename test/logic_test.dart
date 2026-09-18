// 손으로 매번 확인하던 것들을 굳혀둔다.
//
// 대상은 순수 로직뿐이다. UI와 tmux 호출은 여기서 다루지 않는다 —
// 그쪽은 실제로 띄워서 봐야 하고, `CLAUDE_WATCHER_SELFTEST`가 그 역할을 한다.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:claude_watcher/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// 테스트용 등록 파일을 만들고 그 경로를 환경변수로 가리키게 한다.
ProjectStore storeWith(List<Map<String, dynamic>> projects, String suffix) {
  final file = File('${Directory.systemTemp.path}/cw_test_$suffix.json');
  file.writeAsStringSync('{"projects": ${_json(projects)}}');
  return ProjectStore()..loadFrom(file.path);
}

String _json(List<Map<String, dynamic>> rows) {
  final parts = rows.map((r) {
    final fields = r.entries
        .map((e) => '"${e.key}": "${e.value}"')
        .join(', ');
    return '{$fields}';
  });
  return '[${parts.join(', ')}]';
}

void main() {
  group('한글 경로 표기', () {
    test('자모로 분리된 한글을 완성형으로 합친다', () {
      // macOS 파일시스템과 osascript가 돌려주는 형태(NFD)
      const nfd = '운수'; // 운수
      // 이 리터럴이 정말 자모로 저장돼 있는지 먼저 확인한다.
      // 편집기가 완성형으로 정규화해 버리면 이 검사가 헛돌기 때문이다.
      expect(nfd.length, 5, reason: 'NFD 리터럴이 완성형으로 바뀌었다');
      expect(ProjectStore.composeHangul(nfd), '운수');
    });

    test('이미 완성형이면 그대로 둔다', () {
      expect(ProjectStore.composeHangul('무위다라니'), '무위다라니');
    });

    test('영문·숫자는 건드리지 않는다', () {
      expect(ProjectStore.composeHangul('rpg_habit-2'), 'rpg_habit-2');
    });

    test('normalize는 끝의 슬래시를 떼고 표기를 맞춘다', () {
      const nfd = '/a/무위/'; // /a/무위/
      expect(ProjectStore.normalize(nfd), '/a/무위');
    });
  });

  group('프로젝트 매칭', () {
    test('하위 폴더에서 온 cwd도 그 프로젝트로 잡는다', () {
      final s = storeWith([
        {'path': '/w/otaku_log', 'name': 'otaku_log'},
      ], 'sub');
      expect(s.match('/w/otaku_log/lib')?.name, 'otaku_log');
    });

    test('겹치면 더 깊은 등록이 이긴다', () {
      final s = storeWith([
        {'path': '/w', 'name': 'w'},
        {'path': '/w/inner', 'name': 'inner'},
      ], 'deep');
      expect(s.match('/w/inner/src')?.name, 'inner');
      expect(s.match('/w/other')?.name, 'w');
    });

    test('이름만 비슷한 형제 폴더를 잘못 잡지 않는다', () {
      final s = storeWith([
        {'path': '/w/app', 'name': 'app'},
      ], 'sibling');
      // /w/app2 는 /w/app 의 하위가 아니다
      expect(s.match('/w/app2'), isNull);
    });

    test('NFD로 저장된 항목도 NFC cwd와 맞는다', () {
      final s = storeWith([
        {'path': '/w/무위', 'name': '무위'},
      ], 'nfd');
      expect(s.match('/w/무위/sub')?.name, '무위');
    });

    test('상위를 등록하면 하위 등록들을 삼킨다고 알려준다', () {
      final s = storeWith([
        {'path': '/w/a', 'name': 'a'},
        {'path': '/w/b', 'name': 'b'},
      ], 'swallow');
      expect(s.wouldSwallow('/w'), containsAll(['a', 'b']));
      expect(s.swallowedBy('/w/a/deep')?.name, 'a');
    });
  });

  group('tmux 세션 이름', () {
    // scripts/tmux_up.py 의 session_name 과 같은 결과여야 한다.
    test('폴더 이름을 그대로 쓴다', () {
      expect(Tmux.sessionName('/a/b/rpg_habit'), 'rpg_habit');
    });

    test('마침표와 공백은 밑줄로 바꾼다', () {
      expect(Tmux.sessionName('/a/00.rpg 앱'), '00_rpg_앱');
    });

    test('끝의 슬래시가 있어도 같은 이름이 나온다', () {
      expect(Tmux.sessionName('/a/otaku_log/'), 'otaku_log');
    });

    test('한글은 그대로 두되 표기는 완성형으로 맞춘다', () {
      expect(Tmux.sessionName('/a/02_무위다라니'), '02_무위다라니');
      // NFD로 들어와도 tmux_up.py와 같은 이름이 나와야 한다
      expect(Tmux.sessionName('/a/\u1106\u116E\u110B\u1171'), '무위');
    });
  });

  _tableTests();
  _securityTests();

  group('transcript 파싱', () {
    String write(String name, List<String> lines) {
      final f = File('${Directory.systemTemp.path}/cw_$name.jsonl');
      f.writeAsStringSync(lines.join('\n'));
      return f.path;
    }

    test('마지막 사람 발화 뒤의 응답만 가져온다', () {
      final path = write('last', [
        '{"type":"user","message":{"role":"user","content":"첫 질문"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"첫 답"}]}}',
        '{"type":"user","message":{"role":"user","content":"둘째 질문"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"둘째 답"}]}}',
      ]);
      expect(TranscriptReader.lastTurn(path)?.text, '둘째 답');
    });

    test('thinking은 본문에 넣지 않는다', () {
      final path = write('think', [
        '{"type":"user","message":{"role":"user","content":"질문"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"속으로"}]}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"밖으로"}]}}',
      ]);
      expect(TranscriptReader.lastTurn(path)?.text, '밖으로');
    });

    test('도구 결과(role=user)를 사람 발화로 착각하지 않는다', () {
      final path = write('tool', [
        '{"type":"user","message":{"role":"user","content":"고쳐줘"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"고치겠습니다"},{"type":"tool_use","name":"Edit","input":{"file_path":"/x/main.dart"}}]}}',
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"다 고쳤습니다"}]}}',
      ]);
      final turn = TranscriptReader.lastTurn(path)!;
      // 도구 결과 앞의 텍스트까지 한 턴으로 묶여야 한다
      expect(turn.text, '고치겠습니다\n\n다 고쳤습니다');
      expect(turn.toolCounts['Edit'], 1);
      expect(turn.files, ['/x/main.dart']);
    });

    test('도구만 쓰고 말이 없어도 무엇을 했는지는 남는다', () {
      final path = write('silent', [
        '{"type":"user","message":{"role":"user","content":"돌려줘"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}',
      ]);
      final turn = TranscriptReader.lastTurn(path)!;
      expect(turn.text, isNull);
      expect(turn.isEmpty, isFalse);
      expect(turn.toolLine, 'Bash 1');
    });

    test('MCP 도구 이름은 읽을 수 있게 줄인다', () {
      final path = write('mcp', [
        '{"type":"user","message":{"role":"user","content":"올려줘"}}',
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__notion__update-page","input":{}}]}}',
      ]);
      expect(TranscriptReader.lastTurn(path)!.toolLine, 'notion:update-page 1');
    });

    test('없는 파일이면 null', () {
      expect(TranscriptReader.lastTurn('/없는/경로.jsonl'), isNull);
    });
  });

  _speechTests();
  _chatSaveTests();
  _modeTests();
  _slashTests();
  _atTests();
  _signalTests();
  _contextTests();
}

/// 컨텍스트 크기를 transcript에서 읽는지.
void _contextTests() {
  group('스피너가 돌면 일하는 중이다', () {
    // 2026-09-09에 "Hashing 상태일 때도 애니메이션" 요청을 받고 파보니
    // Hashing 은 상태가 아니라 낱말 하나였다 — 클로드 코드가 턴마다
    // 200개 남짓한 목록에서 골라 쓴다. 그래서 낱말이 아니라 줄 모양을 본다.
    //
    // 아래 줄은 실측한 것이다(내 세션 pane 을 떠왔다).
    const spin = '· Canoodling… (2m 21s · ↓ 7.2k tokens)';

    test('어떤 동사든 스피너면 잡는다', () {
      // Beboppin' 은 목록 188개 중 유일하게 -ing 로 안 끝난다.
      // 낱말을 안 보므로 이것도 그대로 잡힌다.
      for (final verb in [
        'Canoodling', 'Hashing', 'Newspapering', 'Baking', "Beboppin'"
      ]) {
        final pane = '어쩌고\n· $verb… (12s · ↓ 1.1k tokens)\n';
        expect(PaneView.signals(pane).spinning, isTrue, reason: verb);
        expect(PaneView.signals(pane).working, isTrue, reason: verb);
      }
    });

    test('실측한 줄 그대로도 잡는다', () {
      expect(PaneView.signals('앞줄\n$spin\n').spinning, isTrue);
    });

    test('끝난 줄은 스피너가 아니다', () {
      // 토큰도 괄호도 없다. `✻ Baked for 4m 25s · done 3:06 PM`
      const done = '✻ Baked for 4m 25s · done 3:06 PM';
      expect(PaneView.signals('앞줄\n$done\n').spinning, isFalse);
    });

    test('평소 화면에서는 안 줍는다', () {
      const idle = '❯ \n'
          '⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent';
      expect(PaneView.signals(idle).spinning, isFalse);
      expect(PaneView.signals(idle).working, isFalse);
    });

    test('대화 본문에 낱말이 나와도 안 줍는다', () {
      const talk = 'Hashing… 이라고 적어 두었다\n· 그리고 이런 줄도 있다';
      expect(PaneView.signals(talk).spinning, isFalse);
    });

    test('⚠️ 들여쓴 줄은 스피너가 아니다 — 화면에 남은 내 글이다', () {
      // 실제로 겪었다(2026-09-09). 이 기능을 만드는 대화에서 스피너 줄을
      // 예시로 적었더니 그 줄이 화면에 그대로 떠서 잡혔다. 앞 공백 2칸이었다.
      const quoted = '  · Canoodling… (2m 21s · ↓ 7.2k tokens)   ← 스피너 예시';
      expect(PaneView.signals('앞줄\n$quoted\n').spinning, isFalse);
    });

    test('진짜 스피너는 왼쪽 끝에서 시작한다', () {
      // 실측: 앞 공백 0칸. 기호는 · ✢ ✳ ✶ ✻ ✽ 로 돌아간다.
      for (final g in ['·', '✢', '✳', '✶', '✻', '✽']) {
        final pane = '앞줄\n$g Creating… (1m 16s · ↓ 2.9k tokens)\n';
        expect(PaneView.signals(pane).spinning, isTrue, reason: g);
      }
    });

    test('말풍선에 낱말을 내걸지는 않는다', () {
      // 매번 바뀌는 낱말이라 내걸어도 뜻이 없다. 압축·재시도만 말이 붙는다.
      expect(PaneView.signals('앞줄\n$spin\n').label, isNull);
    });
  });

  group('컨텍스트 크기', () {
    test('캐시까지 더해야 지금 컨텍스트다', () {
      // 2026-08-07에 실제로 떠온 usage 다.
      expect(
        contextTokensOf({
          'input_tokens': 2,
          'cache_creation_input_tokens': 2183,
          'cache_read_input_tokens': 641056,
          'output_tokens': 1518,
        }),
        643241,
      );
    });

    test('출력 토큰은 더하지 않는다', () {
      // 출력은 다음 요청의 입력으로 넘어가며 이미 합계에 반영된다.
      expect(contextTokensOf({'input_tokens': 100, 'output_tokens': 9999}), 100);
    });

    test('usage가 없거나 비면 null', () {
      expect(contextTokensOf(null), isNull);
      expect(contextTokensOf({}), isNull);
      expect(contextTokensOf('이상한 값'), isNull);
    });

    test('읽기 좋게 줄인다', () {
      expect(formatTokens(643241), '643k');
      expect(formatTokens(1240000), '1.2M');
      expect(formatTokens(950), '950');
    });

    test('말이 없는 응답에서도 컨텍스트를 챙긴다', () {
      // 도구만 쓴 턴에는 text 블록이 없다. 그래도 usage 는 실려 온다.
      final f = File('${Directory.systemTemp.path}/cw_ctx.jsonl');
      f.writeAsStringSync(
        '{"type":"user","message":{"role":"user","content":"돌려줘"}}\n'
        '{"type":"assistant","uuid":"a","message":{"role":"assistant",'
        '"content":[{"type":"tool_use","name":"Bash","input":{}}],'
        '"usage":{"input_tokens":5,"cache_read_input_tokens":12000}}}\n',
      );
      final batch = TranscriptReader.since(f.path, 0)!;
      expect(batch.speeches, isEmpty, reason: '말은 없다');
      expect(batch.contextTokens, 12005, reason: '그래도 컨텍스트는 읽힌다');
    });
  });
}

/// 훅이 안 알려주는 것들을 화면에서 줍는지.
void _signalTests() {
  group('화면에서 줍는 신호', () {
    String pane(String status) => '⏺ 뭔가 했다\n\n❯ \n$status';

    test('실측한 상태바에서 셸과 에이전트를 읽는다', () {
      // 2026-08-07에 돌던 세션에서 그대로 떠온 줄이다.
      final s = PaneView.signals(pane(
          '  ⏵⏵ bypass permissions on · 2 shells · ← 1 agent · ↓ to manage'));
      expect(s.shells, 2);
      expect(s.agents, 1);
    });

    test('셸이 하나일 때도 읽는다 (단수형)', () {
      expect(PaneView.signals(pane('  ⏵⏵ bypass · 1 shell · ← 1 agent')).shells, 1);
    });

    test('에이전트 1은 내걸 것이 아니다', () {
      // 실측한 여섯 세션 전부 `← 1 agent`였다. 늘 있는 값이라 뜻이 없다.
      final s = PaneView.signals(
          pane('  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent'));
      expect(s.agents, 1);
      expect(s.any, isFalse, reason: '1은 노이즈라 내걸지 않는다');
    });

    test('에이전트가 둘 이상이면 내건다', () {
      expect(PaneView.signals(pane('  ⏵⏵ bypass · ← 3 agents')).any, isTrue);
    });

    test('압축 중이면 일하는 중으로 본다', () {
      final s = PaneView.signals('✳ Compacting… (2m 10s)\n\n❯ \n  ⏵⏵ bypass');
      expect(s.compacting, isTrue);
      expect(s.working, isTrue);
      expect(s.label, '대화를 줄이는 중');
    });

    test('재시도 중이면 일하는 중으로 본다', () {
      final s = PaneView.signals('✳ Retrying… (attempt 2)\n\n❯ \n  ⏵⏵ bypass');
      expect(s.retrying, isTrue);
      expect(s.working, isTrue);
      expect(s.label, '다시 부르는 중');
    });

    test('⚠️ 대화 본문에 그 단어가 나와도 줍지 않는다', () {
      // 이 기능을 만드는 대화에서 `Compacting…` 을 여러 번 적었더니 제
      // 화면에 그 글자가 남았다. 스피너 자리만 봐야 한다.
      const talk = '⏺ 압축 중(Compacting…)은 훅이 안 울린다요\n'
          '  Retrying… 도 마찬가지다요\n\n❯ \n  ⏵⏵ bypass permissions on';
      final s = PaneView.signals(talk);
      expect(s.compacting, isFalse);
      expect(s.retrying, isFalse);
    });

    test('평소 스피너는 압축으로 오해하지 않는다', () {
      final s = PaneView.signals(
          '✽ Fiddle-faddling… (8m 3s · ↓ 24.3k tokens)\n\n❯ \n  ⏵⏵ bypass');
      // 이 테스트가 지키려던 것은 '압축으로 오해하지 않는다'이다.
      expect(s.compacting, isFalse);
      expect(s.retrying, isFalse);
      // ⚠️ working 은 2026-09-09부터 참이다. 스피너가 돌면 일하는 중으로 본다 —
      // 예전에는 훅이 조용한 동안 캐릭터가 멈춰 보였다. 예전 이 줄은
      // working 으로 확인하고 있었는데, 그건 뜻이 아니라 곁다리였다.
      expect(s.spinning, isTrue);
      expect(s.working, isTrue);
    });

    test('셸이 남아 있어도 그것만으로 일하는 중은 아니다', () {
      // 턴이 끝난 뒤에도 셸은 남는다. 상태를 뒤집으면 늘 작업 중이 된다.
      final s = PaneView.signals(pane('  ⏵⏵ bypass · 2 shells · ← 1 agent'));
      expect(s.any, isTrue);
      expect(s.working, isFalse);
    });

    test('평소 화면에서는 아무것도 줍지 않는다', () {
      expect(PaneView.signals('⏺ 그냥 답변\n\n❯ ').any, isFalse);
      expect(PaneView.signals(null).any, isFalse);
    });
  });
}

/// `@`로 파일을 집어 넣을 때 무엇을 추리는지.
void _atTests() {
  const files = [
    'lib/main.dart',
    'test/logic_test.dart',
    'scripts/tmux_up.py',
    'main_notes/읽을거리.md',
    'CLAUDE.md',
  ];

  group('할 일 담기', () {
    TodoItem item(String text,
            {String project = '/p',
            TaskStatus status = TaskStatus.waiting,
            DateTime? at}) =>
        TodoItem(text: text, project: project, status: status, at: at);

    test('안 끝난 것이 위, 그 안에서는 먼저 적은 것이 위', () {
      final t1 = item('먼저', at: DateTime(2026, 8, 10, 9));
      final t2 = item('나중', at: DateTime(2026, 8, 10, 11));
      final d = item('끝난 것',
          status: TaskStatus.done, at: DateTime(2026, 8, 10, 8));
      expect(TodoStore.sorted([d, t2, t1]).map((e) => e.text),
          ['먼저', '나중', '끝난 것']);
    });

    test('끝난 것을 지우지 않는다 — 오늘 뭘 했는지가 남아야 한다', () {
      final items = [item('a', status: TaskStatus.done)];
      expect(TodoStore.sorted(items).length, 1);
      expect(TodoStore.encode(items)['tasks'], hasLength(1));
    });

    test('노션 칸을 모두 담아 저장했다 읽으면 그대로다', () {
      final t = TodoItem(
        text: '뼈대',
        project: '/p',
        status: TaskStatus.blocked,
        priority: TaskPriority.two,
        kind: TaskKind.planning,
        content: '작업 내용',
        revisionNote: '수정사항',
        doneDate: DateTime(2026, 9, 14),
        startedAt: DateTime(2026, 9, 14, 13, 35),
        stoppedAt: DateTime(2026, 9, 14, 15, 15),
        subprojectIds: ['3b2177c4'],
        clientIds: ['3c8177c4'],
        sessionIds: ['3db177c4'],
        notionId: '3db177c4-8117',
        at: DateTime(2026, 9, 14, 13, 36),
      );
      final back = TodoStore.decode(TodoStore.encode([t])).single;
      expect(back.status, TaskStatus.blocked);
      expect(back.priority, TaskPriority.two);
      expect(back.kind, TaskKind.planning);
      expect(back.content, '작업 내용');
      expect(back.revisionNote, '수정사항');
      expect(back.doneDate, DateTime(2026, 9, 14));
      expect(back.startedAt, DateTime(2026, 9, 14, 13, 35));
      expect(back.stoppedAt, DateTime(2026, 9, 14, 15, 15));
      expect(back.ticking, isFalse);
      expect(back.subprojectIds, ['3b2177c4']);
      expect(back.clientIds, ['3c8177c4']);
      expect(back.sessionIds, ['3db177c4']);
      expect(back.notionId, '3db177c4-8117');
      expect(TodoStore.encode([t])['version'], 3);
    });

    test('저장했다 읽으면 그대로다', () {
      final at = DateTime(2026, 8, 10, 10, 30);
      final json = TodoStore.encode([
        TodoItem(
            text: '규격 정리',
            project: '/p',
            status: TaskStatus.review,
            body: '자세한 내용',
            spentSec: 90,
            at: at),
      ]);
      final back = TodoStore.decode(json).single;
      expect(back.text, '규격 정리');
      expect(back.project, '/p');
      expect(back.status, TaskStatus.review);
      expect(back.body, '자세한 내용');
      expect(back.spentSec, 90);
      expect(back.at, at);
    });

    test('깨진 줄은 버리고 넘어간다', () {
      expect(TodoItem.fromJson(null), isNull);
      expect(TodoItem.fromJson({'done': true}), isNull, reason: '본문이 없다');
      expect(TodoItem.fromJson({'text': '   '}), isNull, reason: '빈 글자');
      expect(TodoItem.fromJson({'text': 'a'}), isNull,
          reason: '⚠️ 프로젝트가 없으면 시킬 데가 없다');
    });

    test('체크는 원본을 건드리지 않는다', () {
      final a = item('x');
      final b = a.copyWith(status: TaskStatus.done);
      expect(a.done, isFalse);
      expect(b.done, isTrue);
      expect(b.at, a.at, reason: '적은 시각은 그대로여야 순서가 안 튄다');
    });
  });

  group('대표가 바꾼 것을 세션에 알린다', () {
    final rows = [
      ProjectRow(id: 'root', name: '운영', path: '/w'),
      ProjectRow(id: 'cw', name: '워쳐', path: '/w/cw'),
      ProjectRow(id: 'ot', name: '오타쿠', path: '/w/ot'),
    ];
    final base = TodoItem(text: '상세창 개편', project: '/w/cw', projectId: 'cw', status: TaskStatus.review);

    test('바뀐 것만 한 줄로 — 시계만 바뀐 것은 알리지 않는다', () {
      expect(TodoStore.describeOwnerChange(base, base.copyWith(status: TaskStatus.done)),
          '「상세창 개편」 확인필요 → 완료');
      expect(TodoStore.describeOwnerChange(base, base.copyWith(revisionNote: '버튼 더 크게')),
          '「상세창 개편」 수정사항 적힘');
      expect(TodoStore.describeOwnerChange(base, base.copyWith(spentSec: 600, stoppedAt: DateTime(2026))), isNull);
      expect(TodoStore.describeOwnerChange(null, base), '「상세창 개편」 새로 적음 (확인필요)');
      expect(TodoStore.describeOwnerChange(base, null), '「상세창 개편」 지움');
    });

    test('세션마다 한 번씩 · 처음 보는 세션은 지금부터 · 남의 프로젝트 소식은 안 준다', () {
      final n = OwnerNotices();
      n.see('A');
      n.add(base, '「상세창 개편」 확인필요 → 완료');
      n.add(TodoItem(text: '폰트', project: '/w/ot', projectId: 'ot'), '「폰트」 지움');
      final first = n.takeFor('A', '/w/cw/claude_watcher', rows);
      expect(first, contains('확인필요 → 완료'));
      expect(first, isNot(contains('폰트')));
      expect(n.takeFor('A', '/w/cw', rows), '', reason: '한 번 알린 것은 다시 안 준다');
      expect(n.takeFor('B', '/w/cw', rows), '', reason: '처음 보는 세션은 지금부터 센다');
      n.see('R');
      n.add(base, '「상세창 개편」 담당 → 대표');
      expect(n.takeFor('R', '/w', rows), contains('담당 → 대표'), reason: '루트는 전부 받는다');
      expect(n.takeFor('Z', '/elsewhere', rows), '');
    });
  });

  group('세션 API 범위 · 세션 기록', () {
    final rows = [
      ProjectRow(id: 'root', name: '운영', path: '/w'),
      ProjectRow(id: 'cw', name: '워쳐', path: '/w/02_클로드워쳐'),
      ProjectRow(id: 'ot', name: '오타쿠', path: '/w/01_오타쿠기록부/otaku_log', kind: ProjectKind.own),
      ProjectRow(id: 'tb', name: '트봇', path: '/w/06_트레이딩봇', kind: ProjectKind.personal),
      ProjectRow(id: 'jf', name: '햇살카페', kind: ProjectKind.client),
    ];

    test('⚠️ 한글이 풀어진 경로(NFD)도 같은 폴더로 본다', () {
      const nfd = '/w/02_\u1106\u116e\u110b\u1171';
      expect(ProjectStore.composeHangul(nfd), '/w/02_무위');
    });

    test('맨 위 폴더에서 부르면 전부, 그 밖은 가장 깊은 프로젝트 하나', () {
      expect(ApiScope.rootOf(rows)?.id, 'root');
      expect(ApiScope.of('/w', rows)!.all, isTrue);
      expect(ApiScope.of('/w/', rows)!.all, isTrue);
      expect(ApiScope.of('/w/02_클로드워쳐/claude_watcher', rows)!.project!.id, 'cw');
      expect(ApiScope.of('/w/01_오타쿠기록부/otaku_log/titles', rows)!.project!.id, 'ot');
    });

    test('⚠️ 프로젝트 폴더가 아니면 거절한다 — 루트로 새지 않는다', () {
      expect(ApiScope.of('/w/소싱업무', rows), isNull,
          reason: '맨 위 폴더 아래라도 등록 안 된 폴더는 전부를 보면 안 된다');
      expect(ApiScope.of('/elsewhere', rows), isNull);
      expect(ApiScope.of('', rows), isNull);
      expect(ApiScope.of('/w/02_클로드워쳐기타', rows), isNull, reason: '접두어가 같아도 다른 폴더다');
    });

    test('자기 프로젝트 할 일만 허락한다', () {
      final scope = ApiScope.of('/w/02_클로드워쳐', rows)!;
      expect(scope.allows(TodoItem(text: 'a', project: '/w/02_클로드워쳐', projectId: 'cw')), isTrue);
      expect(scope.allows(TodoItem(text: 'b', project: '/w/06_트레이딩봇', projectId: 'tb')), isFalse);
      expect(scope.allows(TodoItem(text: 'c', project: '', projectId: 'jf')), isFalse);
      expect(ApiScope.of('/w', rows)!.allows(TodoItem(text: 'c', project: '', projectId: 'jf')), isTrue);
    });

    test('멈춘 시계 하나가 구간 하나 · 1분 안 되면 안 남긴다', () {
      final t0 = DateTime(2026, 9, 14, 10);
      final before = TodoItem(text: 'x', project: '/p', projectId: 'cw',
          status: TaskStatus.running, startedAt: t0);
      final after = before.copyWith(status: TaskStatus.review, stoppedAt: t0.add(const Duration(minutes: 25)));
      final r = SessionLogStore.fromStop(before, after)!;
      expect(r.minutes, 25);
      expect(r.projectId, 'cw');
      expect(r.date, '2026-09-14');
      final short = before.copyWith(status: TaskStatus.review, stoppedAt: t0.add(const Duration(seconds: 30)));
      expect(SessionLogStore.fromStop(before, short), isNull);
    });

    test('날짜별 종류 합계 — 무위다라니(시간) = 실근무 − 개인', () {
      SessionRecord r(String pid, int min, [String day = '2026-09-14']) {
        final s = DateTime.parse('${day}T10:00:00');
        return SessionRecord(id: '$pid$min$day', start: s, end: s.add(Duration(minutes: min)), projectId: pid);
      }
      final byId = {for (final x in rows) x.id: x};
      final m = SessionLogStore.minutesByKind(
          [r('cw', 90), r('tb', 30), r('jf', 45), r('zz', 5), r('cw', 60, '2026-09-13')],
          '2026-09-14', (id) => byId[id]);
      expect(m['own'], 90);
      expect(m['personal'], 30);
      expect(m['client'], 45);
      expect(m['unknown'], 5);
    });
  });

  group('근무기록 (노션이사)', () {
    test('실근무 = 퇴근 − 출근 − 휴게, 소수 1자리 · 자정을 넘겨도 센다', () {
      expect(WorkLogStore.actualHoursOf('10:16', '19:40', 72), 8.2);
      expect(WorkLogStore.actualHoursOf('22:00', '01:30', 30), 3.0);
      expect(WorkLogStore.actualHoursOf('10:00', null, 0), isNull);
      expect(WorkLogStore.minutesOf('9:05'), 545);
      expect(WorkLogStore.minutesOf('24:00'), isNull);
      expect(WorkLogStore.minutesOf('10시'), isNull);
    });

    test('일 시작 → 점심 시작 → 점심 끝 → 퇴근', () {
      var (d, e) = WorkLogStore.start(null, '2026-09-14', '10:16');
      expect(e, isNull);
      expect(d!.state, WorkState.working);
      (d, e) = WorkLogStore.breakStart(d, '12:30', note: '점심 시작');
      expect(d!.state, WorkState.onBreak);
      expect(d.timeline, '12:30 점심 시작');
      (d, e) = WorkLogStore.breakEnd(d, '13:42', note: '점심 끝');
      expect(d!.breakMin, 72);
      expect(d.breakFrom, isNull);
      expect(d.timeline, '12:30 점심 시작 / 13:42 점심 끝');
      (d, e) = WorkLogStore.end(d, '19:40');
      expect(d!.state, WorkState.done);
      expect(d.actualHours, 8.2);
      expect(d.title, '2026-09-14 (월)');
    });

    test('⚠️ 틀린 순서와 시각은 거절한다 — 기록을 안 바꾼다', () {
      final (started, _) = WorkLogStore.start(null, '2026-09-14', '10:16');
      expect(WorkLogStore.start(started, '2026-09-14', '11:00').$2, isNotNull,
          reason: '출근을 두 번 찍지 않는다');
      expect(WorkLogStore.breakEnd(started, '13:00').$2, isNotNull, reason: '휴게중이 아니다');
      final (onBreak, _) = WorkLogStore.breakStart(started, '12:30');
      expect(WorkLogStore.end(onBreak, '19:00').$2, isNotNull, reason: '휴게를 먼저 끝낸다');
      expect(WorkLogStore.start(null, '2026-09-14', '10시').$2, isNotNull,
          reason: '시각은 부르는 쪽이 date로 확인한 HH:MM만');
      expect(WorkLogStore.breakStart(null, '12:00').$2, isNotNull);
    });

    test('노션 값 그대로 읽는다 — 오타 「가벼게」는 가볍게 · 「휴게」는 휴게중', () {
      expect(WorkIntensity.parse('가벼게'), WorkIntensity.light);
      expect(WorkIntensity.parse('집중'), WorkIntensity.focus);
      expect(WorkState.parse('휴게'), WorkState.onBreak);
      expect(WorkState.parse('완료'), WorkState.done);
    });

    test('하루 한 행 · 저장했다 읽으면 그대로 · 최신 날짜가 앞', () {
      final a = WorkDay(date: '2026-09-13', clockIn: '11:00', clockOut: '15:00',
          breakMin: 0, state: WorkState.done, intensity: WorkIntensity.light,
          actualHours: 4.0, muwidaraniHours: 3.5, timeline: 'a / b', notionId: 'n');
      final b = WorkDay(date: '2026-09-14', clockIn: '10:16');
      final back = WorkLogStore.decode(WorkLogStore.encode([a, b, a]));
      expect(back.map((d) => d.date), ['2026-09-14', '2026-09-13']);
      final x = back.last;
      expect([x.clockIn, x.clockOut, x.breakMin, x.state, x.intensity, x.actualHours,
          x.muwidaraniHours, x.timeline, x.notionId],
          ['11:00', '15:00', 0, WorkState.done, WorkIntensity.light, 4.0, 3.5, 'a / b', 'n']);
    });
  });

  group('시키기가 보내는 곳 · 막는 이유', () {
    test('담당 세션이 먼저, 없거나 대표면 프로젝트 폴더', () {
      final t = TodoItem(text: 'x', project: '/p');
      expect(TodoStore.sendTargetOf(t), '/p');
      expect(TodoStore.sendTargetOf(t.copyWith(assignee: '/q')), '/q');
      expect(TodoStore.sendTargetOf(t.copyWith(assignee: kOwnerAssignee)), '/p');
    });

    test('대표 담당 · 보낼 세션 없음 · ⚠️ 승인 대기면 보내지 않는다', () {
      final t = TodoItem(text: 'x', project: '/p');
      expect(TodoStore.sendRefusal(t, AgentStatus.idle), isNull);
      expect(TodoStore.sendRefusal(t, AgentStatus.working), isNull,
          reason: '일하는 중이면 줄 서서 들어간다');
      expect(TodoStore.sendRefusal(t.copyWith(assignee: kOwnerAssignee), null), isNotNull);
      expect(TodoStore.sendRefusal(t, AgentStatus.waiting), isNotNull,
          reason: '선택지가 떠 있는 창에 엔터를 치면 선택지가 눌린다');
      final noFolder = TodoItem(text: 'x', project: '', projectId: 'n1');
      expect(TodoStore.sendRefusal(noFolder, null), isNotNull);
    });

    test('폴더 없는 프로젝트의 할 일도 담긴다 — 프로젝트 ID로 붙는다', () {
      final t = TodoItem(text: '카드뉴스', project: '', projectId: 'n1', status: TaskStatus.sessionPlanned);
      final back = TodoStore.decode(TodoStore.encode([t])).single;
      expect(back.projectId, 'n1');
      expect(back.project, '');
      expect(TodoItem.fromJson({'text': 'a', 'project': ''}), isNull,
          reason: '폴더도 ID도 없으면 어디 일인지 모른다');
      expect(TodoStore.assigned(t).assignee, isNull,
          reason: '폴더가 없으면 담당 세션을 정할 수 없다');
    });

    test('CSV 비상구 — 노션 칸 이름 머리글 · 노션 진행사항으로 되돌린다', () {
      expect(notionStatusOf(TaskStatus.sessionPlanned), '클로드코드작업');
      expect(notionStatusOf(TaskStatus.blocked), '일시 중지');
      expect(notionStatusOf(TaskStatus.waiting), '시작 전');
    });
  });

  group('프로젝트 목록 (노션이사 3/6)', () {
    test('칸 다섯을 저장했다 읽으면 그대로다', () {
      final at = DateTime(2026, 9, 14, 17, 30);
      final r = ProjectRow(
          id: 'p1', name: '별빛노트', client: '무위다라니', kind: ProjectKind.own,
          path: '/a/rpg_habit', state: ProjectState.active, notionId: 'n1', at: at);
      final back = ProjectDbStore.decode(ProjectDbStore.encode([r])).single;
      expect(back.id, 'p1');
      expect(back.name, '별빛노트');
      expect(back.client, '무위다라니');
      expect(back.kind, ProjectKind.own);
      expect(back.path, '/a/rpg_habit');
      expect(back.state, ProjectState.active);
      expect(back.notionId, 'n1');
      expect(back.at, at);
    });

    test('폴더 없는 프로젝트도 담긴다 — 옛 외주는 폴더가 없다', () {
      final r = ProjectRow(id: 'p2', name: '햇살카페', client: '거래처', kind: ProjectKind.client);
      final back = ProjectDbStore.decode(ProjectDbStore.encode([r])).single;
      expect(back.path, isNull);
      expect(back.client, '거래처');
    });

    test('한글 이름으로도 읽힌다 — 변환표가 한글이다', () {
      expect(ProjectKind.parse('개인'), ProjectKind.personal);
      expect(ProjectKind.parse('외주'), ProjectKind.client);
      expect(ProjectState.parse('보류'), ProjectState.onHold);
      expect(ProjectState.parse('종료'), ProjectState.closed);
    });

    test('진행 → 대기 → 보류 → 종료, 그 안에서 종류 · 이름 순이다', () {
      ProjectRow r(String id, String name, ProjectKind k, ProjectState st) =>
          ProjectRow(id: id, name: name, kind: k, state: st);
      final out = ProjectDbStore.sorted([
        r('1', '가', ProjectKind.own, ProjectState.closed),
        r('2', '나', ProjectKind.personal, ProjectState.active),
        r('3', '다', ProjectKind.own, ProjectState.waiting),
        r('4', '라', ProjectKind.own, ProjectState.active),
      ]);
      expect(out.map((x) => x.id), ['4', '2', '3', '1']);
    });

    test('⚠️ 같은 ID가 둘이면 앞엣것만 둔다 · 이름 없는 줄은 버린다', () {
      final out = ProjectDbStore.decode({
        'projects': [
          {'id': 'p1', 'name': '앞'},
          {'id': 'p1', 'name': '뒤'},
          {'id': 'p2', 'name': '  '},
          {'name': 'ID 없음'},
        ]
      });
      expect(out.map((x) => x.name), ['앞']);
    });
  });

  group('할 일 v1 → v2', () {
    // v1은 {프로젝트: [할 일]}이라 프로젝트가 **담긴 자리**였다. 그러면
    // 프로젝트를 옮길 수도, 상태·시간으로 정렬할 수도 없다.
    final v1 = {
      '/a': [
        {'text': '남은 것', 'done': false, 'at': '2026-08-10T09:00:00.000'},
        {'text': '끝난 것', 'done': true, 'at': '2026-08-10T10:00:00.000'},
      ],
      '/b': [
        {'text': '다른 프로젝트', 'done': false, 'at': '2026-08-10T11:00:00.000'},
      ],
    };

    test('맵의 키가 항목의 프로젝트 필드가 된다', () {
      final out = TodoStore.decode(v1);
      expect(out, hasLength(3));
      expect(out.where((t) => t.project == '/a'), hasLength(2));
      expect(out.firstWhere((t) => t.project == '/b').text, '다른 프로젝트');
    });

    test('체크해 둔 것은 완료로, 나머지는 대기로 올라온다', () {
      final out = TodoStore.decode(v1);
      expect(out.firstWhere((t) => t.text == '끝난 것').status, TaskStatus.done);
      expect(out.firstWhere((t) => t.text == '남은 것').status,
          TaskStatus.waiting);
    });

    test('⚠️ 옛 판을 알아본다 — 갈아엎기 전에 한 벌 남겨야 한다', () {
      expect(TodoStore.isLegacy(v1), isTrue);
      expect(TodoStore.isLegacy(TodoStore.encode([])), isFalse);
    });

    test('v2를 다시 읽어도 v1로 오해하지 않는다', () {
      final v2 = TodoStore.encode(
          [TodoItem(text: 'x', project: '/a', status: TaskStatus.paused)]);
      final back = TodoStore.decode(v2).single;
      expect(back.status, TaskStatus.paused);
      expect(back.project, '/a');
    });
  });

  group('진행상태', () {
    test('노션에서 쓰던 한글 이름으로도 읽힌다', () {
      expect(TaskStatus.parse('진행중'), TaskStatus.running);
      expect(TaskStatus.parse('running'), TaskStatus.running);
      expect(TaskStatus.parse('확인필요'), TaskStatus.review);
    });

    test('모르는 값은 시작 전으로 떨어진다 — 못 읽었다고 항목을 버리지 않는다', () {
      expect(TaskStatus.parse('클로드코드수정요청'), TaskStatus.waiting);
      expect(TaskStatus.parse(null), TaskStatus.waiting);
      expect(TaskStatus.parse(3), TaskStatus.waiting);
    });

    test('완료만 끝난 것이다 — 일시 중지는 아직 살아 있다', () {
      expect(TaskStatus.done.isClosed, isTrue);
      expect(TaskStatus.paused.isClosed, isFalse,
          reason: '멈춘 것을 끝난 것으로 치면 목록에서 사라져 잊힌다');
    });

    test('큰 분류 넷 · 작은 분류 아홉 — 대표가 짠 순서 그대로다', () {
      expect(TaskGroup.values.map((g) => g.label), ['시작 전', '진행중', '일시정지', '완료']);
      expect(
          {for (final g in TaskGroup.values)
            g.label: TaskStatus.values.where((s) => s.group == g).map((s) => s.label).toList()},
          {
            '시작 전': ['백로그', '오늘예정', '세션예정'],
            '진행중': ['진행중', '확인필요', '수정요청'],
            '일시정지': ['일시정지'],
            '완료': ['완료', '대기'],
          });
    });

    test('⚠️ 대기는 완료 묶음이지만 끝난 것이 아니다 — 내리면 잊힌다', () {
      expect(TaskStatus.blocked.group, TaskGroup.complete);
      expect(TaskStatus.blocked.isClosed, isFalse);
      final now = DateTime(2026, 9, 14, 16);
      final t = TodoStore.withStatus(TodoItem(text: 'x', project: '/p'), TaskStatus.blocked, now);
      expect(t.doneDate, isNull, reason: '결과 확인이 남았으니 완료 날짜를 안 찍는다');
    });

    test('옛 파일·노션 값은 새 구분으로 옮겨 읽는다', () {
      expect(TaskStatus.parse('held'), TaskStatus.paused);
      expect(TaskStatus.parse('waiting'), TaskStatus.waiting);
      expect(TaskStatus.parse('시작 전'), TaskStatus.waiting);
      expect(TaskStatus.parse('일시 중지'), TaskStatus.paused);
      expect(TaskStatus.parse('프롬프트작업전'), TaskStatus.waiting);
      expect(TaskStatus.parse('클로드코드작업'), TaskStatus.sessionPlanned);
      expect(TaskStatus.parse('디자인작업'), TaskStatus.running);
      expect(TaskStatus.parse('디자인 피드백 수정'), TaskStatus.revision);
      expect(TaskStatus.parse('디자인 검토중'), TaskStatus.review);
      expect(TaskStatus.parse('오늘예정'), TaskStatus.today);
    });

    test('담당이 비어 있으면 상태가 정해 준다 — 적힌 담당은 안 건드린다', () {
      final now = DateTime(2026, 9, 14, 16);
      final t = TodoItem(text: 'x', project: '/p');
      expect(TodoStore.withStatus(t, TaskStatus.today, now).assignee, kOwnerAssignee);
      expect(TodoStore.withStatus(t, TaskStatus.sessionPlanned, now).assignee, '/p');
      expect(TodoStore.withStatus(t, TaskStatus.running, now).assignee, isNull);
      final mine = t.copyWith(assignee: '/q');
      expect(TodoStore.withStatus(mine, TaskStatus.today, now).assignee, '/q');
      final back = TodoStore.decode(TodoStore.encode([mine])).single;
      expect(back.assignee, '/q');
    });

    test('완료로 들어갈 때만 완료 날짜가 찍히고, 나오면 지워진다', () {
      final now = DateTime(2026, 9, 14, 15, 30);
      final t = TodoItem(text: 'x', project: '/p');
      expect(t.doneDate, isNull, reason: '⚠️ 만들 때 넣으면 끝난 것처럼 보인다');
      final done = TodoStore.withStatus(t, TaskStatus.done, now);
      expect(done.doneDate, DateTime(2026, 9, 14));
      final again = TodoStore.withStatus(done, TaskStatus.done, now.add(const Duration(days: 1)));
      expect(again.doneDate, DateTime(2026, 9, 14), reason: '이미 완료면 날짜가 안 바뀐다');
      expect(TodoStore.withStatus(done, TaskStatus.revision, now).doneDate, isNull);
      expect(TodoStore.withStatus(t, TaskStatus.review, now).doneDate, isNull);
    });
  });

  group('소요시간', () {
    test('재는 중이면 그 몫까지 더해서 준다', () {
      final started = DateTime(2026, 8, 11, 10);
      final t = TodoItem(
          text: 'x', project: '/p', spentSec: 60, startedAt: started,
          status: TaskStatus.running);
      expect(t.spentAt(started.add(const Duration(minutes: 2))), 180);
      expect(t.ticking, isTrue);
    });

    test('⚠️ 진행중이 아니면 시작시간만 있어도 안 돈다 — 옮겨온 태스크에 사흘치가 박힌다', () {
      final t = TodoItem(
          text: 'x', project: '/p', spentSec: 60,
          startedAt: DateTime(2026, 9, 11, 12, 22), status: TaskStatus.review);
      expect(t.ticking, isFalse);
      expect(t.spentAt(DateTime(2026, 9, 14, 18)), 60);
      final out = TodoStore.ended([t], '/p', DateTime(2026, 9, 14, 18));
      expect(out.single.spentSec, 60, reason: 'Stop이 와도 누적이 안 늘어난다');
    });

    test('안 재는 중이면 누적 그대로다', () {
      final t = TodoItem(text: 'x', project: '/p', spentSec: 45);
      expect(t.spentAt(DateTime(2030)), 45);
      expect(t.ticking, isFalse);
    });

    test('한 칸에 들어가게 짧게 쓴다', () {
      expect(formatSpent(0), '–');
      expect(formatSpent(30), '30초');
      expect(formatSpent(90), '1분');
      expect(formatSpent(3600), '1시간');
      expect(formatSpent(3660), '1시간 1분');
    });
  });

  group('우선순위와 마감일', () {
    final now = DateTime(2026, 8, 11, 15);
    TodoItem t(
            {TaskPriority p = TaskPriority.one,
            DateTime? due,
            TaskStatus st = TaskStatus.waiting,
            DateTime? at}) =>
        TodoItem(
            text: 'x',
            project: '/p',
            priority: p,
            due: due,
            status: st,
            at: at ?? DateTime(2026, 8, 1));

    test('🔥가 먼저, 그 다음이 마감일 가까운 것', () {
      final fire = t(p: TaskPriority.three, at: DateTime(2026, 8, 9));
      final soon = t(due: DateTime(2026, 8, 12), at: DateTime(2026, 8, 2));
      final later = t(due: DateTime(2026, 8, 20), at: DateTime(2026, 8, 1));
      final none = t(at: DateTime(2026, 8, 1));
      final out = TodoStore.sorted([none, later, soon, fire]);
      expect(out[0], same(fire));
      expect(out[1], same(soon));
      expect(out[2], same(later));
      expect(out[3], same(none), reason: '⚠️ 날짜 없는 것이 위로 오면 마감일이 뜻을 잃는다');
    });

    test('끝난 것은 🔥라도 아래다', () {
      final done = t(p: TaskPriority.three, st: TaskStatus.done);
      final open = t();
      expect(TodoStore.sorted([done, open])[0], same(open));
    });

    test('지난 마감만 지났다고 한다 — 끝낸 것은 아니다', () {
      expect(t(due: DateTime(2026, 8, 10)).overdue(now), isTrue);
      expect(t(due: DateTime(2026, 8, 11)).overdue(now), isFalse,
          reason: '오늘까지는 안 지났다');
      expect(t(due: DateTime(2026, 8, 10), st: TaskStatus.done).overdue(now),
          isFalse, reason: '이미 한 일이다');
      expect(t().overdue(now), isFalse);
    });

    test('카드 한 줄에 들어가게 짧게 쓴다', () {
      expect(formatDue(DateTime(2026, 8, 11), now), '오늘');
      expect(formatDue(DateTime(2026, 8, 12), now), '내일');
      expect(formatDue(DateTime(2026, 8, 10), now), '어제');
      expect(formatDue(DateTime(2026, 8, 8), now), '3일 지남');
      expect(formatDue(DateTime(2026, 8, 15), now), '4일 뒤');
      expect(formatDue(DateTime(2026, 9, 20), now), '9/20');
    });

    test('저장했다 읽으면 그대로다', () {
      final back = TodoStore.decode(TodoStore.encode([
        t(p: TaskPriority.three, due: DateTime(2026, 8, 20)),
      ])).single;
      expect(back.urgent, isTrue);
      expect(back.due, DateTime(2026, 8, 20));
    });

    test('노션 우선순위 네 단계를 그대로 읽는다', () {
      expect(TaskPriority.values.map((p) => p.label),
          ['타임기록', '🔥', '🔥🔥', '🔥🔥🔥']);
      expect(TaskPriority.parse('🔥🔥'), TaskPriority.two);
      expect(TaskPriority.parse('urgent'), TaskPriority.three, reason: '두 단계 시절의 급함');
      expect(TaskPriority.parse('normal'), TaskPriority.one);
      expect(TaskPriority.one.mark, '', reason: '전부에 불이 붙으면 불이 뜻이 없다');
      expect(TaskPriority.three.mark, '🔥🔥🔥');
    });

    test('예전 파일에는 없던 값이라 기본값으로 떨어진다', () {
      final old = TodoItem.fromJson({'text': 'a', 'project': '/p'})!;
      expect(old.priority, TaskPriority.one, reason: '노션 새 페이지의 기본값이 🔥다');
      expect(old.due, isNull);
    });
  });

  group('시키기가 보내는 말', () {
    // ⚠️ 예전에는 늘 작업명만 보냈다. 본문에 아무리 자세히 적어도 터미널에는
    // 제목 한 줄만 가서, 적어둔 것이 쓸모가 없었다.
    test('본문이 있으면 본문을 보낸다', () {
      final t = TodoItem(
          text: '크롤러 손보기', project: '/p', body: 'titles/ 아래 크롤러를 고쳐줘');
      expect(t.command, 'titles/ 아래 크롤러를 고쳐줘');
    });

    test('본문이 비었으면 작업명을 보낸다', () {
      expect(TodoItem(text: '크롤러 손보기', project: '/p').command, '크롤러 손보기');
      expect(TodoItem(text: '크롤러', project: '/p', body: '  \n ').command, '크롤러');
    });
  });

  group('붙여넣은 그림', () {
    test('이름은 시각이라 겹치지 않는다', () {
      expect(ClipboardImage.nameFor(DateTime(2026, 8, 11, 9, 5, 3)),
          '20260811_090503.png');
      expect(ClipboardImage.nameFor(DateTime(2026, 12, 31, 23, 59, 59)),
          '20261231_235959.png');
    });

    test('⚠️ 세션 폴더가 아니라 설정 파일 옆에 모은다', () {
      // 세션이 열린 폴더에 떨구면 남의 저장소에 PNG가 쌓인다.
      // 다른 설정 파일과 같은 자리라 옮길 때 같이 딸려간다.
      expect(ClipboardImage.dirPath, endsWith('pasted'));
      expect(ClipboardImage.dirPath,
          startsWith(resolveConfigPath('').replaceAll(RegExp(r'/$'), '')));
    });

    test('오래된 것을 치워도 폴더가 없으면 조용히 넘어간다', () async {
      // 켤 때마다 도는 자리라 폴더가 없다고 터지면 안 된다.
      await expectLater(ClipboardImage.sweep(), completes);
    });

    test('박히는 모양은 끌어다 놓은 것과 같다', () {
      // 붙여넣은 그림은 세션 폴더 밖에 있으므로 절대경로로 박힌다.
      final token = dropToken('/tmp/pasted/20260811_090503.png', '/Users/me/proj');
      expect(token, '@/tmp/pasted/20260811_090503.png');
    });
  });

  group('밖으로 여는 열쇠', () {
    // ⚠️ TodoKey.value 는 디스크를 건드리므로 여기서는 순수한 부분만 본다.
    test('짐작할 수 없는 값이어야 한다', () {
      final a = TodoKey.generateKey(), b = TodoKey.generateKey();
      expect(a, hasLength(32));
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a, isNot(b), reason: '켤 때마다 같으면 자물쇠가 아니다');
    });

    test('훅 포트와 나눠 둔다 — 훅은 밖으로 열지 않는다', () {
      expect(kTodoPort, isNot(kPort));
    });

    test('쿠키로도 열린다 — 폰 북마크에 열쇠를 안 달고 다녀도 된다', () {
      // 실물 대신 같은 판단 규칙을 눈으로 확인한다.
      bool allows(String? q, String? cookie, String key) =>
          q == key || cookie == key;
      expect(allows('abc', null, 'abc'), isTrue, reason: '주소에 실려 온 것');
      expect(allows(null, 'abc', 'abc'), isTrue, reason: '쿠키로 온 것');
      expect(allows(null, null, 'abc'), isFalse);
      expect(allows('틀림', '틀림', 'abc'), isFalse);
    });
  });

  group('시계는 훅이 돌린다', () {
    final t0 = DateTime(2026, 8, 11, 10);
    List<TodoItem> three() => [
          TodoItem(text: 'a', project: '/p', at: DateTime(2026, 8, 11, 9)),
          TodoItem(text: 'b', project: '/p', at: DateTime(2026, 8, 11, 9, 1)),
          TodoItem(text: '남의 것', project: '/q', at: DateTime(2026, 8, 11, 9, 2)),
        ];

    test('시키면 진행중이 되고 시계가 돈다', () {
      final out = TodoStore.started(three(), 0, t0);
      expect(out[0].status, TaskStatus.running);
      expect(out[0].startedAt, t0);
    });

    test('⚠️ 같은 세션에서 재는 것은 하나뿐이다 — 앞엣것은 확인필요로 넘어간다', () {
      // 훅은 세션 단위라, 둘을 동시에 재면 Stop 하나로 둘 다 멈춰야 하는데
      // 그러면 그 시간이 어느 쪽 것인지 알 수 없다.
      var out = TodoStore.started(three(), 0, t0);
      out = TodoStore.started(out, 1, t0.add(const Duration(minutes: 5)));
      expect(out[0].ticking, isFalse);
      expect(out[0].status, TaskStatus.review);
      expect(out[0].spentSec, 300, reason: '멈추면서 잰 만큼이 누적에 들어간다');
      expect(out[1].ticking, isTrue);
    });

    test('다른 세션이 재는 것은 안 건드린다', () {
      var out = TodoStore.started(three(), 2, t0);
      out = TodoStore.started(out, 0, t0.add(const Duration(minutes: 1)));
      expect(out[2].ticking, isTrue, reason: '칸이 다르면 남남이다');
    });

    test('Stop이 오면 확인필요로 넘어간다 — 완료가 아니다', () {
      var out = TodoStore.started(three(), 0, t0);
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 30)));
      expect(out[0].status, TaskStatus.review,
          reason: '시킨 일이 끝났다는 뜻이지 다 됐다는 뜻이 아니다');
      expect(out[0].spentSec, 1800);
      expect(out[0].ticking, isFalse);
      expect(out[0].startedAt, t0, reason: '노션처럼 시작시간은 남긴다');
      expect(out[0].stoppedAt, t0.add(const Duration(minutes: 30)),
          reason: '최근 중지 시간이 있어야 다음 정산이 이 구간을 다시 안 더한다');
    });

    test('문항이 여럿이면 문항 표를 읽고 앞말에서 뺀다', () {
      String fx(String name) =>
          File('test/fixtures/panes/20260831_문항두개/$name').readAsStringSync();
      final first = PaneChoice.parse(fx('01_문항1_Next.txt'))!;
      expect(first.tabs.map((t) => t.label), ['Fruit', 'Drink']);
      expect(first.tabs.every((t) => !t.done), isTrue);
      expect(first.tabAt, 1);
      expect(first.question, 'Which fruits?');
      expect(first.lead.any((l) => l.contains('←')), isFalse, reason: '화살표 줄은 앞말이 아니다');

      final second = PaneChoice.parse(fx('03_문항2_Submit.txt'))!;
      expect(second.tabs.map((t) => '${t.label}:${t.done}'), ['Fruit:true', 'Drink:false']);
      expect(second.tabAt, 2, reason: '답 안 한 첫 칸이 지금 문항이다');
      expect(second.question, 'Which drinks?');

      expect(PaneTab.parseTabs('그냥 글줄'), isEmpty);
    });

    test('칸 안에서 불이 센 것이 위로 온다 — 지난 마감이 그보다 먼저다', () {
      TodoItem t(String name, {TaskPriority p = TaskPriority.one, DateTime? due}) => TodoItem(
          text: name, project: '/p', status: TaskStatus.today, assignee: kOwnerAssignee,
          priority: p, due: due, at: DateTime(2026, 9, 1));
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final list = [
        t('보통'),
        t('불셋', p: TaskPriority.three),
        t('타임기록', p: TaskPriority.timeLog),
        t('불둘', p: TaskPriority.two),
        t('지난마감', due: yesterday),
      ]..sort(TodoBoard.compare);
      expect(list.map((x) => x.text), ['지난마감', '불셋', '불둘', '보통', '타임기록']);
    });

    test('진행중에서 바로 완료로 끝내는 것은 대표 담당뿐이다 (A안)', () {
      TodoItem t({String? who}) =>
          TodoItem(text: 'x', project: '/p', status: TaskStatus.running, assignee: who);
      expect(TodoStore.finishesSelf(t(who: kOwnerAssignee)), isTrue);
      expect(TodoStore.finishesSelf(t(who: '/p')), isFalse, reason: '세션이 한 일은 대표가 보고 판단한다');
      expect(TodoStore.finishesSelf(t()), isFalse, reason: '담당이 비면 시키기가 세션으로 보낸다 — 대표 것이 아니다');
    });

    test('하위는 상위와 같은 칸에서 시작한다 — 차례를 물려받는다', () {
      TodoItem p(TaskStatus st, {String? who}) =>
          TodoItem(text: '상위', project: '/p', status: st, assignee: who);
      expect(Todos.childStatusOf(p(TaskStatus.today, who: kOwnerAssignee)), TaskStatus.today);
      expect(Todos.childStatusOf(p(TaskStatus.today, who: '/p')), TaskStatus.sessionPlanned,
          reason: '담당이 세션이면 오늘예정이어도 세션 차례 칸이다');
      expect(Todos.childStatusOf(p(TaskStatus.review, who: kOwnerAssignee)), TaskStatus.today,
          reason: '확인필요도 내 차례 칸이다');
      expect(Todos.childStatusOf(p(TaskStatus.sessionPlanned, who: '/p')), TaskStatus.sessionPlanned);
      expect(Todos.childStatusOf(p(TaskStatus.revision, who: '/p')), TaskStatus.sessionPlanned,
          reason: '수정요청도 세션 차례 칸이다');
      expect(Todos.childStatusOf(p(TaskStatus.running, who: '/p')), TaskStatus.sessionPlanned,
          reason: '⚠️ 진행중을 그대로 물려주면 하위에 시계가 저절로 돈다');
      expect(Todos.childStatusOf(p(TaskStatus.running, who: kOwnerAssignee)), TaskStatus.today);
      expect(Todos.childStatusOf(p(TaskStatus.paused)), TaskStatus.waiting);
      expect(Todos.childStatusOf(p(TaskStatus.done)), TaskStatus.waiting);
    });

    test('수정사항이 적힌 채 다시 시작하면 한 회차가 닫히고 작업 내용이 비워진다', () {
      final base = three();
      base[0] = base[0].copyWith(content: '1차 결과', revisionNote: '버튼 색 바꿔', status: TaskStatus.revision);
      var out = TodoStore.started(base, 0, t0);
      expect(out[0].rounds, hasLength(1));
      expect(out[0].rounds.single.content, '1차 결과');
      expect(out[0].rounds.single.note, '버튼 색 바꿔');
      expect(out[0].content, '');
      expect(out[0].revisionNote, '');
      // 2회차 — 다시 수정요청
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 5)));
      out[0] = out[0].copyWith(content: '2차 결과', revisionNote: '간격도', status: TaskStatus.revision);
      out = TodoStore.started(out, 0, t0.add(const Duration(minutes: 10)));
      expect(out[0].rounds.map((r) => r.content), ['1차 결과', '2차 결과']);
      expect(TodoItem.fromJson(out[0].toJson())!.rounds.last.note, '간격도', reason: '파일에 남는다');
    });

    test('수정사항이 없으면 회차를 안 닫는다 · 재는 중에 다시 시작해도 안 닫는다', () {
      final base = three();
      base[0] = base[0].copyWith(content: '결과');
      var out = TodoStore.started(base, 0, t0);
      expect(out[0].rounds, isEmpty);
      expect(out[0].content, '결과');
      out[0] = out[0].copyWith(revisionNote: '재는 중에 적음');
      out = TodoStore.started(out, 0, t0.add(const Duration(minutes: 1)));
      expect(out[0].rounds, isEmpty, reason: '다음에 다시 시작할 때 닫는다');
    });

    test('⚠️ 시키기가 보낼 말에는 수정사항이 들어간 뒤에 회차가 닫힌다', () {
      final t = three()[0].copyWith(content: 'a', revisionNote: '고칠 것', status: TaskStatus.revision);
      expect(t.dispatch, contains('고칠 것'));
      expect(TodoStore.started([t], 0, t0)[0].revisionNote, '');
    });

    test('⚠️ 세션이 API로 시작한 시계는 턴 끝에 안 멈춘다 — 세션이 끝나야 멈춘다', () {
      var out = TodoStore.started(three(), 0, t0, held: true);
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 3)));
      expect(out[0].ticking, isTrue, reason: '대표와 주고받는 기획이 첫 답에서 3분에 끊겼다(9/15)');
      expect(out[0].status, TaskStatus.running);
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 30)), gone: true);
      expect(out[0].ticking, isFalse);
      expect(out[0].spentSec, 1800);
      expect(out[0].held, isFalse, reason: '멈추면 표시를 지운다');
    });

    test('API로 시작한 시계도 다른 태스크를 시작하면 멈춘다', () {
      var out = TodoStore.started(three(), 0, t0, held: true);
      out = TodoStore.started(out, 1, t0.add(const Duration(minutes: 5)));
      expect(out[0].ticking, isFalse);
      expect(out[0].held, isFalse);
      expect(out[1].held, isFalse, reason: '시키기로 돈 시계는 턴 끝에 멈춘다');
    });

    test('held는 파일에 남는다 — 위젯을 다시 켜도 턴 끝에 안 멈춘다', () {
      final t = TodoStore.started(three(), 0, t0, held: true)[0];
      expect(TodoItem.fromJson(t.toJson())!.held, isTrue);
      expect(TodoItem.fromJson(three()[0].toJson())!.held, isFalse);
    });

    test('⚠️ 멈춘 뒤 다시 시작하면 새 구간만 더한다', () {
      var out = TodoStore.started(three(), 0, t0);
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 10)));
      final t1 = t0.add(const Duration(hours: 1));
      out = TodoStore.started(out, 0, t1);
      expect(out[0].startedAt, t1);
      expect(out[0].ticking, isTrue);
      expect(out[0].spentAt(t1.add(const Duration(minutes: 5))), 900,
          reason: '앞 구간 10분 + 새 구간 5분 — 점심시간이 끼면 안 된다');
    });

    test('⚠️ 두 번 시켜도 잰 시간이 0으로 안 돌아간다', () {
      var out = TodoStore.started(three(), 0, t0);
      out = TodoStore.started(out, 0, t0.add(const Duration(minutes: 10)));
      expect(out[0].startedAt, t0);
      out = TodoStore.ended(out, '/p', t0.add(const Duration(minutes: 20)));
      expect(out[0].spentSec, 1200);
    });

    test('안 재던 것에 Stop이 와도 아무 일도 안 난다', () {
      final before = three();
      final out = TodoStore.ended(before, '/p', t0);
      expect(out.map((t) => t.spentSec), everyElement(0));
      expect(out.map((t) => t.status), everyElement(TaskStatus.waiting));
    });
  });

  group('훅 cwd 바로잡기', () {
    // 2026-08-10에 실제로 터진 자리를 본뜬 것이다. 이름 규칙은 실측했다 —
    // 영숫자가 아닌 글자는 전부 대시 하나다(한글 한 글자도 하나).
    const tp = '/Users/me/.claude/projects/'
        '-Users-nemo-Desktop---/abc.jsonl';
    const home = '/Users/nemo/Desktop/일감';

    test('⚠️ 도구가 하위에서 돌아 cwd가 내려가도 세션 폴더로 돌려놓는다', () {
      // 실제로 터진 자리다 — .claude 라는 임시 캐릭터로 세션이 통째로 샜다.
      expect(resolveSessionCwd('$home/.claude', tp), home);
    });

    test('여러 단계 아래에서 와도 찾아 올라간다', () {
      expect(resolveSessionCwd('$home/a/b/c', tp), home);
    });

    test('이미 세션 폴더면 그대로 둔다', () {
      expect(resolveSessionCwd(home, tp), home);
    });

    test('하위 폴더에서 따로 띄운 세션은 제 자리를 지킨다', () {
      // 그 세션의 transcript 폴더는 그 하위를 가리키므로 안 올라간다.
      const sub = '$home/01_오타쿠기록부/otaku_log';
      const subTp = '/Users/me/.claude/projects/'
          '-Users-nemo-Desktop----01--------otaku-log/x.jsonl';
      expect(resolveSessionCwd(sub, subTp), sub);
    });

    test('transcript가 없으면 손대지 않는다', () {
      expect(resolveSessionCwd('$home/.claude', null), '$home/.claude');
      expect(resolveSessionCwd('$home/.claude', ''), '$home/.claude');
    });

    test('맞는 조상이 없으면 그대로 둔다', () {
      expect(resolveSessionCwd('/tmp/딴데', tp), '/tmp/딴데');
    });
  });

  group('끌어다 놓은 파일', () {
    const root = '/Users/me/proj';

    test('세션 폴더 아래면 상대경로로 줄인다', () {
      expect(dropToken('$root/lib/main.dart', root), '@lib/main.dart');
    });

    test('세션 폴더 밖이면 절대경로 그대로', () {
      expect(dropToken('/tmp/메모.txt', root), '@/tmp/메모.txt');
    });

    test('이름만 비슷한 형제 폴더를 하위로 착각하지 않는다', () {
      // /Users/me/proj2 는 /Users/me/proj 의 하위가 아니다
      expect(dropToken('/Users/me/proj2/a.dart', root),
          '@/Users/me/proj2/a.dart');
    });

    test('세션 폴더 자기 자신이면 절대경로', () {
      expect(dropToken(root, root), '@$root');
    });

    test('⚠️ 한글 경로는 NFD로 들어와도 같은 폴더로 본다', () {
      // macOS가 주는 경로는 자모가 분리돼 있다(NFD). 등록 경로는 완성형이다.
      // ⚠️ 이스케이프로 써야 한다 — 한글을 그대로 적으면 편집기가 완성형으로
      // 정규화해 버려서 검사가 헛돈다.
      const nfd = '/Users/me/무위'; // /Users/me/무위
      expect(nfd.length, 14, reason: 'NFD 리터럴이 완성형으로 바뀌었다');
      expect(dropToken('$nfd/lib/a.dart', '/Users/me/무위'), '@lib/a.dart');
    });

    test('끝의 슬래시가 있어도 같은 결과', () {
      expect(dropToken('$root/a.dart', '$root/'), '@a.dart');
    });
  });

  group('@ 로 파일 집기', () {
    test('@ 뒤에 친 글자를 토큰으로 준다', () {
      expect(atToken('이거 봐줘 @main'), 'main');
      expect(atToken('@'), '');
    });

    test('공백이 들어가면 이름이 끝난 것으로 본다', () {
      expect(atToken('@lib/main.dart 이거 고쳐줘'), isNull);
      expect(atToken('그냥 할 말'), isNull);
    });

    test('마지막 @ 를 본다', () {
      expect(atToken('@CLAUDE.md 랑 @log'), 'log');
    });

    test('파일 이름에 걸린 것이 경로에 걸린 것보다 앞이다', () {
      // main 은 lib/main.dart 의 이름이고 main_notes/… 는 경로다.
      final hit = matchFiles(files, 'main');
      expect(hit.first, 'lib/main.dart');
      expect(hit, contains('main_notes/읽을거리.md'));
    });

    test('대소문자를 가리지 않는다', () {
      expect(matchFiles(files, 'claude'), contains('CLAUDE.md'));
    });

    test('한글 이름도 찾는다', () {
      expect(matchFiles(files, '읽을'), ['main_notes/읽을거리.md']);
    });

    test('@ 만 쳤으면 앞에서부터 몇 개 준다', () {
      expect(matchFiles(files, '', max: 3).length, 3);
    });

    test('없는 이름이면 비어 있다', () {
      expect(matchFiles(files, 'zzz없다'), isEmpty);
    });
  });
}

/// 입력창에 `/`를 쳤을 때 무엇을 내거는지.
void _slashTests() {
  group('슬래시 명령 고르기', () {
    test('/ 만 치면 전부 준다', () {
      expect(matchSlash('/').length, kSlashCommands.length);
    });

    test('친 글자로 추린다', () {
      final names = matchSlash('/co').map((c) => c.name).toList();
      expect(names, containsAll(['/compact', '/context']));
      expect(names, isNot(contains('/clear')));
    });

    test('슬래시로 시작하지 않으면 내걸지 않는다', () {
      expect(matchSlash('테스트 돌려줘'), isEmpty);
      expect(matchSlash(''), isEmpty);
    });

    test('인자를 쓰는 중이면 비켜 준다', () {
      // `/model opus` 를 치는 중에 목록이 뜨면 가리기만 한다.
      expect(matchSlash('/model opus'), isEmpty);
    });

    test('없는 명령이면 아무것도 안 준다', () {
      expect(matchSlash('/없는명령'), isEmpty);
    });
  });
}

/// 상태바에서 권한 모드를 읽어내는지. 훅은 이걸 알려주지 않는다.
void _modeTests() {
  group('권한 모드 읽기', () {
    String pane(String status) => '⏺ 뭔가 했다\n\n❯ \n$status';

    test('실측한 상태바에서 모드를 뽑는다', () {
      // 2026-08-06에 돌던 세 세션에서 그대로 떠온 줄들이다.
      expect(
        PaneView.mode(pane(
            '  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← 1 agent')),
        'bypass permissions',
      );
      expect(
        PaneView.mode(pane(
            '  ⏵⏵ bypass permissions on · 1 shell · ← 1 agent · ↓ to manage')),
        'bypass permissions',
      );
    });

    test('계획 모드도 읽는다', () {
      expect(PaneView.mode(pane('  ⏸ plan mode on (shift+tab to cycle)')),
          'plan mode');
    });

    test('편집 승인 모드도 읽는다', () {
      expect(PaneView.mode(pane('  ⏵⏵ accept edits on · esc to interrupt')),
          'accept edits');
    });

    test('상태바가 없으면 null — 기본 모드다', () {
      expect(PaneView.mode('⏺ 그냥 답변\n\n❯ '), isNull);
      expect(PaneView.mode(null), isNull);
    });

    test('위쪽에 지나간 같은 글자를 줍지 않는다', () {
      // 대화 내용에 상태바처럼 생긴 줄이 남아 있을 수 있다. 꼬리만 본다.
      final old = ['  ⏵⏵ plan mode on', '', ...List.filled(8, '⏺ 뭔가'), '❯ '];
      expect(PaneView.mode(old.join('\n')), isNull);
    });
  });
}

/// 아직 안 깨어난 세션의 대화를 저장이 지워 버리지 않는지.
void _chatSaveTests() {
  AgentSession session(String path, List<ChatEntry> chat) {
    final s = AgentSession(
        project: WatchedProject(path: path, name: path.split('/').last));
    s.chat.addAll(chat);
    return s;
  }
  group('대화 저장', () {
    test('복원이 실패해도 디스크에 있던 대화를 덮어쓰지 않는다', () {
      // 복원이 어떤 이유로든 실패하면, 살아 있는 세션의 짧은 대화가 같은
      // 키를 덮어써 옛 대화가 통째로 날아갔다. 실제로 당했다 — 77줄이
      // 2줄로 줄었다. 저장만은 그걸 지우지 않아야 한다.
      final old = DateTime(2026, 8, 6, 20, 45);
      final prior = {
        '/a/집': [
          ChatEntry(kind: ChatKind.mine, text: '지난 대화', at: old),
          ChatEntry(kind: ChatKind.reply, text: '지난 답', at: old),
        ],
      };
      final live = session('/a/집', [
        ChatEntry(kind: ChatKind.mine, text: '새 말', at: DateTime(2026, 8, 6, 22)),
      ]);
      final rows = ChatStore.encode([live], prior);
      final lines = rows['/a/집'] as List;
      expect(lines.length, 3, reason: '옛 2줄 + 새 1줄');
      expect((lines.first as Map)['text'], '지난 대화');
      expect((lines.last as Map)['text'], '새 말');
    });

    test('겹치는 줄은 두 번 담지 않는다', () {
      final at = DateTime(2026, 8, 6, 20, 45);
      final entry = ChatEntry(kind: ChatKind.mine, text: '같은 말', at: at);
      final rows = ChatStore.encode(
        [session('/a/집', [ChatEntry(kind: ChatKind.mine, text: '같은 말', at: at)])],
        {'/a/집': [entry]},
      );
      expect((rows['/a/집'] as List).length, 1);
    });

    test('세션이 안 깨어났어도 그 대화를 지우지 않는다', () {
      // 세션은 훅이 와야 생긴다. 먼저 깨어난 세션 하나 때문에 저장이 돌면
      // 아직 조용한 세션들의 대화가 통째로 날아갔다 — 실제로 당했다.
      final pending = {
        '/a/조용한': [ChatEntry(kind: ChatKind.reply, text: '지난 대화')],
      };
      final data = ChatStore.encode(const [], pending);
      expect(data['/a/조용한'], isNotNull);
      expect((data['/a/조용한'] as List).length, 1);
    });

    test('비어 있는 것은 담지 않는다', () {
      final data = ChatStore.encode(const [], {'/b/빈방': <ChatEntry>[]});
      expect(data, isEmpty);
    });
  });

  group('transcript 스스로 찾기', () {
    test('클로드 코드의 폴더 이름 규칙을 그대로 따른다', () {
      // 실측으로 확인한 실제 폴더 이름들이다(2026-08-06).
      expect(TranscriptFinder.dirName('/Users/nemo/Desktop/일감'),
          '-Users-nemo-Desktop---');
      expect(
        TranscriptFinder.dirName(
            '/Users/nemo/Desktop/일감/02_클로드워쳐/claude_watcher'),
        '-Users-nemo-Desktop----02-------claude-watcher',
      );
      // 공백도 한 글자에 대시 하나다
      expect(
        TranscriptFinder.dirName('/Users/nemo/Desktop/작업 폴더/03_배너 디자인'),
        '-Users-nemo-Desktop-------03-------',
      );
    });

    test('없는 프로젝트면 null', () {
      expect(TranscriptFinder.latest('/없는/폴더/여기'), isNull);
    });
  });
}

/// 턴이 끝나기 전에 한 말까지 따라 읽는다.
///
/// `Stop`의 `last_assistant_message`는 턴의 **마지막 한 마디**뿐이라, 도구를
/// 부르기 전에 한 말들이 메시지 탭에서 통째로 사라졌다. 그걸 푸는 쪽이다.
void _speechTests() {
  group('말 따라 읽기 (증분)', () {
    late File file;

    setUp(() {
      file = File('${Directory.systemTemp.path}/cw_speech.jsonl');
      if (file.existsSync()) file.deleteSync();
    });

    /// jsonl 한 줄을 실제 파일처럼 **개행까지 붙여** 덧쓴다.
    void append(String line) =>
        file.writeAsStringSync('$line\n', mode: FileMode.append);

    String say(String uuid, String text) =>
        '{"type":"assistant","uuid":"$uuid","message":{"role":"assistant",'
        '"content":[{"type":"text","text":"$text"}]}}';

    test('처음 읽을 때는 마지막 사람 발화 뒤의 말만 올린다', () {
      // 앱을 켜자마자 지난 턴이 통째로 쏟아지면 대화가 아니라 로그가 된다.
      append('{"type":"user","message":{"role":"user","content":"첫 질문"}}');
      append(say('a', '지난 턴의 말'));
      append('{"type":"user","message":{"role":"user","content":"둘째 질문"}}');
      append(say('b', '이번 턴의 말'));

      final batch = TranscriptReader.since(file.path, 0)!;
      expect(batch.speeches.map((s) => s.text), ['이번 턴의 말']);
      expect(batch.offset, file.lengthSync());
    });

    test('이어 읽으면 새로 붙은 말만 온다', () {
      append('{"type":"user","message":{"role":"user","content":"고쳐줘"}}');
      append(say('a', '먼저 보겠다'));
      final first = TranscriptReader.since(file.path, 0)!;
      expect(first.speeches.map((s) => s.text), ['먼저 보겠다']);

      // 도구를 쓰고 한 마디 더 했다 — 이게 예전에는 사라지던 말이다.
      append('{"type":"assistant","uuid":"t","message":{"role":"assistant",'
          '"content":[{"type":"tool_use","name":"Read","input":{}}]}}');
      append(say('b', '여기가 원인이다'));

      final second = TranscriptReader.since(file.path, first.offset)!;
      expect(second.speeches.map((s) => s.text), ['여기가 원인이다']);
    });

    test('더 붙은 게 없으면 빈 손으로 돌아온다', () {
      append(say('a', '한 마디'));
      final first = TranscriptReader.since(file.path, 0)!;
      final again = TranscriptReader.since(file.path, first.offset)!;
      expect(again.speeches, isEmpty);
      expect(again.offset, first.offset);
    });

    test('반쯤 쓰인 줄은 삼키지 않는다', () {
      // jsonl은 한 줄이 쓰이는 도중일 수 있다. 소비해 버리면 그 말은 영영 못 읽는다.
      append(say('a', '다 쓰인 말'));
      final done = TranscriptReader.since(file.path, 0)!;
      expect(done.speeches.length, 1);

      file.writeAsStringSync('{"type":"assistant","uuid":"b","mes',
          mode: FileMode.append);
      final mid = TranscriptReader.since(file.path, done.offset)!;
      expect(mid.speeches, isEmpty);
      // 자리를 안 옮겼으니 다 쓰이면 그때 읽는다
      expect(mid.offset, done.offset);

      file.writeAsStringSync(
          'sage":{"role":"assistant","content":[{"type":"text","text":"늦게 온 말"}]}}\n',
          mode: FileMode.append);
      final late = TranscriptReader.since(file.path, mid.offset)!;
      expect(late.speeches.map((s) => s.text), ['늦게 온 말']);
    });

    test('서브에이전트가 제 안에서 한 말은 거른다', () {
      append(say('a', '본 대화'));
      append('{"type":"assistant","uuid":"s","isSidechain":true,'
          '"message":{"role":"assistant","content":[{"type":"text","text":"곁가지"}]}}');
      final batch = TranscriptReader.since(file.path, 0)!;
      expect(batch.speeches.map((s) => s.text), ['본 대화']);
    });

    test('thinking만 있는 줄은 올리지 않는다', () {
      append('{"type":"assistant","uuid":"t","message":{"role":"assistant",'
          '"content":[{"type":"thinking","thinking":"속으로"}]}}');
      expect(TranscriptReader.since(file.path, 0)!.speeches, isEmpty);
    });

    test('말마다 uuid가 붙어 같은 말을 두 번 올리지 않는다', () {
      append(say('a', '같은 말'));
      append(say('b', '같은 말'));
      final batch = TranscriptReader.since(file.path, 0)!;
      expect(batch.speeches.map((s) => s.uuid), ['a', 'b']);
    });

    test('파일이 갈려 짧아지면 꼬리부터 다시 본다', () {
      for (final u in ['a', 'b', 'c', 'd']) {
        append(say(u, '$u 말'));
      }
      final first = TranscriptReader.since(file.path, 0)!;
      expect(first.speeches.length, 4);

      // 파일이 갈려 옛 offset이 파일 끝을 넘어섰다. 그 자리에서 이어 읽으면
      // 파일 밖을 가리키므로, 처음 읽는 것처럼 꼬리부터 다시 본다.
      file.writeAsStringSync('');
      append(say('z', '새 말'));
      expect(file.lengthSync(), lessThan(first.offset));

      final batch = TranscriptReader.since(file.path, first.offset)!;
      expect(batch.speeches.map((s) => s.text), ['새 말']);
    });

    test('없는 파일이면 null', () {
      expect(TranscriptReader.since('/없는/경로.jsonl', 0), isNull);
    });
  });
}

void _tableTests() {
  group('마크다운 표 가르기', () {
    test('머리행과 내용행을 나누고 구분선은 버린다', () {
      final rows = parseMarkdownTable([
        '| 항목 | 값 | 비고 |',
        '|---|---|---|',
        '| 파일 | main.dart | 수정 |',
        '| 줄 수 | 2980 | +120 |',
      ]);
      expect(rows.length, 3); // 구분선이 빠져야 3
      expect(rows.first, ['항목', '값', '비고']);
      expect(rows[1], ['파일', 'main.dart', '수정']);
    });

    test('정렬 표시가 든 구분선도 버린다', () {
      final rows = parseMarkdownTable([
        '| a | b |',
        '|:---|---:|',
        '| 1 | 2 |',
      ]);
      expect(rows.length, 2);
    });

    test('양끝 막대가 없어도 가른다', () {
      expect(parseMarkdownTable(['a | b']), [
        ['a', 'b']
      ]);
    });

    test('칸 수가 모자란 행도 그대로 돌려준다', () {
      final rows = parseMarkdownTable([
        '| a | b | c |',
        '| 1 | 2 |',
      ]);
      expect(rows[1].length, 2);
    });
  });
}

void _securityTests() {
  group('transcript 경로 제한', () {
    const home = '/Users/x';

    test('클로드가 쓰는 폴더 아래는 읽는다', () {
      expect(
        isTranscriptPathAllowed('$home/.claude/projects/p/a.jsonl', home: home),
        isTrue,
      );
    });

    test('그 밖의 경로는 읽지 않는다', () {
      expect(isTranscriptPathAllowed('/etc/passwd', home: home), isFalse);
      expect(
        isTranscriptPathAllowed('$home/Documents/비밀.jsonl', home: home),
        isFalse,
      );
    });

    test('.. 로 빠져나가려는 경로를 막는다', () {
      expect(
        isTranscriptPathAllowed(
            '$home/.claude/projects/../../.ssh/id_rsa.jsonl',
            home: home),
        isFalse,
      );
    });

    test('jsonl이 아니면 읽지 않는다', () {
      expect(
        isTranscriptPathAllowed('$home/.claude/projects/p/a.txt', home: home),
        isFalse,
      );
    });

    test('HOME을 모르면 아무것도 허용하지 않는다', () {
      expect(
        isTranscriptPathAllowed('/.claude/projects/p/a.jsonl', home: ''),
        isFalse,
      );
    });
  });

  group('차단 목록', () {
    final list = BlockList(['/w/95_보안자료', '/w/98_가계부']);

    test('그 폴더와 하위를 막는다', () {
      expect(list.blocks('/w/95_보안자료'), isTrue);
      expect(list.blocks('/w/95_보안자료/인감'), isTrue);
    });

    test('이름만 비슷한 형제는 막지 않는다', () {
      expect(list.blocks('/w/95_보안자료2'), isFalse);
      expect(list.blocks('/w/97_웹사이트'), isFalse);
    });

    test('표기가 달라도(NFD) 막는다', () {
      final l = BlockList(['/w/무위']); // /w/무위
      expect(l.blocks('/w/무위/sub'), isTrue);
    });
  });

  group('선택창 읽기', () {
    // 실제로 떠온 화면이다 (test/fixtures/panes/20260804/01_launch.txt).
    const trust = ' Quick safety check: Is this a project you trust?\n'
        '\n'
        " Claude Code'll be able to read, edit, and execute files here.\n"
        '\n'
        ' Security guide\n'
        '\n'
        ' ❯ 1. Yes, I trust this folder\n'
        '   2. No, exit\n'
        '\n'
        ' Enter to confirm · Esc to cancel';

    // 승인창은 네모 상자 안에 들어온다.
    const permission = '╭────────────────────────────────╮\n'
        '│ Bash command                   │\n'
        '│                                │\n'
        '│   rm -rf build                 │\n'
        '│                                │\n'
        '│ Do you want to proceed?        │\n'
        '│ ❯ 1. Yes                       │\n'
        "│   2. Yes, and don't ask again  │\n"
        '│   3. No, and tell Claude what  │\n'
        '╰────────────────────────────────╯';

    test('선택지와 커서 자리를 읽는다', () {
      final c = PaneChoice.parse(trust)!;
      expect(c.options.length, 2);
      expect(c.options.first.text, 'Yes, I trust this folder');
      expect(c.options.last.text, 'No, exit');
      expect(c.cursor, 1);
    });

    test('상자 테두리를 걷어내고 읽는다', () {
      final c = PaneChoice.parse(permission)!;
      expect(c.options.length, 3);
      expect(c.options[1].text, "Yes, and don't ask again");
      expect(c.cursor, 1);
    });

    test('물음표로 끝나는 줄만 물음으로 내건다', () {
      expect(PaneChoice.parse(permission)!.question, 'Do you want to proceed?');
      // 신뢰 확인창은 선택지 바로 위가 링크 이름이라 물음이 아니다.
      expect(PaneChoice.parse(trust)!.question, isNull);
    });

    test('실제로 떠온 화면을 그대로 읽는다', () {
      // test/fixtures/panes/20260804/06_choice_live.txt — 2026-08-05 라이브 캡처.
      final f = File('test/fixtures/panes/20260804/06_choice_live.txt');
      final c = PaneChoice.parse(f.readAsStringSync())!;
      expect(c.options.map((o) => o.text).toList(),
          ['Yes, I trust this folder', 'No, exit']);
      expect(c.cursor, 1);
    });

    test('응답 본문의 번호 목록은 선택창이 아니다', () {
      const reply = ' 정리하면 이렇다.\n'
          '\n'
          ' 1. 파서를 붙였다\n'
          ' 2. 테스트를 넣었다\n'
          ' 3. 빌드했다\n';
      expect(PaneChoice.parse(reply), isNull);
    });

    test('화면 위쪽의 번호 목록에 속지 않는다', () {
      // 꼬리에 확인 안내가 있어도 목록이 위쪽이면 잡히지 않는다.
      final long = [
        ' 1. 위쪽 목록',
        ' 2. 두번째',
        ...List.filled(30, ' 아무 말'),
        ' Enter to confirm',
      ].join('\n');
      expect(PaneChoice.parse(long), isNull);
    });

    test('선택지가 하나뿐이면 선택창이 아니다', () {
      expect(PaneChoice.parse(' ❯ 1. Yes\n Enter to confirm'), isNull);
    });

    test('차례가 어긋난 번호는 선택지로 세지 않는다', () {
      expect(PaneChoice.parse(' 1. 하나\n 5. 다섯\n Enter to confirm'), isNull);
    });

    test('빈 화면이면 null', () {
      expect(PaneChoice.parse(null), isNull);
      expect(PaneChoice.parse(''), isNull);
    });

    test('화살표로 옮기는 창은 따로 알아본다', () {
      expect(PaneChoice.isCursorPrompt('  ←/→ to adjust'), isTrue);
      expect(PaneChoice.isCursorPrompt(trust), isFalse);
    });

    test('꼬리 몇 줄은 테두리를 걷어내고 준다', () {
      final t = PaneChoice.tail(permission, max: 3);
      expect(t.length, 3);
      expect(t.last, '3. No, and tell Claude what');
      expect(t.every((l) => !l.contains('│')), isTrue);
    });
  });

  group('설정을 어디서 찾나', () {
    // 예전에는 만든 사람의 절대경로가 main.dart에 박혀 있었다. 남의 기계에는
    // 없는 경로라 받아도 설정도 그림도 못 찾았다. 실행 파일 위치에서 되짚는
    // 방식으로 바꿨는데, 그 과정에서 기존 설정이 안 깨지는 것이 제일 중요하다.
    test('작업 디렉토리를 가장 먼저 본다', () {
      // flutter test 는 패키지 뿌리에서 돈다. 지금까지 쓰던 자리가 그곳이다.
      expect(kConfigRoots.first, Directory.current.path);
    });

    test('앱 바로 옆도 뒤진다 — 설치본이 이 모양이다', () {
      // ⚠️ 이게 없으면 파인더에서 더블클릭으로 띄울 때 설정을 못 찾는다.
      // 터미널에서 cd 해서 띄우면 우연히 맞으므로 안 드러난다(2026-09-09).
      final exe = File(Platform.resolvedExecutable).parent;
      final beside = exe.parent.parent.parent.path;
      expect(kConfigRoots, contains(beside));
    });

    test('설치해서 쓸 자리도 뒤진다', () {
      expect(kConfigRoots.any((r) => r.contains('Library/Application Support')),
          isTrue);
    });

    test('누구의 홈 경로도 박혀 있지 않다', () {
      // 오픈소스라 만든 사람의 절대경로가 소스에 남으면 안 된다.
      // 남의 기계에는 없는 경로라 아무 일도 못 하면서 이름만 드러낸다.
      // ⚠️ 이름을 여기 적어 두면 이 테스트가 그 이름을 드러낸다 — 돌리는 사람의 HOME을 쓴다.
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;
      final user = home.split('/').last;
      final files = [
        'lib/main.dart',
        'README.md',
        ...Directory('test/fixtures').listSync(recursive: true).whereType<File>().map((f) => f.path),
      ];
      for (final f in files) {
        final body = File(f).readAsStringSync();
        expect(body, isNot(contains(home)), reason: '$f 에 개인 경로가 남아 있다');
        expect(body, isNot(contains('-Users-$user-')), reason: '$f 에 인코딩된 개인 경로가 남아 있다');
      }
    });

    test('이미 있는 파일은 그 자리를 그대로 준다', () {
      // pubspec.yaml 은 반드시 작업 디렉토리에 있다.
      expect(resolveConfigPath('pubspec.yaml'),
          '${Directory.current.path}/pubspec.yaml');
    });

    test('프로젝트 폴더에서 돌면 거기에 만든다', () {
      // 작업 디렉토리에 pubspec.yaml 이 있으면 그곳을 쓴다 — 지금까지와 같다.
      expect(kConfigHome, Directory.current.path);
    });
  });

  group('기동 명령', () {
    // 위젯과 cw가 같은 명령을 쳐야 한다. 다르면 어느 쪽에서 띄웠는지를
    // 기억해야 하는데, 그건 못 지킬 약속이다.
    test('main.dart와 tmux_up.py가 같은 명령을 쓴다', () {
      final py = File('scripts/tmux_up.py').readAsStringSync();
      expect(py, contains('LAUNCH_COMMAND = "${Tmux.launchCommand}"'));
    });

    test('기본은 승인창을 받는 쪽이다', () {
      // ⚠️ 남이 받아 쓰는 도구라 안전한 쪽이 기본이어야 한다.
      // 예전에는 반대였다 — 그 전제('폴더가 전부 본인 것')가 깨졌다.
      expect(Tmux.launchCommand, 'claude');
    });

    test('승인 생략은 켜야 나온다', () {
      expect(Tmux.skipCommand, 'claude --dangerously-skip-permissions');
    });

    test('생략 명령도 두 곳이 같다', () {
      final py = File('scripts/tmux_up.py').readAsStringSync();
      expect(py, contains('SKIP_COMMAND = "${Tmux.skipCommand}"'));
    });

    test('표식 자리가 두 곳에서 같다', () {
      // ⚠️ 실제로 갈렸다(2026-09-09). 설치본을 저장소에서 떼어내자
      // 위젯은 설치본 옆을, cw 는 저장소를 봐서 책상은 🔓인데
      // cw yolo 는 꺼짐이라고 했다. 설치 자리와 무관한 한 곳이어야 한다.
      final py = File('scripts/tmux_up.py').readAsStringSync();
      expect(py, contains('"Library", "Application Support"'));
      expect(py, contains('"madang", "yolo"'));
      // 이름을 마당으로 바꾼 뒤(2026-09-16) 새 자리는 madang이다. 옛 폴더가 남아 있는 기계에서는
      // 그쪽을 계속 보므로(기록을 잃지 않으려고) 둘 중 하나로 끝나면 맞다.
      expect(
          Tmux.yoloPath.endsWith('/Library/Application Support/madang/yolo') ||
              Tmux.yoloPath.endsWith('/Library/Application Support/claude-watcher/yolo'),
          isTrue,
          reason: Tmux.yoloPath);
    });

    test('표식은 설치 자리를 따라가지 않는다', () {
      // resolveConfigPath 를 쓰면 설치본마다 달라진다 — 그게 갈린 원인이었다.
      expect(Tmux.yoloPath, isNot(contains(Directory.current.path)));
    });

    test('파일로도 켤 수 있다 — 파인더로 띄울 때 필요하다', () {
      // ⚠️ 환경변수만 두면 파인더에서 더블클릭했을 때 켤 방법이 없다.
      // 그러면 cw 로 띄운 세션과 위젯이 띄운 세션이 서로 다르게 군다.
      final src = File('lib/main.dart').readAsStringSync();
      expect(src, contains('static File get yoloFile'));
    });

    test('그래도 기본은 꺼져 있다', () {
      // 이 저장소에는 yolo 파일이 없다. 받아서 그냥 띄우면 승인창을 받는다.
      expect(File('yolo').existsSync(), isFalse);
      expect(Tmux.launchCommand, 'claude');
    });

    test('스크립트가 --yolo 로 켠다', () {
      // 옵션 이름이 바뀌면 문서와 어긋난다. 이름까지 굳혀 둔다.
      final py = File('scripts/tmux_up.py').readAsStringSync();
      expect(py, contains('"--yolo"'));
      expect(py, contains('CLAUDE_WATCHER_YOLO'));
      expect(py, isNot(contains('CLAUDE_WATCHER_ASK')));
    });

    test('세션 크기도 두 곳이 같다', () {
      // 짧으면 슬라이더 창의 옵션 줄이 잘려 위젯이 고를 것을 못 읽는다.
      final py = File('scripts/tmux_up.py').readAsStringSync();
      expect(py, contains('PANE_WIDTH = ${Tmux.paneWidth}'));
      expect(py, contains('PANE_HEIGHT = ${Tmux.paneHeight}'));
    });
  });

  group('진행 스트립 읽기', () {
    test('상태바와 빈 입력창은 걷어낸다', () {
      const pane = ' ⏺ Searching for 1 pattern…\n'
          ' ✽ Orbiting… (5s · ↓ 135 tokens)\n'
          '───────────── 프로젝트 세팅 요구사항 확인 ──\n'
          ' ❯ \n'
          '──────────────────────────────────────────\n'
          '  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt\n';
      expect(PaneView.activity(pane),
          ['⏺ Searching for 1 pattern…', '✽ Orbiting… (5s · ↓ 135 tokens)']);
    });

    test('글자가 박힌 구분선도 걷어낸다', () {
      // 입력창 위 테두리에 제목이 얹혀 온다. 늘 같은 자리라 진행이 아니다.
      const line = '───────────────────────── 프로젝트 세팅 요구사항 확인 ──';
      expect(PaneView.activity(line), isEmpty);
    });

    test('내가 친 말은 남긴다 — 무엇에 대한 작업인지 알려준다', () {
      const pane = ' ❯ 파일 세줘\n ⏺ 세는 중…\n';
      expect(PaneView.activity(pane), ['❯ 파일 세줘', '⏺ 세는 중…']);
    });

    test('마지막 max줄만 준다', () {
      final pane = List.generate(20, (i) => ' 줄 $i').join('\n');
      expect(PaneView.activity(pane, max: 3), ['줄 17', '줄 18', '줄 19']);
    });

    test('실제로 떠온 작업 화면에서 알맹이만 남는다', () {
      // test/fixtures/panes/20260804/07_working_live.txt — 2026-08-05 라이브 캡처.
      final f = File('test/fixtures/panes/20260804/07_working_live.txt');
      final lines = PaneView.activity(f.readAsStringSync(), max: 4);
      expect(lines, isNotEmpty);
      // 상태바가 한 줄도 안 섞여야 한다.
      expect(lines.any((l) => l.contains('permissions on')), isFalse);
      expect(lines.any((l) => l.contains('shortcuts')), isFalse);
      expect(lines.any((l) => l.startsWith('───')), isFalse);
      expect(lines.any((l) => l.contains('Tip:')), isFalse);
    });

    test('회전 안내문(Tip:)은 진행이 아니다', () {
      const pane = ' ⏺ 세는 중…\n'
          '  ⎿  Tip: Use /btw to ask a quick side question\n';
      expect(PaneView.activity(pane), ['⏺ 세는 중…']);
    });

    test('빈 화면이면 빈 목록', () {
      expect(PaneView.activity(null), isEmpty);
      expect(PaneView.activity(''), isEmpty);
    });
  });

  group('도구 한 줄 요약', () {
    test('Bash는 명령을 보여준다', () {
      expect(toolSummary('Bash', {'command': 'flutter test'}),
          'Bash · flutter test');
    });

    test('파일을 다루는 도구는 파일 이름만 남긴다', () {
      // 절대경로를 다 적으면 한 줄을 통째로 먹는다.
      expect(toolSummary('Edit', {'file_path': '/a/b/c/main.dart'}),
          'Edit · main.dart');
      expect(toolSummary('Read', {'file_path': '/x/pubspec.yaml'}),
          'Read · pubspec.yaml');
    });

    test('여러 줄 명령은 첫 줄만 쓴다', () {
      expect(toolSummary('Bash', {'command': 'cd foo\nls -al'}),
          'Bash · cd foo');
    });

    test('너무 길면 자른다', () {
      final long = 'x' * 200;
      final out = toolSummary('Bash', {'command': long});
      expect(out.length, lessThan(80));
      expect(out, endsWith('…'));
    });

    test('알맹이가 없으면 도구 이름만', () {
      expect(toolSummary('Bash', {'command': '   '}), 'Bash');
      expect(toolSummary('TodoWrite', {'todos': []}), 'TodoWrite');
      expect(toolSummary('Bash', null), 'Bash');
    });

    test('Grep은 패턴, Task는 설명', () {
      expect(toolSummary('Grep', {'pattern': 'setState'}), 'Grep · setState');
      expect(toolSummary('Task', {'description': '버그 찾기'}), 'Task · 버그 찾기');
    });
  });

  group('묻고 있는 화면 가려내기', () {
    // 빈 입력줄(❯)이 있으면 평소, 없으면 무언가 묻는 창이 떠 있다.
    // 실측(2026-08-06): 평소 1개 · 작업 중 1개 · /effort 열림 0개 · 취소 후 1개
    test('입력창이 살아 있으면 평소다', () {
      const pane = ' ⏺ 세는 중…\n'
          '───── 프로젝트 세팅 요구사항 확인 ──\n'
          '❯ \n'
          '──────────────────────────────────\n'
          '  ⏵⏵ bypass permissions on\n';
      expect(PaneView.awaitingChoice(pane), isFalse);
    });

    test('입력창에 글자를 쳐 뒀어도 평소다', () {
      // 비어 있는지로 가르면 여기서 오탐이 난다. 실제로 겪은 자리다.
      final f = File('test/fixtures/panes/20260804/08_input_typed.txt');
      expect(PaneView.awaitingChoice(f.readAsStringSync()), isFalse);
    });

    test('실제로 떠온 화살표형 창을 잡아낸다', () {
      final f = File('test/fixtures/panes/20260804/09_cursor_prompt.txt');
      expect(PaneView.awaitingChoice(f.readAsStringSync()), isTrue);
    });

    test('커서가 확정 줄에 내려가도 묻는 창으로 본다', () {
      // `❯    Submit` / `❯    Next` 는 커서가 그 줄에 놓인 것이지 입력창이
      // 아니다. 입력창으로 세면 확정 직전에 카드가 통째로 사라진다.
      final a = File('test/fixtures/panes/20260811_다중선택/04_커서가_Submit에.txt');
      expect(PaneView.awaitingChoice(a.readAsStringSync()), isTrue);
      final b = File('test/fixtures/panes/20260831_문항두개/02_커서가_Next에.txt');
      expect(PaneView.awaitingChoice(b.readAsStringSync()), isTrue);
    });

    test('화면 위쪽에 남은 지난 대화의 ❯ 에 속지 않는다', () {
      // 입력창은 늘 맨 아래다. 위쪽 ❯ 를 입력창으로 세면
      // 무슨 창이 떠 있어도 평소가 되어 버린다.
      final pane = [
        '❯ 아까 내가 친 말',
        '  답변이다요',
        ...List.filled(10, '  이런저런 줄'),
        '▔▔▔▔▔▔▔▔',
        '   Effort',
        '   Faster        Smarter   ↓',
      ].join('\n');
      expect(PaneView.awaitingChoice(pane), isTrue);
    });

    test('빈 입력줄이 없으면 묻고 있는 것이다', () {
      // /effort 를 열면 입력줄이 사라지고 슬라이더가 자리를 차지한다.
      const pane = '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n'
          '   Effort\n'
          '   Faster                    Smarter    ↓\n';
      expect(PaneView.awaitingChoice(pane), isTrue);
    });

    test('번호 선택창도 묻고 있는 것으로 잡는다', () {
      const pane = ' Security guide\n'
          ' ❯ 1. Yes, I trust this folder\n'
          '   2. No, exit\n'
          ' Enter to confirm · Esc to cancel\n';
      // ❯ 뒤에 글자가 있으므로 '빈 입력줄'이 아니다.
      expect(PaneView.awaitingChoice(pane), isTrue);
    });

    test('빈 화면이면 묻는 것이 아니다', () {
      expect(PaneView.awaitingChoice(null), isFalse);
      expect(PaneView.awaitingChoice(''), isFalse);
    });
  });

  group('AskUserQuestion 선택창', () {
    // test/fixtures/panes/20260804/10_ask_question.txt — 2026-08-06 라이브 캡처
    late PaneChoice c;
    setUp(() {
      final f = File('test/fixtures/panes/20260804/10_ask_question.txt');
      c = PaneChoice.parse(f.readAsStringSync())!;
    });

    test('선택지를 다 읽는다', () {
      expect(c.options.length, greaterThanOrEqualTo(4));
      expect(c.options.first.text, '첫째');
      expect(c.cursor, 1);
    });

    test('문항을 내건다 — 마침표로 끝나도 잡는다', () {
      // ?나 :만 받으면 이런 물음을 놓친다. 실제로 놓쳤다.
      expect(c.question, isNotNull);
      expect(c.question, contains('아무거나 골라주라요'));
    });

    test('선택지 아래 들여쓴 설명을 그 선택지에 붙인다', () {
      expect(c.options.first.detail, '그냥 첫 번째다요.');
      expect(c.options[1].detail, '그냥 두 번째다요.');
    });

    test('화면이 알려주는 조작법을 그대로 들고 온다', () {
      // 창마다 먹는 키가 다르다. 여기는 ←→ 가 아니라 ↑↓ 다.
      expect(c.hint, isNotNull);
      expect(c.hint, contains('↑/↓'));
    });

    test('이름표는 문항으로 내걸지 않는다', () {
      // 신뢰 확인창의 'Security guide'(14자)는 문장이 아니다.
      final f = File('test/fixtures/panes/20260804/06_choice_live.txt');
      expect(PaneChoice.parse(f.readAsStringSync())!.question, isNull);
    });
  });

  group('대화 저장 모양', () {
    test('내 말·응답·도구 줄을 되살린다', () {
      for (final kind in ChatKind.values) {
        final e = ChatEntry(kind: kind, text: '어떤 말');
        final back = ChatEntry.fromJson(e.toJson())!;
        expect(back.kind, kind);
        expect(back.text, '어떤 말');
      }
    });

    test('보낸 시각을 지킨다', () {
      final at = DateTime(2026, 8, 6, 13, 45, 12);
      final e = ChatEntry(kind: ChatKind.mine, text: '안녕', at: at);
      expect(ChatEntry.fromJson(e.toJson())!.at, at);
    });

    test('깨진 줄은 버리고 넘어간다', () {
      // 파일 한 줄이 상했다고 대화를 통째로 잃으면 안 된다.
      expect(ChatEntry.fromJson(null), isNull);
      expect(ChatEntry.fromJson({'text': '종류가 없다'}), isNull);
      expect(ChatEntry.fromJson({'kind': 'mine'}), isNull);
      expect(ChatEntry.fromJson({'kind': '없는종류', 'text': 'x'}), isNull);
      expect(ChatEntry.fromJson({'kind': 'mine', 'text': ''}), isNull);
    });

    test('시각이 깨져 있어도 줄은 살린다', () {
      final back = ChatEntry.fromJson({'kind': 'reply', 'text': '살아남는다', 'at': '엉망'});
      expect(back, isNotNull);
      expect(back!.text, '살아남는다');
    });

    test('도구 요약은 안 남긴다 — 파일만 커진다', () {
      final e = ChatEntry(kind: ChatKind.reply, text: 'x');
      expect(e.toJson().containsKey('turn'), isFalse);
    });
  });

  group('링크 가려내기', () {
    test('그냥 박힌 주소를 잡는다', () {
      expect(parseLinks('여기 보라요 https://example.com 좋다요'), [
        const TextPiece('여기 보라요 '),
        const TextPiece('https://example.com', 'https://example.com'),
        const TextPiece(' 좋다요'),
      ]);
    });

    test('마크다운 링크는 보이는 글만 남긴다', () {
      expect(parseLinks('[노션 태스크](https://notion.so/abc) 확인'), [
        const TextPiece('노션 태스크', 'https://notion.so/abc'),
        const TextPiece(' 확인'),
      ]);
    });

    test('문장 끝 부호는 주소에서 떼어낸다', () {
      // 마침표까지 주소로 삼으면 열리지 않는다.
      final out = parseLinks('여기다요 https://example.com/a.');
      expect(out[1].url, 'https://example.com/a');
      expect(out[2].text, '.');
    });

    test('괄호로 감싼 주소도 떼어낸다', () {
      final out = parseLinks('(https://example.com)');
      expect(out.firstWhere((p) => p.isLink).url, 'https://example.com');
    });

    test('http·https 가 아니면 링크가 아니다', () {
      // open 은 무엇이든 여는지라 낯선 스킴을 넘기면 안 된다.
      final out = parseLinks('file:///etc/passwd 와 ftp://x.com');
      expect(out.every((p) => !p.isLink), isTrue);
    });

    test('링크가 없으면 통째로 한 조각', () {
      expect(parseLinks('아무 말이나'), [const TextPiece('아무 말이나')]);
      expect(parseLinks(''), [const TextPiece('')]);
    });

    test('한 줄에 여러 개도 다 잡는다', () {
      final out = parseLinks('https://a.com 그리고 [비](https://b.com) 끝');
      expect(out.where((p) => p.isLink).map((p) => p.url).toList(),
          ['https://a.com', 'https://b.com']);
    });

    test('마크다운 링크의 주소를 두 번 잡지 않는다', () {
      final out = parseLinks('[가](https://a.com)');
      expect(out.where((p) => p.isLink).length, 1);
      expect(out.first.text, '가');
    });
  });

  group('슬라이더 창 읽기', () {
    // test/fixtures/panes/20260804/11_slider.txt — 2026-08-06 /effort 라이브 캡처
    late PaneSlider sl;
    setUp(() {
      final f = File('test/fixtures/panes/20260804/11_slider.txt');
      sl = PaneSlider.parse(f.readAsStringSync())!;
    });

    test('고를 것을 차례대로 읽는다', () {
      expect(sl.options,
          ['low', 'medium', 'high', 'xhigh', 'max', 'ultracode']);
    });

    test('▲ 가 가리키는 자리를 찾는다', () {
      // 이 캡처를 뜰 때 90_테스트는 low 였다.
      expect(sl.current, 0);
      expect(sl.options[sl.current], 'low');
    });

    test('이름과 조작법을 들고 온다', () {
      expect(sl.title, 'Effort');
      expect(sl.hint, contains('←/→'));
    });

    test('한 칸 띄어쓰기는 이름 안으로 본다', () {
      // `xhigh + workflows` 가 셋으로 쪼개지면 안 된다.
      const line = '   느림      보통 조금      아주 빠름';
      const pane = '  ─▲──────────────────────────────\n$line\n';
      final s = PaneSlider.parse(pane)!;
      expect(s.options, ['느림', '보통 조금', '아주 빠름']);
    });

    test('▲ 가 가운데 있으면 그 자리를 고른다', () {
      const pane = '  ───────────▲──────────────────\n'
          '  low        medium        high\n';
      expect(PaneSlider.parse(pane)!.current, 1);
    });

    test('슬라이더가 아니면 null', () {
      expect(PaneSlider.parse(null), isNull);
      expect(PaneSlider.parse(''), isNull);
      // 번호 선택창은 슬라이더가 아니다.
      final f = File('test/fixtures/panes/20260804/10_ask_question.txt');
      expect(PaneSlider.parse(f.readAsStringSync()), isNull);
    });
  });

  group('묻기 직전에 한 말', () {
    // test/fixtures/panes/20260804/12_ask_with_lead.txt — 2026-08-06 라이브 캡처
    // 말풍선은 턴이 끝나야 오르는데 선택창이 뜨면 턴이 멈춘다.
    // 그래서 물음만 뜨고 앞뒤 사정이 안 보였다.
    late PaneChoice c;
    setUp(() {
      final f = File('test/fixtures/panes/20260804/12_ask_with_lead.txt');
      c = PaneChoice.parse(f.readAsStringSync())!;
    });

    test('왜 묻는지가 담긴다', () {
      expect(c.lead, isNotEmpty);
      expect(c.lead.join(' '), contains('점심 메뉴를 정해달라고'));
    });

    test('문항은 앞말에 넣지 않는다 — 따로 내걸기 때문이다', () {
      expect(c.question, '점심 뭐 먹을까요?');
      expect(c.lead.any((l) => l.contains('점심 뭐 먹을까요?')), isFalse);
    });

    test('내가 친 말은 한 줄도 섞이지 않는다', () {
      // 내가 친 말이 길면 줄바꿈되어 `❯` 없는 줄이 생긴다.
      // 그 줄이 앞말에 섞이면 안 된다.
      expect(c.lead.any((l) => l.startsWith('❯')), isFalse);
      expect(c.lead.any((l) => l.contains('AskUserQuestion')), isFalse);
      expect(c.lead.any((l) => l.contains('세 문장 설명하고')), isFalse);
    });

    test('답변 시작(⏺)을 못 찾으면 아무것도 안 보여준다', () {
      // 어디부터가 답변인지 모르면 엉뚱한 줄을 내걸기보다 비우는 편이 낫다.
      const pane = ' 그냥 아무 줄\n'
          ' 또 아무 줄\n'
          ' 무엇을 고를까요?\n'
          ' ❯ 1. 가\n'
          '   2. 나\n'
          ' Enter to confirm\n';
      expect(PaneChoice.parse(pane)!.lead, isEmpty);
    });

    test('구분선과 머리표는 뺀다', () {
      expect(c.lead.any((l) => l.startsWith('─')), isFalse);
      expect(c.lead.any((l) => l.startsWith('☐')), isFalse);
    });

    test('앞말이 없어도 선택창은 읽힌다', () {
      final f = File('test/fixtures/panes/20260804/06_choice_live.txt');
      final t = PaneChoice.parse(f.readAsStringSync());
      expect(t, isNotNull);
      expect(t!.options.length, 2);
    });
  });

  group('다중 선택창', () {
    // test/fixtures/panes/20260811_다중선택/ — 실제로 띄워 놓고 눌러 본 화면이다.
    // 숫자는 확정이 아니라 토글이고, 확정은 `Submit` 줄에서 Enter다.
    PaneChoice at(String name) =>
        PaneChoice.parse(File('test/fixtures/panes/20260811_다중선택/$name')
            .readAsStringSync())!;

    test('체크박스가 붙은 창인 것을 알아본다', () {
      final c = at('01_열린창.txt');
      expect(c.multi, isTrue);
      expect(c.question, '어떤 과일을 좋아하세요?');
      // 사과 · 바나나 · 포도 · Type something · Chat about this
      expect(c.options.length, 5);
    });

    test('체크박스 표시는 떼어내고 켜짐만 남긴다', () {
      final c = at('01_열린창.txt');
      expect(c.options.first.text, '사과');
      expect(c.options.first.checked, isFalse);
      expect(c.checkedOptions, isEmpty);
    });

    test('켜진 것을 읽어낸다', () {
      final c = at('02_숫자로_토글.txt');
      expect(c.checkedOptions.map((o) => o.text), ['사과', '포도']);
    });

    test('체크박스 없는 줄은 checkable이 아니다', () {
      // `Chat about this` 는 켜고 끄는 것이 아니라 모드를 바꾸는 줄이다.
      final c = at('01_열린창.txt');
      expect(c.options.last.text, 'Chat about this');
      expect(c.options.last.checkable, isFalse);
      expect(c.options.first.checkable, isTrue);
    });

    test('설명이 선택지와 같은 깊이여도 설명으로 붙는다', () {
      // 다중 선택창은 설명을 2칸만 들여쓴다 — 선택지와 똑같다.
      // 들여쓰기만 보면 설명이 통째로 날아간다.
      final c = at('01_열린창.txt');
      expect(c.options.first.detail, '아삭하고 달콤한 사과');
      expect(c.options[1].detail, '부드럽고 든든한 바나나');
    });

    test('Submit은 선택지로 세지 않고 자리만 기억한다', () {
      final c = at('01_열린창.txt');
      expect(c.options.any((o) => o.text == 'Submit'), isFalse);
      // 선택지 4개 뒤가 Submit이고, 커서는 첫 줄에 있다.
      expect(c.submitRow, 4);
      expect(c.cursorRow, 0);
      expect(c.toSubmit, 4);
    });

    test('Submit이 선택지의 설명으로 새지 않는다', () {
      // 화면에서 `Submit` 은 5칸 들여써 있어 그냥 두면 바로 위
      // `Type something` 의 설명으로 붙는다.
      final c = at('01_열린창.txt');
      expect(c.options[3].text, 'Type something');
      expect(c.options[3].detail, isNull);
    });

    test('조작법이 마지막 선택지의 설명으로 빨려 들어가지 않는다', () {
      // 다중 선택창은 마지막 선택지 바로 다음 줄이 조작법이다.
      // '바로 뒤에 붙은 줄은 설명'으로만 가르면 그걸 설명으로 먹는다.
      final c = at('01_열린창.txt');
      expect(c.options.last.detail, isNull);
      expect(c.hint, contains('Enter to select'));
    });

    test('커서가 Submit에 있으면 더 옮기지 않는다', () {
      final c = at('04_커서가_Submit에.txt');
      expect(c.cursorRow, c.submitRow);
      expect(c.toSubmit, 0);
    });

    test('한 칸 더 내려간 화면은 Submit이 아니라고 읽는다', () {
      // 여기서 Enter를 치면 `Chat about this` 로 새어 나간다.
      final c = at('05_한칸_더_내리면_ChatAbout.txt');
      expect(c.cursorRow == c.submitRow, isFalse);
      expect(c.toSubmit, -1);
    });

    test('검토 화면은 평범한 번호 선택창으로 읽힌다', () {
      // 되돌릴 수 없는 자리다. 여기는 기존대로 두 번 눌러 고른다.
      final c = at('06_검토화면.txt');
      expect(c.multi, isFalse);
      expect(c.options.map((o) => o.text), ['Submit answers', 'Cancel']);
    });

    test('앞말의 표가 무너지지 않는다', () {
      // test/fixtures/panes/20260811_다중선택/07_앞말에_표.txt — 라이브 캡처
      // 표는 세로줄과 자리를 맞춘 공백으로 서 있다. 둘 중 하나만 잃어도
      // 표가 아니게 된다.
      final c = at('07_앞말에_표.txt');
      final lead = c.lead.join('\n');
      expect(lead, contains('│'));
      expect(lead, contains('├────────┼──────┤'));
      // 표의 위·아래 테두리가 다 있어야 표로 보인다.
      expect(lead, contains('┌────────┬──────┐'));
      expect(lead, contains('└────────┴──────┘'));
      // 칸 너비가 살아 있어야 세로로 줄이 맞는다.
      final rows = c.lead.where((l) => l.contains('사과')).toList();
      expect(rows, isNotEmpty);
      expect(rows.first, contains('│ 사과   │ 1000 │'));
    });

    test('표의 세로줄과 상자 옆선을 가른다', () {
      // 승인창의 상자 옆선은 줄의 맨 앞·맨 끝에만 있다. 가운데 것은
      // 표의 칸막이라 지우면 안 된다.
      final c = at('07_앞말에_표.txt');
      expect(c.lead.any((l) => l.trimLeft().startsWith('│  이름')), isTrue);
    });

    test('다 같이 들여쓴 만큼만 당긴다 — 표의 어긋남은 남긴다', () {
      // 클로드가 한 말은 통째로 2칸 들여써 있다. 그건 떼되, 줄끼리의
      // 어긋남(=표의 칸)은 그대로여야 한다.
      final c = at('07_앞말에_표.txt');
      expect(c.lead.first.startsWith(' '), isFalse);
      final widths = c.lead
          .where((l) => l.trim().isNotEmpty)
          .map((l) => l.length - l.trimLeft().length)
          .toSet();
      // 표는 전부 같은 자리에서 시작한다 — 한 줄만 튀면 안 맞는 것이다.
      expect(widths.length, 1);
    });

    test('문항이 여럿이면 그 자리가 Next다', () {
      // test/fixtures/panes/20260831_문항두개/ — 문항 두 개짜리 라이브 캡처.
      // `Submit`만 찾던 때는 submitRow가 비어 확정 버튼이 통째로 잠겼다.
      final c = PaneChoice.parse(
          File('test/fixtures/panes/20260831_문항두개/01_문항1_Next.txt')
              .readAsStringSync())!;
      expect(c.multi, isTrue);
      expect(c.question, 'Which fruits?');
      expect(c.submitLabel, 'Next');
      expect(c.isNext, isTrue);
      // 선택지 4개 뒤가 Next, 커서는 첫 줄이다.
      expect(c.submitRow, 4);
      expect(c.cursorRow, 0);
      expect(c.toSubmit, 4);
      // Next도 선택지로 세지 않는다 — 바로 위 줄의 설명으로도 새면 안 된다.
      expect(c.options.any((o) => o.text == 'Next'), isFalse);
      expect(c.options[3].text, 'Type something');
      expect(c.options[3].detail, isNull);
    });

    test('커서가 Next에 있으면 더 옮기지 않는다', () {
      final c = PaneChoice.parse(
          File('test/fixtures/panes/20260831_문항두개/02_커서가_Next에.txt')
              .readAsStringSync())!;
      expect(c.cursorRow, c.submitRow);
      expect(c.toSubmit, 0);
      expect(c.checkedOptions.map((o) => o.text), ['apple']);
    });

    test('마지막 문항은 다시 Submit이다', () {
      final c = PaneChoice.parse(
          File('test/fixtures/panes/20260831_문항두개/03_문항2_Submit.txt')
              .readAsStringSync())!;
      expect(c.question, 'Which drinks?');
      expect(c.submitLabel, 'Submit');
      expect(c.isNext, isFalse);
      expect(c.toSubmit, 4);
    });

    test('문항 하나짜리 옛 창은 Next가 아니다', () {
      final c = at('01_열린창.txt');
      expect(c.submitLabel, 'Submit');
      expect(c.isNext, isFalse);
    });

    test('체크박스 없는 옛 창은 그대로다', () {
      final c = PaneChoice.parse(
          File('test/fixtures/panes/20260804/12_ask_with_lead.txt')
              .readAsStringSync())!;
      expect(c.multi, isFalse);
      expect(c.submitRow, isNull);
      expect(c.toSubmit, isNull);
    });
  });

  group('심심함이 결과를 덮지 않는다', () {
    // 2026-09-08에 겪은 것. 턴이 끝나고 사용자가 답을 안 하면 클로드 코드가
    // idle_prompt를 보내는데, 그게 완료를 심심함으로 밀어내 결과 애니메이션이
    // 한 번 돌다 말고 얼어붙었다(bored는 아트가 없어 base 한 장이 된다).
    SessionStore boardWith(AgentStatus status) {
      final projects = storeWith([
        {'path': '/tmp/cw_anim', 'name': '테스트'}
      ], 'anim_${status.name}');
      final store = SessionStore(projects);
      store.handleEvent({
        'hook_event_name': 'SessionStart',
        'session_id': 'ANIM',
        'cwd': '/tmp/cw_anim',
      });
      store.sessions.first.status = status;
      return store;
    }

    void idlePrompt(SessionStore store) => store.handleEvent({
          'hook_event_name': 'Notification',
          'session_id': 'ANIM',
          'cwd': '/tmp/cw_anim',
          'notification_type': 'idle_prompt',
        });

    test('완료는 그대로 남는다', () {
      final store = boardWith(AgentStatus.done);
      idlePrompt(store);
      expect(store.sessions.first.status, AgentStatus.done);
    });

    test('승인 대기도 그대로 남는다', () {
      final store = boardWith(AgentStatus.waiting);
      idlePrompt(store);
      expect(store.sessions.first.status, AgentStatus.waiting);
    });

    test('문제 발생도 그대로 남는다', () {
      final store = boardWith(AgentStatus.error);
      idlePrompt(store);
      expect(store.sessions.first.status, AgentStatus.error);
    });

    test('아무 일도 없을 때는 심심함으로 간다', () {
      final store = boardWith(AgentStatus.idle);
      idlePrompt(store);
      expect(store.sessions.first.status, AgentStatus.bored);
    });
  });

  group('완료 몸짓은 5분만', () {
    // 끝난 티는 계속 나야 하지만 몸짓까지 몇 시간 남을 필요는 없다.
    // 그림만 대기로 돌리고 점은 초록으로 둔다 — 둘을 갈라 놓은 이유다.
    AgentSession sessionDone(Duration ago) {
      final projects = storeWith([
        {'path': '/tmp/cw_pose', 'name': '테스트'}
      ], 'pose_${ago.inSeconds}');
      final store = SessionStore(projects);
      store.handleEvent({
        'hook_event_name': 'Stop',
        'session_id': 'POSE',
        'cwd': '/tmp/cw_pose',
      });
      final s = store.sessions.first;
      s.statusSince = DateTime.now().subtract(ago);
      return s;
    }

    test('끝난 직후에는 완료 몸짓이다', () {
      final s = sessionDone(const Duration(seconds: 5));
      expect(s.artStatus, AgentStatus.done);
    });

    test('5분이 지나면 몸짓만 대기로 바뀐다', () {
      final s = sessionDone(const Duration(minutes: 6));
      expect(s.artStatus, AgentStatus.idle);
    });

    test('그래도 상태와 점 색은 완료 그대로다', () {
      final s = sessionDone(const Duration(minutes: 6));
      expect(s.status, AgentStatus.done);
      expect(s.shownStatus, AgentStatus.done);
      expect(s.shownStatus.color, success);
    });

    test('승인 대기는 오래돼도 몸짓을 빼지 않는다', () {
      final s = sessionDone(const Duration(hours: 3));
      s.status = AgentStatus.waiting;
      expect(s.artStatus, AgentStatus.waiting);
    });
  });

  group('모니터 고정', () {
    // 창을 어느 모니터에 붙여 둘지 기억하는 값이다.
    // macOS의 CGDirectDisplayID는 뽑았다 꽂으면 바뀌는 일이 있어
    // id 하나만 보고 찾으면 고정이 풀린 것처럼 보인다.
    Display display(String id, {String? name, double w = 1920, double h = 1080}) =>
        Display(id: id, name: name, size: Size(w, h));

    final pin = DisplayPin.of(display('69733382', name: 'Studio Display'));

    test('id가 같으면 그것으로 찾는다', () {
      final list = [display('1', name: '내장'), display('69733382', name: '이름이 바뀜')];
      expect(pin.find(list)?.id, '69733382');
    });

    test('id가 바뀌었어도 이름으로 찾는다', () {
      // 뽑았다 꽂으면 실제로 겪는 상황이다.
      final list = [display('1', name: '내장'), display('99', name: 'Studio Display')];
      expect(pin.find(list)?.id, '99');
    });

    test('id도 이름도 안 맞으면 크기로 찾는다', () {
      final list = [display('1', name: '내장', w: 1512, h: 982), display('99')];
      expect(pin.find(list)?.id, '99');
    });

    test('아무것도 안 맞으면 못 찾는다 — 그래도 기록은 남는다', () {
      final list = [display('1', name: '내장', w: 1512, h: 982)];
      expect(pin.find(list), isNull);
      // 다시 꽂으면 돌아가야 하므로 값 자체는 그대로다.
      expect(pin.id, '69733382');
      expect(pin.label, 'Studio Display');
    });

    test('적어 두고 다시 읽어도 같다', () {
      final back = DisplayPin.fromJson(pin.toJson());
      expect(back.id, pin.id);
      expect(back.name, pin.name);
      expect(back.width, pin.width);
      expect(back.height, pin.height);
    });

    test('이름 없는 모니터는 id로 부른다', () {
      expect(DisplayPin.of(display('42')).label, '모니터 42');
    });
  });


  group('굵게 쓴 주소', () {
    // ⚠️ 대표가 실제로 겪은 것이다(2026-09-09). 채팅에 **주소** 를 굵게 쓰면
    // 말풍선의 링크가 뒤의 ** 를 주소에 붙여 버려 엉뚱한 데로 갔다.
    test('뒤의 별표를 주소에 붙이지 않는다', () {
      final p = parseLinks('여기 **https://muwidarani.com/log/android-launch/** 다');
      final link = p.firstWhere((x) => x.isLink);
      expect(link.url, 'https://muwidarani.com/log/android-launch/');
      // 떼어 낸 별표는 사라지지 않고 글자로 남는다.
      expect(p.map((x) => x.text).join(),
          '여기 **https://muwidarani.com/log/android-launch/** 다');
    });

    test('별표 하나짜리 기울임도 마찬가지다', () {
      final p = parseLinks('*https://example.com/a*');
      expect(p.firstWhere((x) => x.isLink).url, 'https://example.com/a');
    });

    // 주소 한가운데의 별표는 진짜 주소의 일부일 수 있으니 두고 본다.
    test('가운데 별표는 건드리지 않는다', () {
      final p = parseLinks('https://example.com/a*b');
      expect(p.firstWhere((x) => x.isLink).url, 'https://example.com/a*b');
    });

    // 대표 QA(9/15) — 닫는 별표 뒤에 글자가 바로 붙으면 꼬리 떼기로 못 뗐다.
    test('닫는 별표 뒤에 글자가 붙어도 별표 둘에서 끊는다', () {
      final p = parseLinks('**https://example.com/a**에서 받는다');
      expect(p.firstWhere((x) => x.isLink).url, 'https://example.com/a');
      expect(p.map((x) => x.text).join(), '**https://example.com/a**에서 받는다');
    });
  });

  group('그림 없는 상태는 대기로 떨어진다', () {
    // ⚠️ 예전에는 base로 떨어졌다. base는 **한 장뿐이라 얼어붙는다.**
    // 심심함이 실제로 그랬고(2026-09-08), 상태를 늘릴 때마다 반복될
    // 자리였다. 이제 대기(네 장)로 먼저 떨어진다.
    const base = {'idle': '대기', 'base': '한장', 'done': '완료'};

    test('제 그림이 있으면 그것이 먼저다', () {
      expect(ArtStore.pickFrames([base], 'done'), '완료');
    });

    test('없으면 base가 아니라 대기로 간다', () {
      expect(ArtStore.pickFrames([base], 'bored'), '대기');
    });

    test('대기마저 없을 때만 base로 간다', () {
      expect(ArtStore.pickFrames([{'base': '한장'}], 'bored'), '한장');
    });

    test('대기 자신도 없으면 base다', () {
      expect(ArtStore.pickFrames([{'base': '한장'}], 'idle'), '한장');
    });

    // 세트에 한 장만 넣어도 그 프로젝트만 다른 캐릭터가 되는 성질을 지킨다.
    test('좁은 단계가 넓은 단계보다 먼저다', () {
      expect(ArtStore.pickFrames([{'base': '전용'}, base], 'bored'), '전용');
    });

    test('빈 단계는 건너뛴다', () {
      expect(
          ArtStore.pickFrames(
              [null, <String, String>{}, base], 'bored'),
          '대기');
    });

    test('아무 데도 없으면 null이다', () {
      expect(
          ArtStore.pickFrames([null, <String, String>{}], 'bored'), isNull);
    });
  });

  group('리스트·보드 — 공을 쥔 쪽 4칸', () {
    final now = DateTime(2026, 9, 14, 22); // 월요일
    TodoItem t(TaskStatus st, {String? who, DateTime? due, DateTime? statusAt, DateTime? at}) =>
        TodoItem(text: 'x', project: '/p', status: st, assignee: who, due: due,
            statusAt: statusAt, at: at);

    test('진행중·멈춤·대기·확인필요·담당으로 칸을 가른다', () {
      expect(TodoBoard.laneOf(t(TaskStatus.running)), BallLane.running);
      expect(TodoBoard.laneOf(t(TaskStatus.paused)), BallLane.hold);
      // 대기는 외부 때문에 막힌 것 — 대표 몫이 아니다(대표 결정 2026-09-14).
      expect(TodoBoard.laneOf(t(TaskStatus.blocked, who: kOwnerAssignee)), BallLane.hold);
      expect(TodoBoard.laneOf(t(TaskStatus.review)), BallLane.me);
      expect(TodoBoard.laneOf(t(TaskStatus.today, who: kOwnerAssignee)), BallLane.me);
      expect(TodoBoard.laneOf(t(TaskStatus.sessionPlanned, who: '/p')), BallLane.session);
      expect(TodoBoard.laneOf(t(TaskStatus.done)), isNull);
    });

    test('수정요청은 담당이 대표여도 세션 차례다', () {
      expect(TodoBoard.laneOf(t(TaskStatus.revision, who: kOwnerAssignee)), BallLane.session);
    });

    test('백로그는 마감이 범위 안에 든 것만 칸에 올라온다', () {
      final noDue = t(TaskStatus.waiting);
      final thisWeek = t(TaskStatus.waiting, due: DateTime(2026, 9, 20));
      final nextWeek = t(TaskStatus.waiting, due: DateTime(2026, 9, 21));
      final overdue = t(TaskStatus.waiting, due: DateTime(2026, 9, 10));
      expect(TodoBoard.onBoard(noDue, TodoScope.all, now), isFalse);
      expect(TodoBoard.onBoard(overdue, TodoScope.today, now), isTrue);
      expect(TodoBoard.onBoard(thisWeek, TodoScope.today, now), isFalse);
      expect(TodoBoard.onBoard(thisWeek, TodoScope.week, now), isTrue);
      expect(TodoBoard.onBoard(nextWeek, TodoScope.week, now), isFalse);
      expect(TodoBoard.onBoard(nextWeek, TodoScope.all, now), isTrue);
      // 살아 있는 카드는 범위와 상관없이 늘 보인다.
      expect(TodoBoard.onBoard(t(TaskStatus.sessionPlanned), TodoScope.today, now), isTrue);
      expect(TodoBoard.onBoard(t(TaskStatus.done), TodoScope.all, now), isFalse);
    });

    test('이번 주는 월요일부터 일요일까지다', () {
      expect(TodoBoard.weekStart(now), DateTime(2026, 9, 14));
      expect(TodoBoard.weekEnd(now), DateTime(2026, 9, 20));
      final sunday = DateTime(2026, 9, 20, 9);
      expect(TodoBoard.weekStart(sunday), DateTime(2026, 9, 14));
      expect(TodoBoard.weekEnd(sunday), DateTime(2026, 9, 20));
    });

    test('칸 안은 확인필요 → 수정요청 → 오늘예정 순, 같은 상태면 마감이 이른 것', () {
      final a = t(TaskStatus.today, due: DateTime(2026, 9, 18), at: DateTime(2026, 9, 1));
      final b = t(TaskStatus.today, at: DateTime(2026, 9, 2));
      final c = t(TaskStatus.revision, at: DateTime(2026, 9, 3));
      final d = t(TaskStatus.review, at: DateTime(2026, 9, 4));
      expect(([b, a, c, d]..sort(TodoBoard.compare)), [d, c, a, b]);
    });

    test('어제 못 한 오늘예정 — 옮긴 시각이 없으면 적은 시각으로 친다', () {
      expect(TodoBoard.staleToday(t(TaskStatus.today, statusAt: DateTime(2026, 9, 13, 23)), now), isTrue);
      expect(TodoBoard.staleToday(t(TaskStatus.today, statusAt: DateTime(2026, 9, 14, 1)), now), isFalse);
      expect(TodoBoard.staleToday(t(TaskStatus.today, at: DateTime(2026, 9, 11)), now), isTrue);
      expect(TodoBoard.staleToday(t(TaskStatus.review, at: DateTime(2026, 9, 11)), now), isFalse);
    });

    test('옮긴 시각과 즐겨찾기는 저장했다 읽어도 남는다', () {
      final at = DateTime(2026, 9, 14, 9);
      final back = TodoItem.fromJson(t(TaskStatus.today, statusAt: at).toJson())!;
      expect(back.statusAt, at);
      final row = ProjectRow(id: 'p1', name: '클로드워쳐', favorite: true);
      expect(ProjectRow.fromJson(row.toJson())!.favorite, isTrue);
      expect(ProjectRow.fromJson(row.copyWith(favorite: false).toJson())!.favorite, isFalse);
      // 즐겨찾기가 아니면 파일에 칸을 쓰지 않는다 — 옛 파일과 모양이 같다.
      expect(ProjectRow(id: 'p2', name: 'x').toJson().containsKey('favorite'), isFalse);
    });

    test('수정요청을 시키면 수정사항이 프롬프트 뒤에 붙는다', () {
      final r = TodoItem(text: '보드 고치기', project: '/p', status: TaskStatus.revision,
          body: '보드를 4칸으로', revisionNote: '버튼이 카드를 가린다');
      expect(r.command, '보드를 4칸으로\n\n[수정요청]\n버튼이 카드를 가린다');
      // 수정요청이 아니면 수정사항이 남아 있어도 붙이지 않는다.
      expect(r.copyWith(status: TaskStatus.sessionPlanned).command, '보드를 4칸으로');
    });
  });


  group('시키기 줄', () {
    test('같은 세션 앞의 줄만, 먼저 선 순서로', () {
      final a = TodoItem(text: 'a', project: '/p', queuedAt: DateTime(2026, 9, 14, 23, 2));
      final b = TodoItem(text: 'b', project: '/p', queuedAt: DateTime(2026, 9, 14, 23, 1));
      final other = TodoItem(text: 'c', project: '/q', queuedAt: DateTime(2026, 9, 14, 23));
      final notQueued = TodoItem(text: 'd', project: '/p');
      // 담당 세션이 있으면 그쪽 줄에 선다.
      final assigned = TodoItem(text: 'e', project: '/q', assignee: '/p', queuedAt: DateTime(2026, 9, 14, 23, 3));
      final done = TodoItem(text: 'f', project: '/p', status: TaskStatus.done, queuedAt: DateTime(2026, 9, 14, 22));
      expect(TodoStore.queueFor([a, b, other, notQueued, assigned, done], '/p').map((t) => t.text),
          ['b', 'a', 'e']);
    });

    test('일하는 중·생각 중·승인 대기면 보내지 않는다', () {
      expect(TodoStore.readyToSend(AgentStatus.working), isFalse);
      expect(TodoStore.readyToSend(AgentStatus.thinking), isFalse);
      expect(TodoStore.readyToSend(AgentStatus.waiting), isFalse);
      expect(TodoStore.readyToSend(AgentStatus.idle), isTrue);
      expect(TodoStore.readyToSend(AgentStatus.done), isTrue);
    });

    test('줄 선 시각은 저장했다 읽어도 남고, 지우면 빠진다', () {
      final at = DateTime(2026, 9, 14, 23, 30);
      final t = TodoItem(text: 'a', project: '/p', queuedAt: at);
      expect(TodoItem.fromJson(t.toJson())!.queuedAt, at);
      expect(t.copyWith(clearQueued: true).queuedAt, isNull);
      expect(t.copyWith(text: 'b').queuedAt, at);
    });
  });


  group('계층 모자', () {
    test('떨어져 떠 있는 방울이 아니라 가장 큰 덩어리의 윗줄을 머리로 잡는다', () {
      // 한 칸 8×6: y=0에 점 하나(방울), y=2~5에 3×4 몸통(x=2..4).
      const w = 8, h = 6;
      final bytes = Uint8List(w * h * 4);
      void dot(int x, int y) => bytes[(y * w + x) * 4 + 3] = 255;
      dot(6, 0);
      for (var y = 2; y < 6; y++) {
        for (var x = 2; x < 5; x++) {
          dot(x, y);
        }
      }
      expect(ArtStore.headsOf(bytes, w, h, 1), [(2.0, 3.5)]);
      // 빈 칸은 null — 모자를 안 그린다.
      expect(ArtStore.headsOf(Uint8List(w * h * 4), w, h, 1), [null]);
    });
  });


  group('프로젝트 기록', () {
    test('날짜형 파일 이름만 문서로 읽고 금지어는 뺀다', () {
      final d = ProjectDocs.parse('/p/20260915_기획_프로젝트기록페이지.html')!;
      expect([d.date, d.kind, d.title], ['2026-09-15', '기획', '프로젝트기록페이지']);
      expect(ProjectDocs.parse('/p/20260914_시안_할일리스트보드_v5.html')!.title, '할일리스트보드 v5');
      expect(ProjectDocs.parse('/p/README.md'), isNull);
      expect(ProjectDocs.parse('/p/20261399_기획_x.md'), isNull);
      expect(ProjectDocs.parse('/p/20260901_사업_임대차계약서.pdf'), isNull);
    });

    test('깊이 2 · 숨김·빌드·보안 폴더와 다른 프로젝트 폴더는 훑지 않는다', () {
      final root = Directory.systemTemp.createTempSync('cw_docs_');
      void touch(String rel) => (File('${root.path}/$rel')..createSync(recursive: true)).writeAsStringSync('x');
      touch('20260901_기획_위.md');
      touch('docs/20260902_설계_둘째.md');
      touch('docs/deep/20260903_설계_셋째.md'); // 깊이 3 — 안 봄
      touch('build/20260904_기획_빌드.md');
      touch('.claude/20260905_기획_숨김.md');
      touch('95_보안자료/20260906_기획_보안.md');
      touch('sub/20260907_기획_남의것.md');
      final docs = ProjectDocs.scan(root.path, otherProjects: ['${root.path}/sub']);
      expect(docs.map((d) => d.title), ['둘째', '위']);
      root.deleteSync(recursive: true);
    });

    test('기록은 저장했다 읽어도 남고, 결정은 새 것이 위로 붙는다', () {
      var n = ProjectNote.empty;
      expect(ProjectRow(id: 'p', name: 'x').toJson().containsKey('note'), isFalse);
      n = n.added('decisions', const NoteEntry(date: '2026-09-14', text: '보드는 4칸', why: '작업지시서'));
      n = n.added('decisions', const NoteEntry(date: '2026-09-15', text: '표 보기 삭제'));
      n = n.added('links', const NoteEntry(text: '저장소', why: 'https://example.com'));
      n = n.copyWith(intro: '세션 위젯');
      final back = ProjectRow.fromJson(ProjectRow(id: 'p', name: 'x', note: n).toJson())!.note;
      expect(back.intro, '세션 위젯');
      expect(back.decisions.map((e) => e.text), ['표 보기 삭제', '보드는 4칸']);
      expect(back.links.single.why, 'https://example.com');
      expect(back.removedAt('decisions', 0).decisions.single.text, '보드는 4칸');
      expect(back.removedAt('decisions', 9).decisions.length, 2); // 없는 줄은 그대로
    });

    test('판 번호는 pubspec과 같다 — 화면에 보이는 값이라 어긋나면 안 된다', () {
      final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      expect(line.split(':')[1].trim().split('+').first, kVersion);
    });

    test('폰으로 보기 — 붙을 수 있는 주소만, QR은 SVG', () {
      expect(phoneAddressLabel('192.168.219.103'), '같은 와이파이');
      expect(phoneAddressLabel('10.0.0.5'), '같은 와이파이');
      expect(phoneAddressLabel('172.20.1.1'), '같은 와이파이');
      expect(phoneAddressLabel('100.101.2.3'), '테일스케일');
      expect(phoneAddressLabel('169.254.1.1'), isNull, reason: '링크 로컬은 폰이 못 붙는다');
      expect(phoneAddressLabel('8.8.8.8'), isNull);
      final svg = qrSvg('http://192.168.0.2:9878/todo?k=${'a' * 32}');
      expect(svg, startsWith('<svg'));
      expect(svg, contains('h1v1h-1z'));
    });

    test('대화 속 경로 풀기 — 상대·~·줄번호·..·차단·없음', () {
      final root = Directory.systemTemp.createTempSync('reveal');
      final home = root.path;
      Directory('${root.path}/proj/lib').createSync(recursive: true);
      File('${root.path}/proj/lib/main.dart').writeAsStringSync('x');
      Directory('${root.path}/vault').createSync();
      final block = BlockList(['${root.path}/vault']);
      final cwd = '${root.path}/proj';
      var t = revealTarget('lib/main.dart:123', cwd, home: home, block: block);
      expect(t.path, '${root.path}/proj/lib/main.dart');
      expect(t.dir, isFalse);
      t = revealTarget('~/proj/', '', home: home, block: block);
      expect((t.path, t.dir), ('${root.path}/proj', true));
      expect(revealTarget('../vault', cwd, home: home, block: block).error, contains('차단'),
          reason: '..로 돌아 차단 폴더에 들어가지 못한다');
      expect(revealTarget('lib/none.dart', cwd, home: home, block: block).error, contains('없는'));
      expect(revealTarget('lib/main.dart', '', home: home, block: block).error, isNotNull,
          reason: '상대 경로인데 세션을 모르면 거절');
      root.deleteSync(recursive: true);
    });

    test('지난 날짜로 적은 결정은 그 날짜 자리에 끼고, 고치면 자리를 옮긴다', () {
      var n = ProjectNote.empty;
      n = n.added('decisions', const NoteEntry(date: '2026-09-15', text: '오늘 것'));
      n = n.added('decisions', const NoteEntry(date: '2026-08-11', text: '노션 8월'));
      n = n.added('decisions', const NoteEntry(date: '2026-09-01', text: '노션 9월'));
      n = n.added('decisions', const NoteEntry(text: '날짜 없음'));
      expect(n.decisions.map((e) => e.text), ['오늘 것', '노션 9월', '노션 8월', '날짜 없음']);
      n = n.editedAt('decisions', 0, (e) => NoteEntry(date: '2026-07-01', text: e.text));
      expect(n.decisions.map((e) => e.text), ['노션 9월', '노션 8월', '오늘 것', '날짜 없음']);
      expect(n.editedAt('decisions', 9, (e) => e).decisions.length, 4, reason: '없는 줄은 그대로');
    });

    test('결정 날짜 — 비우면 오늘, 없는 날·앞날·모양 틀림은 거절', () {
      expect(NoteEntry.dateOf(null, '2026-09-15'), '2026-09-15');
      expect(NoteEntry.dateOf('2026-08-11', '2026-09-15'), '2026-08-11');
      expect(NoteEntry.dateOf('2026-02-30', '2026-09-15'), isNull);
      expect(NoteEntry.dateOf('2026-09-16', '2026-09-15'), isNull);
      expect(NoteEntry.dateOf('2026/08/11', '2026-09-15'), isNull);
    });
  });


  group('하위 태스크 — 한 단계', () {
    final base = DateTime(2026, 9, 15, 10);
    TodoItem task(String text, int min, {String? parent, TaskStatus status = TaskStatus.waiting,
            String projectId = 'p1', int spent = 0, DateTime? due}) =>
        TodoItem(text: text, project: '/x', projectId: projectId, status: status,
            parentId: parent, spentSec: spent, due: due, at: base.add(Duration(minutes: min)));
    String id(TodoItem t) => Todos.idOf(t);

    test('상위 ID는 저장했다 읽어도 남고, 없으면 파일에 안 쓴다', () {
      final top = task('공개', 0);
      final kid = task('보안 점검', 1, parent: id(top));
      expect(top.toJson().containsKey('parentId'), isFalse);
      expect(TodoItem.fromJson(kid.toJson())!.parentId, id(top));
      expect(kid.copyWith(clearParent: true).parentId, isNull);
    });

    test('진행률은 하위 완료 수, 시간은 상위 몫 + 하위 합계, 마감은 가장 늦은 하위', () {
      final top = task('공개', 0, spent: 600);
      final all = [
        top,
        task('1', 1, parent: id(top), status: TaskStatus.done, spent: 1200, due: DateTime(2026, 9, 16)),
        task('2', 2, parent: id(top), spent: 300, due: DateTime(2026, 9, 18)),
        task('3', 3, parent: id(top)),
      ];
      final kids = TaskTree.childrenOf(all, id(top));
      expect(kids.map((k) => k.text), ['1', '2', '3']);
      final pr = TaskTree.progress(kids);
      expect((pr.done, pr.total), (1, 3));
      expect(TaskTree.left(all, top), 2);
      expect(TaskTree.spentAt(top, kids, base), 2100);
      expect(TaskTree.lastDue(kids), DateTime(2026, 9, 18));
    });

    test('하위가 남은 상위는 칸에서 빠지고, 다 끝나면 돌아온다', () {
      final top = task('공개', 0, status: TaskStatus.sessionPlanned);
      final open = [top, task('1', 1, parent: id(top))];
      expect(TaskTree.hiddenOnBoard(open, top), isTrue);
      expect(TaskTree.hiddenOnBoard(open, open[1]), isFalse);
      final closed = [top, task('1', 1, parent: id(top), status: TaskStatus.done)];
      expect(TaskTree.hiddenOnBoard(closed, top), isFalse);
      expect(TaskTree.hiddenOnBoard([top], top), isFalse);
    });

    test('두 단계·자기 자신·하위 있는 태스크·다른 프로젝트는 상위로 못 붙인다', () {
      final top = task('공개', 0);
      final kid = task('보안', 1, parent: id(top));
      final lone = task('따로', 2);
      final other = task('남의 것', 3, projectId: 'p2');
      final all = [top, kid, lone, other];
      expect(TaskTree.parentRefusal(all, id(lone), id(top)), isNull);
      expect(TaskTree.parentRefusal(all, '', id(top)), isNull);
      expect(TaskTree.parentRefusal(all, id(lone), id(kid)), contains('한 단계'));
      expect(TaskTree.parentRefusal(all, id(lone), id(lone)), contains('자기 자신'));
      expect(TaskTree.parentRefusal(all, id(top), id(lone)), contains('하위가 있는'));
      expect(TaskTree.parentRefusal(all, id(other), id(top)), contains('같은 프로젝트'));
      expect(TaskTree.parentRefusal(all, id(lone), 'nope'), contains('없다'));
    });

    test('마지막 하위가 끝나는 순간 상위가 확인필요로 오른다 — 완료는 아니다', () {
      final top = task('대시보드 UX', 0, status: TaskStatus.paused);
      final k1 = task('1', 1, parent: id(top), status: TaskStatus.done);
      final k2before = task('2', 2, parent: id(top), status: TaskStatus.review);
      final k2after = k2before.copyWith(status: TaskStatus.done);
      final before = {for (final t in [top, k1, k2before]) id(t): t};
      final out = TaskTree.rollUp([top, k1, k2after], before, base);
      expect(out.first.status, TaskStatus.review);
      expect(out.first.done, isFalse);
    });

    test('하위가 남았거나, 이번에 완료로 넘어온 하위가 없으면 상위를 건드리지 않는다', () {
      final top = task('상위', 0, status: TaskStatus.sessionPlanned);
      final k1 = task('1', 1, parent: id(top), status: TaskStatus.done);
      final k2 = task('2', 2, parent: id(top));
      final before = {for (final t in [top, k1, k2]) id(t): t};
      // 하위 하나가 남음
      final k1b = task('1', 1, parent: id(top));
      expect(TaskTree.rollUp([top, k1, k2], {...before, id(k1): k1b}, base).first.status, TaskStatus.sessionPlanned);
      // 다 끝나 있었지만 이번에 바뀐 하위가 없음(대표가 상위를 옮겨 둔 것)
      final k2d = k2.copyWith(status: TaskStatus.done);
      final all = [top, k1, k2d];
      expect(TaskTree.rollUp(all, {for (final t in all) id(t): t}, base).first.status, TaskStatus.sessionPlanned);
    });

    test('상위를 지우면 하위는 맨 위 태스크로 풀린다', () {
      final top = task('공개', 0);
      final rest = TaskTree.orphaned([task('1', 1, parent: id(top)), task('2', 2)], id(top));
      expect(rest.map((t) => t.parentId), [null, null]);
      expect(rest.length, 2);
    });
  });

  group('업무 지시서 — 세 칸과 보내는 말', () {
    test('세 칸은 머리말로 합쳐 한 칸에 담기고 그대로 되읽힌다', () {
      const b = TaskBrief(what: '스크롤 튐 고치기', done: '맨 아래가 유지된다', dont: '위젯은 건드리지 않는다');
      final body = b.compose();
      expect(body, '스크롤 튐 고치기\n\n완료 기준:\n맨 아래가 유지된다\n\n하지 말 것:\n위젯은 건드리지 않는다');
      final back = TaskBrief.parse(body);
      expect([back.what, back.done, back.dont], [b.what, b.done, b.dont]);
    });

    test('머리말 없는 옛 프롬프트는 통째로 「무엇을」이고, 빈 칸은 머리말도 안 붙는다', () {
      final old = TaskBrief.parse('titles/ 아래 크롤러를 고쳐줘\n여러 줄이다');
      expect([old.what, old.done, old.dont], ['titles/ 아래 크롤러를 고쳐줘\n여러 줄이다', '', '']);
      expect(const TaskBrief(what: '하나').compose(), '하나');
      expect(const TaskBrief(done: '끝나면').compose(), '완료 기준:\n끝나면');
    });

    test('보내는 말은 태스크 표시가 앞에 붙고, 프롬프트가 비면 제목을 되풀이하지 않는다', () {
      final at = DateTime(2026, 9, 15, 18, 38);
      final t = TodoItem(text: '채팅창 튐', project: '/p', body: '고쳐줘', at: at);
      final tag = '[태스크 ${at.toIso8601String()}] 「채팅창 튐」';
      expect(t.dispatch, '$tag\n고쳐줘');
      expect(TodoItem(text: '채팅창 튐', project: '/p', at: at).dispatch, tag);
      final rv = t.copyWith(status: TaskStatus.revision, revisionNote: '아직 튄다');
      expect(rv.dispatch, '$tag\n고쳐줘\n\n[수정요청]\n아직 튄다');
    });
  });

  group('미리보기가 붙은 선택지', () {
    // test/fixtures/panes/20260915_미리보기/ — qa_직원 세션 실측(대표 제보 9/15: 선택 카드 표가 깨진다)
    PaneChoice read(String f) =>
        PaneChoice.parse(File('test/fixtures/panes/20260915_미리보기/$f').readAsStringSync())!;

    test('선택지 이름에 오른쪽 상자 글자가 안 붙고, 설명으로 빨려 들지 않는다', () {
      final c = read('02_cursor2.txt');
      expect(c.options.map((o) => o.text), ['간단 표', '상세 표', '종류별 묶음 표']);
      expect(c.options.every((o) => o.detail == null), isTrue);
      expect(c.question, '마당대시판 할 일 목록을 어떤 표 형태로 보여줄까요?');
      expect(c.cursor, 2);
    });

    test('커서가 놓인 선택지의 미리보기를 상자 테두리만 벗겨 모양 그대로 담는다', () {
      final one = read('01_cursor1.txt');
      expect(one.preview.first, startsWith('┌──────────────┬'));
      expect(one.preview[1], '│ 제목         │ 상태     │ 시간   │');
      expect(one.preview.last, startsWith('└──────────────┴'));
      final three = read('03_cursor3.txt');
      expect(three.cursor, 3);
      expect(three.preview.first, '[자사] 합계 1h 20m');
      expect(three.preview, contains(''));
      expect(three.preview.any((l) => l.contains('Notes')), isFalse);
    });

    test('긴 미리보기는 ✂ 줄을 안내 한 줄로 두고, 설명으로 새지 않는다', () {
      final c = read('05_tall_clipped.txt');
      expect(c.cursor, 2);
      expect(c.preview.first, '1. 항목 1');
      expect(c.preview.last, '✂ 6줄 더 있다 — 터미널도 잘라서 보여 준다');
      expect(c.options.every((o) => o.detail == null), isTrue);
    });

    test('미리보기 창에서 줄바꿈된 긴 선택지 이름은 이름으로 잇는다', () {
      final c = read('06_long_name.txt');
      expect(c.options.map((o) => o.text).last, '이름이 아주 긴 선택지 — 설명이 두 줄로 넘어갈 만큼 긴 이름을 붙여 본다');
      expect(c.options.last.detail, isNull);
      expect(c.cursor, 4);
      expect(c.preview.first, startsWith('┌──────────────┬'));
    });

    test('넓은 표는 터미널이 상자 폭에서 접은 줄을 다시 이어 한 줄로 담는다', () {
      final c = read('04_wide_wrap.txt');
      expect(c.preview.length, 5); // 머리 · 구분선 · 3줄
      expect(c.preview[0], startsWith('| col01'));
      expect(c.preview[0], endsWith('| col10  |'));
      expect(c.preview[1], endsWith('|--------|--------|'));
      expect(c.preview[4], endsWith('| r3-c10 |'));
      expect(c.options.length, 4);
    });

    test('칸 수는 한글을 두 칸으로 센다', () {
      expect(termCols('abc'), 3);
      expect(termCols('한글 표'), 7);
      expect(termCols('─│'), 2);
    });

    test('미리보기가 없는 선택창은 그대로다', () {
      final f = File('test/fixtures/panes/20260804/10_ask_question.txt');
      expect(PaneChoice.parse(f.readAsStringSync())!.preview, isEmpty);
    });
  });

  group('처음 설정 — 훅', () {
    test('넣는 줄이 setup_hooks.py 와 글자까지 같다 (다르면 스크립트가 못 알아보고 두 번 넣는다)', () {
      expect(FirstRun.hookCommand(9876, 'Stop'),
          "cat | curl -s -m 2 -X POST http://127.0.0.1:9876/ -H 'Content-Type: application/json' --data-binary @- > /dev/null 2>&1 || true  # claude-watcher");
      expect(FirstRun.hookCommand(9876, 'UserPromptSubmit'),
          "cat | curl -s -m 2 -X POST http://127.0.0.1:9876/ -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || true  # claude-watcher");
    });

    test('빈 설정에는 아홉 개를 넣고, 다시 부르면 더 안 넣는다', () {
      expect(FirstRun.missingHooks({}, 9876), FirstRun.hookEvents);
      final once = FirstRun.withHooks({}, 9876);
      expect(FirstRun.missingHooks(once, 9876), isEmpty);
      expect(FirstRun.withHooks(once, 9876), once);
      final pre = (once['hooks'] as Map)['PreToolUse'] as List;
      expect(pre.single['matcher'], '*');
      expect(((once['hooks'] as Map)['Stop'] as List).single.containsKey('matcher'), isFalse);
    });

    test('남의 훅은 그대로 두고 옆에 선다 · 표식 없는 옛 훅도 우리 것으로 본다', () {
      final mine = {'type': 'command', 'command': 'curl -X POST http://127.0.0.1:9876/'};
      final other = {'type': 'command', 'command': 'say done'};
      final s = {
        'model': 'x',
        'hooks': {
          'Stop': [{'hooks': [other]}],
          'SessionStart': [{'hooks': [mine]}],
        },
      };
      final out = FirstRun.withHooks(s, 9876);
      expect(out['model'], 'x');
      final stop = (out['hooks'] as Map)['Stop'] as List;
      expect(stop.length, 2);
      expect(stop.first, {'hooks': [other]});
      expect(((out['hooks'] as Map)['SessionStart'] as List).length, 1);
      expect(((s['hooks'] as Map)['Stop'] as List).length, 1, reason: '원본을 건드리면 안 된다');
    });

    test('빼기는 우리 훅만 뺀다 · 넣고 빼면 원래대로', () {
      final other = {'type': 'command', 'command': 'say done'};
      final s = {'model': 'x', 'hooks': {'Stop': [{'hooks': [other]}]}};
      final back = FirstRun.withoutHooks(FirstRun.withHooks(s, 9876), 9876);
      expect(back, s);
      expect(FirstRun.withoutHooks(FirstRun.withHooks({}, 9876), 9876), isEmpty);
    });

    test('배열이 아닌 이벤트는 손대지 않는다', () {
      final s = {'hooks': {'Stop': 'weird'}};
      expect(FirstRun.missingHooks(s, 9876), isNot(contains('Stop')));
      expect((FirstRun.withHooks(s, 9876)['hooks'] as Map)['Stop'], 'weird');
    });
  });

  group('처음 설정 — 시작용 CLAUDE.md', () {
    test('포트·cwd·완료 규칙이 들어 있고 셸 변수는 글자 그대로 남는다', () {
      final md = FirstRun.starterClaudeMd('내 프로젝트', 9876);
      expect(md, startsWith('# 내 프로젝트\n'));
      expect(md, contains('http://127.0.0.1:9876/todo/api'));
      expect(md, contains(r'CWD="$(pwd)"'));
      expect(md, contains(r'-d "{\"cwd\":\"$CWD\",\"text\":\"제목\"}"'));
      expect(md, contains('"ownerConfirmed":true'));
      expect(md, contains('무엇을 도와드릴까요?'));
      final dir = Directory.systemTemp.createTempSync('cw_greet');
      File('${dir.path}/CLAUDE.md').writeAsStringSync(md);
      expect(FirstRun.needsGreeting(dir.path), isTrue);
      File('${dir.path}/CLAUDE.md').writeAsStringSync(md.replaceFirst('- 무엇을 만드는가:\n', '- 무엇을 만드는가: 블로그\n'));
      expect(FirstRun.needsGreeting(dir.path), isFalse, reason: '칸을 채운 뒤에는 먼저 묻지 않는다');
      dir.deleteSync(recursive: true);
      final out = Platform.environment['CW_STARTER_OUT'];
      if (out != null) File(out).writeAsStringSync(md);
    });
  });

  group('출근·휴식·퇴근 버튼', () {
    test('오늘 기록으로 보일 버튼을 고른다', () {
      expect(ClockButtons.actionsFor(null), ['start']);
      expect(ClockButtons.actionsFor(WorkDay(date: '2026-09-16', clockIn: '09:00')), ['breakStart', 'end']);
      expect(ClockButtons.actionsFor(WorkDay(date: '2026-09-16', clockIn: '09:00', breakFrom: '12:00')), ['breakEnd']);
      expect(ClockButtons.actionsFor(WorkDay(date: '2026-09-16', clockIn: '09:00', clockOut: '18:00')), isEmpty);
    });
  });


  group('사무실 꾸밈 — 이름과 층 차례', () {
    late Directory tmp;
    late OfficeLayout office;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('office');
      office = OfficeLayout.at('${tmp.path}/office_layout.json');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Floor floor(String root, {bool top = false}) =>
        Floor(name: root.split('/').last, sessions: const [], rootPath: root, top: top, depths: const {});

    test('별명을 지우면 폴더 이름으로 돌아간다', () {
      expect(office.rename('/a/b', '마당 제작팀'), isNull);
      expect(office.nameOf('/a/b'), '마당 제작팀');
      expect(office.rename('/a/b', '  '), isNull);
      expect(office.nameOf('/a/b'), isNull);
    });

    test('30자를 넘는 이름은 거절한다', () {
      expect(office.rename('/a/b', 'ㄱ' * 31), isNotNull);
      expect(office.nameOf('/a/b'), isNull);
    });

    test('이사 층은 차례를 바꿔도 맨 위다', () {
      final floors = [floor('/z', top: true), floor('/a'), floor('/b')];
      expect(office.move(floors, '/b', -1), isNull);
      expect(office.arrange(floors).map((f) => f.rootPath), ['/z', '/b', '/a']);
      // 이사 층은 옮길 대상이 아니다.
      expect(office.move(floors, '/z', 1), isNotNull);
      expect(office.arrange(floors).first.rootPath, '/z');
    });

    test('맨 끝에서 더 내리려 해도 차례가 안 망가진다', () {
      final floors = [floor('/z', top: true), floor('/a'), floor('/b')];
      expect(office.move(floors, '/b', 1), isNull);
      expect(office.arrange(floors).map((f) => f.rootPath), ['/z', '/a', '/b']);
    });

    test('이름 소식은 세션마다 한 번만 간다', () {
      office.rename('/a/b', '마당 제작팀');
      final first = office.noticeFor('sid-1', '/a/b', 'claude_watcher');
      expect(first, contains('마당 제작팀'));
      expect(office.noticeFor('sid-1', '/a/b', 'claude_watcher'), '');
      // 새로 켠 세션(다른 session_id)은 첫 말에서 받는다.
      expect(office.noticeFor('sid-2', '/a/b', 'claude_watcher'), contains('마당 제작팀'));
      // 지우면 그것도 한 번 알린다.
      office.rename('/a/b', '');
      expect(office.noticeFor('sid-1', '/a/b', 'claude_watcher'), contains('claude_watcher'));
      expect(office.noticeFor('sid-1', '/a/b', 'claude_watcher'), '');
    });

    test('별명이 없던 세션에는 아무 말도 안 한다', () {
      expect(office.noticeFor('sid-9', '/no/name', 'no'), '');
    });
  });

  group('하는 일 줄 — 남은 한도는 걸러낸다 (UI 리뷰 9/18)', () {
    test('상태줄의 5h·7d 줄은 진행이 아니다', () {
      const pane = '⏺ 파일을 고치는 중\n5h 4% · 7d 63%\n';
      expect(PaneView.activity(pane), ['⏺ 파일을 고치는 중']);
    });

    test('본문에 나온 비슷한 글자는 안 지운다', () {
      const pane = '5시간 뒤에 7일치를 본다\n';
      expect(PaneView.activity(pane), ['5시간 뒤에 7일치를 본다']);
    });
  });

  group('출퇴근 버튼 — 자정을 넘겨도 일 시작이 뜨지 않는다 (대표 제보 9/18)', () {
    WorkDay? Function(String) log(Map<String, WorkDay> days) => (d) => days[d];

    test('어제 퇴근을 안 했으면 어제 자리를 이어간다', () {
      final days = {'2026-09-17': WorkDay(date: '2026-09-17', clockIn: '10:00')};
      final now = DateTime.parse('2026-09-18T00:16:00');
      expect(ClockButtons.openDate(log(days), now), '2026-09-17');
      expect(ClockButtons.actionsFor(days['2026-09-17']), ['breakStart', 'end']);
    });

    test('어제 휴식 중인 채로 날이 바뀌면 휴식 끝만 뜬다', () {
      final days = {
        '2026-09-17':
            WorkDay(date: '2026-09-17', clockIn: '10:00', breakFrom: '23:40')
      };
      final now = DateTime.parse('2026-09-18T00:16:00');
      expect(ClockButtons.openDate(log(days), now), '2026-09-17');
      expect(ClockButtons.actionsFor(days['2026-09-17']), ['breakEnd']);
    });

    test('어제 퇴근했으면 오늘 자리다 — 일 시작이 맞다', () {
      final days = {
        '2026-09-17': WorkDay(
            date: '2026-09-17', clockIn: '10:00', clockOut: '23:00')
      };
      final now = DateTime.parse('2026-09-18T00:16:00');
      expect(ClockButtons.openDate(log(days), now), '2026-09-18');
      expect(ClockButtons.actionsFor(days['2026-09-18']), ['start']);
    });

    test('오늘 이미 출근했으면 어제는 보지 않는다', () {
      final days = {
        '2026-09-17': WorkDay(date: '2026-09-17', clockIn: '10:00'),
        '2026-09-18': WorkDay(date: '2026-09-18', clockIn: '09:00'),
      };
      expect(
          ClockButtons.openDate(log(days), DateTime.parse('2026-09-18T11:00:00')),
          '2026-09-18');
    });
  });

  group('취소한 선택창 — 승인 대기에 굳지 않는다 (대표 제보 9/18)', () {
    // 선택창을 esc로 물린 뒤의 실제 화면 모양. 입력창이 돌아와 있다.
    const cancelled = '''
● User declined to answer questions
  ⎿ · 사무실 배경 그림은 어떻게 준비할까요?
    · 아침 · 오후 · 저녁은 몇 시로 나눌까요?
✻ Sautéed for 12s · done 12:07 AM
────────────────────────────────────────
❯
────────────────────────────────────────
  5h 3% · 7d 63%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
''';

    test('입력창이 돌아왔으면 묻는 화면이 아니다', () {
      expect(PaneView.awaitingChoice(cancelled), isFalse);
    });

    test('선택창이 아직 떠 있으면 그대로 묻는 화면이다', () {
      const asking = '''
무엇으로 할까?
❯ 1. Yes
  2. No
  Enter to select · Esc to cancel
''';
      expect(PaneView.awaitingChoice(asking), isTrue);
    });
  });
}
