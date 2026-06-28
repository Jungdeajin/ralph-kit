# Ralph 키트 — 이식형 자동 개선 루프 (어떤 프로젝트든)

Claude Code로 **리뷰 → 수정 → 검증**을 반복해 코드를 자율 개선하는 Ralph 루프를, **프로젝트에 무관하게** 쓸 수 있도록 분리한 키트입니다. (원본은 한 프로젝트 전용이었음.)

## 구성
```
ralph-kit/
  ralph_loop.sh            # 범용 루프(한도 대기·텔레그램·브랜치 모델·커버리지·센티넬 내장)
  PROMPT.md                # 오케스트레이터 프롬프트(2모드·커버리지·DONE 조건 — 프로젝트 무관)
  ralph.config.example.sh  # 프로젝트별 설정 템플릿 ← 여기만 채우면 됨
  agents/
    ralph-reviewer.md      # 적대적 코드 리뷰어(read-only)
    ralph-verifier.md      # 검증자(빌드/테스트, read-only)
  install.sh               # 대상 프로젝트에 설치
  README.md
```

## 설치 (대상 프로젝트마다)
```bash
bash ~/ralph-kit/install.sh /path/to/your-project
```
→ `your-project/ralph/`(루프·프롬프트·설정) + `your-project/.claude/agents/`(서브에이전트) + 스타터 `BACKLOG.md` 생성.

## 프로젝트마다 채울 것 — `ralph/ralph.config.sh`
- `RALPH_PROJECT_NAME` — 로그/알림 이름
- **`RALPH_VERIFY_CMD`** — 회귀 0 검증 명령(★ 가장 중요). 예: `"npm ci && npm run build && npm test"` / `"go build ./... && go test ./..."`
- `RALPH_GUIDELINES` — 에이전트가 지켜야 할 규칙 문서(CLAUDE.md/AGENTS.md/README 등)
- `ralph_inventory()` — 커버리지 대상 소스 파일 목록(테스트/생성물 제외) 출력 함수
- (선택) `RALPH_REVIEWER`/`RALPH_VERIFIER` 서브에이전트 이름

## 실행
```bash
cd /path/to/your-project
git checkout -b ralph/auto-review            # main/master 에서는 실행 거부됨
setsid nohup env MAX_ITERS=8 \
  bash ralph/ralph_loop.sh > ralph/state/loop.log 2>&1 &
tail -f ralph/state/loop.log
```

## 동작 (2모드)
- **기능 모드**: `BACKLOG.md`에 `- [ ]` 항목이 있으면 위에서부터 하나씩 구현 + 테스트 + 검증 → 완료 시 `- [x]`.
- **하드닝 모드**: 백로그가 비면 전체 소스를 **커버리지 체크리스트**로 전수 정독하며 적대적 리뷰 → 결함 수정.
- 매 이터레이션 **커밋**(되돌리기 보장). 깨끗해지면 `state/DONE` 남기고 종료.

## 전제(대상 서버/머신)
- **필수**: `claude` CLI(로그인됨), `git`, `bash`
- **검증용**: 프로젝트 스택의 빌드/테스트 도구(node·go·python 등). 없으면 해당 단계 SKIP.
- **선택**: 텔레그램 알림 — `TELEGRAM_BOT_TOKEN`·`TELEGRAM_CHAT_ID` 환경변수(둘 다 있어야 활성).

## 안전장치
- main/master 자동수정 금지(작업 브랜치 강제). `SYNC_MAIN=1`이면 시작 시 base에 ff-only 동기화(미커밋/미병합 있으면 생략).
- `MAX_ITERS` 캡, 진척 없음 2회 연속 중단, 사용량 한도 시 자동 대기·재개(`MAX_WAIT` 초과 시 BLOCKED·재실행으로 이어짐).
- 서브에이전트(리뷰어/검증자)는 read-only — 코드 수정은 오케스트레이터만.

## 주의
- **두 곳에서 같은 git 브랜치/원격에 동시 실행 금지**(커밋 충돌). 서버마다 별도 클론·별도 프로젝트로.
- 루프는 Claude 계정 토큰을 소비한다(동시 실행 시 한도 2배 소모).
- `PROMPT.md`/서브에이전트는 범용이지만, **프로젝트의 진짜 규칙은 `RALPH_GUIDELINES` 문서**에서 읽는다 — 그 문서를 잘 적어두면 리뷰 품질이 올라간다.
