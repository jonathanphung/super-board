#!/usr/bin/env bash
# super-qa-file-bug.sh — file a QA finding as a board-readable GitHub issue.
#
# Called by super-qa iteration workers (see skills/super-qa/SKILL.md
# "Filing semantics"). Creates the issue, adds it to the resolved
# "Super Ultimate QA" project, and sets its Status column. Prints the
# issue NUMBER on stdout (and nothing else) so callers can capture it:
#
#   ISSUE_N=$(.claude/bin/super-qa-file-bug.sh --title "..." --body-file f.md \
#     --kind bug --priority high --category functional --route /imports \
#     --iter 3 --fingerprint "imports|tc-2|csv-upload-500")
#
# Flags:
#   --title <t>            one-line title (emoji + Type prefix added if absent)
#   --body-file <f>        markdown body (validated; see below)         [required]
#   --kind <k>             bug|feature|ux|tests|docs|tech-debt  (default bug)
#   --priority <p>         high|medium|low                      (default medium)
#   --category <c>         functional|visual|network|console|i18n|a11y|data|testability|docs
#   --area <a>             product area label (area:<a>)
#   --route <r>            route the finding is on (title + metadata)
#   --spec <s>             spec file path (metadata)
#   --iter <n>             iteration number (metadata)
#   --fingerprint <fp>     stable dedupe key; derived from kind|route|category|title if absent
#   --suggested-skill <s>  skill:<s> label (super-build|super-qa|super-ux|super-review)
#   --status <col>         project column (default Bug; Flaky / Skip for those streams;
#                          override default via SUPER_QA_TARGET_OPTION_NAME)
#   --dry-run              validate + resolve + print what would happen; file nothing
#
# Body validation (skip with SUPER_QA_ALLOW_WEAK_BODY=1 — never in normal runs):
#   required sections: ## Summary, ## Repro steps, ## Expected behavior,
#                      ## Actual behavior, ## Evidence, ## Acceptance criteria
#   rejected placeholders: TBD, TODO:, <...>
#
# Project resolution (skills/super-qa/SKILL.md §Project resolution):
#   owner: $SUPER_QA_PROJECT_OWNER, else `gh repo view` owner
#   title: $SUPER_QA_PROJECT_TITLE, else "Super Ultimate QA" (case-insensitive)
#
# Dedupe: if an OPEN issue labeled source:qa already carries this fingerprint,
# comment the new evidence on it and print ITS number instead of filing a dupe.
#
# Exit codes (iteration-preamble.md contract):
#   0   issue number printed (created, or dedupe hit)
#   64  bad arguments
#   66  body file missing/unreadable
#   70  body validation failed
#   71  issue created but project add / status set failed (number still printed)
#   77  QA project not found (create it: gh project create --owner "@me"
#       --title "Super Ultimate QA" with Status: Queue/Testing/Done/Bug/Flaky/Skip)

set -euo pipefail

TITLE=""; BODY_FILE=""; KIND="bug"; PRIORITY="medium"; CATEGORY=""
AREA=""; ROUTE=""; SPEC=""; ITERN=""; FINGERPRINT=""; SUGGESTED=""
STATUS_COL="${SUPER_QA_TARGET_OPTION_NAME:-Bug}"; DRY_RUN=0

err() { echo "super-qa-file-bug: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --title)           TITLE="${2:-}"; shift 2 ;;
    --body-file)       BODY_FILE="${2:-}"; shift 2 ;;
    --kind)            KIND="${2:-}"; shift 2 ;;
    --priority)        PRIORITY="${2:-}"; shift 2 ;;
    --category)        CATEGORY="${2:-}"; shift 2 ;;
    --area)            AREA="${2:-}"; shift 2 ;;
    --route)           ROUTE="${2:-}"; shift 2 ;;
    --spec)            SPEC="${2:-}"; shift 2 ;;
    --iter)            ITERN="${2:-}"; shift 2 ;;
    --fingerprint)     FINGERPRINT="${2:-}"; shift 2 ;;
    --suggested-skill) SUGGESTED="${2:-}"; shift 2 ;;
    --status)          STATUS_COL="${2:-}"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    *) err "unknown flag: $1"; exit 64 ;;
  esac
done

[ -n "$TITLE" ] || { err "--title is required"; exit 64; }
[ -n "$BODY_FILE" ] || { err "--body-file is required"; exit 64; }
[ -f "$BODY_FILE" ] || { err "body file not found: $BODY_FILE"; exit 66; }

case "$KIND" in bug|feature|ux|tests|docs|tech-debt) ;; *) err "bad --kind: $KIND"; exit 64 ;; esac
case "$PRIORITY" in high|medium|low) ;; *) err "bad --priority: $PRIORITY"; exit 64 ;; esac

# ── body validation ──────────────────────────────────────────────
if [ "${SUPER_QA_ALLOW_WEAK_BODY:-0}" != "1" ]; then
  MISSING=""
  for section in "## Summary" "## Repro steps" "## Expected behavior" "## Actual behavior" "## Evidence" "## Acceptance criteria"; do
    grep -q "^${section}" "$BODY_FILE" || MISSING="${MISSING}${section}, "
  done
  if [ -n "$MISSING" ]; then
    err "body rejected — missing required sections: ${MISSING%, }"
    exit 70
  fi
  # Placeholder patterns: TBD / TODO: / literal <...> / template stubs like
  # "<one sentence: what is wrong and where>" — an angle-bracketed phrase
  # containing a space (first char not ! or /, so HTML comments and closing
  # tags don't trip it). Rare legit HTML like <a href="..."> in evidence can
  # false-positive; reword it or use the documented escape hatch.
  if grep -nE '(^|[^A-Za-z])TBD([^A-Za-z]|$)|TODO:|<\.\.\.>|<[^!/>][^>]* [^>]*>' "$BODY_FILE" >/dev/null; then
    err "body rejected — contains placeholder text (TBD / TODO: / <...> / an unfilled '<template stub>'). Fill it in or set SUPER_QA_ALLOW_WEAK_BODY=1 (not in normal runs)."
    exit 70
  fi
fi

# ── title normalization: "<emoji> <Type> <route?> — <short>" ─────
case "$KIND" in
  bug)       EMOJI="🐛"; TYPE_WORD="Bug" ;;
  feature)   EMOJI="✨"; TYPE_WORD="Feature" ;;
  ux)        EMOJI="🎨"; TYPE_WORD="UX" ;;
  tests)     EMOJI="🧪"; TYPE_WORD="Tests" ;;
  docs)      EMOJI="📝"; TYPE_WORD="Docs" ;;
  tech-debt) EMOJI="🔧"; TYPE_WORD="Tech-debt" ;;
esac
case "$TITLE" in
  "$EMOJI"*|🐛*|✨*|🎨*|🧪*|📝*|🔧*) FULL_TITLE="$TITLE" ;;
  *) FULL_TITLE="${EMOJI} ${TYPE_WORD}${ROUTE:+ ${ROUTE}} — ${TITLE}" ;;
esac

# ── fingerprint ──────────────────────────────────────────────────
if [ -z "$FINGERPRINT" ]; then
  FINGERPRINT="${KIND}|${ROUTE:-no-route}|${CATEGORY:-no-category}|$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9|-' | cut -c1-60)"
fi

# ── project resolution (BEFORE filing — a missing board halts the loop) ──
OWNER="${SUPER_QA_PROJECT_OWNER:-$(gh repo view --json owner -q .owner.login 2>/dev/null || true)}"
[ -n "$OWNER" ] || { err "cannot resolve project owner (set SUPER_QA_PROJECT_OWNER or run inside a repo with a GitHub remote)"; exit 64; }
WANT_TITLE="${SUPER_QA_PROJECT_TITLE:-Super Ultimate QA}"

PROJECT_JSON=$(gh project list --owner "$OWNER" --format json 2>/dev/null \
  | jq --arg t "$WANT_TITLE" '[.projects[] | select((.title | ascii_downcase) == ($t | ascii_downcase))] | first // empty')
if [ -z "$PROJECT_JSON" ]; then
  err "QA project '${WANT_TITLE}' not found for owner '${OWNER}'."
  err "Create it: gh project create --owner \"@me\" --title \"${WANT_TITLE}\""
  err "with Status options: Queue / Testing / Done / Bug / Flaky / Skip"
  exit 77
fi
PROJECT_NUMBER=$(echo "$PROJECT_JSON" | jq -r '.number')
PROJECT_ID=$(echo "$PROJECT_JSON" | jq -r '.id')

STATUS_FIELD_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json 2>/dev/null \
  | jq '[.fields[] | select(.name == "Status")] | first // empty')
FIELD_ID=$(echo "$STATUS_FIELD_JSON" | jq -r '.id // empty')
OPTION_ID=$(echo "$STATUS_FIELD_JSON" | jq -r --arg o "$STATUS_COL" '.options[]? | select((.name | ascii_downcase) == ($o | ascii_downcase)) | .id' | head -1)
if [ -z "$FIELD_ID" ] || [ -z "$OPTION_ID" ]; then
  err "project #${PROJECT_NUMBER} has no Status option named '${STATUS_COL}' — fix the board columns (Queue/Testing/Done/Bug/Flaky/Skip)"
  exit 77
fi

# ── dedupe against open source:qa issues ─────────────────────────
EXISTING=$(gh issue list --label "source:qa" --state open --json number,body --limit 200 2>/dev/null \
  | jq -r --arg fp "$FINGERPRINT" '[.[] | select(.body | contains("fingerprint: " + $fp))] | first | .number // empty')
if [ -n "$EXISTING" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    err "[dry-run] dedupe hit — would comment on existing issue #${EXISTING}"
  else
    {
      echo "🔁 super-qa re-encountered this finding$( [ -n "$ITERN" ] && echo " (iter ${ITERN})")."
      echo ""
      echo "New evidence:"
      echo ""
      cat "$BODY_FILE"
    } | gh issue comment "$EXISTING" --body-file - >/dev/null 2>&1 \
      || err "warning: dedupe comment on #${EXISTING} failed (still returning its number)"
  fi
  echo "$EXISTING"
  exit 0
fi

# ── labels (create-if-missing, then apply) ───────────────────────
LABELS=("$KIND" "source:qa" "priority:${PRIORITY}")
[ -n "$AREA" ] && LABELS+=("area:${AREA}")
[ -n "$CATEGORY" ] && LABELS+=("qa:${CATEGORY}")
[ -n "$SUGGESTED" ] && LABELS+=("skill:${SUGGESTED}")

# ── compose final body: Board summary up top + hidden meta block ─
FINAL_BODY=$(mktemp)
trap 'rm -f "$FINAL_BODY"' EXIT
{
  if ! grep -q "^## Board summary" "$BODY_FILE"; then
    echo "## Board summary"
    echo ""
    echo "${TYPE_WORD}${ROUTE:+ on \`${ROUTE}\`} · priority **${PRIORITY}**${CATEGORY:+ · ${CATEGORY}}${ITERN:+ · found in iter ${ITERN}}"
    echo ""
  fi
  cat "$BODY_FILE"
  echo ""
  echo "<!-- super-qa-meta"
  echo "route: ${ROUTE:-n/a}"
  echo "spec: ${SPEC:-n/a}"
  echo "iteration: ${ITERN:-n/a}"
  echo "area: ${AREA:-n/a}"
  echo "category: ${CATEGORY:-n/a}"
  echo "priority: ${PRIORITY}"
  echo "type: ${KIND}"
  echo "fingerprint: ${FINGERPRINT}"
  echo "-->"
} > "$FINAL_BODY"

if [ "$DRY_RUN" -eq 1 ]; then
  err "[dry-run] would create issue: ${FULL_TITLE}"
  err "[dry-run]   labels: ${LABELS[*]}"
  err "[dry-run]   project: ${WANT_TITLE} #${PROJECT_NUMBER} (owner ${OWNER}) → Status=${STATUS_COL}"
  err "[dry-run]   fingerprint: ${FINGERPRINT}"
  echo "0"
  exit 0
fi

for label in "${LABELS[@]}"; do
  gh label create "$label" --color "ededed" >/dev/null 2>&1 || true
done

LABEL_FLAGS=()
for label in "${LABELS[@]}"; do LABEL_FLAGS+=(--label "$label"); done
ISSUE_URL=$(gh issue create --title "$FULL_TITLE" --body-file "$FINAL_BODY" "${LABEL_FLAGS[@]}")
ISSUE_N=$(basename "$ISSUE_URL")

# ── add to the QA project + set Status ───────────────────────────
PROMOTE_OK=1
ITEM_ID=$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json 2>/dev/null | jq -r '.id // empty') || true
if [ -n "$ITEM_ID" ]; then
  gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
    --field-id "$FIELD_ID" --single-select-option-id "$OPTION_ID" >/dev/null 2>&1 || PROMOTE_OK=0
else
  PROMOTE_OK=0
fi

echo "$ISSUE_N"
if [ "$PROMOTE_OK" -ne 1 ]; then
  err "issue #${ISSUE_N} created but board promote failed — move it to '${STATUS_COL}' on '${WANT_TITLE}' manually"
  exit 71
fi
exit 0
