#!/usr/bin/env bash
# Installiert claude-code-guardrails fuer den aktuellen Nutzer.
#   Repository-Inhalt  -> $GUARDRAILS_DIR (Standard ~/.claude/guardrails)
#   agents/*.md        -> ~/.claude/agents/
#   commands/*.md      -> ~/.claude/commands/
# Ueberschreibt nichts ohne Sicherung: eine vorhandene, abweichende Datei wird vorher als
# <datei>.backup_<zeitstempel> gesichert. settings.json bleibt unberuehrt; die Hook-Eintraege stehen in
# settings.example.json und werden von Hand uebernommen.
# Aufruf: bash install.sh [--dry-run]
set -euo pipefail

QUELLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
ZIEL="${GUARDRAILS_DIR:-$CLAUDE_DIR/guardrails}"
TROCKEN=0
case "${1:-}" in
  "") ;;
  --dry-run) TROCKEN=1 ;;
  *) echo "Unbekannte Option: $1 (erlaubt: --dry-run)" >&2; exit 1 ;;
esac
STEMPEL=$(date +%Y%m%d_%H%M%S)

for programm in jq python3; do
  command -v "$programm" >/dev/null 2>&1 || { echo "Fehlt: $programm (die Hooks brauchen es)" >&2; exit 1; }
done

kopiere() { # quelle ziel
  local q="$1" z="$2"
  if [ -e "$z" ] && cmp -s "$q" "$z"; then
    echo "unveraendert  $z"
    return
  fi
  if [ "$TROCKEN" = 1 ]; then
    if [ -e "$z" ]; then echo "wuerde sichern und ersetzen  $z"; else echo "wuerde anlegen  $z"; fi
    return
  fi
  mkdir -p "$(dirname "$z")"
  if [ -e "$z" ]; then
    cp -p "$z" "$z.backup_$STEMPEL"
    echo "gesichert     $z.backup_$STEMPEL"
  fi
  cp -p "$q" "$z"
  echo "kopiert       $z"
}

if [ "$(cd "$ZIEL" 2>/dev/null && pwd || true)" != "$QUELLE" ]; then
  while IFS= read -r -d '' datei; do
    kopiere "$datei" "$ZIEL/${datei#"$QUELLE"/}"
  done < <(find "$QUELLE" -type f -not -path "$QUELLE/.git/*" -print0 | sort -z)
else
  echo "Repository liegt bereits in $ZIEL, kein Kopieren noetig."
fi

for datei in "$QUELLE"/agents/*.md; do kopiere "$datei" "$CLAUDE_DIR/agents/$(basename "$datei")"; done
for datei in "$QUELLE"/commands/*.md; do kopiere "$datei" "$CLAUDE_DIR/commands/$(basename "$datei")"; done

cat <<HINWEIS

Naechste Schritte:
  1. Hook-Eintraege aus $ZIEL/settings.example.json in $CLAUDE_DIR/settings.json uebernehmen
     (bestehende "hooks"-Eintraege dort zusammenfuehren, nicht ersetzen).
  2. Geschuetzte Pfade: $ZIEL/config/protected-paths.example nach protected-paths.conf kopieren und anpassen.
     Ohne eigene Datei gelten die Beispielregeln.
  3. Liegt die Installation nicht unter ~/.claude/guardrails, die Pfade in settings.json, in
     $CLAUDE_DIR/commands/diagnose.md und in den Agenten anpassen.
HINWEIS
