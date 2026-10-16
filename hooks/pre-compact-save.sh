#!/bin/bash
# Hook: pre-compact-save.sh
# Event: PreCompact
# Purpose: Save session state before context compaction
# Writes checkpoint to ~/.claude/hooks/last-checkpoint.json

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

# Determine current git branch (if in a git repo)
GIT_BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ] || git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
fi

# Determine project name from CWD (Name des Git-Wurzelordners, sonst leer)
PROJECT=""
if [ -n "$CWD" ]; then
    PROJECT=$(basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
fi

# Get last 3 commits for context
RECENT_COMMITS=""
if [ -n "$CWD" ]; then
    RECENT_COMMITS=$(git -C "$CWD" log --oneline -3 2>/dev/null | tr '\n' ' ')
fi

# Write checkpoint file using jq for safe JSON generation
CHECKPOINT_FILE="$HOME/.claude/hooks/last-checkpoint.json"
mkdir -p "$(dirname "$CHECKPOINT_FILE")" 2>/dev/null
jq -n \
    --arg ts "$TIMESTAMP" \
    --arg sid "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg proj "$PROJECT" \
    --arg branch "$GIT_BRANCH" \
    --arg commits "$RECENT_COMMITS" \
    '{timestamp: $ts, session_id: $sid, cwd: $cwd, project: $proj, git_branch: $branch, recent_commits: $commits, event: "pre-compact"}' \
    > "$CHECKPOINT_FILE"

# Inject context so Claude remembers after compaction (jq for safe escaping)
jq -n \
    --arg msg "SESSION CHECKPOINT (pre-compact): Project=$PROJECT, Branch=$GIT_BRANCH, CWD=$CWD. Recent commits: $RECENT_COMMITS" \
    '{"additionalContext": $msg}'
exit 0
