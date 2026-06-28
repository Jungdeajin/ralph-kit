# AGENTS.md — AI 에이전트용 Ralph 셋업 지시문

> **당신이 AI 코딩 에이전트(Claude Code 등)라면, 이 문서를 따라 "현재 프로젝트"에 Ralph 자동 개선 루프를 설치·설정·실행하라.**
> 사용자는 이 repo(ralph-kit)를 당신에게 보여주며 "알아서 세팅해줘"라고 요청한 것이다. 아래 STEP을 순서대로 수행하고, 막히면 사용자에게 그 지점만 물어라.

Ralph 루프 = 매 이터레이션마다 `claude -p` 오케스트레이터 1회 실행 → (백로그 항목 구현 또는 코드 하드닝) → 검증 → 커밋. 무상태 + 디스크 상태(`ralph/state/`) + 안전 캡 + 사용량 한도 자동 대기. 코드 수정은 전용 작업 브랜치에서만(되돌리기 가능).

---

## STEP 0 — 전제 확인
다음을 점검하고, 없으면 사용자에게 알려라(설치는 사용자 몫일 수 있음):
- `command -v claude` — Claude Code CLI 설치 + **로그인**되어 있어야 한다(루프가 이걸 호출).
- `command -v git` + 현재 폴더가 git 저장소(`git rev-parse --is-inside-work-tree`).
- 프로젝트 스택의 **빌드/테스트 도구**(node/go/python/rust 등) — 검증에 필요(없으면 해당 단계 SKIP).

## STEP 1 — 키트 설치
이 repo가 `<kit>` 경로에 있고, 대상 프로젝트가 `<project>`(보통 현재 디렉터리)라면:
```bash
bash <kit>/install.sh <project>
```
이게 하는 일: `<project>/ralph/`(루프·프롬프트·설정 템플릿) + `<project>/.claude/agents/`(서브에이전트 2개) + 스타터 `ralph/BACKLOG.md` 생성, `.gitignore`에 `ralph/state/` 추가.
(install.sh를 못 쓰면 이 repo의 `ralph_loop.sh`·`PROMPT.md`·`ralph.config.example.sh`를 `<project>/ralph/`로, `agents/*.md`를 `<project>/.claude/agents/`로 직접 복사하라.)

## STEP 2 — `<project>/ralph/ralph.config.sh` 작성 (★ 핵심)
프로젝트 스택을 **자동 감지**해서 채워라:

- `RALPH_PROJECT_NAME` — 프로젝트 이름(로그/알림용).
- **`RALPH_VERIFY_CMD`** — 회귀 0 검증 명령. 아래 표로 감지(★ 가장 중요, 비우지 마라):
  | 감지 파일 | RALPH_VERIFY_CMD 예시 |
  |---|---|
  | `package.json` (scripts.build/test) | `npm ci && npm run build && npm test --silent` (test 없으면 build만) |
  | `go.mod` | `go build ./... && go vet ./... && go test ./...` |
  | `pyproject.toml`/`requirements.txt` | `ruff check . ; pytest -q` (도구 있는 것만) |
  | `Cargo.toml` | `cargo build && cargo test` |
  | 모노레포(여러 개) | 하위별로 `&&`로 연결 (예: `cd frontend && npm run build && cd ../backend && go test ./...`) |
  실제 프로젝트의 `package.json` scripts / Makefile / CI 설정(`.github/workflows`)을 읽어 **그 프로젝트가 실제 쓰는 명령**으로 맞춰라.
- `RALPH_GUIDELINES` — 에이전트가 지켜야 할 규칙 문서. 프로젝트에 실제 존재하는 것만 나열(예: `CLAUDE.md AGENTS.md CONTRIBUTING.md README.md`). 없으면 비워도 되지만, **있으면 리뷰 품질이 크게 오른다** — 없다면 사용자에게 "불변식/규칙을 CLAUDE.md에 적어두면 좋다"고 권하라.
- `ralph_inventory()` — 커버리지 대상 소스 목록. 기본값이 흔한 언어를 커버하지만, 프로젝트 언어/제외경로(생성물·의존성·테스트)에 맞게 `find` 글롭을 조정하라.

## STEP 3 — 작업 브랜치
루프는 `main`/`master`에선 거부한다(안전). 작업 브랜치를 만들어라:
```bash
cd <project> && git checkout -b ralph/auto-review   # 이미 있으면 checkout
```

## STEP 4 — `<project>/ralph/BACKLOG.md` 작성
사용자가 원하는 작업을 **`- [ ]` 항목**으로 적어라. 각 항목에 **배경 + 완료조건(Acceptance)** 을 구체적으로(어디에·무엇을·어떤 동작·어떤 테스트). 구체적일수록 결과가 좋다. 예:
```markdown
- [ ] FEAT-1: <한 줄 제목>
      - 배경: <왜 필요한가>
      - 완료조건(Acceptance):
        1. <구체적 동작/파일/API>
        2. <테스트>
        3. <불변식 준수: 기존 규칙을 깨지 않음>
```
사용자 요청이 모호하면 항목으로 옮기기 전에 한 번 명확화하라.

## STEP 5 — 루프 실행
```bash
cd <project>
setsid nohup env MAX_ITERS=8 \
  bash ralph/ralph_loop.sh > ralph/state/loop.log 2>&1 &
tail -f ralph/state/loop.log
```
- 통합테스트가 외부 의존(DB 등)을 요구하면 그 env(예 `TEST_DATABASE_URL=...`)를 함께 넘겨라.
- 텔레그램 진행 알림을 원하면 `TELEGRAM_BOT_TOKEN`·`TELEGRAM_CHAT_ID`를 env로(둘 다 있어야 활성, 기본은 조용히 꺼짐).
- 백로그가 비면 루프는 **하드닝 모드**(전체 코드 전수 정독·결함 수정)로 전환한다.

## STEP 6 — 모니터링/마무리
- 진행: `tail -f ralph/state/loop.log`. 산출물: `ralph/state/`(STATE.md·COVERAGE.md·ISSUES/VERDICT·diff·DONE).
- 완료: `ralph/state/DONE` 생기거나 로그에 `RALPH_STATUS: DONE`. 매 이터레이션 커밋되므로 되돌리기 가능(`git log`, `git reset`).
- 끝나면 사용자에게: 빌드/테스트 PASS인지, 남은 결함, 커밋 요약을 정리해 보고하라. 운영본에 반영하려면 `main`에 `--no-ff` 병합을 제안하라.

---

## 안전 불변식 (에이전트가 지킬 것)
- **작업 브랜치에서만** 수정·커밋. main/master 직접 수정 금지.
- 서브에이전트(`ralph-reviewer`/`ralph-verifier`)는 read-only — 코드 수정은 오케스트레이터(메인)만.
- `RALPH_GUIDELINES`에 적힌 프로젝트 불변식(보안·데이터·아키텍처)을 절대 깨지 마라.
- 비밀/자격증명을 코드·로그·커밋에 절대 남기지 마라. 한 곳에서 같은 git 브랜치에 두 루프 동시 실행 금지(커밋 충돌).

## 동작 요약 (2모드)
- **기능 모드**: BACKLOG에 `- [ ]` 있으면 위에서부터 하나씩 구현+테스트 → 완료 시 `- [x]`.
- **하드닝 모드**: 백로그 비면 INVENTORY 전수 정독(COVERAGE 체크리스트)하며 적대적 리뷰 → 결함 수정. 무이슈+커버리지 100%+검증 PASS면 `DONE`.

더 자세한 사람용 설명은 `README.md` 참고.
