# ==============================================================================
# ralph.config.sh — 프로젝트별 설정 (ralph_loop.sh 가 source 한다)
# install.sh 가 이 예시를 ralph/ralph.config.sh 로 복사한다. 프로젝트에 맞게 채우세요.
# 모든 값은 선택 — 비우면 합리적 기본값을 씁니다.
# ==============================================================================

# 로그/텔레그램 알림에 표시할 프로젝트 이름.
RALPH_PROJECT_NAME="MyProject"

# 서브에이전트 이름(.claude/agents/<이름>.md). install.sh 가 generic 정의를 깔아둠.
RALPH_REVIEWER="ralph-reviewer"
RALPH_VERIFIER="ralph-verifier"

# 에이전트·오케스트레이터가 작업 전 반드시 읽어야 할 "프로젝트 규칙/불변식" 문서.
# (PROJECT_DIR 기준 상대경로, 공백 구분. 없는 파일은 무시됨.)
RALPH_GUIDELINES="CLAUDE.md AGENTS.md CONTRIBUTING.md README.md"

# 회귀 0 검증 명령 — 검증자가 이걸 실행해 빌드/테스트 통과를 확인한다.
# 프로젝트 스택에 맞게 바꾸세요. 여러 명령은 && 로 연결. 비우면 검증자가 자동 추론 시도.
#   예) Node:   "npm ci && npm run build && npm test --silent"
#   예) Go:     "go build ./... && go vet ./... && go test ./..."
#   예) Python: "ruff check . && pytest -q"
#   예) 복합:   "cd frontend && npm run build && cd ../backend && go build ./... && go test ./..."
RALPH_VERIFY_CMD=""

# 커버리지 체크리스트(전수 정독 보장)용 소스 파일 목록 생성 함수.
# 한 줄에 한 파일을 출력하면 된다. 테스트/생성물/의존성은 제외하도록 커스터마이즈.
# (PROJECT_DIR 에서 실행됨. 아래 기본값은 흔한 언어를 커버하고 node_modules/vendor/dist 등 제외.)
ralph_inventory() {
  find . \
    -path ./.git -prune -o \
    -name node_modules -prune -o \
    -name vendor -prune -o \
    -name dist -prune -o \
    -name build -prune -o \
    -name .next -prune -o \
    -name target -prune -o \
    -name __pycache__ -prune -o \
    -type f \( \
        -name '*.go' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
        -o -name '*.py' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.php' \
        -o -name '*.cs' -o -name '*.kt' -o -name '*.swift' -o -name '*.vue' -o -name '*.svelte' \
      \) \
      ! -name '*_test.go' ! -name '*.test.ts' ! -name '*.test.tsx' ! -name '*.test.js' \
      ! -name '*.spec.ts' ! -name '*.spec.js' ! -name '*.d.ts' ! -name '*_test.py' ! -name 'test_*.py' \
    -print
}
