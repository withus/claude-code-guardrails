#!/usr/bin/env bash
# Testfaelle fuer den Rollenhinweis in session-context-loader.sh (seit 2026-09-28).
# HOME zeigt auf ein Temp-Verzeichnis, cwd ist ein Ordner ohne Git, damit nichts Echtes gelesen wird.
# Aufruf: bash hooks/tests/session-context-loader.test.sh [pfad/zum/hook] (im Repository)
set -o pipefail
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOK="${1:-$GUARDRAILS_DIR/hooks/session-context-loader.sh}"
TMP=$(mktemp -d) || { echo "FEHL mktemp"; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fehler=0; nr=0
ok()   { printf '  OK    %2d %-52s %s\n' "$nr" "$1" "$2"; }
fehl() { printf '  FEHL  %2d %-52s %s\n' "$nr" "$1" "$2"; fehler=$((fehler+1)); }
# Kontext nur aus dem Schema, das Claude Code 2.1.283 auswertet: hookSpecificOutput mit hookEventName SessionStart
kontext() { jq -n --arg c "$2" '{cwd:$c}' | HOME="$1" PROJEKTE_WURZEL="$TMP/projekte" bash "$HOOK" 2>/dev/null \
  | jq -r 'if .hookSpecificOutput.hookEventName == "SessionStart" then (.hookSpecificOutput.additionalContext // "") else "FALSCHES-SCHEMA" end'; }
mkdir -p "$TMP/arbeit" "$TMP/projekte/shop" "$TMP/mit/.claude" "$TMP/ohne/.claude"
printf '# Rolle\n' > "$TMP/mit/.claude/ROLLE-umsetzer.md"; printf '# Rolle\n' > "$TMP/mit/.claude/ROLLE-orchestrator.md"
echo "Rollenhinweis, Testlauf gegen $HOOK"
nr=$((nr+1)); ist=$(kontext "$TMP/mit" "$TMP/arbeit")
case "$ist" in "Rolle zuerst lesen: ~/.claude/ROLLE-umsetzer.md ~/.claude/ROLLE-orchestrator.md"*) ok "ausserhalb-der-projekte-beide-rollen-vorne" "ja";; *) fehl "ausserhalb-der-projekte-beide-rollen-vorne" "ist=${ist:0:80}";; esac
nr=$((nr+1)); ist=$(kontext "$TMP/mit" "$TMP/projekte/shop")
case "$ist" in "Rolle zuerst lesen: ~/.claude/ROLLE-orchestrator.md"*) ok "im-projektordner-nur-orchestrator" "ja";; *) fehl "im-projektordner-nur-orchestrator" "ist=${ist:0:80}";; esac
nr=$((nr+1)); ist=$(kontext "$TMP/ohne" "$TMP/arbeit")
case "$ist" in *"Rolle zuerst lesen"*) fehl "ohne-rollendateien-kein-hinweis" "Hinweis trotzdem da";; FALSCHES-SCHEMA) fehl "ohne-rollendateien-kein-hinweis" "falsches Schema";; *) ok "ohne-rollendateien-kein-hinweis" "kein Hinweis";; esac
mkdir -p "$TMP/mit/.claude/hooks"; printf '{"timestamp":"2026-09-28T00:00:00","project":"fremd","cwd":"/x"}' > "$TMP/mit/.claude/hooks/last-checkpoint.json"
nr=$((nr+1)); ist=$(kontext "$TMP/mit" "$TMP/arbeit")
case "$ist" in *"Last session checkpoint"*) fehl "standard-nur-rollenhinweis-ohne-checkpoint" "Checkpoint im Kontext";; "Rolle zuerst lesen"*) ok "standard-nur-rollenhinweis-ohne-checkpoint" "nur Rolle";; *) fehl "standard-nur-rollenhinweis-ohne-checkpoint" "ist=${ist:0:60}";; esac
nr=$((nr+1)); ist=$(STARTKONTEXT_VOLL=1 kontext "$TMP/mit" "$TMP/arbeit")
case "$ist" in "Rolle zuerst lesen"*"Last session checkpoint"*) ok "voller-kontext-mit-schalter" "Rolle und Checkpoint";; *) fehl "voller-kontext-mit-schalter" "ist=${ist:0:60}";; esac
echo
if [ "$fehler" -eq 0 ]; then echo "Alle $nr Faelle bestanden."; exit 0; else echo "$fehler von $nr Faellen fehlgeschlagen."; exit 1; fi
