#!/usr/bin/env bash
# ==============================================================================
# ralph_loop.sh — 프로젝트 무관(이식형) Ralph 자동 개선 루프 (Claude 멀티에이전트).
#   매 이터레이션마다 claude -p 오케스트레이터를 1회 실행한다(fresh context).
#   오케스트레이터: 서브에이전트로 리뷰 → 직접 수정 → 검증 → 깨끗해지면 state/DONE.
#
# 이식: 이 폴더(ralph/)를 대상 프로젝트에 복사하고 ralph.config.sh 를 채운 뒤 실행.
#   - 프로젝트 전용(이름·서브에이전트·검증명령·인벤토리)은 전부 ralph.config.sh 에서 온다.
#   - 코드 수정은 전용 작업 브랜치에서만(되돌리기 가능). git 필수.
#
# 실행:
#   bash ralph/ralph_loop.sh
#   # 백그라운드:
#   setsid nohup bash ralph/ralph_loop.sh > ralph/state/loop.log 2>&1 &
#   tail -f ralph/state/loop.log
#
# 환경변수(선택):
#   MAX_ITERS=10           # 최대 이터레이션(1~50, 기본 10)
#   CLAUDE_MODEL=opus      # claude --model (미설정 시 기본 모델)
#   SYNC_MAIN=1            # 시작 시 작업 브랜치를 base(main/master)에 ff-only 동기화(기본 1)
#   WAIT_ON_LIMIT=1        # 사용량 한도 시 대기·재개(기본 1) / POLL_INTERVAL=5m / MAX_WAIT=12h
#   TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID  # 진행 알림(둘 다 있어야 활성). 미설정 시 조용히 비활성.
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 0. 경로 + 설정 로드
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../<project>/ralph
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                  # .../<project>  (claude 실행 위치)
RALPH_STATE_REL="ralph/state"
RALPH_STATE="$PROJECT_DIR/$RALPH_STATE_REL"
PROMPT_FILE="$SCRIPT_DIR/PROMPT.md"
STATE_MD="$RALPH_STATE/STATE.md"
DONE_FILE="$RALPH_STATE/DONE"

# 프로젝트 설정(있으면 source). 모든 프로젝트 전용 값은 여기서 온다.
RALPH_PROJECT_NAME="project"
RALPH_REVIEWER="ralph-reviewer"
RALPH_VERIFIER="ralph-verifier"
RALPH_VERIFY_CMD=""
RALPH_GUIDELINES="CLAUDE.md AGENTS.md README.md"
ralph_inventory() {   # 기본 인벤토리(설정에서 재정의 가능)
  find . -path ./.git -prune -o -name node_modules -prune -o -name vendor -prune -o \
         -name dist -prune -o -name build -prune -o -name target -prune -o \
         -type f \( -name '*.go' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
                    -o -name '*.py' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' \) \
         ! -name '*_test.go' ! -name '*.test.ts' ! -name '*.test.tsx' ! -name '*.d.ts' -print
}
[ -f "$SCRIPT_DIR/ralph.config.sh" ] && source "$SCRIPT_DIR/ralph.config.sh"
PN="$RALPH_PROJECT_NAME"

timestamp() { date +"%Y%m%d_%H%M%S"; }
hms()       { date +"%H:%M:%S"; }
log()       { echo "[$(hms)] $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. 설정 검증 + 사용량 한도 대기 파라미터
# ─────────────────────────────────────────────────────────────────────────────
MAX_ITERS="${MAX_ITERS:-10}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERS" -lt 1 ] || [ "$MAX_ITERS" -gt 50 ]; then
  echo "[오류] MAX_ITERS 는 1~50 정수여야 합니다 (입력: '$MAX_ITERS')." >&2; exit 1
fi

WAIT_ON_LIMIT="${WAIT_ON_LIMIT:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-5m}"
MAX_WAIT="${MAX_WAIT:-12h}"
to_secs() { local v="$1"; case "$v" in *h) echo $(( ${v%h} * 3600 ));; *m) echo $(( ${v%m} * 60 ));; *s) echo "${v%s}";; *) echo "$v";; esac; }
POLL_SECS="$(to_secs "$POLL_INTERVAL")"
MAX_WAIT_SECS="$(to_secs "$MAX_WAIT")"
LIMIT_RE='usage limit|session limit|limit reached|hit your[^.]*limit|reset[s]? +(at +)?[0-9]|will reset|rate.?limit|overloaded|status (429|529)|too many requests|quota|try again later'

# Go 환경(있을 때만) — 비대화형 셸은 ~/.bashrc 미로드 → 직접 PATH/GOPATH 보정.
if [ -x "$HOME/.local/go/bin/go" ]; then
  export GOPATH="${GOPATH:-$HOME/.local/gopath}"
  export PATH="$HOME/.local/go/bin:$GOPATH/bin:$PATH"
  mkdir -p "$GOPATH" 2>/dev/null || true
fi

# 진행 알림(텔레그램). 둘 다 있어야 활성. 토큰은 런타임에만 읽고 절대 기록하지 않는다.
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$HOME/.cokacdir/bot_settings.json" ] && command -v python3 >/dev/null 2>&1; then
  TELEGRAM_BOT_TOKEN="$(python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    d = json.load(open(os.path.expanduser("~/.cokacdir/bot_settings.json")))
    for v in (d.values() if isinstance(d, dict) else []):
        if isinstance(v, dict) and v.get("token"):
            print(v["token"]); break
except Exception:
    pass
PY
)"
fi
notify() {
  local text="$1"
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -s -o /dev/null --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${text}" || log "[텔레그램] 전송 실패(무시)"
}
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then log "[정보] 텔레그램 진행 알림 활성(chat ${TELEGRAM_CHAT_ID})"; else log "[정보] 텔레그램 알림 비활성(TOKEN/CHAT_ID 미설정)"; fi

log "══════════════════════════════════════════════════════════════════"
log " [$PN] Ralph 루프 시작 ($(date))"
log "══════════════════════════════════════════════════════════════════"

# 1.1 claude CLI
if ! command -v claude >/dev/null 2>&1; then
  echo "[오류] 'claude' CLI 를 PATH 에서 찾을 수 없습니다 (Claude Code 설치 + 로그인 필요)." >&2; exit 1
fi
log "[정보] claude: $(command -v claude) / $(claude --version 2>&1 | head -1)"
command -v go  >/dev/null 2>&1 && log "[정보] go: $(go version 2>&1)"   || true
command -v npm >/dev/null 2>&1 && log "[정보] npm: $(npm --version 2>&1)" || true

# 1.2 git 저장소 + 안전 브랜치(main/master 금지)
cd "$PROJECT_DIR"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[오류] git 저장소가 아닙니다. 자동 수정 루프는 되돌리기를 위해 git 이 필요합니다." >&2
  echo "       먼저: (git init && git add -A && git commit -m init && git checkout -b ralph/auto-review)" >&2; exit 1
fi
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
log "[정보] git 브랜치: $CUR_BRANCH"
if [ "$CUR_BRANCH" = "main" ] || [ "$CUR_BRANCH" = "master" ]; then
  echo "[오류] main/master 에서는 자동 수정 금지. 작업 브랜치로 전환 후 실행: git checkout -b ralph/auto-review" >&2; exit 1
fi

# 1.2a 베이스 브랜치 ff-only 동기화(단일-브랜치 재사용 모델). SYNC_MAIN=0 으로 비활성.
SYNC_MAIN="${SYNC_MAIN:-1}"
if [ "$SYNC_MAIN" = "1" ]; then
  BASE_BRANCH=""
  for b in main master; do git show-ref --verify --quiet "refs/heads/$b" && { BASE_BRANCH="$b"; break; }; done
  if [ -z "$BASE_BRANCH" ]; then log "[정보] 베이스 브랜치(main/master) 없음 — 동기화 생략."
  elif ! git diff --quiet || ! git diff --cached --quiet; then log "[경고] 미커밋 변경 있음 — base 동기화 생략(덮어쓰기 방지)."
  else
    _ahead="$(git rev-list --count "$BASE_BRANCH..$CUR_BRANCH" 2>/dev/null || echo 0)"
    _behind="$(git rev-list --count "$CUR_BRANCH..$BASE_BRANCH" 2>/dev/null || echo 0)"
    if [ "$_behind" = "0" ]; then log "[정보] $CUR_BRANCH 는 이미 $BASE_BRANCH 최신."
    elif [ "$_ahead" != "0" ]; then log "[경고] $CUR_BRANCH 에 미병합 커밋 ${_ahead}개 — 먼저 병합 권장. ff 생략."
    elif git merge --ff-only "$BASE_BRANCH" >/dev/null 2>&1; then log "[정보] $CUR_BRANCH 를 $BASE_BRANCH 로 ff 동기화(${_behind} 커밋)."
    else log "[경고] ff-only 동기화 실패 — 현재 상태로 진행."; fi
  fi
fi

# 1.3 필수 파일 / 서브에이전트
[ -f "$PROMPT_FILE" ] || { echo "[오류] PROMPT.md 없음: $PROMPT_FILE" >&2; exit 1; }
for sa in "$RALPH_REVIEWER" "$RALPH_VERIFIER"; do
  [ -f "$PROJECT_DIR/.claude/agents/$sa.md" ] || { echo "[오류] 서브에이전트 정의 없음: .claude/agents/$sa.md" >&2; exit 1; }
done
log "[정보] 서브에이전트: $RALPH_REVIEWER, $RALPH_VERIFIER 확인"

# 1.4 state 디렉터리
mkdir -p "$RALPH_STATE"
rm -f "$DONE_FILE"
log "[정보] PROJECT_DIR=$PROJECT_DIR / MAX_ITERS=$MAX_ITERS / MODEL=${CLAUDE_MODEL:-default}"
notify "🚀 [$PN] Ralph 루프 시작 (브랜치 $CUR_BRANCH, 최대 ${MAX_ITERS}회)"

CLAUDE_FLAGS=( --dangerously-skip-permissions -p )
[ -n "$CLAUDE_MODEL" ] && CLAUDE_FLAGS+=( --model "$CLAUDE_MODEL" )
log "[정보] 한도 대기: WAIT_ON_LIMIT=$WAIT_ON_LIMIT POLL=${POLL_INTERVAL}(${POLL_SECS}s) MAX_WAIT=${MAX_WAIT}(${MAX_WAIT_SECS}s)"

# ─────────────────────────────────────────────────────────────────────────────
# 1a. 오케스트레이터 실행 — 사용량 한도 시 하이브리드 대기·재개
#     반환: 0=성공, 99=한도 대기 누적 MAX_WAIT 초과(BLOCKED), 그 외=claude 실패 rc
# ─────────────────────────────────────────────────────────────────────────────
run_orchestrator() {
  local iter="$1" out="$2" prompt="$3"
  local waited=0 rc sleep_s reset_line t reset_epoch now_epoch
  while :; do
    set +e
    RALPH_ITER="$iter" RALPH_STATE="$RALPH_STATE_REL" \
      claude "${CLAUDE_FLAGS[@]}" "$prompt" < /dev/null > "$out" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      [ "$waited" -gt 0 ] && notify "▶️ [$PN] 토큰 복구 — 작업 재개됨 (이터 ${iter}, 약 $((waited/60))분 대기 후)."
      return 0
    fi
    if ! grep -qiE "$LIMIT_RE" "$out"; then return "$rc"; fi
    if [ "$WAIT_ON_LIMIT" != "1" ]; then log "[경고] 사용량 한도 감지(rc=$rc) — WAIT_ON_LIMIT=0, 대기 없이 반환."; return "$rc"; fi
    if [ "$waited" -ge "$MAX_WAIT_SECS" ]; then log "[중단] 한도 대기 누적 ${waited}s ≥ MAX_WAIT — BLOCKED."; return 99; fi
    sleep_s=""
    reset_line="$(grep -oiE 'reset[^.]*' "$out" | head -1 || true)"
    if [ -n "$reset_line" ]; then
      t="$(echo "$reset_line" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | head -1 || true)"
      if [ -n "$t" ]; then
        reset_epoch="$(date -d "$t" +%s 2>/dev/null || true)"; now_epoch="$(date +%s)"
        if [ -n "$reset_epoch" ]; then
          [ "$reset_epoch" -le "$now_epoch" ] && reset_epoch=$((reset_epoch + 86400))
          sleep_s=$(( reset_epoch - now_epoch + 60 ))
        fi
      fi
    fi
    if [ -z "$sleep_s" ] || [ "$sleep_s" -le 0 ] || [ "$sleep_s" -gt "$MAX_WAIT_SECS" ]; then sleep_s="$POLL_SECS"; fi
    log "[대기] 한도 감지 — ${sleep_s}s 후 이터 ${iter} 재시도 (누적 ${waited}s)."
    notify "⏳ [$PN] 사용량 한도 — ${sleep_s}s 대기 후 재개 (이터 ${iter})."
    sleep "$sleep_s"; waited=$((waited + sleep_s))
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. 메인 루프
# ─────────────────────────────────────────────────────────────────────────────
prev_head="$(git rev-parse HEAD)"; no_progress=0

for iter in $(seq 1 "$MAX_ITERS"); do
  echo ""
  log "════════════════════════════════════════════════════════════════"
  log " ITERATION $iter / $MAX_ITERS — 시작"
  log "════════════════════════════════════════════════════════════════"
  notify "🔁 [$PN] 이터레이션 ${iter}/${MAX_ITERS} 시작"

  iter_out="$RALPH_STATE/orchestrator_iter${iter}_$(timestamp).log"
  iter_start_head="$(git rev-parse HEAD)"

  # 전체 소스 인벤토리(결정적) — 커버리지 체크리스트의 권위 목록(프로젝트 설정의 ralph_inventory).
  ralph_inventory 2>/dev/null | LC_ALL=C sort > "$RALPH_STATE/INVENTORY.txt" || true
  _inv_total="$(wc -l < "$RALPH_STATE/INVENTORY.txt" 2>/dev/null | tr -d ' ')"
  log "[정보] 소스 인벤토리: ${_inv_total} files (커버리지 대상)"

  # 오케스트레이터 프롬프트 = 컨텍스트 헤더(루프 주입 변수) + PROMPT.md 본문
  prompt="$(cat <<EOF
[루프 주입 변수]
RALPH_PROJECT_NAME=${PN}
RALPH_ITER=${iter}
RALPH_STATE=${RALPH_STATE_REL}
RALPH_REVIEWER=${RALPH_REVIEWER}
RALPH_VERIFIER=${RALPH_VERIFIER}
RALPH_GUIDELINES=${RALPH_GUIDELINES}
RALPH_VERIFY_CMD=${RALPH_VERIFY_CMD}
(작업 디렉터리는 ${PROJECT_DIR} 입니다. 상태 파일은 ${RALPH_STATE_REL}/ 아래에 두십시오.
 위 RALPH_GUIDELINES 문서를 먼저 읽고 그 불변식·제약을 지키십시오. 검증은 RALPH_VERIFY_CMD 로 합니다.)

$(cat "$PROMPT_FILE")
EOF
)"

  set +e; run_orchestrator "$iter" "$iter_out" "$prompt"; rc=$?; set -e

  log "[정보] 오케스트레이터 종료코드=$rc, 출력: $iter_out ($(wc -c < "$iter_out" 2>/dev/null || echo 0) bytes)"
  last_status="$(grep -E '^RALPH_STATUS: (DONE|CONTINUE|BLOCKED)$' "$iter_out" | tail -1 || true)"
  log "[정보] 보고 상태: ${last_status:-(없음)}"

  git diff "$iter_start_head" > "$RALPH_STATE/diff_iter${iter}.patch" 2>/dev/null || true
  _patch_files="$(git diff --name-only "$iter_start_head" 2>/dev/null | wc -l | tr -d ' ')"
  log "[정보] 변경 스냅샷: diff_iter${iter}.patch (${_patch_files} files)"

  if [ -f "$DONE_FILE" ]; then
    log "[성공] state/DONE 감지 — 깨끗한 상태 도달. 루프 정상 종료."
    notify "✅ [$PN] Ralph 완료 (이터 ${iter}). 더 처리할 결함 없음."; break
  fi
  if echo "$last_status" | grep -q "RALPH_STATUS: BLOCKED"; then
    log "[중단] 오케스트레이터 BLOCKED 보고 — 사람 확인 필요."; notify "🛑 [$PN] Ralph BLOCKED (이터 ${iter})."; break
  fi
  if [ "$rc" -eq 99 ]; then
    log "[중단] 한도 대기가 MAX_WAIT 초과 — BLOCKED. 한도 회복 후 재실행하면 이어집니다."
    notify "🛑 [$PN] 사용량 한도 대기 초과(이터 ${iter}). 재실행 시 이어서 진행."; break
  fi
  if [ "$rc" -ne 0 ]; then
    log "[경고] 오케스트레이터 비정상 종료(코드 $rc). 안전을 위해 중단."
    notify "🚨 [$PN] Ralph 오케스트레이터 오류(코드 $rc, 이터 ${iter})."; break
  fi

  cur_head="$(git rev-parse HEAD)"
  if [ "$cur_head" = "$prev_head" ] && git diff --quiet HEAD 2>/dev/null; then
    no_progress=$((no_progress + 1))
    log "[경고] 코드 변경/커밋 없음 (연속 ${no_progress}회)."
    if [ "$no_progress" -ge 2 ]; then log "[중단] 진척 없음 2회 — 무한 스핀 방지로 중단."; notify "⚠️ [$PN] Ralph 진척 없음 2회 — 중단(이터 ${iter})."; break; fi
  else no_progress=0; fi
  prev_head="$cur_head"
  log "[정보] 이터레이션 $iter 완료 — 다음 라운드 진행."
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. 마무리 요약
# ─────────────────────────────────────────────────────────────────────────────
echo ""
log "════════════════════════════════════════════════════════════════"
log " [$PN] Ralph 루프 종료 — 요약"
log "════════════════════════════════════════════════════════════════"
if [ -f "$DONE_FILE" ]; then log "[결과] DONE — 정리 완료. 요약:"; sed 's/^/    /' "$DONE_FILE" 2>/dev/null || true
else log "[결과] 미완료(잔여 이슈 또는 중단). 아래 확인:"; fi
echo ""
log "  최신 상태:   $STATE_MD"
log "  이슈/판정:   $RALPH_STATE/ISSUES_iter*.md , VERDICT_iter*.md"
log "  변경 스냅샷: $RALPH_STATE/diff_iter*.patch"
log "  커밋 로그:   git log --oneline $CUR_BRANCH"
echo ""
notify "🏁 [$PN] Ralph 루프 종료. 상태: $RALPH_STATE"
