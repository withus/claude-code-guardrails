#!/usr/bin/env bash
# Startet eine Diagnose: legt den Marker an, den diagnose-schema-gate.sh auswertet.
# Aufgerufen von /diagnose, damit das Setzen deterministisch ist und nicht vom Modell abhaengt.
#
# Der Marker traegt von Anfang an Besitzer (session) und Lebensdauer (gueltig_bis).
# Ohne Sitzungskennung wird abgebrochen, statt einen herrenlosen Marker zu schreiben.

set -u

SESSION="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SESSION" ]; then
  echo "FEHLER: CLAUDE_CODE_SESSION_ID ist nicht gesetzt. Kein Marker angelegt."
  echo "Ein Marker ohne Besitzer wuerde fremde Sitzungen blockieren."
  exit 1
fi
# Allowlist: die ID landet im Marker und wird vom Hook verglichen. Ein Zeilenumbruch
# koennte ein zweites Feld wie gueltig_bis einschleusen, deshalb nur sichere Zeichen.
# Bash-Regex prueft den GANZEN String, grep wuerde zeilenweise pruefen.
if ! [[ "$SESSION" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "FEHLER: CLAUDE_CODE_SESSION_ID enthaelt unzulaessige Zeichen. Kein Marker angelegt."
  exit 1
fi

# Im Projekt ablegen, wenn eines erkennbar ist, sonst global.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ZIEL="$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
else
  ZIEL="$HOME/.claude/state/diagnose-active"
fi
mkdir -p "$(dirname "$ZIEL")"

# Ein gueltiger Marker einer ANDEREN Sitzung wird nie ueberschrieben: sonst verliert eine laufende
# Diagnose ihr Gate (Codex-Gegenpruefung 2026-09-22). Abgelaufene oder eigene Marker duerfen ersetzt werden.
if [ -f "$ZIEL" ]; then
  ALT_SESSION=$(grep -oE '^session=.*' "$ZIEL" | head -1 | cut -d= -f2-)
  ALT_BIS=$(grep -oE '^gueltig_bis=.*' "$ZIEL" | head -1 | cut -d= -f2-)
  if [ -n "$ALT_SESSION" ] && [ "$ALT_SESSION" != "$SESSION" ] && [ -n "$ALT_BIS" ] && ! [ "$(date +%Y-%m-%d)" \> "$ALT_BIS" ]; then
    echo "FEHLER: Unter $ZIEL laeuft bereits eine Diagnose der Sitzung ${ALT_SESSION:0:8}... (gueltig bis $ALT_BIS). Kein Marker angelegt."
    exit 2
  fi
fi

BIS=$(date -d '+1 day' +%Y-%m-%d)
# Schemakennung: ein laufender Vorgang behaelt die Regeln, mit denen er gestartet wurde.
# Der Hook wendet die Regeln des Schemas an, das im Marker steht. Neue Marker bekommen das aktuelle.
# Schema 3 seit 2026-09-25: Bericht als Datei unter .claude/diagnosen/, Kurzfassung im Chat.
SCHEMA=3
# Startzeit: das Gate nimmt nur Berichtsdateien an, die danach geaendert wurden.
printf 'session=%s\ngueltig_bis=%s\nschema=%s\ngestartet=%s\n' "$SESSION" "$BIS" "$SCHEMA" "$(date +%s)" > "$ZIEL"

echo "Diagnose-Modus aktiv."
echo "Marker:      $ZIEL"
echo "Sitzung:     ${SESSION:0:8}..."
echo "Gueltig bis: $BIS (verlaengert sich bei jeder durchgelassenen Phase)"
echo "Schema:      $SCHEMA"
echo "Endet:       mit einer Phase C, in der 'Entscheidung des Auftraggebers' ausgefuellt ist."
echo
echo "Vorlage:     ~/.claude/guardrails/templates/diagnose.md"
