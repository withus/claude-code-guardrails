#!/usr/bin/env bash
# Testfaelle fuer diagnose-schema-gate.sh und diagnose-start.sh
# Grundsatz: eine Pruefung traegt ihre Beispiele bei sich,
# und jeder Testfall nennt die erwartete MELDUNG, nicht nur "blockt ja oder nein".
# Grund: Ein Fall lieferte am 2026-09-22 einen Fehlalarm, weil der Test nur Muster der
# Form R<n> kannte. Der Hook hatte korrekt geblockt, der Test es falsch gelesen.
#
# Aufruf: bash hooks/tests/diagnose-schema-gate.test.sh (im Repository)
# Erwartung: alle Faelle OK, Exit 0.

GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOK="$GUARDRAILS_DIR/hooks/diagnose-schema-gate.sh"
START="$GUARDRAILS_DIR/scripts/diagnose-start.sh"
TMP=$(mktemp -d) || { echo "mktemp fehlgeschlagen" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "Temp-Verzeichnis fehlt" >&2; exit 1; }
# Der Test arbeitet ausschliesslich mit einem eigenen Marker. Der echte Marker einer
# laufenden Diagnose wird nie geschrieben, nur vorher und nachher verglichen.
# Am 2026-09-22 lief der Test parallel zu einer echten Diagnose und ueberschrieb
# deren Marker waehrend des Laufs. Das ist hier ausgeschlossen.
ECHTER_MARKER="$HOME/.claude/state/diagnose-active"
export DIAGNOSE_MARKER_GLOBAL="$TMP/diagnose-active"
MARKER="$DIAGNOSE_MARKER_GLOBAL"
ECHT_VORHER=$(cat "$ECHTER_MARKER" 2>/dev/null || printf 'FEHLT')

# Der Test darf weder den echten Marker noch das echte Projekt beruehren.
# Der Marker wird mit INHALT gesichert und wiederhergestellt, nicht nur seine Existenz:
# ein leer zurueckgeschriebener Marker waere ohne Besitzer und Ablauf verwaist.
aufraeumen() { rm -rf "$TMP"; }
trap aufraeumen EXIT

# TASKLOG und Projekt-Marker landen im Testverzeichnis, nie im echten Projekt.
export CLAUDE_PROJECT_DIR="$TMP/projekt"
export AGENTS_STATE_DIR="$TMP/state"
export DIAGNOSE_GATE_LOG="$TMP/diagnose-gate.log"

# Isolation vollstaendig belegen: alle fuenf Schreibziele des Hooks und des Startskripts,
# jeweils am ECHTEN Pfad, vorher gehasht und nachher verglichen. Ein Ziel, das nicht
# umgelenkt ist, faellt hier auf, egal wie viele andere Tests gruen sind.
echte_ziele() {
  for f in $(printf '%s\n' "$HOME/.claude/state/diagnose-active" "$HOME/.claude/hooks/diagnose-gate.log" \
           "$HOME/.claude/state" "$PWD/TASKLOG.md" "$HOME/TASKLOG.md" "$PWD/.claude/TASKLOG.md" "$HOME/.claude/TASKLOG.md" | sort -u); do
    # Zustandsordner: andere laufende Sessions schreiben dort staendig (seit 2026-09-22).
    # Gehasht werden nur Dateien OHNE Session-UUID, also genau die, die ein Test anlegen koennte.
    # Im Zustandsordner schreiben andere Sitzungen laufend (Logs, Zaehler). Verglichen werden nur Dateien,
    # die dieser Test bei versagender Umlenkung anlegen wuerde: Namen mit den Test-Kennungen.
    if [ -d "$f" ]; then printf '%s %s\n' "$f" "$(find "$f" -type f 2>/dev/null | grep -E 'test-sitzung|ausbruch|fremd|start-test|harmlos' | sort | xargs -r sha256sum | sort | sha256sum | cut -c1-16)"
    elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(sha256sum < "$f" | cut -c1-16)"
    else printf '%s FEHLT\n' "$f"; fi
  done
}
ZIELE_VORHER=$(echte_ziele)
mkdir -p "$CLAUDE_PROJECT_DIR" "$AGENTS_STATE_DIR"

fehler=0; nr=0



transcript() {
  printf '%s' "$1" > "$TMP/text"
  python3 -c "
import json
text=open('$TMP/text',encoding='utf-8').read()
with open('$TMP/tr.jsonl','w',encoding='utf-8') as f:
    f.write(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':text}]}})+'\n')
"
}

# Zwei Ebenen (seit 2026-09-25): der Bericht liegt als Datei unter
# .claude/diagnosen/, im Chat steht nur die Kurzfassung mit Pfad. kurzfassung() baut eine gueltige
# Kurzfassung zu einer Berichtsdatei; Belegt nennt [B-1], wenn die Datei diesen Beleg traegt.
BERICHT_REL=".claude/diagnosen/test-bericht.md"
BERICHT="$CLAUDE_PROJECT_DIR/$BERICHT_REL"
kurzfassung() {
  local belegt='keine'
  grep -qE '^(#+[[:space:]]*)?\[B-1\]' "$BERICHT" 2>/dev/null && belegt='Die API liefert die Version 3 [B-1]'
  printf 'Stand: Bericht liegt vor.\nBelegt: %s\nOffen: nichts\nVorschlag: weiter nach Vorlage\nVon dir: Freigabe\nBericht: %s\n' "$belegt" "${1:-$BERICHT_REL}"
}
# Legt den Bericht als Datei ab und liefert die Chat-Antwort dazu. Eine Rueckfrage bleibt reiner Chat-Text.
antwort_zu() {
  mkdir -p "$(dirname "$BERICHT")"
  # Ein Marker mit schema=2 gehoert zu einem vor dem Umbau gestarteten Vorgang: dort bleibt der Bericht im Chat.
  if grep -q '^schema=2$' "$MARKER" 2>/dev/null || printf '%s' "$1" | grep -vE '^[[:space:]]*$' | head -1 | grep -qiE '^(Rückfrage|Rueckfrage):'; then
    rm -f "$BERICHT"; printf '%s' "$1"
  else
    printf '%s\n' "$1" > "$BERICHT"; kurzfassung
  fi
}
# Ruft den Hook mit einer fertigen Chat-Antwort und liefert DURCH oder die Kennung der Meldung.
lauf_chat() {
  # Das Transcript bekommt bewusst einen anderen, neutralen Text. So laufen diese Tests
  # nachweislich ueber last_assistant_message: faellt der Hauptweg aus, findet der Hook
  # im Transcript keinen Bericht und die Tests werden rot (Mutationsprobe 2026-09-22).
  transcript 'Neutraler Platzhalter, kein Diagnosebericht.'
  local sid="${2:-test-sitzung}" aktiv="${3:-false}" out
  # Hauptweg wie in Claude Code: die Antwort steht in last_assistant_message.
  out=$(jq -n --arg tp "$TMP/tr.jsonl" --arg sid "$sid" --argjson a "$aktiv" --arg m "$1" \
        '{transcript_path:$tp, session_id:$sid, stop_hook_active:$a, last_assistant_message:$m}' \
        | bash "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then printf 'DURCH'
  elif printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1; then printf 'AUFGEGEBEN'
  else printf '%s' "$out" | jq -r '.reason' 2>/dev/null \
       | grep -oE '(ursache-in-phase-a|schlussfrage-fehlt|gemessen-ohne-beleg|reproduktion-fehlt|bezeichner-fehlt|filter-fehlt|unabhaengige-pruefung-fehlt|gegenprobe-nein|naechste-phase-fehlt|kein-diagnosebericht|mehrdeutige-phase|diagnosedatei-fehlt|kurzfassung-unvollstaendig|beleg-nicht-in-datei|kurzfassung-mit-rohdaten)' | head -1
  fi
}
# Bisherige Faelle: der Text ist der Bericht, er landet in der Datei, der Chat traegt die Kurzfassung.
lauf() { lauf_chat "$(antwort_zu "$1")" "${2:-test-sitzung}" "${3:-false}"; }

ok()   { printf '  OK    %2d %-44s %s\n' "$nr" "$1" "$2"; }
fehl() { printf '  FEHL  %2d %-44s %s\n' "$nr" "$1" "$2"; fehler=$((fehler+1)); }

pruefe() {
  nr=$((nr+1))
  local name="$1" erwartet="$2" text="$3" sid="${4:-test-sitzung}"
  local ist; ist=$(lauf "$text" "$sid")
  if [ "$ist" = "$erwartet" ]; then ok "$name" "$ist"; else fehl "$name" "erwartet=$erwartet ist=$ist"; fi
}

frischer_marker() { printf 'session=test-sitzung\ngueltig_bis=%s\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$MARKER"; }

BELEGE='## Belege
[B-1] Befehl: `curl -s URL`
      Ausgabe: "version": 3
'

C_KOPF="Phase: C
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort des Auftraggebers: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Ergebnis: reproduziert JA
"
C_REST="## Geschlossen
Hypothese: Der Cache ignoriert die Abfrageparameter.
Filter: alle Anfragen mit Abfrageparametern

## Gegenprobe
1. Liegt AB-0001 im Filter? Ergebnis: JA [B-1]
2. Ein Fall ohne Parameter zeigt den Fehler nicht [B-1]

## Unabhängige Prüfung
Urteil: JA"

echo "Diagnose-Schema-Gate, Testlauf"
echo
echo "A) Grundverhalten"

rm -f "$MARKER"
pruefe "ohne-marker-geht-alles-durch" "DURCH" 'Phase: A
beliebiger Text'

frischer_marker
pruefe "antwort-ohne-phase-zeile" "kein-diagnosebericht" 'Die Ursache ist der Cache.'

echo
echo "B) Die acht Regeln"

frischer_marker
pruefe "phase-a-mit-ursache" "ursache-in-phase-a" 'Phase: A
Bezeichner: AB-0001

## Geschlossen
Hypothese: Cache'

frischer_marker
pruefe "phase-a-ohne-schlussfrage" "schlussfrage-fehlt" 'Phase: A
Bezeichner: AB-0001

## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

Das war die Karte.'

frischer_marker
pruefe "gemessen-ohne-belegverweis" "gemessen-ohne-beleg" "$C_KOPF
## Gemessen
- Die Logik liegt nicht in der Steuerungsschicht

$C_REST"

frischer_marker
pruefe "verweis-ohne-beleg" "gemessen-ohne-beleg" "$C_KOPF
## Gemessen
- Aussage [B-9]

$C_REST"

frischer_marker
pruefe "phase-c-ohne-reproduktion" "reproduktion-fehlt" "Phase: C
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Gemessen
- Aussage [B-1]

$C_REST"

frischer_marker
pruefe "phase-b-ohne-kartenfreigabe" "reproduktion-fehlt" "Phase: B
Bezeichner: AB-0001

$BELEGE
Eingabe: AB-0001
Ergebnis: reproduziert JA"

frischer_marker
pruefe "phase-c-nach-reproduziert-nein" "reproduktion-fehlt" "Phase: C
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Ergebnis: reproduziert NEIN

## Gemessen
- Aussage [B-1]

$C_REST"

frischer_marker
pruefe "bezeichner-fehlt-in-gegenprobe-1" "bezeichner-fehlt" "$C_KOPF
## Gemessen
- 493 Eintraege ohne Gruppenkennung [B-1]

## Geschlossen
Filter: alle Eintraege ohne Gruppenkennung
## Gegenprobe
1. Ein Eintrag ohne Gruppe zeigt den Fehler
## Unabhängige Prüfung
Urteil: JA"

frischer_marker
pruefe "bezeichner-fehlt-ohne-anforderung" "bezeichner-fehlt" 'Phase: A
Bezeichner: FEHLT

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?'

frischer_marker
pruefe "bezeichner-fehlt-mit-anforderung-a" "DURCH" 'Phase: A
Bezeichner: FEHLT
Anforderung an den Auftraggeber: Bitte eine betroffene Eintrags-ID nennen.

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?'

frischer_marker
pruefe "bezeichner-fehlt-unter-eingabe-b" "bezeichner-fehlt" "Phase: B
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: eine andere ID 999
Ergebnis: reproduziert JA

## Nächste Phase
Gemessen wird: Ursache am reproduzierten Fall
Nicht angefasst: Live, Datenbank
Umfang: drei Befehle"

frischer_marker
pruefe "geschlossen-ohne-filter" "filter-fehlt" "$C_KOPF
## Gemessen
- Aussage [B-1]
## Geschlossen
Hypothese: irgendwas
## Gegenprobe
1. AB-0001 Ergebnis: JA [B-1]
## Unabhängige Prüfung
Urteil: JA"

frischer_marker
pruefe "phase-c-ohne-unabhaengige-pruefung" "unabhaengige-pruefung-fehlt" "$C_KOPF
## Gemessen
- Aussage [B-1]
## Geschlossen
Filter: alle
## Gegenprobe
1. AB-0001 Ergebnis: JA [B-1]"

# Der schwerste beobachtete Fehlschluss: Bezeichner steht in der Gegenprobe,
# aber das Ergebnis ist NEIN. R5 ist erfuellt, R8 muss greifen.
frischer_marker
pruefe "gegenprobe-1-ergibt-nein" "gegenprobe-nein" "$C_KOPF
## Gemessen
- 493 Eintraege ohne Gruppenkennung [B-1]

## Geschlossen
Filter: alle Eintraege ohne Gruppenkennung
## Gegenprobe
1. Liegt AB-0001 im Filter? Ergebnis: NEIN, es hat eine Gruppenkennung [B-1]
## Unabhängige Prüfung
Urteil: NEIN"

echo
echo "C) Korrekte Berichte muessen durchgehen"

frischer_marker
pruefe "korrekte-phase-a" "DURCH" "# Diagnose: Veraltete Version
Phase: A
Bezeichner: AB-0001

$BELEGE
## Suchraum
Verzeichnisse: application/
Ausgeschlossen: .worktrees/ (Arbeitskopien)

## Karte
| 1 | api/Status.php | 194 | setzt Pfad | /api/status | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"

frischer_marker
pruefe "korrekte-phase-b" "DURCH" "# Diagnose: Veraltete Version
Phase: B
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort des Auftraggebers: \"passt so\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Pfad aus der Karte: Nr 1
Befehl: \`curl -s URL\`
Soll: 4   Ist: 3
Ergebnis: reproduziert JA

## Nächste Phase
Gemessen wird: Ursache am reproduzierten Fall
Nicht angefasst: Live, Datenbank
Umfang: drei Befehle"

frischer_marker
pruefe "korrekte-phase-c" "DURCH" "# Diagnose: Veraltete Version
$C_KOPF
## Gemessen
- Mit Abfrageparametern liefert die API die Version 3 [B-1]

$C_REST"

frischer_marker
pruefe "fremde-liste-nach-naechstem-heading" "DURCH" "$C_KOPF
## Gemessen
- belegte Aussage [B-1]

## Geschlossen
Filter: alle X
## Gegenprobe
1. AB-0001 Ergebnis: JA [B-1]
## Vermutet
- bewusst ohne Beleg, darf R3 nicht ausloesen
## Unabhängige Prüfung
Urteil: JA
## Optionen
- auch ohne Beleg"

echo
echo "D) Abweichende Formen"

frischer_marker
pruefe "phase-klein-geschrieben" "DURCH" "phase: a
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"

frischer_marker
pruefe "zwei-phase-zeilen" "mehrdeutige-phase" 'Phase: A
Phase: C
Bezeichner: AB-0001

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?'

frischer_marker
pruefe "b-01-ohne-passenden-beleg" "gemessen-ohne-beleg" "$C_KOPF
## Gemessen
- Aussage [B-01]

$C_REST"

frischer_marker
pruefe "b-01-mit-passendem-beleg" "DURCH" "Phase: C
Bezeichner: AB-0001

## Belege
[B-01] Befehl: \`x\`
      Ausgabe: y

## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Ergebnis: reproduziert JA

## Gemessen
- Aussage [B-01]

## Geschlossen
Filter: alle
## Gegenprobe
1. AB-0001 Ergebnis: JA [B-01]
## Unabhängige Prüfung
Urteil: JA"

frischer_marker
pruefe "geschlossen-mit-doppelpunkt-in-phase-a" "ursache-in-phase-a" 'Phase: A
Bezeichner: AB-0001

## Geschlossen:
Hypothese: irgendwas'

echo
echo "E) Offenes Ausfallen (kein Sicherheitsgate)"

frischer_marker
nr=$((nr+1))
out=$(printf 'das ist kein json' | bash "$HOOK" 2>/dev/null); rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "ungueltige-eingabe" "DURCH"
else fehl "ungueltige-eingabe" "rc=$rc out=${out:0:40}"; fi

frischer_marker
nr=$((nr+1))
out=$(printf '{"transcript_path":"/gibt/es/nicht.jsonl","session_id":"test-sitzung"}' | bash "$HOOK" 2>/dev/null); rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ok "transcript-fehlt" "DURCH"
else fehl "transcript-fehlt" "rc=$rc out=${out:0:40}"; fi

echo
echo "F) Marker: Besitzer und Lebensdauer"

printf 'session=fremde-sitzung\ngueltig_bis=%s\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$MARKER"
pruefe "marker-fremder-sitzung-wird-ignoriert" "DURCH" 'Phase: A
kein gueltiger Bericht' "aktuelle-sitzung"

printf 'session=test-sitzung\ngueltig_bis=2020-01-01\n' > "$MARKER"
pruefe "abgelaufener-marker-wird-ignoriert" "DURCH" 'Phase: A
kein gueltiger Bericht'

printf 'session=test-sitzung\n' > "$MARKER"
touch -d '2 days ago' "$MARKER"
pruefe "marker-ohne-ablauf-aelter-als-24-h" "DURCH" 'Phase: A
kein gueltiger Bericht'

printf 'session=test-sitzung\n' > "$MARKER"
pruefe "marker-ohne-ablauf-frisch-gilt-noch" "kein-diagnosebericht" 'Die Ursache ist der Cache.'

echo
echo "G) Marker-Pflege durch den Hook"

printf 'session=test-sitzung\ngueltig_bis=%s\n' "$(date +%Y-%m-%d)" > "$MARKER"
lauf "Phase: A
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?" >/dev/null
nr=$((nr+1))
if grep -q "gueltig_bis=$(date -d '+1 day' +%Y-%m-%d)" "$MARKER" 2>/dev/null && grep -q '^session=test-sitzung' "$MARKER"; then
  ok "durchgelassene-phase-verlaengert-marker" "verlaengert, Besitzer erhalten"
else fehl "durchgelassene-phase-verlaengert-marker" "$(tr '\n' ' ' < "$MARKER" 2>/dev/null)"; fi

frischer_marker
lauf "$C_KOPF
## Gemessen
- Aussage [B-1]

$C_REST

## Entscheidung des Auftraggebers
Option 1, umsetzen." >/dev/null
nr=$((nr+1))
if [ ! -f "$MARKER" ]; then ok "phase-c-mit-entscheidung-entfernt-marker" "entfernt"
else fehl "phase-c-mit-entscheidung-entfernt-marker" "Marker noch da"; fi

frischer_marker
lauf "$C_KOPF
## Gemessen
- Aussage [B-1]

$C_REST

## Entscheidung des Auftraggebers
<leer, bis entschieden>" >/dev/null
nr=$((nr+1))
if [ -f "$MARKER" ]; then ok "phase-c-ohne-entscheidung-laesst-marker" "bleibt"
else fehl "phase-c-ohne-entscheidung-laesst-marker" "Marker faelschlich entfernt"; fi

echo
echo "H) Uebergehung"

frischer_marker
rm -f "$CLAUDE_PROJECT_DIR/.claude/TASKLOG.md"
pruefe "uebergehung-in-alter-form-laesst-durch" "DURCH" "$C_KOPF
Übergehung: R3, Aussage ist ein woertliches Zitat des Auftraggebers
## Gemessen
- Der Auftraggeber sagt, es gibt einen Controller

$C_REST"
nr=$((nr+1))
if grep -q '| Übergehung | gemessen-ohne-beleg | Aussage ist ein woertliches Zitat' "$CLAUDE_PROJECT_DIR/.claude/TASKLOG.md" 2>/dev/null; then
  ok "uebergehung-steht-im-tasklog-mit-regelnamen" "Eintrag vorhanden"
else fehl "uebergehung-steht-im-tasklog-mit-regelnamen" "kein Eintrag: $(tail -1 "$CLAUDE_PROJECT_DIR/.claude/TASKLOG.md" 2>/dev/null)"; fi

frischer_marker
pruefe "uebergehung-mit-regelnamen-in-anderer-schreibweise" "DURCH" "$C_KOPF
Übergehung: Gemessen-Ohne-Beleg, Aussage ist ein woertliches Zitat
## Gemessen
- Der Auftraggeber sagt, es gibt einen Controller

$C_REST"
frischer_marker
pruefe "uebergehung-mit-regelnamen-laesst-durch" "DURCH" "$C_KOPF
Übergehung: gemessen-ohne-beleg, Aussage ist ein woertliches Zitat
## Gemessen
- Der Auftraggeber sagt, es gibt einen Controller

$C_REST"

frischer_marker
pruefe "uebergehung-schuetzt-nicht-vor-anderer-regel" "bezeichner-fehlt" "$C_KOPF
Übergehung: R3, Zitat
## Gemessen
- ohne Beleg

## Geschlossen
Filter: alle
## Gegenprobe
1. ohne Bezeichner
## Unabhängige Prüfung
Urteil: JA"

echo
echo "I) Startskript /diagnose"

rm -f "$MARKER" "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
nr=$((nr+1))
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$START" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" ]; then
  ok "ohne-sitzungskennung-kein-marker" "abgebrochen"
else fehl "ohne-sitzungskennung-kein-marker" "rc=$rc"; fi

nr=$((nr+1))
CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1
PM="$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
if grep -q '^session=start-test' "$PM" 2>/dev/null && grep -qE '^gueltig_bis=[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$PM"; then
  ok "mit-sitzungskennung-beide-felder-gesetzt" "session und gueltig_bis"
else fehl "mit-sitzungskennung-beide-felder-gesetzt" "$(tr '\n' ' ' < "$PM" 2>/dev/null)"; fi
rm -f "$PM"

PM="$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
printf 'session=fremd\ngueltig_bis=%s\nschema=2\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$PM"
nr=$((nr+1)); CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && grep -q '^session=fremd' "$PM" && ok "startskript-ueberschreibt-keinen-gueltigen-fremden-marker" "rc=2, Marker bleibt" || fehl "startskript-ueberschreibt-keinen-gueltigen-fremden-marker" "rc=$rc $(tr '\n' ' ' < "$PM")"
printf 'session=fremd\ngueltig_bis=2020-01-01\n' > "$PM"
nr=$((nr+1)); CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q '^session=start-test' "$PM" && ok "startskript-ersetzt-abgelaufenen-fremden-marker" "ersetzt" || fehl "startskript-ersetzt-abgelaufenen-fremden-marker" "rc=$rc"
nr=$((nr+1)); CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "startskript-ersetzt-eigenen-marker" "rc=0" || fehl "startskript-ersetzt-eigenen-marker" "rc=$rc"
rm -f "$PM"

echo
echo "K) Schleifenschutz fuer Stop-Gates"

FALSCH='Die Ursache ist der Cache.'
zaehler() { jq -r '."diagnose-schema-gate" // 0' "$AGENTS_STATE_DIR/stopgate-test-sitzung.json" 2>/dev/null || printf 'keine'; }

# stop_hook_active wird ausgewertet und erhoeht den Zaehler
frischer_marker
lauf "$FALSCH" test-sitzung false >/dev/null   # neue Kette, Zaehler 0, Block 1
lauf "$FALSCH" test-sitzung true  >/dev/null   # Folge, Block 2
nr=$((nr+1))
if [ "$(zaehler)" = "2" ]; then ok "stop-hook-active-zaehlt-weiter" "Zaehler 2"
else fehl "stop-hook-active-zaehlt-weiter" "Zaehler $(zaehler)"; fi

# Drei Zurueckweisungen, die vierte wird durchgelassen
frischer_marker
rm -f "$CLAUDE_PROJECT_DIR/.claude/TASKLOG.md"
r1=$(lauf "$FALSCH" test-sitzung false)
r2=$(lauf "$FALSCH" test-sitzung true)
r3=$(lauf "$FALSCH" test-sitzung true)
r4=$(lauf "$FALSCH" test-sitzung true)
nr=$((nr+1))
if [ "$r1 $r2 $r3 $r4" = "kein-diagnosebericht kein-diagnosebericht kein-diagnosebericht AUFGEGEBEN" ]; then
  ok "zurueckweisungen-4-wird-durchgelassen (3)" "block block block aufgegeben"
else fehl "zurueckweisungen-4-wird-durchgelassen (3)" "$r1 / $r2 / $r3 / $r4"; fi
nr=$((nr+1))
if grep -q '| Gate aufgegeben | diagnose-schema-gate' "$CLAUDE_PROJECT_DIR/.claude/TASKLOG.md" 2>/dev/null; then
  ok "gate-aufgegeben-steht-im-tasklog" "Eintrag vorhanden"
else fehl "gate-aufgegeben-steht-im-tasklog" "kein Eintrag"; fi
nr=$((nr+1))
if [ "$(zaehler)" = "0" ]; then ok "nach-aufgabe-zaehler-zurueckgesetzt" "Zaehler 0"
else fehl "nach-aufgabe-zaehler-zurueckgesetzt" "Zaehler $(zaehler)"; fi

# Zwei Zurueckweisungen, dann korrekte Antwort, Zaehler auf null
frischer_marker
lauf "$FALSCH" test-sitzung false >/dev/null
lauf "$FALSCH" test-sitzung true  >/dev/null
KORREKT="Phase: A
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"
r=$(lauf "$KORREKT" test-sitzung true)
nr=$((nr+1))
if [ "$r" = "DURCH" ] && [ "$(zaehler)" = "0" ]; then ok "zurueckweisungen-dann-korrekt (2)" "DURCH, Zaehler 0"
else fehl "zurueckweisungen-dann-korrekt (2)" "$r, Zaehler $(zaehler)"; fi

# Neue Kette (stop_hook_active false) setzt den Zaehler zurueck, auch ohne Durchlass
frischer_marker
lauf "$FALSCH" test-sitzung false >/dev/null
lauf "$FALSCH" test-sitzung true  >/dev/null
lauf "$FALSCH" test-sitzung false >/dev/null   # neuer Turn des Nutzers
nr=$((nr+1))
if [ "$(zaehler)" = "1" ]; then ok "neue-kette-setzt-zaehler-zurueck" "Zaehler 1"
else fehl "neue-kette-setzt-zaehler-zurueck" "Zaehler $(zaehler)"; fi

nr=$((nr+1))
if [ ! -d "$HOME/.claude/state" ] || [ -z "$(ls "$HOME/.claude/state"/stopgate-test-sitzung.json 2>/dev/null)" ]; then
  ok "kein-zaehler-ausserhalb-temp-hinterlassen" "sauber"
else fehl "kein-zaehler-ausserhalb-temp-hinterlassen" "Datei in ~/.claude/state"; fi

echo
echo "L) Eingabe-Validierung der Session-ID (Codex-Gegenpruefung 2026-09-22)"

# Path Traversal: eine session_id mit ../ darf keinen Zaehler ausserhalb des Zustandsordners anlegen.
frischer_marker
ZUSTAND_VOR=$(ls "$AGENTS_STATE_DIR" 2>/dev/null | sort)
printf 'session=../../../ausbruch\ngueltig_bis=%s\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$MARKER"
transcript 'Die Ursache ist der Cache.'
printf '{"transcript_path":"%s/tr.jsonl","session_id":"../../../ausbruch","stop_hook_active":false}' "$TMP" \
  | bash "$HOOK" >/dev/null 2>&1
nr=$((nr+1))
if [ -z "$(find "$TMP" -name 'ausbruch*' 2>/dev/null)" ] && [ ! -e "$TMP/ausbruch.json" ] \
   && [ ! -e "$AGENTS_STATE_DIR/../../../ausbruch.json" ]; then
  ok "session-id-mit-bricht-nicht-aus" "kein Ausbruch"
else fehl "session-id-mit-bricht-nicht-aus" "$(find "$TMP" -name 'ausbruch*')"; fi
nr=$((nr+1))
# Keine gemeinsame Ersatzdatei: sie wuerde die Zaehler mehrerer Sitzungen vermischen.
if [ "$ZUSTAND_VOR" = "$(ls "$AGENTS_STATE_DIR" 2>/dev/null | sort)" ]; then
  ok "ungueltige-id-legt-keine-zaehlerdatei-an" "keine neue Datei"
else fehl "ungueltige-id-legt-keine-zaehlerdatei-an" "$(ls "$AGENTS_STATE_DIR")"; fi

# Der Fall, der die erste Absicherung per grep gebrochen haette: harmlose erste Zeile,
# Ausbruch in der zweiten. grep prueft zeilenweise und liess das durch.
frischer_marker
ZUSTAND_VOR=$(ls "$AGENTS_STATE_DIR" 2>/dev/null | sort)
transcript 'Die Ursache ist der Cache.'
jq -n --arg tp "$TMP/tr.jsonl" --arg sid $'harmlos\n../../../ausbruch2' \
  '{transcript_path:$tp, session_id:$sid, stop_hook_active:false}' | bash "$HOOK" >/dev/null 2>&1
# Geprueft wird die ERKENNUNG, nicht das Ausbleiben eines Ausbruchs. Eine Mutationsprobe
# am 2026-09-22 zeigte: mit fehlerhafter grep-Pruefung bleibt der Ausbruch trotzdem aus,
# weil der Pfad am Zeilenumbruch scheitert. "Kein Ausbruch" haette also auch den Fehler
# bestaetigt. Nur "unter festem Namen abgelegt" beweist, dass die ID verworfen wurde.
nr=$((nr+1))
if [ "$ZUSTAND_VOR" = "$(ls "$AGENTS_STATE_DIR" 2>/dev/null | sort)" ] \
   && [ -z "$(find "$TMP" -name '*ausbruch2*' 2>/dev/null)" ]; then
  ok "id-mit-harmloser-1-zeile-und-in-der-2" "als ungueltig erkannt"
else fehl "id-mit-harmloser-1-zeile-und-in-der-2" "nicht als ungueltig erkannt"; fi

# Startskript lehnt eine ID mit Zeilenumbruch ab (Feld-Injection in den Marker)
rm -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
nr=$((nr+1))
CLAUDE_CODE_SESSION_ID=$'gut\ngueltig_bis=2099-12-31' bash "$START" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" ]; then
  ok "startskript-lehnt-zeilenumbruch-in-id-ab" "abgelehnt"
else fehl "startskript-lehnt-zeilenumbruch-in-id-ab" "rc=$rc"; fi
nr=$((nr+1))
CLAUDE_CODE_SESSION_ID='../../x' bash "$START" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "startskript-lehnt-in-id-ab" "abgelehnt"
else fehl "startskript-lehnt-in-id-ab" "rc=$rc"; fi

echo
echo "M) Antwort aus last_assistant_message, nicht aus dem Transcript (Testlauf 2026-09-22)"

# Nachgestellt: Das Transcript enthaelt noch die VORIGE Antwort, die neue steht nur im
# Hook-Eingang. So wies der Hook am 2026-09-22 um 12:23:59 einen korrekten Bericht zurueck.
frischer_marker
transcript 'Ich schaue mir das an und melde mich gleich.'
KORREKT_A="# Diagnose: X
Phase: A
Bezeichner: AB-0001

$BELEGE
## Suchraum
Verzeichnisse: application/
Ausgeschlossen: nichts

## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"
KURZ_A=$(antwort_zu "$KORREKT_A")
out=$(jq -n --arg tp "$TMP/tr.jsonl" --arg m "$KURZ_A" \
      '{transcript_path:$tp, session_id:"test-sitzung", stop_hook_active:false, last_assistant_message:$m}' \
      | bash "$HOOK" 2>/dev/null)
nr=$((nr+1))
if [ -z "$out" ]; then ok "neue-antwort-im-eingang-altes-transcript" "DURCH"
else fehl "neue-antwort-im-eingang-altes-transcript" "$(printf '%s' "$out" | jq -r '.reason' | cut -c1-50)"; fi

# Umgekehrt: die Antwort im Eingang ist falsch, das Transcript zufaellig korrekt.
# Gepruef wird der Eingang, also muss das Gate greifen.
frischer_marker
transcript "$KURZ_A"
out=$(jq -n --arg tp "$TMP/tr.jsonl" '{transcript_path:$tp, session_id:"test-sitzung", stop_hook_active:false, last_assistant_message:"Die Ursache ist der Cache."}' \
      | bash "$HOOK" 2>/dev/null)
nr=$((nr+1))
if printf '%s' "$out" | jq -r '.reason' 2>/dev/null | grep -q 'diagnosedatei-fehlt'; then
  ok "falsche-antwort-im-eingang-korrektes-transcript" "diagnosedatei-fehlt"
else fehl "falsche-antwort-im-eingang-korrektes-transcript" "haette blocken muessen"; fi

echo
echo "O) Parallele Aufrufe derselben Sitzung (Codex-Gegenpruefung 2026-09-22)"
# Mitgelesen wird, waehrend 30 Aufrufe gleichzeitig schreiben. Vor der Umstellung auf
# Lock und atomares mv waren 11 von 200 Leseversuchen leer.
frischer_marker
echo '{"diagnose-schema-gate": 0}' > "$AGENTS_STATE_DIR/stopgate-test-sitzung.json"
IN_P=$(jq -n '{session_id:"test-sitzung", stop_hook_active:true, last_assistant_message:"Die Ursache ist der Cache."}')
leer=0; kaputt=0
for i in $(seq 1 30); do printf '%s' "$IN_P" | bash "$HOOK" >/dev/null 2>&1 & done
for i in $(seq 1 300); do
  c=$(cat "$AGENTS_STATE_DIR/stopgate-test-sitzung.json" 2>/dev/null)
  if [ -z "$c" ]; then leer=$((leer+1)); elif ! printf '%s' "$c" | jq -e . >/dev/null 2>&1; then kaputt=$((kaputt+1)); fi
done
wait 2>/dev/null
nr=$((nr+1))
if [ "$leer" -eq 0 ] && [ "$kaputt" -eq 0 ]; then ok "parallel-nie-leer-oder-kaputt-gelesen" "0 von 300"
else fehl "parallel-nie-leer-oder-kaputt-gelesen" "leer=$leer kaputt=$kaputt"; fi
nr=$((nr+1))
if [ -z "$(ls "$AGENTS_STATE_DIR"/*.tmp 2>/dev/null)" ]; then ok "keine-temporaeren-reste" "sauber"
else fehl "keine-temporaeren-reste" "$(ls "$AGENTS_STATE_DIR"/*.tmp)"; fi

# Ein beschaedigter Zaehler darf den Schleifenschutz nicht auf null zuruecksetzen.
frischer_marker
printf 'kein json' > "$AGENTS_STATE_DIR/stopgate-test-sitzung.json"
r=$(lauf 'Die Ursache ist der Cache.' test-sitzung true)
nr=$((nr+1))
if [ "$r" = "AUFGEGEBEN" ]; then ok "beschaedigter-zaehler-zaehlt-als-grenze" "aufgegeben"
else fehl "beschaedigter-zaehler-zaehlt-als-grenze" "$r"; fi

echo
echo "P) Schema 2: Rueckfrage, Versuche, R9 (2026-09-22). Marker ohne Kennung bleibt bei Schema 1."
marker2() { printf 'session=test-sitzung\ngueltig_bis=%s\nschema=2\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$MARKER"; }
marker3() { printf 'session=test-sitzung\ngueltig_bis=%s\nschema=3\n' "$(date -d '+1 day' +%Y-%m-%d)" > "$MARKER"; }
NP='## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall ueber Pfad Nr 1
Nicht angefasst: Live, Datenbank
Umfang: zwei curl-Aufrufe'
A_OHNE_NP="Phase: A
Bezeichner: AB-0001

$BELEGE
## Suchraum
Verzeichnisse: application/
Ausgeschlossen: nichts

## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Frage an den Auftraggeber
Fehlt eine Stelle?"
A_MIT_NP="Phase: A
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

$NP

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"
marker2; pruefe "schema-2-rueckfrage-geht-durch" "DURCH" 'Rückfrage: Welche der 87 IDs stammen aus der Importdatei vom 20.09.?
Ich brauche die Liste, bevor ich die Karte fertigstellen kann.'
marker2; pruefe "schema-2-rueckfrage-mit-karte-abschnitt-ist-ein-bericht" "kein-diagnosebericht" 'Rückfrage: passt das?
## Karte
| 1 | a.php |'
marker2; pruefe "schema-2-rueckfrage-mit-gemessen-abschnitt-ist-ein-bericht" "kein-diagnosebericht" 'Rueckfrage: passt das?
## Gemessen
- x [B-1]'
# Schema 1 ist seit 2026-09-22 14:42 entfernt: ein Marker ohne Kennung gilt als aktuelles Schema.
frischer_marker; pruefe "marker-ohne-kennung-rueckfrage-geht-durch" "DURCH" 'Rückfrage: welche IDs?'
marker2; pruefe "schema-2-naechste-phase-phase-a-ohne-naechste-phase" "naechste-phase-fehlt" "$A_OHNE_NP"
marker3; pruefe "schema-3-naechste-phase-phase-a-ohne-naechste-phase" "naechste-phase-fehlt" "$A_OHNE_NP"
marker2; pruefe "schema-2-naechste-phase-phase-a-mit-block" "DURCH" "$A_MIT_NP"
marker3; pruefe "schema-3-naechste-phase-phase-a-mit-block" "DURCH" "$A_MIT_NP"
marker2; pruefe "schema-2-naechste-phase-block-ohne-umfang" "naechste-phase-fehlt" "$(printf '%s' "$A_MIT_NP" | grep -v '^Umfang:')"
marker3; pruefe "schema-3-naechste-phase-block-ohne-umfang" "naechste-phase-fehlt" "$(printf '%s' "$A_MIT_NP" | grep -v '^Umfang:')"
marker2; pruefe "schema-2-naechste-phase-block-mit-leerem-feld" "naechste-phase-fehlt" "$(printf '%s' "$A_MIT_NP" | sed 's|^Nicht angefasst: .*|Nicht angefasst:|')"
marker3; pruefe "schema-3-naechste-phase-block-mit-leerem-feld" "naechste-phase-fehlt" "$(printf '%s' "$A_MIT_NP" | sed 's|^Nicht angefasst: .*|Nicht angefasst:|')"
frischer_marker; pruefe "marker-ohne-kennung-phase-a-ohne-naechste-phase-block" "naechste-phase-fehlt" "$A_OHNE_NP"
B_ZWEI="Phase: B
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Versuch 1
Pfad aus der Karte: Nr 1
Ergebnis: reproduziert NEIN
Wenn NEIN: Cache lieferte alten Wert, Versuch mit Cache-Bypass noetig
Versuch 2
Pfad aus der Karte: Nr 1
Ergebnis: reproduziert JA

$NP"
marker2; pruefe "schema-2-phase-b-versuch-1-nein-dokumentiert-versuch-2-ja" "DURCH" "$B_ZWEI"
marker3; pruefe "schema-3-phase-b-versuch-1-nein-dokumentiert-versuch-2-ja" "DURCH" "$B_ZWEI"
marker2; pruefe "schema-2-phase-b-nein-ohne-wenn-nein-zeile" "reproduktion-fehlt" "$(printf '%s' "$B_ZWEI" | grep -v '^Wenn NEIN:')"
marker3; pruefe "schema-3-phase-b-nein-ohne-wenn-nein-zeile" "reproduktion-fehlt" "$(printf '%s' "$B_ZWEI" | grep -v '^Wenn NEIN:')"
marker2; pruefe "schema-2-phase-b-wenn-nein-leer" "reproduktion-fehlt" "$(printf '%s' "$B_ZWEI" | sed 's|^Wenn NEIN: .*|Wenn NEIN:|')"
marker3; pruefe "schema-3-phase-b-wenn-nein-leer" "reproduktion-fehlt" "$(printf '%s' "$B_ZWEI" | sed 's|^Wenn NEIN: .*|Wenn NEIN:|')"
marker2; pruefe "schema-2-phase-b-ohne-naechste-phase" "naechste-phase-fehlt" "$(printf '%s' "$B_ZWEI" | sed '/^## Nächste Phase/,$d')"
marker3; pruefe "schema-3-phase-b-ohne-naechste-phase" "naechste-phase-fehlt" "$(printf '%s' "$B_ZWEI" | sed '/^## Nächste Phase/,$d')"
C_ZWEI="Phase: C
Bezeichner: AB-0001

$BELEGE
## Karte-Freigabe
Antwort: \"passt\" (2026-09-22)

## Reproduktion
Eingabe: AB-0001
Versuch 1
Ergebnis: reproduziert NEIN
Wenn NEIN: Cache
Versuch 2
Ergebnis: reproduziert JA

## Gemessen
- Aussage [B-1]

$C_REST"
marker2; pruefe "schema-2-phase-c-nach-versuch-1-nein-und-versuch-2-ja" "DURCH" "$C_ZWEI"
marker3; pruefe "schema-3-phase-c-nach-versuch-1-nein-und-versuch-2-ja" "DURCH" "$C_ZWEI"
marker2; pruefe "schema-2-phase-c-nur-nein-versuche" "reproduktion-fehlt" "$(printf '%s' "$C_ZWEI" | sed 's|reproduziert JA|reproduziert NEIN\nWenn NEIN: auch nicht|')"
marker3; pruefe "schema-3-phase-c-nur-nein-versuche" "reproduktion-fehlt" "$(printf '%s' "$C_ZWEI" | sed 's|reproduziert JA|reproduziert NEIN\nWenn NEIN: auch nicht|')"
marker2; pruefe "schema-2-phase-c-nein-am-ende-ohne-wenn-nein" "reproduktion-fehlt" "$(printf '%s' "$C_ZWEI" | sed 's|^Wenn NEIN: Cache$||')"
marker3; pruefe "schema-3-phase-c-nein-am-ende-ohne-wenn-nein" "reproduktion-fehlt" "$(printf '%s' "$C_ZWEI" | sed 's|^Wenn NEIN: Cache$||')"
marker2; pruefe "schema-2-phase-c-braucht-keinen-naechste-phase-block" "DURCH" "$C_ZWEI"
marker3; pruefe "schema-3-phase-c-braucht-keinen-naechste-phase-block" "DURCH" "$C_ZWEI"
marker2
lauf "$A_MIT_NP" >/dev/null
nr=$((nr+1)); grep -q '^schema=2$' "$MARKER" 2>/dev/null && grep -q '^session=test-sitzung' "$MARKER" && ok "schema-2-marker-verlaengerung-behaelt-kennung" "schema=2" || fehl "schema-2-marker-verlaengerung-behaelt-kennung" "$(tr '\n' ' ' < "$MARKER")"
marker2; lauf 'Rückfrage: kurz?' >/dev/null
nr=$((nr+1)); grep -q '^schema=2$' "$MARKER" 2>/dev/null && ok "schema-2-rueckfrage-verlaengert-marker-mit-kennung" "schema=2" || fehl "schema-2-rueckfrage-verlaengert-marker-mit-kennung" "$(tr '\n' ' ' < "$MARKER")"
frischer_marker; lauf "$A_MIT_NP" >/dev/null
nr=$((nr+1)); grep -q '^schema=3$' "$MARKER" 2>/dev/null && ok "marker-ohne-kennung-bekommt-bei-verlaengerung-schema-3" "schema=3" || fehl "marker-ohne-kennung-bekommt-bei-verlaengerung-schema-3" "$(tr '\n' ' ' < "$MARKER")"
nr=$((nr+1)); [ -z "$(ls "$TMP"/diagnose-active.*.tmp 2>/dev/null)" ] && ok "marker-schreiben-hinterlaesst-keine-temporaere-datei" "sauber" || fehl "marker-schreiben-hinterlaesst-keine-temporaere-datei" "$(ls "$TMP"/diagnose-active.*.tmp)"
rm -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1
nr=$((nr+1)); grep -q '^schema=3$' "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" 2>/dev/null && ok "startskript-schreibt-schema-3" "schema=3" || fehl "startskript-schreibt-schema-3" "$(tr '\n' ' ' < "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" 2>/dev/null)"
rm -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"

echo
echo "J) Isolation: kein echtes Schreibziel wird beruehrt"
ZIELE_NACHHER=$(echte_ziele)
while IFS= read -r zeile; do
  pfad=${zeile% *}
  nr=$((nr+1))
  nachher=$(printf '%s\n' "$ZIELE_NACHHER" | grep -F "$pfad " | head -1)
  if [ "$zeile" = "$nachher" ]; then ok "unberuehrt-$pfad" "gleich"
  else fehl "unberuehrt-$pfad" "veraendert"; fi
done <<< "$ZIELE_VORHER"
nr=$((nr+1))
ECHT_NACHHER=$(cat "$ECHTER_MARKER" 2>/dev/null || printf 'FEHLT')
if [ "$ECHT_VORHER" = "$ECHT_NACHHER" ]; then ok "echter-marker-vorher-gleich-nachher" "unberuehrt"
else fehl "echter-marker-vorher-gleich-nachher" "veraendert"; fi

echo
echo "N) Rueckfall auf das Transcript, wenn last_assistant_message fehlt"
rueckfall() {
  nr=$((nr+1))
  local name="$1" erwartet="$2" text="$3" out ist
  transcript "$(antwort_zu "$text")"
  out=$(printf '{"transcript_path":"%s/tr.jsonl","session_id":"test-sitzung","stop_hook_active":false}' "$TMP" | bash "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then ist="DURCH"
  else ist=$(printf '%s' "$out" | jq -r '.reason' | grep -oE '(ursache-in-phase-a|schlussfrage-fehlt|gemessen-ohne-beleg|reproduktion-fehlt|bezeichner-fehlt|filter-fehlt|unabhaengige-pruefung-fehlt|gegenprobe-nein|naechste-phase-fehlt|kein-diagnosebericht|mehrdeutige-phase|diagnosedatei-fehlt|kurzfassung-unvollstaendig|beleg-nicht-in-datei|kurzfassung-mit-rohdaten)' | head -1); fi
  if [ "$ist" = "$erwartet" ]; then ok "$name" "$ist"; else fehl "$name" "erwartet=$erwartet ist=$ist"; fi
}
frischer_marker
rueckfall "rueckfall-korrekte-phase-a" "DURCH" "Phase: A
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"
frischer_marker
rueckfall "rueckfall-ohne-phase-zeile" "kein-diagnosebericht" 'Die Ursache ist der Cache.'
frischer_marker
rueckfall "rueckfall-ursache-in-phase-a" "ursache-in-phase-a" 'Phase: A
Bezeichner: AB-0001

## Geschlossen
Hypothese: x'

echo
echo "Q) Zwei Ebenen: Datei unter .claude/diagnosen/, Kurzfassung im Chat (2026-09-25)"
GUELTIG_A="Phase: A
Bezeichner: AB-0001

$BELEGE
## Karte
| 1 | a.php | 10 | liest | Route | ja | [B-1] |

## Nächste Phase
Gemessen wird: Antwort am gemeldeten Fall
Nicht angefasst: Live, Datenbank
Umfang: zwei Befehle

## Frage an den Auftraggeber
Fehlt eine Stelle?"
# Legt GUELTIG_A als Datei ab und prueft die uebergebene Chat-Antwort dagegen.
pruefe_chat() {
  nr=$((nr+1))
  local name="$1" erwartet="$2" chat="$3" ist
  frischer_marker; antwort_zu "$GUELTIG_A" >/dev/null
  ist=$(lauf_chat "$chat")
  if [ "$ist" = "$erwartet" ]; then ok "$name" "$ist"; else fehl "$name" "erwartet=$erwartet ist=$ist"; fi
}
pruefe_chat "gueltige-kurzfassung-mit-datei-geht-durch" "DURCH" "$(antwort_zu "$GUELTIG_A")"
pruefe_chat "kurzfassung-mit-fetten-stichworten-und-liste-geht-durch" "DURCH" "**Stand:** Karte liegt vor.

**Belegt:**
- Die API liefert die Version 3 [B-1]

**Offen:** nichts
**Vorschlag:** Reproduktion
**Von dir:** Freigabe der Karte

Bericht: $BERICHT_REL"
pruefe_chat "kurzfassung-mit-absolutem-pfad-geht-durch" "DURCH" "$(kurzfassung "$BERICHT")"
pruefe_chat "kurzfassung-ohne-pfad" "diagnosedatei-fehlt" "$(kurzfassung | grep -v '^Bericht:')"
pruefe_chat "pfad-auf-fehlende-datei" "diagnosedatei-fehlt" "$(kurzfassung .claude/diagnosen/gibt-es-nicht.md)"
pruefe_chat "pfad-ausserhalb-von-diagnosen" "diagnosedatei-fehlt" "$(kurzfassung | sed 's#^Bericht: .*#Bericht: .claude/notizen/test-bericht.md#')"
pruefe_chat "kurzfassung-ohne-von-dir" "kurzfassung-unvollstaendig" "$(kurzfassung | grep -v '^Von dir:')"
pruefe_chat "kurzfassung-ohne-stand" "kurzfassung-unvollstaendig" "$(kurzfassung | grep -v '^Stand:')"
pruefe_chat "stichwort-mitten-im-satz-zaehlt-nicht" "kurzfassung-unvollstaendig" "$(kurzfassung | sed 's/^Offen:/Nichts ist Offen:/')"
pruefe_chat "belegnummer-nicht-in-datei" "beleg-nicht-in-datei" "$(kurzfassung | sed 's/\[B-1\]/[B-7]/')"
pruefe_chat "belegt-aussage-ohne-nummer" "beleg-nicht-in-datei" "$(kurzfassung | sed 's/^Belegt: .*/Belegt: Die Version ist falsch./')"
pruefe_chat "belegt-zweite-zeile-ohne-nummer" "beleg-nicht-in-datei" "$(kurzfassung | sed 's/^\(Belegt: .*\)$/\1\n- und der Export auch/')"
pruefe_chat "kurzfassung-mit-tabelle" "kurzfassung-mit-rohdaten" "$(kurzfassung; printf '| a | b |\n|---|---|\n')"
pruefe_chat "kurzfassung-mit-codeblock" "kurzfassung-mit-rohdaten" "$(kurzfassung; printf '```\ncurl -s URL\n```\n')"
pruefe_chat "kurzfassung-mit-befehlszeile" "kurzfassung-mit-rohdaten" "$(kurzfassung; printf '$ curl -s https://example.org\n')"
pruefe_chat "kurzfassung-mit-31-zeilen" "kurzfassung-mit-rohdaten" "$(kurzfassung; for i in $(seq 1 25); do printf 'Offen: Punkt %s\n' "$i"; done)"
pruefe_chat "kurzfassung-mit-30-zeilen-geht-durch" "DURCH" "$(kurzfassung; for i in $(seq 1 24); do printf -- '- Punkt %s\n' "$i"; done)"
pruefe_chat "uebergehung-in-kurzfassung-mit-regelnamen" "DURCH" "$(kurzfassung | grep -v '^Von dir:'; printf 'Übergehung: kurzfassung-unvollstaendig, Test\n')"
# Die Dateiregeln greifen weiter: ein Verstoss in der Datei wird trotz gueltiger Kurzfassung gemeldet.
nr=$((nr+1)); frischer_marker
printf '%s\n' "Phase: A
Bezeichner: AB-0001
## Geschlossen
Hypothese: x" > "$BERICHT"
ist=$(lauf_chat "$(kurzfassung)")
if [ "$ist" = "ursache-in-phase-a" ]; then ok "dateiregel-greift-trotz-gueltiger-kurzfassung" "$ist"
else fehl "dateiregel-greift-trotz-gueltiger-kurzfassung" "ist=$ist"; fi

echo
echo "R) Nachbesserung nach Codex-Review (2026-09-25)"
# Schema 2 laeuft weiter im Chat: ein Bericht im Chat ohne Datei geht durch.
nr=$((nr+1)); marker2
ist=$(lauf_chat "$GUELTIG_A")
if [ "$ist" = "DURCH" ]; then ok "schema-2-vorgang-bleibt-im-chat" "$ist"; else fehl "schema-2-vorgang-bleibt-im-chat" "ist=$ist"; fi
# Rueckfrage mit Kurzfassungsfeldern ist ein Bericht und wird geprueft.
nr=$((nr+1)); frischer_marker
printf '%s\n' "Phase: A
Bezeichner: AB-0001
## Geschlossen
Hypothese: x" > "$BERICHT"
ist=$(lauf_chat "Rückfrage: passt das?
$(kurzfassung)")
if [ "$ist" = "ursache-in-phase-a" ]; then ok "rueckfrage-mit-kurzfassung-ist-ein-bericht" "$ist"; else fehl "rueckfrage-mit-kurzfassung-ist-ein-bericht" "ist=$ist"; fi
nr=$((nr+1)); frischer_marker
ist=$(lauf_chat "Rückfrage: passt das?
Stand: x")
if [ "$ist" != "DURCH" ]; then ok "rueckfrage-mit-stand-feld-geht-nicht-als-rueckfrage-durch" "$ist"; else fehl "rueckfrage-mit-stand-feld-geht-nicht-als-rueckfrage-durch" "DURCH"; fi
nr=$((nr+1)); frischer_marker
printf '%s\n' "Phase: A
Bezeichner: AB-0001
## Geschlossen
Hypothese: x" > "$BERICHT"
ist=$(lauf_chat "Rückfrage: passt das?
Siehe $BERICHT_REL")
if [ "$ist" != "DURCH" ]; then ok "rueckfrage-mit-berichtspfad-ist-ein-bericht" "$ist"; else fehl "rueckfrage-mit-berichtspfad-ist-ein-bericht" "DURCH"; fi
# Pfad muss im Projekt unter .claude/diagnosen/ liegen, auch nach Aufloesen von .. und Symlinks.
mkdir -p "$TMP/fremd/.claude/diagnosen"; printf '%s\n' "$GUELTIG_A" > "$TMP/fremd/.claude/diagnosen/alt.md"
pruefe_chat "absoluter-pfad-in-fremdes-projekt" "diagnosedatei-fehlt" "$(kurzfassung "$TMP/fremd/.claude/diagnosen/alt.md")"
pruefe_chat "pfad-mit-punkt-punkt-aus-dem-projekt" "diagnosedatei-fehlt" "$(kurzfassung ".claude/diagnosen/../../../fremd/.claude/diagnosen/alt.md")"
ln -sf "$TMP/fremd/.claude/diagnosen/alt.md" "$CLAUDE_PROJECT_DIR/.claude/diagnosen/link.md"
pruefe_chat "symlink-aus-dem-projekt-heraus" "diagnosedatei-fehlt" "$(kurzfassung .claude/diagnosen/link.md)"
rm -f "$CLAUDE_PROJECT_DIR/.claude/diagnosen/link.md"
nr=$((nr+1)); frischer_marker
head -c 1100000 /dev/zero | tr '\0' 'x' > "$CLAUDE_PROJECT_DIR/.claude/diagnosen/riesig.md"
ist=$(lauf_chat "$(kurzfassung .claude/diagnosen/riesig.md)")
if [ "$ist" = "diagnosedatei-fehlt" ]; then ok "datei-ueber-einem-megabyte" "$ist"; else fehl "datei-ueber-einem-megabyte" "ist=$ist"; fi
rm -f "$CLAUDE_PROJECT_DIR/.claude/diagnosen/riesig.md"
# Pflichtfelder brauchen Inhalt.
pruefe_chat "leeres-stand-feld" "kurzfassung-unvollstaendig" "$(kurzfassung | sed 's/^Stand: .*/Stand:/')"
pruefe_chat "leeres-belegt-feld" "kurzfassung-unvollstaendig" "$(kurzfassung | sed 's/^Belegt: .*/Belegt:/')"
pruefe_chat "stand-mit-inhalt-in-der-folgezeile-geht-durch" "DURCH" "$(kurzfassung | sed 's/^Stand: .*/Stand:\nDie Karte liegt vor./')"
# Listen mit * und +, umgebrochene Aussagen.
pruefe_chat "belegt-als-sternliste-geht-durch" "DURCH" "$(kurzfassung | sed 's/^Belegt: .*/Belegt:\n* Die API liefert die Version 3 [B-1]\n+ Sie stammt aus dem Cache [B-1]/')"
pruefe_chat "umgebrochene-aussage-mit-nummer-in-folgezeile-geht-durch" "DURCH" "$(kurzfassung | sed 's/^Belegt: .*/Belegt:\n- Die API liefert die Version 3,\n  gemessen am Fall AB-0001 [B-1]/')"
pruefe_chat "aussage-mit-diagnosen-text-ohne-nummer" "beleg-nicht-in-datei" "$(kurzfassung | sed 's#^Belegt: .*#Belegt:\n- Siehe .claude/diagnosen/alt.md, dort steht es#')"
pruefe_chat "keine-plus-weitere-aussage-ohne-nummer" "beleg-nicht-in-datei" "$(kurzfassung | sed 's/^Belegt: .*/Belegt: keine\n- aber die Version ist falsch/')"
# Weitere Rohdaten-Formen.
pruefe_chat "tabelle-in-liste" "kurzfassung-mit-rohdaten" "$(kurzfassung; printf -- '- | a | b |\n')"
pruefe_chat "eingerueckter-codeblock" "kurzfassung-mit-rohdaten" "$(kurzfassung; printf '    curl -s https://example.org\n')"
# Transcript-Rueckfall nimmt den Pfad der letzten Antwort.
nr=$((nr+1)); frischer_marker
printf '%s\n' "Phase: A
Bezeichner: AB-0001
## Geschlossen
Hypothese: x" > "$CLAUDE_PROJECT_DIR/.claude/diagnosen/alt-falsch.md"
antwort_zu "$GUELTIG_A" >/dev/null
python3 -c "
import json,sys
alt=sys.argv[1]; neu=sys.argv[2]
with open('$TMP/tr.jsonl','w',encoding='utf-8') as f:
    for text in (alt, neu):
        f.write(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':text}]}})+'\\n')
" "$(kurzfassung .claude/diagnosen/alt-falsch.md)" "$(kurzfassung)"
out=$(printf '{"transcript_path":"%s/tr.jsonl","session_id":"test-sitzung","stop_hook_active":false}' "$TMP" | bash "$HOOK" 2>/dev/null)
if [ -z "$out" ]; then ok "rueckfall-nimmt-pfad-der-letzten-antwort" "DURCH"; else fehl "rueckfall-nimmt-pfad-der-letzten-antwort" "$(printf '%s' "$out" | jq -r '.reason' | cut -c1-60)"; fi
rm -f "$CLAUDE_PROJECT_DIR/.claude/diagnosen/alt-falsch.md"

echo
echo "S) Startzeit im Marker, Regelnamen statt Kuerzel (2026-09-25)"
marker_mit_start() { printf 'session=test-sitzung\ngueltig_bis=%s\nschema=3\ngestartet=%s\n' "$(date -d '+1 day' +%Y-%m-%d)" "$1" > "$MARKER"; }
nr=$((nr+1)); antwort_zu "$GUELTIG_A" >/dev/null; marker_mit_start "$(date -d '-1 hour' +%s)"
ist=$(lauf_chat "$(kurzfassung)")
if [ "$ist" = "DURCH" ]; then ok "datei-nach-dem-start-geaendert-geht-durch" "$ist"; else fehl "datei-nach-dem-start-geaendert-geht-durch" "ist=$ist"; fi
nr=$((nr+1)); antwort_zu "$GUELTIG_A" >/dev/null; touch -d '-2 hours' "$BERICHT"; marker_mit_start "$(date -d '-1 hour' +%s)"
ist=$(lauf_chat "$(kurzfassung)")
if [ "$ist" = "diagnosedatei-fehlt" ]; then ok "datei-vor-dem-start-zuletzt-geaendert" "$ist"; else fehl "datei-vor-dem-start-zuletzt-geaendert" "ist=$ist"; fi
nr=$((nr+1)); antwort_zu "$GUELTIG_A" >/dev/null; touch -d '-2 hours' "$BERICHT"; marker3
ist=$(lauf_chat "$(kurzfassung)")
if [ "$ist" = "DURCH" ] && grep -q 'ohne Startzeit' "$DIAGNOSE_GATE_LOG"; then ok "marker-ohne-startzeit-laesst-pruefung-aus-und-loggt" "$ist"; else fehl "marker-ohne-startzeit-laesst-pruefung-aus-und-loggt" "ist=$ist"; fi
nr=$((nr+1)); antwort_zu "$GUELTIG_A" >/dev/null; marker_mit_start 1700000000; lauf_chat "$(kurzfassung)" >/dev/null
if grep -q '^gestartet=1700000000$' "$MARKER"; then ok "verlaengerung-behaelt-startzeit" "gestartet=1700000000"; else fehl "verlaengerung-behaelt-startzeit" "$(tr '\n' ' ' < "$MARKER")"; fi
rm -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
CLAUDE_CODE_SESSION_ID=start-test bash "$START" >/dev/null 2>&1
nr=$((nr+1)); grep -qE '^gestartet=[0-9]{10}$' "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" 2>/dev/null && ok "startskript-schreibt-startzeit" "gestartet" || fehl "startskript-schreibt-startzeit" "$(tr '\n' ' ' < "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active" 2>/dev/null)"
rm -f "$CLAUDE_PROJECT_DIR/.claude/state/diagnose-active"
# Keine Kuerzel in Meldung und Log
nr=$((nr+1)); frischer_marker; : > "$DIAGNOSE_GATE_LOG"
printf '%s\n' "Phase: A
Bezeichner: AB-0001
## Geschlossen
Hypothese: x" > "$BERICHT"
out=$(jq -n --arg m "$(kurzfassung)" '{session_id:"test-sitzung", stop_hook_active:false, last_assistant_message:$m}' | bash "$HOOK" 2>/dev/null)
if printf '%s' "$out" | jq -r '.reason' | grep -q '^Diagnose-Schema: ursache-in-phase-a verletzt' && ! printf '%s' "$out" | grep -qE '\(R[0-9]+\)'; then
  ok "meldung-nennt-regelnamen-ohne-kuerzel" "ursache-in-phase-a"; else fehl "meldung-nennt-regelnamen-ohne-kuerzel" "$(printf '%s' "$out" | jq -r '.reason' | cut -c1-60)"; fi
nr=$((nr+1)); if ! grep -qE '\bR[0-9]+\b' "$DIAGNOSE_GATE_LOG"; then ok "log-ohne-kuerzel" "sauber"; else fehl "log-ohne-kuerzel" "$(grep -E '\bR[0-9]+\b' "$DIAGNOSE_GATE_LOG" | head -1 | cut -c1-60)"; fi

echo
if [ "$fehler" -eq 0 ]; then
  echo "Alle $nr Faelle bestanden."
  exit 0
else
  echo "$fehler von $nr Faellen fehlgeschlagen."
  exit 1
fi
