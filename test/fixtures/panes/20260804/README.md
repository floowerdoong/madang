# tmux capture-pane / send-keys 검증 (2026-08-04)

BRIEF 3단계 검증에서 실제로 떠온 화면이다. 판단 근거로 남긴다.
결론과 그에 따른 설계 결정은 `../../../files 6/BRIEF.md`의 3단계 절에 있다.

| 파일 | 무엇 |
|---|---|
| `01_launch.txt` | 세션을 만들고 `claude`를 띄운 직후. 폴더 신뢰 확인 화면 |
| `05_long_plain.txt` | 표·코드블록·목록이 섞인 응답을 받은 뒤의 화면 |
| `06_choice_live.txt` | 선택창 파서(`PaneChoice`)가 물고 있는 고정 자료. 2026-08-05 캡처 |
| `07_working_live.txt` | 작업 중 화면. 진행 스트립(`PaneView.activity`)이 읽는다 |
| `08_input_typed.txt` | **입력창에 글자가 들어 있는** 화면. 오탐을 막는 고정 자료 |
| `09_cursor_prompt.txt` | `/effort` 가 열린 화면. 화살표형 창을 잡아내는지 본다 |
| `10_ask_question.txt` | AskUserQuestion 선택창. 문항·설명·조작법을 읽어내는지 본다 |
| `11_slider.txt` | `/effort` 슬라이더. **60줄 화면**이어야 옵션 줄이 보인다 |
| `12_ask_with_lead.txt` | 묻기 직전에 한 말이 위에 있는 선택창. 앞말을 가려내는지 본다 |

## 선택창 파서의 근거 (2026-08-05 추가)

`06_choice_live.txt`는 테스트가 직접 읽는다. 여기서 확인된 것이 둘이다.

- **선택창이 화면 아래쪽에 뜬다는 보장이 없다.** 45줄짜리 화면의 17번째 줄에 뜨고
  그 아래가 통째로 비어 있다. "꼬리 N줄만 본다" 식의 자리 규칙은 못 쓴다
- **숫자만 보내면 그 자리에서 확정된다.** `send-keys '1'` 뒤 0.4초면 선택창이 사라진다.
  Enter를 같이 보내면 확정된 뒤의 입력창에 빈 줄이 들어간다

```bash
tmux new-session -d -s cw_probe -c <빈폴더> -x 120 -y 45
tmux send-keys -t cw_probe 'claude' Enter && sleep 9
tmux capture-pane -p -t cw_probe          # 신뢰 확인창이 떠 있다
tmux send-keys -t cw_probe '1' && sleep 1
tmux capture-pane -p -t cw_probe          # 벌써 통과했다 — Enter 불필요
tmux kill-session -t cw_probe
```

## 여기서 확인된 것

- 화면 텍스트는 **그대로 읽을 만하다.** 별도 정리 없이 띄워도 된다
- 떨어져 있는(detached) 세션도 읽힌다. 붙어 있을 필요가 없다
- 한글 입력이 깨지지 않는다. 다만 `Enter`는 별도 인자로 보내야 제출된다
- **스크롤백이 없다.** 클로드 코드는 alternate screen에서 돌아 화면을 다시 그린다.
  `-S -2000`을 줘도 지금 보이는 화면만 돌아온다

마지막 항목 때문에 "완료 시 보여줄 서류"의 기본 소스는 transcript로 간다.
capture-pane은 "지금 화면 스냅샷" 용도로만 쓴다.

## 다시 해보려면

```bash
tmux new-session -d -s cw_test -c <빈폴더> -x 120 -y 45
tmux send-keys -t cw_test 'claude' Enter
tmux send-keys -t cw_test '질문'          # 입력만 된다
tmux send-keys -t cw_test Enter           # 이걸 보내야 제출된다
tmux capture-pane -p -t cw_test           # 평문
tmux capture-pane -p -e -t cw_test        # ANSI 색까지
tmux kill-session -t cw_test
```
