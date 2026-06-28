#!/usr/bin/env bash
# ==============================================================================
# install.sh — Ralph 키트를 대상 프로젝트에 설치한다.
#   사용: bash ~/ralph-kit/install.sh /path/to/target-project
#   하는 일:
#     1) <project>/ralph/ 에 루프·프롬프트·설정 템플릿 복사
#     2) <project>/.claude/agents/ 에 ralph-reviewer/verifier 복사
#     3) <project>/ralph/BACKLOG.md 스타터 생성(없으면)
#     4) git 작업 브랜치(ralph/auto-review) 안내
#   복사만 한다(루프를 자동 실행하진 않음).
# ==============================================================================
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "사용법: bash install.sh /path/to/target-project" >&2; exit 1; }
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "[오류] 대상 경로 없음: $1" >&2; exit 1; }

echo "[install] 대상: $TARGET"
mkdir -p "$TARGET/ralph/state" "$TARGET/.claude/agents"

# 1) 루프·프롬프트
cp "$KIT_DIR/ralph_loop.sh" "$TARGET/ralph/ralph_loop.sh"
cp "$KIT_DIR/PROMPT.md"     "$TARGET/ralph/PROMPT.md"
chmod +x "$TARGET/ralph/ralph_loop.sh"

# 2) 설정(없을 때만 — 기존 설정 보존)
if [ ! -f "$TARGET/ralph/ralph.config.sh" ]; then
  cp "$KIT_DIR/ralph.config.example.sh" "$TARGET/ralph/ralph.config.sh"
  echo "[install] ralph/ralph.config.sh 생성 — ★ 프로젝트에 맞게 채우세요(이름·RALPH_VERIFY_CMD·인벤토리)."
else
  echo "[install] ralph/ralph.config.sh 이미 있음 — 보존."
fi

# 3) 서브에이전트(없을 때만)
for a in ralph-reviewer ralph-verifier; do
  if [ ! -f "$TARGET/.claude/agents/$a.md" ]; then cp "$KIT_DIR/agents/$a.md" "$TARGET/.claude/agents/$a.md"; echo "[install] .claude/agents/$a.md 설치"; else echo "[install] .claude/agents/$a.md 이미 있음 — 보존."; fi
done

# 4) 스타터 백로그(없을 때만)
if [ ! -f "$TARGET/ralph/BACKLOG.md" ]; then
  cat > "$TARGET/ralph/BACKLOG.md" <<'MD'
# Ralph 기능 백로그

> 원하는 새 기능을 `- [ ]`로 적는다. 루프(기능 모드)가 위에서부터 하나씩 구현하고 완료 시 `- [x]`로 체크한다.
> pending이 비면 하드닝 모드(전수 정독·결함 수정)로 전환된다.
> 각 항목에 **완료조건(Acceptance)** 을 구체적으로 적을수록 좋다.

## 할 일 (pending)

- [ ] (예시) FEAT-1: 첫 기능 — 배경/완료조건을 여기 적으세요. 다 적으면 이 줄을 지우고 시작.

## 완료 (done)
MD
  echo "[install] ralph/BACKLOG.md 스타터 생성."
fi

# 5) state는 git에서 제외 권장
if [ -f "$TARGET/.gitignore" ] && ! grep -qE '(^|/)ralph/state/?$' "$TARGET/.gitignore" 2>/dev/null; then
  echo "ralph/state/" >> "$TARGET/.gitignore"; echo "[install] .gitignore 에 ralph/state/ 추가."
fi

echo ""
echo "[install] 완료. 다음 단계:"
echo "  1) $TARGET/ralph/ralph.config.sh 를 프로젝트에 맞게 편집 (★ RALPH_VERIFY_CMD 중요)"
echo "  2) $TARGET/ralph/BACKLOG.md 에 원하는 기능을 - [ ] 로 작성"
echo "  3) 작업 브랜치로:   cd $TARGET && git checkout -b ralph/auto-review   (main/master 금지)"
echo "  4) 실행:           cd $TARGET && setsid nohup bash ralph/ralph_loop.sh > ralph/state/loop.log 2>&1 &"
echo "  (claude CLI 로그인 필요. 텔레그램 알림 원하면 TELEGRAM_BOT_TOKEN/CHAT_ID 환경변수 설정.)"
