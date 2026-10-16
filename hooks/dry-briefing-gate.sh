#!/usr/bin/env bash
# DRY-Gate: blockt Agent-/SendMessage-Briefings, die neue Anzeigefelder/Labels/Keys einführen,
# ohne eine belegte Bestandsaufnahme (2026-09-04: keine Doppeldaten, vorher prüfen was da ist)
INPUT=$(cat)
TEXT=$(printf '%s' "$INPUT" | jq -r '(.tool_input.prompt // "") + " " + (.tool_input.message // "")' 2>/dev/null)
[ -z "$TEXT" ] && exit 0

# Pruefer-Briefing (2026-09-22): ein Pruefer-Agent bekommt den Pfad der Pruefbericht-Vorlage mit,
# damit sein Bericht die Form der Vorlage hat. Typenliste aus gates/pruefbericht.conf.json.
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PRUEF_CONF="${PRUEFBERICHT_CONF:-$GUARDRAILS_DIR/gates/pruefbericht.conf.json}"
TYP=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
if [ -n "$TYP" ] && [ -f "$PRUEF_CONF" ] && jq -e --arg t "$TYP" '.pruefer_typen | index($t)' "$PRUEF_CONF" >/dev/null 2>&1; then
  if ! printf '%s' "$TEXT" | grep -qF 'templates/pruefbericht.md'; then
    jq -n --arg t "$TYP" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Briefing-Gate pruefer-vorlage-fehlt: Der Pruefer-Agent " + $t + " bekommt den Pfad der Pruefbericht-Vorlage nicht mit. In das Briefing aufnehmen: \"Bericht nach ~/.claude/guardrails/templates/pruefbericht.md: Urteil PASS|FLAG|GAP, Regel-ID, Beleg Pfad:Zeile oder [B-n], ein Satz.\" Dann erneut senden.")}}'
    exit 0
  fi
fi
# Nur Briefings, die etwas Neues anzeigen/anlegen wollen
if printf '%s' "$TEXT" | grep -qiE '(anzeigen|anlegen|rendern|neue[rs]? (feld|zeile|karte|abschnitt|label|sprachkey|link|spalte)|sprachkey|mockup|umsetzen|einführen|hinzufügen|ergänzen)'; then
  # Freigabe nur mit belegter Bestandsaufnahme UND der Pflichtformel
  if printf '%s' "$TEXT" | grep -qi 'Bestandsaufnahme' && printf '%s' "$TEXT" | grep -qiE 'nichts doppelt|keine zweite Quelle|bereits ausgegeben'; then
    exit 0
  fi
  # Read-only-Aufträge (Recherche/Verifier) nicht blocken
  if printf '%s' "$TEXT" | grep -qiE '100 ?% READ-ONLY|READ-ONLY am Code|adversarial|WIDERLEGEN'; then
    exit 0
  fi
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"DRY-Gate: Briefing führt Anzeigefelder/Labels/Keys ein, enthält aber keine belegte \"Bestandsaufnahme\" (Suchergebnis, ob Feld, Label oder Key schon existiert) und nicht die Pflichtformel \"nichts doppelt anzeigen; keine zweite Quelle für denselben Zustand\". Erst den Bestand durchsuchen (z. B. grep in Views, Sprachdateien, Modellen), Ergebnis + Formel ins Briefing, dann erneut senden."}}'
  exit 0
fi
exit 0
