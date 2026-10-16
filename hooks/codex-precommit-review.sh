#!/bin/bash
# =============================================================================
# Hook: codex-precommit-review.sh
# Event: PreToolUse (Bash)
# Purpose: Run Codex adversarial review before git commit; block on needs-attention
# Exit 0 = allow, Exit 2 = block
# =============================================================================

CODEX_COMPANION="${CODEX_COMPANION:-$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs}"
REVIEW_TIMEOUT=280  # seconds (hook timeout is 300, leave 20s buffer)

# --- 1. Read stdin JSON ---
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- 2. Early exit if not a git commit command ---
if ! echo "$CMD" | grep -qE '^\s*git\s+((-C\s+\S+\s+)?commit|commit)'; then
    exit 0
fi

# --- 3. Check bypass flags ---
if echo "$CMD" | grep -qiE 'SKIP_CODEX_REVIEW=1'; then
    echo "Codex review skipped (SKIP_CODEX_REVIEW=1)" >&2
    exit 0
fi

if echo "$CMD" | grep -qiE '\[skip-review\]|\[no-review\]'; then
    echo "Codex review skipped ([skip-review] in commit message)" >&2
    exit 0
fi

if echo "$CMD" | grep -qE '\-\-allow-empty'; then
    exit 0
fi

# --- 4. Determine working directory ---
WORK_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$PWD"
fi

# Verify it's a git repo
if ! git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    exit 0
fi

# --- 5. Check if there are staged changes (only staged = what gets committed) ---
STAGED=$(git -C "$WORK_DIR" diff --cached --stat 2>/dev/null)
if [ -z "$STAGED" ]; then
    exit 0  # Nothing staged, nothing to review
fi

# --- 6. Isolate staged changes for review ---
# Stash unstaged changes so working tree only contains what will be committed
STASHED=0
HAS_UNSTAGED=$(git -C "$WORK_DIR" diff --stat 2>/dev/null)
if [ -n "$HAS_UNSTAGED" ]; then
    git -C "$WORK_DIR" stash push --keep-index -q 2>/dev/null && STASHED=1
fi

# Ensure stash is restored on any exit
cleanup_stash() {
    if [ $STASHED -eq 1 ]; then
        git -C "$WORK_DIR" stash pop -q 2>/dev/null
    fi
}
trap cleanup_stash EXIT

# --- 7. Run Codex adversarial review (now working tree = staged only) ---
echo "Running Codex adversarial review on staged changes..." >&2

REVIEW_OUTPUT=$(timeout "$REVIEW_TIMEOUT" node "$CODEX_COMPANION" adversarial-review \
    --cwd "$WORK_DIR" \
    --scope working-tree \
    --wait \
    --json 2>/dev/null)

REVIEW_EXIT=$?

# --- 8. Handle timeout or error ---
if [ $REVIEW_EXIT -eq 124 ]; then
    echo "WARNING: Codex review timed out after ${REVIEW_TIMEOUT}s. Allowing commit." >&2
    exit 0
fi

if [ $REVIEW_EXIT -ne 0 ] || [ -z "$REVIEW_OUTPUT" ]; then
    echo "WARNING: Codex review failed (exit=$REVIEW_EXIT). Allowing commit." >&2
    exit 0
fi

# --- 9. Parse verdict ---
VERDICT=$(echo "$REVIEW_OUTPUT" | jq -r '.result.verdict // "unknown"' 2>/dev/null)

if [ "$VERDICT" = "approve" ]; then
    echo "Codex review: APPROVED" >&2
    exit 0
fi

if [ "$VERDICT" = "needs-attention" ]; then
    SUMMARY=$(echo "$REVIEW_OUTPUT" | jq -r '.result.summary // "No summary"' 2>/dev/null)
    FINDINGS=$(echo "$REVIEW_OUTPUT" | jq -r '
        .result.findings[]? |
        "  [\(.severity | ascii_upcase)] \(.title) (\(.file):\(.line_start))"
    ' 2>/dev/null)

    echo "" >&2
    echo "BLOCKED: Codex adversarial review found issues:" >&2
    echo "" >&2
    echo "  Summary: $SUMMARY" >&2
    echo "" >&2
    if [ -n "$FINDINGS" ]; then
        echo "  Findings:" >&2
        echo "$FINDINGS" >&2
        echo "" >&2
    fi
    echo "  Fix the issues and try again, or use [skip-review] in commit message to bypass." >&2
    exit 2
fi

# Unknown verdict: fail open
echo "WARNING: Codex review returned unknown verdict '$VERDICT'. Allowing commit." >&2
exit 0
