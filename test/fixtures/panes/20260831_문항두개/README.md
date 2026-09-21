# 문항이 여러 개인 multiSelect 창 (2026-08-31 실측)

Claude Code v2.1.251. `AskUserQuestion`에 문항을 **두 개** 주고 둘 다 `multiSelect`로 띄웠다.

문항이 하나일 때는 선택지 아래 줄이 `Submit`인데(`../tmux_검증_20260811_다중선택/`),
**문항이 여럿이면 마지막 문항 전까지 그 자리가 `Next`다.** 위쪽에는 문항 사이를
오가는 머리줄(`←  ☐ Fruit  ☐ Drink  ✔ Submit  →`)이 따로 붙는다.

| 파일 | 화면 |
|---|---|
| `01_문항1_Next.txt` | 문항 1이 막 떴다. `4. Type something` 아래가 `Next` |
| `02_커서가_Next에.txt` | `1`로 apple을 켜고 Down 네 번 — 커서가 `Next`에 있다 |
| `03_문항2_Submit.txt` | `Next`에서 Enter — 문항 2로 넘어왔고 같은 자리가 `Submit`이다 |

키는 문항 하나짜리와 같다.

| 키 | 결과 |
|---|---|
| 숫자 | 그 줄 토글 |
| `Next`에서 Enter | **다음 문항으로 넘어간다.** 확정이 아니다 |
| `Submit`에서 Enter | `Review your answers` → `1. Submit answers / 2. Cancel` |

`Submit`만 찾던 `PaneChoice.submitLine`이 `Next`를 못 읽어 `toSubmit`이 null이었다.
그래서 확정 버튼이 잠긴 채로 떠서 **체크는 되는데 다음으로 넘어갈 수가 없었다** —
동현동현이 그림으로 잡아 준 자리다(v1.53.0에서 고침).
