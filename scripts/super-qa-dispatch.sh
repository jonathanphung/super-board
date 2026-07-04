#!/usr/bin/env bash
# super-qa-dispatch.sh — thin dispatcher for one super-qa iteration worker.
#
# Called by the /super-qa orchestrator (see skills/super-qa/SKILL.md §2b):
#   .claude/bin/super-qa-dispatch.sh <iteration-number>
#
# What it does:
#   1. Composes the worker prompt = references/iteration-preamble.md
#      + a per-iteration metadata footer (iter num, branch, base SHA,
#      iteration-file path, mandatory final-commit format).
#   2. Runs `claude -p --dangerously-skip-permissions --max-turns 250`
#      in the repo root (no worktree), logging to
#      .planning/super-build-logs/super-qa-iter-N.log.
#   3. Verifies the worker produced the close-out commit.
#
# Exit codes (the orchestrator's contract — do not renumber):
#   0  iter complete (close-out commit found)
#   2  worker exited non-zero (and no human gate)
#   3  worker exited zero but no close-out commit found
#   4  HUMAN GATE tripped (worker printed "HUMAN GATE TRIPPED")
#   5  WIP-CHECKPOINT: no close-out commit, but a `wip:` commit landed —
#      wall-clock clipped the worker mid-fix; next iter picks it up
#   64 bad arguments / missing prerequisites

set -euo pipefail

ITER="${1:-}"
if [ -z "$ITER" ] || ! [[ "$ITER" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <iteration-number>" >&2
  exit 64
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "super-qa-dispatch: not inside a git repository" >&2
  exit 64
fi
cd "$REPO_ROOT"

# Preamble: installed location first, then the source-repo layout (dev runs).
PREAMBLE=""
for cand in \
  ".claude/skills/super-qa/references/iteration-preamble.md" \
  "$(dirname "${BASH_SOURCE[0]}")/../skills/super-qa/references/iteration-preamble.md"; do
  if [ -f "$cand" ]; then PREAMBLE="$cand"; break; fi
done
if [ -z "$PREAMBLE" ]; then
  echo "super-qa-dispatch: iteration-preamble.md not found (is super-qa installed?)" >&2
  exit 64
fi

if [ ! -f "docs/super-qa/queue.md" ]; then
  echo "super-qa-dispatch: docs/super-qa/queue.md missing — seed the queue first (see SKILL.md)" >&2
  exit 64
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "super-qa-dispatch: claude CLI not on PATH" >&2
  exit 64
fi

# BASE_URL must come from the environment / local config — never hardcoded.
if [ -z "${BASE_URL:-}" ]; then
  echo "super-qa-dispatch: BASE_URL not set — defaulting to http://localhost:3000 (local static server)." >&2
  echo "                   Override for deployed targets: BASE_URL=https://... $0 $ITER" >&2
  export BASE_URL="http://localhost:3000"
fi

# Forensics writes are ON for every dispatched iter (report-fixture gates on this).
export SUPER_QA_FORENSICS=1

LOG_DIR=".planning/super-build-logs"
mkdir -p "$LOG_DIR" "docs/super-qa/iter"
LOG="$LOG_DIR/super-qa-iter-${ITER}.log"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASE_SHA=$(git rev-parse HEAD)
ITER_FILE="docs/super-qa/iter/iteration-${ITER}.md"

FOOTER=$(cat <<EOF

- Iteration number: ${ITER}
- Working directory: ${REPO_ROOT} (repo root — NO worktree)
- Active branch: ${BRANCH}
- Base commit SHA: ${BASE_SHA}
- Iteration file you MUST create: ${ITER_FILE}
- Target: BASE_URL=${BASE_URL}
- Mandatory final-commit format: super-qa: iter ${ITER} (X bugs, Y items, Z PRs opened)
EOF
)

PROMPT="$(cat "$PREAMBLE")${FOOTER}"

echo "[super-qa-dispatch] iter ${ITER} — branch=${BRANCH} base=${BASE_SHA:0:8} target=${BASE_URL}" | tee -a "$LOG"

set +e
claude -p "$PROMPT" --dangerously-skip-permissions --max-turns 250 >>"$LOG" 2>&1
WORKER_EXIT=$?
set -e

# Human gate takes precedence over every other signal.
if grep -q "HUMAN GATE TRIPPED" "$LOG"; then
  echo "[super-qa-dispatch] HUMAN GATE — see $LOG" >&2
  exit 4
fi

# What did the worker commit since dispatch? Commit evidence outranks the
# worker's exit code: a close-out commit means the iteration finished even if
# the claude process then died at teardown, and a wip checkpoint is the
# documented recoverable state — failing either as exit 2 would halt the
# orchestrator on work the next iteration can pick up.
CLOSEOUT=$(git log --format='%s' "${BASE_SHA}..HEAD" 2>/dev/null | grep -c "^super-qa: iter ${ITER} " || true)
WIP=$(git log --format='%s' "${BASE_SHA}..HEAD" 2>/dev/null | grep -c "^wip: super-qa iter ${ITER}" || true)

if [ "$CLOSEOUT" -ge 1 ]; then
  SUBJECT=$(git log --format='%s' "${BASE_SHA}..HEAD" | grep "^super-qa: iter ${ITER} " | head -1)
  [ "$WORKER_EXIT" -ne 0 ] && echo "[super-qa-dispatch] note: worker exited ${WORKER_EXIT} after committing its close-out — treating as complete (see $LOG)" >&2
  echo "[super-qa-dispatch] iter ${ITER} complete — ${SUBJECT}"
  exit 0
fi

if [ "$WIP" -ge 1 ]; then
  [ "$WORKER_EXIT" -ne 0 ] && echo "[super-qa-dispatch] note: worker exited ${WORKER_EXIT} after its wip checkpoint (see $LOG)" >&2
  echo "[super-qa-dispatch] iter ${ITER} clipped mid-fix (wip commit, no close-out) — exit 5 (WIP-CHECKPOINT)" >&2
  exit 5
fi

if [ "$WORKER_EXIT" -ne 0 ]; then
  echo "[super-qa-dispatch] worker exited ${WORKER_EXIT} with no commit evidence — see $LOG" >&2
  exit 2
fi

echo "[super-qa-dispatch] worker exited 0 but produced no 'super-qa: iter ${ITER}' commit — see $LOG" >&2
exit 3
