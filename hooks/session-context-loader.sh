#!/bin/bash
# Hook: session-context-loader.sh
# Event: SessionStart (startup)
# Purpose: Inject project context at session start
# Outputs additionalContext with current branch, last checkpoint, and project info

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# If no CWD, use home
if [ -z "$CWD" ]; then
    CWD="$HOME"
fi

CONTEXT=""

# === 0. Rollendateien (seit 2026-09-28): jede Session liest ihre Rolle zuerst ===
# Unter dem Projektordner ist die Session Orchestrator, sonst kann sie beides sein und waehlt selbst.
PROJEKTE_WURZEL="${PROJEKTE_WURZEL:-$HOME/projekte}"
case "$CWD/" in
    "$PROJEKTE_WURZEL"/*) ROLLEN="orchestrator" ;;
    *) ROLLEN="umsetzer orchestrator" ;;
esac
ROLLEN_HINWEIS=""
for ROLLE in $ROLLEN; do
    [ -f "$HOME/.claude/ROLLE-$ROLLE.md" ] && ROLLEN_HINWEIS="${ROLLEN_HINWEIS} ~/.claude/ROLLE-$ROLLE.md"
done
if [ -n "$ROLLEN_HINWEIS" ]; then
    CONTEXT="Rolle zuerst lesen:${ROLLEN_HINWEIS} (Umsetzer = Arbeit am Agenten-Setup selbst, etwa in ~/.claude; Orchestrator = Projektarbeit mit Unteragenten). "
fi

# 2026-09-28: vorerst nur der Rollenhinweis. Checkpoint und Projektkontext kamen wegen des falschen
# Ausgabeschemas nie an; zugeschaltet werden sie mit STARTKONTEXT_VOLL=1.
if [ "${STARTKONTEXT_VOLL:-0}" != "1" ]; then
    [ -n "$CONTEXT" ] && jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
    exit 0
fi

# === 1. Check for last checkpoint (from pre-compact or previous session) ===
CHECKPOINT_FILE="$HOME/.claude/hooks/last-checkpoint.json"
if [ -f "$CHECKPOINT_FILE" ]; then
    CHECKPOINT_TIME=$(jq -r '.timestamp // empty' "$CHECKPOINT_FILE" 2>/dev/null)
    CHECKPOINT_PROJECT=$(jq -r '.project // empty' "$CHECKPOINT_FILE" 2>/dev/null)
    CHECKPOINT_BRANCH=$(jq -r '.git_branch // empty' "$CHECKPOINT_FILE" 2>/dev/null)
    CHECKPOINT_CWD=$(jq -r '.cwd // empty' "$CHECKPOINT_FILE" 2>/dev/null)

    if [ -n "$CHECKPOINT_TIME" ]; then
        CONTEXT="${CONTEXT}Last session checkpoint ($CHECKPOINT_TIME): Project=$CHECKPOINT_PROJECT, Branch=$CHECKPOINT_BRANCH, CWD=$CHECKPOINT_CWD. "
    fi
fi

# === 3. current-task.md des Projekts, falls vorhanden ===
PROJECT_DIR=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$PROJECT_DIR" ]; then
    TASK_FILE="$PROJECT_DIR/.claude/context/current-task.md"
    if [ -f "$TASK_FILE" ]; then
        TASK_SUMMARY=$(head -5 "$TASK_FILE" 2>/dev/null | tr '\n' ' ')
        CONTEXT="${CONTEXT}Current task: $TASK_SUMMARY "
    fi
fi

# === 5. Warn if local branch is behind its remote ===
# If cwd is a git repo with a remote, fetch (best-effort, offline-safe) and
# check how far HEAD is behind origin/<branch>.
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null)
    CUR_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
    if [ -n "$REMOTE_URL" ] && [ -n "$CUR_BRANCH" ]; then
        # Fetch quietly, never let offline/errors break the session
        timeout 8 git -C "$CWD" fetch origin --quiet >/dev/null 2>&1 || true
        COUNTS=$(git -C "$CWD" rev-list --left-right --count "HEAD...origin/$CUR_BRANCH" 2>/dev/null)
        if [ -n "$COUNTS" ]; then
            BEHIND=$(echo "$COUNTS" | awk '{print $2}')
            if [ -n "$BEHIND" ] && [ "$BEHIND" -gt 0 ] 2>/dev/null; then
                CONTEXT="${CONTEXT}Achtung: Lokaler Stand ist $BEHIND Commits HINTER origin/$CUR_BRANCH, Basis prüfen vor Änderungen! "
            fi
        fi
    fi
fi

# === Output context if we have any ===
if [ -n "$CONTEXT" ]; then
    # Schema von Claude Code 2.1.283: oberstes additionalContext wird verworfen (gemessen 2026-09-28, Verlauf zeigte
    # hook_success mit leerem content), nur hookSpecificOutput mit hookEventName kommt in der Session an.
    jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
