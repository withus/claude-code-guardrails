#!/usr/bin/env bash
# Diagnose-Schema-Gate: prueft Diagnoseberichte auf Form und Vollstaendigkeit.
# Prueft NIE Inhalt, nur Struktur. Neun Regeln, alle als Regex. Regelnamen:
#   R1 ursache-in-phase-a, R2 schlussfrage-fehlt, R3 gemessen-ohne-beleg, R4 reproduktion-fehlt,
#   R5 bezeichner-fehlt, R6 filter-fehlt, R7 unabhaengige-pruefung-fehlt, R8 gegenprobe-nein,
#   R9 naechste-phase-fehlt, dazu kein-diagnosebericht und mehrdeutige-phase. Schema 2 (Marker schema=2) seit 2026-09-22:
# Zwei Ebenen seit 2026-09-25: der Bericht liegt als Datei unter .claude/diagnosen/ und wird mit allen Regeln geprueft,
# der Chat traegt nur die Kurzfassung mit Pfad. Regeln dafuer: R10 diagnosedatei-fehlt, R11 kurzfassung-unvollstaendig,
# R12 beleg-nicht-in-datei, R13 kurzfassung-mit-rohdaten. Gilt fuer Marker mit schema=3; Vorgaenge mit schema=2 bleiben im Chat.
# Rueckfrage geht durch, Reproduktion mit Versuchen, R9 Block "Naechste Phase" in Phase A und B.
# Vorlage: ~/.claude/guardrails/templates/diagnose.md
# Hintergrund: 2026-09-22, drei aufeinanderfolgende Fehlschluesse durch zu fruehe Verdichtung.
#
# Meldungen, Log und TASKLOG nennen nur den Regelnamen (2026-09-25). Die alte Uebergehungsform
# "Übergehung: R<n>, Grund" wird ueber REGEL_KUERZEL weiter angenommen, aber nirgends mehr angezeigt.
#
# Faellt OFFEN aus: bei eigenem Fehler wird geloggt und durchgelassen.
# Das ist kein Sicherheitsgate: ein eigener Fehler darf die Arbeit nicht blockieren.

set +e

# Ueberschreibbar wie alle Schreibziele dieses Hooks, damit Tests nichts Echtes beruehren.
LOG="${DIAGNOSE_GATE_LOG:-$HOME/.claude/hooks/diagnose-gate.log}"
MARKER_PROJEKT="${CLAUDE_PROJECT_DIR:-.}/.claude/state/diagnose-active"
# Ueberschreibbar, damit Tests einen eigenen Marker nutzen und eine laufende
# Diagnose nie beruehren. Produktiv bleibt der Standardpfad.
MARKER_GLOBAL="${DIAGNOSE_MARKER_GLOBAL:-$HOME/.claude/state/diagnose-active}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null; }
durchlassen() { exit 0; }
# Eine Uebergehung ist ein bewusster Eintrag mit Begruendung, kein abgeschalteter Hook.
# Format im Bericht oder in der Kurzfassung:  Übergehung: <regelname>, <Grund>
# Alte Form mit Kuerzel wird ueber diese Zuordnung weiter angenommen.
declare -A REGEL_KUERZEL=([R1]=ursache-in-phase-a [R2]=schlussfrage-fehlt [R3]=gemessen-ohne-beleg [R4]=reproduktion-fehlt
  [R5]=bezeichner-fehlt [R6]=filter-fehlt [R7]=unabhaengige-pruefung-fehlt [R8]=gegenprobe-nein [R9]=naechste-phase-fehlt
  [R10]=diagnosedatei-fehlt [R11]=kurzfassung-unvollstaendig [R12]=beleg-nicht-in-datei [R13]=kurzfassung-mit-rohdaten)
UEBERGEHUNG_NAMEN_ERLAUBT=1
# Wird die Regel uebergangen, laeuft die Pruefung weiter und der Fall landet im TASKLOG
# des Projekts. Dort lassen sich die Uebergehungen je Regel zaehlen.
# Pfad: <projekt>/.claude/TASKLOG.md.
TASKLOG="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/TASKLOG.md"
tasklog_ordner() { mkdir -p "$(dirname "$TASKLOG")" 2>/dev/null; }
tasklog() {
  tasklog_ordner
  { [ -f "$TASKLOG" ] || printf '# TASKLOG\n\n| Datum | Art | Regel | Grund |\n|---|---|---|---|\n'
    printf '| %s | Übergehung | %s | %s |\n' "$(date +%Y-%m-%d)" "$1" "$2"
  } >> "$TASKLOG" 2>/dev/null || log "TASKLOG nicht beschreibbar: $TASKLOG"
}
# Schleifenschutz fuer Stop-Gates.
# Ein Stop-Gate, das dieselbe Antwort immer wieder zurueckweist, verbrennt das Budget.
# Nach 3 Zurueckweisungen in Folge laesst es durch und meldet "Gate aufgegeben".
# Zaehler je Sitzung im neutralen Zustandsordner, damit auch Codex ihn erreichen kann.
STATE_DIR="${AGENTS_STATE_DIR:-$HOME/.claude/state}"
MAX_ZURUECKWEISUNGEN=3
# Die Session-ID kommt aus der Hook-Eingabe und wird Teil eines Dateinamens.
# Sie darf nur aus Zeichen bestehen, die keinen Pfad bilden koennen (Schutz gegen ../).
# Allowlist statt Denylist (security.md). Alles andere faellt auf einen festen Namen zurueck.
sichere_session() {
  # Bash-Regex prueft den GANZEN String. grep wuerde zeilenweise pruefen und eine ID
  # mit harmloser erster Zeile und ../ in der zweiten durchlassen.
  if [[ "${SESSION:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
    printf '%s' "$SESSION"
  else
    return 1
  fi
}
# Ohne gueltige Sitzung gibt es keinen Zaehler. Eine gemeinsame Ersatzdatei fuer alle
# ungueltigen Kennungen wuerde die Zaehler mehrerer Sitzungen vermischen und genau dort
# echte Parallelitaet erzeugen (Codex-Gegenpruefung 2026-09-22).
zaehler_datei() { local s; s=$(sichere_session) || return 1; printf '%s/stopgate-%s.json' "$STATE_DIR" "$s"; }
zaehler_lesen() {
  local d; d=$(zaehler_datei) || { printf 'ohne'; return; }
  [ -f "$d" ] || { printf '0'; return; }
  local n; n=$(jq -r '."diagnose-schema-gate" // empty' "$d" 2>/dev/null)
  # Unlesbar heisst nicht null. Waere es null, koennte ein beschaedigter Zaehler
  # den Schleifenschutz zuruecksetzen. Unlesbar wird wie "Grenze erreicht" behandelt.
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || { log "Zaehler unlesbar: $d"; printf '%s' "$MAX_ZURUECKWEISUNGEN"; }
}
zaehler_setzen() {
  local d; d=$(zaehler_datei) || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  # Atomar: in eine temporaere Datei schreiben und per mv ersetzen. mv auf demselben
  # Dateisystem ist atomar, ein paralleler Leser sieht nie eine halb geschriebene Datei.
  local tmp="$d.$$.tmp"
  jq -n --argjson n "$1" '{"diagnose-schema-gate": $n}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$d" \
    || { rm -f "$tmp"; log "Zaehler nicht schreibbar: $d"; }
}
# Marker atomar schreiben: temporaere Datei im selben Ordner, dann mv. Ein Abbruch waehrend des
# Schreibens darf den Marker nie abschneiden (Codex-Gegenpruefung 2026-09-22).
marker_schreiben() {
  local tmp="$MARKER.$$.tmp"
  { [ -n "$MARKER_SESSION" ] && printf 'session=%s\n' "$MARKER_SESSION"
    printf 'gueltig_bis=%s\n' "$(date -d '+1 day' +%Y-%m-%d)"
    # if statt &&: bei Schema 1 darf der Gruppenstatus nicht auf 1 fallen, sonst bleibt das mv aus.
    printf 'schema=%s\n' "$MARKER_SCHEMA"
    [ -n "${MARKER_START:-}" ] && printf 'gestartet=%s\n' "$MARKER_START"
    true
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$MARKER" || { rm -f "$tmp"; log "MARKER nicht schreibbar: $MARKER"; return 1; }
}
# Lesen, Erhoehen und Schreiben als eine Einheit unter exklusivem Lock.
# Ohne Lock gehen bei parallelen Aufrufen Erhoehungen verloren.
zaehler_erhoehen() {
  local d; d=$(zaehler_datei) || { printf 'ohne'; return; }
  mkdir -p "$STATE_DIR" 2>/dev/null
  (
    flock -x -w 5 9 || { log "Lock nicht erhalten: $d"; printf '%s' "$MAX_ZURUECKWEISUNGEN"; exit 0; }
    local n; n=$(zaehler_lesen)
    [ "$n" = "ohne" ] && { printf 'ohne'; exit 0; }
    printf '%s' "$n"
    [ "$n" -lt "$MAX_ZURUECKWEISUNGEN" ] && zaehler_setzen $((n+1))
  ) 9>"$d.lock"
}
gate_aufgegeben() {
  local regel="$1" meldung="$2"
  log "GATE AUFGEGEBEN nach $MAX_ZURUECKWEISUNGEN Zurueckweisungen, letzte: $meldung"
  tasklog_ordner
  { [ -f "$TASKLOG" ] || printf '# TASKLOG\n\n| Datum | Art | Regel | Grund |\n|---|---|---|---|\n'
    printf '| %s | Gate aufgegeben | diagnose-schema-gate, %s | %s Zurueckweisungen in Folge |\n' \
      "$(date +%Y-%m-%d)" "${regel:-ohne Regel}" "$MAX_ZURUECKWEISUNGEN"
  } >> "$TASKLOG" 2>/dev/null
  zaehler_setzen 0
  jq -n --arg m "Gate aufgegeben: diagnose-schema-gate, ${regel:-ohne Regel}. Die Antwort wurde $MAX_ZURUECKWEISUNGEN Mal in Folge zurueckgewiesen und jetzt ungeprueft durchgelassen. Bitte selbst pruefen. Letzte Meldung: $meldung" \
    '{systemMessage:$m}' 2>/dev/null
  exit 0
}

zurueck() {
  # Regelname ist das erste Wort der Meldung, etwa "naechste-phase-fehlt verletzt. ..." (2026-09-22 und 2026-09-25).
  local regel; regel=$(printf '%s' "$1" | grep -oE '^[a-z]+(-[a-z]+)+' | head -1)
  if [ -n "$regel" ] && [ -n "${UEBERGEHUNG_TEXT:-$TEXT}" ]; then
    local zeile uz="" grund
    while IFS= read -r zeile; do
      local ziel; ziel=$(printf '%s' "$zeile" | sed -E 's/^(Übergehung|Uebergehung):[[:space:]]*//I; s/[[:space:]]*,.*$//; s/[[:space:]]*$//')
      [ "$UEBERGEHUNG_NAMEN_ERLAUBT" = 1 ] || [[ "$ziel" =~ ^[Rr][0-9]+$ ]] || continue
      [[ "$ziel" =~ ^[Rr][0-9]+$ ]] && ziel="${REGEL_KUERZEL[${ziel^^}]:-}"
      ziel="${ziel,,}"
      [ "$ziel" = "$regel" ] && { uz="$zeile"; break; }
    done < <(printf '%s\n' "${UEBERGEHUNG_TEXT:-$TEXT}" | grep -iE '^(Übergehung|Uebergehung):')
    if [ -n "$uz" ]; then
      grund=$(printf '%s' "$uz" | sed -E 's/^[^,]*,[[:space:]]*//')
      [ "$grund" = "$uz" ] && grund="(ohne Begruendung)"
      log "UEBERGEHUNG $regel: $grund"
      tasklog "$regel" "$grund"
      return 0
    fi
  fi
  local n; n=$(zaehler_erhoehen)
  # Ohne gueltige Sitzung kein Schleifenschutz moeglich: offen ausfallen statt schleifen.
  [ "$n" = "ohne" ] && { log "ohne gueltige Sitzung, kein Zaehler, durchgelassen"; durchlassen; }
  [ "$n" -ge "$MAX_ZURUECKWEISUNGEN" ] 2>/dev/null && gate_aufgegeben "$regel" "$1"
  log "BLOCK $1 (Zurueckweisung $((n+1)) von $MAX_ZURUECKWEISUNGEN)"
  jq -n --arg r "Diagnose-Schema: $1 Vorlage: ~/.claude/guardrails/templates/diagnose.md" \
    '{decision:"block", reason:$r}' 2>/dev/null || durchlassen
  exit 0
}

# Diagnose-Modus aktiv? Sonst nichts tun.
MARKER=""
[ -f "$MARKER_PROJEKT" ] && MARKER="$MARKER_PROJEKT"
[ -z "$MARKER" ] && [ -f "$MARKER_GLOBAL" ] && MARKER="$MARKER_GLOBAL"
[ -n "$MARKER" ] || durchlassen

INPUT=$(cat)
command -v jq >/dev/null 2>&1 || { log "jq fehlt, durchgelassen"; durchlassen; }

# Marker hat Besitzer und Lebensdauer. Ein verwaister Marker darf
# keine fremde Sitzung gaten: er wird ignoriert und als verwaist geloggt.
# Format je Zeile: session=<id>  bzw.  gueltig_bis=<JJJJ-MM-TT>
# Ein Marker ohne gueltig_bis gilt hoechstens 24 Stunden ab Dateialter, nie unbegrenzt.
# Gesetzt wird er regulaer ueber /diagnose, das beide Felder schreibt.
MARKER_SESSION=$(grep -oE '^session=.*' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)
MARKER_BIS=$(grep -oE '^gueltig_bis=.*' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)
# Schemakennung des Markers: ein laufender Vorgang behaelt die Regeln, mit denen er gestartet wurde.
# Schema 1 (Marker ohne Kennung, vor 2026-09-22) ist entfernt, nachdem der letzte Marker dieses Schemas
# am 2026-09-22 14:42 regulaer abgeschlossen wurde. Ein Marker ohne Kennung gilt als aktuelles Schema.
# Schema 3 seit 2026-09-25: Bericht als Datei, Kurzfassung im Chat. Laufende Schema-2-Vorgaenge behalten den Chat-Bericht.
AKTUELLES_SCHEMA=3
MARKER_SCHEMA=$(grep -oE '^schema=[0-9]+' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)
# Startzeit der Diagnose (Unix-Sekunden, schreibt diagnose-start.sh seit 2026-09-25). Eine Berichtsdatei,
# die seitdem nicht geaendert wurde, gilt nicht als aktueller Bericht.
MARKER_START=$(grep -oE '^gestartet=[0-9]+$' "$MARKER" 2>/dev/null | head -1 | cut -d= -f2-)
[[ "$MARKER_SCHEMA" =~ ^[0-9]+$ ]] || MARKER_SCHEMA=$AKTUELLES_SCHEMA
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# stop_hook_active ist true, wenn diese Antwort Folge einer frueheren Zurueckweisung ist.
# Ist es false, beginnt eine neue Kette, und der Zaehler startet bei null.
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_HOOK_ACTIVE" = "true" ] || zaehler_setzen 0

if [ -z "$MARKER_BIS" ] && [ -n "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then
  log "VERWAIST Marker ohne gueltig_bis und aelter als 24 Stunden, ignoriert"
  durchlassen
fi
if [ -n "$MARKER_BIS" ] && [ "$(date +%Y-%m-%d)" \> "$MARKER_BIS" ]; then
  log "VERWAIST Marker abgelaufen am $MARKER_BIS, ignoriert"
  durchlassen
fi
if [ -n "$MARKER_SESSION" ] && [ -n "$SESSION" ] && [ "$MARKER_SESSION" != "$SESSION" ]; then
  log "VERWAIST Marker gehoert Sitzung $MARKER_SESSION, aktuell ist $SESSION, ignoriert"
  durchlassen
fi

# Die Antwort kommt direkt aus dem Hook-Eingang (last_assistant_message).
# Das Transcript ist beim Stop-Ereignis nicht zwingend schon geschrieben: am 2026-09-22
# wies der Hook dadurch einen korrekten Bericht zurueck, weil er eine veraltete Antwort las.
# Das Transcript bleibt nur Rueckfall fuer Werkzeuge, die das Feld nicht liefern.
TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [ -z "$TEXT" ]; then
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { log "weder last_assistant_message noch Transcript, durchgelassen"; durchlassen; }
  TEXT=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' \
          "$TRANSCRIPT" 2>/dev/null | tail -200)
  log "Rueckfall auf Transcript, last_assistant_message fehlte"
  AUS_TRANSCRIPT=1
fi
[ -n "$TEXT" ] || { log "kein Text, durchgelassen"; durchlassen; }

# Eine Rueckfrage an den Auftraggeber ist kein Bericht und geht durch, solange sie
# keinen Karte-, Gemessen-, Ursache- oder Geschlossen-Abschnitt traegt.
ERSTE_ZEILE=$(printf '%s' "$TEXT" | grep -vE '^[[:space:]]*$' | head -1)
STICH='^[[:space:]]*([-*+][[:space:]]+)?(\*\*)?'
KURZ_FELDER="${STICH}(Stand|Belegt|Offen|Vorschlag|Von dir)(\*\*)?:"
BERICHT_IM_CHAT=0
if [ "$MARKER_SCHEMA" -ge 3 ] 2>/dev/null; then
  printf '%s' "$TEXT" | grep -qiE "$KURZ_FELDER" && BERICHT_IM_CHAT=1
  printf '%s' "$TEXT" | grep -qF '.claude/diagnosen/' && BERICHT_IM_CHAT=1
fi
if printf '%s' "$ERSTE_ZEILE" | grep -qiE '^(Rückfrage|Rueckfrage):' && [ "$BERICHT_IM_CHAT" = 0 ] \
   && ! printf '%s' "$TEXT" | grep -qiE '^#+[[:space:]]*(Karte|Gemessen|Ursache|Geschlossen)'; then
  log "PASS Rueckfrage (Schema $MARKER_SCHEMA)"
  zaehler_setzen 0
  marker_schreiben && log "MARKER verlaengert"
  exit 0
fi

# --- Zwei Ebenen: Kurzfassung im Chat, Bericht in der Datei (Schema 3) ---
if [ "$MARKER_SCHEMA" -ge "$AKTUELLES_SCHEMA" ] 2>/dev/null; then
KURZ="$TEXT"
UEBERGEHUNG_TEXT="$KURZ"
MAX_BERICHT_BYTES=1048576
PFAD_MUSTER='[^[:space:]]*\.claude/diagnosen/[^[:space:]]+\.md'
# Bevorzugt die Zeile "Bericht:", "Datei:" oder "Pfad:"; sonst jeder Pfad. Beim Transcript-Rueckfall der letzte, sonst der erste.
PFADE=$(printf '%s\n' "$KURZ" | grep -iE "${STICH}(Bericht|Datei|Pfad)(\*\*)?:" | grep -oE "$PFAD_MUSTER")
[ -n "$PFADE" ] || PFADE=$(printf '%s\n' "$KURZ" | grep -oE "$PFAD_MUSTER")
if [ "${AUS_TRANSCRIPT:-0}" = 1 ]; then PFAD=$(printf '%s\n' "$PFADE" | tail -1); else PFAD=$(printf '%s\n' "$PFADE" | head -1); fi
PFAD=$(printf '%s' "$PFAD" | sed -E "s/^[\`'\"(<*]+//")
PROJEKT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$PFAD" in
  "") DATEI="" ;;
  "~/"*) DATEI="$HOME/${PFAD#\~/}" ;;
  /*) DATEI="$PFAD" ;;
  *) DATEI="$PROJEKT_DIR/$PFAD" ;;
esac
if [ -z "$DATEI" ]; then
  zurueck "diagnosedatei-fehlt verletzt. Die Antwort nennt keinen Pfad auf eine Datei unter .claude/diagnosen/. Der vollstaendige Bericht gehoert in die Datei, im Chat steht die Kurzfassung mit Pfad."
else
  # Nach Aufloesen von .. und Symlinks muss die Datei im Projekt unter .claude/diagnosen/ liegen.
  ECHT=$(realpath -m -- "$DATEI" 2>/dev/null)
  ERLAUBT=$(realpath -m -- "$PROJEKT_DIR/.claude/diagnosen" 2>/dev/null)
  if [ -z "$ECHT" ] || [ -z "$ERLAUBT" ] || [ "${ECHT#"$ERLAUBT"/}" = "$ECHT" ]; then
    zurueck "diagnosedatei-fehlt verletzt. $PFAD liegt nicht im Projekt unter .claude/diagnosen/."
  elif [ ! -f "$ECHT" ]; then
    zurueck "diagnosedatei-fehlt verletzt. Die genannte Datei $PFAD gibt es nicht."
  elif [ "$(stat -c %s -- "$ECHT" 2>/dev/null || echo 0)" -gt "$MAX_BERICHT_BYTES" ]; then
    zurueck "diagnosedatei-fehlt verletzt. $PFAD ist groesser als 1 MB, das ist kein Bericht mehr."
  elif [ -z "$MARKER_START" ]; then
    log "Marker ohne Startzeit, Aenderungszeit der Diagnosedatei nicht geprueft"
  elif [ "$(stat -c %Y -- "$ECHT" 2>/dev/null || echo 0)" -lt "$MARKER_START" ]; then
    zurueck "diagnosedatei-fehlt verletzt. $PFAD wurde vor dem Start dieser Diagnose zuletzt geaendert und ist damit kein aktueller Bericht."
  fi
fi
# Eigener Lesefehler: offen ausfallen wie bei allen Hookfehlern.
BERICHT_TEXT=$(cat -- "${ECHT:-$DATEI}" 2>/dev/null) || { log "Diagnosedatei nicht lesbar: $PFAD, durchgelassen"; durchlassen; }
UEBERGEHUNG_TEXT="$KURZ
$BERICHT_TEXT"

# R13: Kurzfassung ohne Rohdaten
KURZ_ZEILEN=$(printf '%s\n' "$KURZ" | grep -cvE '^[[:space:]]*$')
[ "$KURZ_ZEILEN" -le 30 ] || \
  zurueck "kurzfassung-mit-rohdaten verletzt. Die Kurzfassung hat $KURZ_ZEILEN Zeilen, erlaubt sind 30. Einzelheiten gehoeren in die Datei."
printf '%s\n' "$KURZ" | grep -qE '^[[:space:]]*([-*+][[:space:]]+)?\|' && \
  zurueck "kurzfassung-mit-rohdaten verletzt. Die Kurzfassung enthaelt eine Tabelle. Tabellen gehoeren in die Datei."
printf '%s\n' "$KURZ" | grep -qE '^([[:space:]]*(```|~~~|\$[[:space:]]|([-*+][[:space:]]+)?Befehl:)|    |'$'\t'')' && \
  zurueck "kurzfassung-mit-rohdaten verletzt. Die Kurzfassung enthaelt einen Codeblock oder eine Befehlszeile. Befehle und Ausgaben gehoeren in die Belege der Datei."

# R11: alle fuenf Stichworte am Zeilenanfang (Liste oder fett erlaubt), jeweils mit Inhalt
# in derselben oder der folgenden Zeile.
ENDE_MUSTER="${STICH}(Stand|Belegt|Offen|Vorschlag|Von dir|Bericht|Datei|Pfad)(\*\*)?:"
for feld in 'Stand' 'Belegt' 'Offen' 'Vorschlag' 'Von dir'; do
  printf '%s\n' "$KURZ" | grep -qiE "${STICH}${feld}(\*\*)?:" || \
    zurueck "kurzfassung-unvollstaendig verletzt. Die Kurzfassung hat keine Zeile, die mit '${feld}:' beginnt. Pflicht sind Stand:, Belegt:, Offen:, Vorschlag:, Von dir:."
  INHALT=$(printf '%s\n' "$KURZ" | awk -v feld="$feld" -v stich="$STICH" -v ende="$ENDE_MUSTER" '
    BEGIN { IGNORECASE = 1 }
    gefunden == 1 { if ($0 ~ /^[[:space:]]*$/) next; if ($0 ~ ende) exit; print; exit }
    $0 ~ (stich feld "(\\*\\*)?:") { gefunden = 1; rest = $0; sub(stich feld "(\\*\\*)?:(\\*\\*)?", "", rest)
      if (rest ~ /[^[:space:]]/) { print rest; exit } }')
  [ -n "$INHALT" ] || \
    zurueck "kurzfassung-unvollstaendig verletzt. '${feld}:' steht ohne erklaerenden Satz da."
done

# R12: jede Aussage unter Belegt traegt eine Belegnummer, die in der Datei als [B-n] steht.
# Eine Aussage beginnt mit einem Listenzeichen oder direkt hinter "Belegt:"; Folgezeilen ohne Listenzeichen gehoeren dazu.
AUSSAGEN=$(printf '%s\n' "$KURZ" | awk -v stich="$STICH" -v ende="$ENDE_MUSTER" '
  BEGIN { IGNORECASE = 1; aktiv = 0; n = 0 }
  $0 ~ (stich "Belegt(\\*\\*)?:") { aktiv = 1; rest = $0; sub(stich "Belegt(\\*\\*)?:(\\*\\*)?", "", rest)
    if (rest ~ /[^[:space:]]/) { n++; a[n] = rest }; next }
  aktiv == 1 && $0 ~ ende { aktiv = 0 }
  aktiv == 1 { if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^[[:space:]]*[-*+][[:space:]]+/ || n == 0) { n++; a[n] = $0 } else { a[n] = a[n] " " $0 } }
  END { for (i = 1; i <= n; i++) { gsub(/^[[:space:]]*([-*+][[:space:]]+)?|[[:space:]]+$/, "", a[i]); print a[i] } }')
ANZAHL_AUSSAGEN=$(printf '%s\n' "$AUSSAGEN" | grep -c .)
OHNE_NR=""; BELEG_REFS=""
while IFS= read -r aussage; do
  [ -z "$aussage" ] && continue
  # "Belegt: keine" heisst: in diesem Stand nichts gemessen. Nur als einzige Aussage.
  if [ "$ANZAHL_AUSSAGEN" = 1 ] && printf '%s' "$aussage" | grep -qiE '^keine\.?$'; then continue; fi
  if ! printf '%s' "$aussage" | grep -qE '\[B-[0-9]+\]'; then OHNE_NR="$aussage"; break; fi
  BELEG_REFS="$BELEG_REFS $(printf '%s' "$aussage" | grep -oE '\[B-[0-9]+\]' | tr -d '[]' | tr '\n' ' ')"
done <<< "$AUSSAGEN"
[ -z "$OHNE_NR" ] || \
  zurueck "beleg-nicht-in-datei verletzt. Aussage unter 'Belegt' ohne Belegnummer [B-n]: ${OHNE_NR:0:80}"
for ref in $BELEG_REFS; do
  printf '%s\n' "$BERICHT_TEXT" | grep -qE "^(#+[[:space:]]*)?\[$ref\]" || \
    zurueck "beleg-nicht-in-datei verletzt. [$ref] steht unter 'Belegt', aber nicht als Beleg in $PFAD."
done

# Ab hier gelten alle bisherigen Regeln fuer den Bericht in der Datei.
TEXT="$BERICHT_TEXT"
[ -n "$TEXT" ] || zurueck "kein-diagnosebericht: Die Datei $PFAD ist leer."
fi

# Traegt die Antwort ueberhaupt eine Phase-Zeile?
PHASE_ZEILEN=$(printf '%s' "$TEXT" | grep -ciE '^Phase:[[:space:]]*[ABC][[:space:]]*$')
if [ "$PHASE_ZEILEN" -gt 1 ]; then
  zurueck "mehrdeutige-phase: $PHASE_ZEILEN Zeilen 'Phase:' gefunden. Ein Bericht traegt genau eine Phase."
fi
# Kleinschreibung ist zulaessig und wird normalisiert.
PHASE=$(printf '%s' "$TEXT" | grep -oiE '^Phase:[[:space:]]*[ABC]' | head -1 \
        | grep -oiE '[ABC]$' | tr '[:lower:]' '[:upper:]')
if [ -z "$PHASE" ]; then
  zurueck "kein-diagnosebericht: Der Task ist als Diagnose markiert, die Antwort traegt aber keine Zeile 'Phase: A|B|C'."
fi

hat() { printf '%s' "$TEXT" | grep -qiE "$1"; }

# --- R1: Phase A darf keine Ursache enthalten ---
if [ "$PHASE" = "A" ] && hat '^#+[[:space:]]*(Ursache|Geschlossen):?[[:space:]]*$'; then
  zurueck "ursache-in-phase-a verletzt. Phase A darf keinen Abschnitt 'Ursache' oder 'Geschlossen' enthalten. Erst die Karte vorlegen."
fi

# --- R2: Phase A endet mit der Frage an den Auftraggeber ---
if [ "$PHASE" = "A" ]; then
  LETZTE=$(printf '%s' "$TEXT" | grep -vE '^[[:space:]]*$' | tail -1 | sed 's/[[:space:]]*$//')
  printf '%s' "$LETZTE" | grep -qiE 'Fehlt eine Stelle\?' || \
    zurueck "schlussfrage-fehlt verletzt. Letzte Zeile von Phase A muss 'Fehlt eine Stelle?' sein. Gefunden: '$LETZTE'"
fi

# --- R3: Jede Zeile unter Gemessen braucht [B-n], jedes [B-n] braucht einen Beleg ---
if hat '^#+[[:space:]]*Gemessen'; then
  GEMESSEN=$(printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Gemessen/,/^#\+[[:space:]]/p' | grep -E '^[[:space:]]*-[[:space:]]')
  while IFS= read -r zeile; do
    [ -z "$zeile" ] && continue
    printf '%s' "$zeile" | grep -qE '\[B-[0-9]+\]' || \
      zurueck "gemessen-ohne-beleg verletzt. Zeile unter 'Gemessen' ohne Belegverweis [B-n]: ${zeile:0:90}"
  done <<< "$GEMESSEN"
  # Jeder referenzierte Beleg muss existieren und Befehl plus Ausgabe tragen
  for ref in $(printf '%s' "$TEXT" | grep -oE '\[B-[0-9]+\]' | sort -u | tr -d '[]'); do
    BLOCK=$(printf '%s' "$TEXT" | sed -n "/^\[$ref\]/,/^\[B-/p")
    printf '%s' "$BLOCK" | grep -qi 'Befehl:' && printf '%s' "$BLOCK" | grep -qi 'Ausgabe:' || \
      zurueck "gemessen-ohne-beleg verletzt. Beleg [$ref] fehlt unter 'Belege' oder hat kein 'Befehl:' und 'Ausgabe:'."
  done
fi

# --- R4: Phase B braucht Karte-Freigabe, Phase C braucht gelungene Reproduktion ---
if [ "$PHASE" = "B" ] || [ "$PHASE" = "C" ]; then
  hat '^#+[[:space:]]*Karte-Freigabe' || \
    zurueck "reproduktion-fehlt verletzt. Phase $PHASE ohne Abschnitt 'Karte-Freigabe'. Die Karte muss vom Auftraggeber freigegeben sein."
  printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Karte-Freigabe/,/^#\+[[:space:]]/p' \
    | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || \
    zurueck "reproduktion-fehlt verletzt. 'Karte-Freigabe' ohne Datum im Format JJJJ-MM-TT."
fi
if [ "$PHASE" = "C" ]; then
  hat 'Ergebnis:[[:space:]]*reproduziert[[:space:]]+JA' || \
    zurueck "reproduktion-fehlt verletzt. Phase C ohne 'Ergebnis: reproduziert JA' aus Phase B. Reproduktion fehlt."
fi
# Reproduktion darf mehrere Versuche haben. Jeder Versuch mit NEIN braucht direkt danach
# eine Zeile 'Wenn NEIN:' mit Inhalt. Phase C ist frei, sobald ein Versuch JA hat und alle NEIN so
# dokumentiert sind.
if [ "$PHASE" = "B" ] || [ "$PHASE" = "C" ]; then
  NEIN_OHNE=$(printf '%s' "$TEXT" | grep -vE '^[[:space:]]*$' \
    | awk 'tolower($0) ~ /^ergebnis:[ \t]*reproduziert[ \t]+nein/ {warte=1; next}
           warte==1 { if (tolower($0) ~ /^wenn nein:[ \t]*[^ \t]/) {warte=0} else {print; warte=0} }
           END { if (warte==1) print "(Ende des Berichts)" }' | head -1)
  [ -z "$NEIN_OHNE" ] || \
    zurueck "reproduktion-fehlt verletzt. Ein Versuch mit 'reproduziert NEIN' ohne folgende Zeile 'Wenn NEIN: <was fehlt>'. Gefunden statt dessen: ${NEIN_OHNE:0:80}"
fi
# --- R9: jede Freigabe-Anfrage (Phase A und B) endet mit dem Block 'Naechste Phase' ---
if [ "$PHASE" = "A" ] || [ "$PHASE" = "B" ]; then
  NP=$(printf '%s' "$TEXT" | sed -n '/^\(#\+[[:space:]]*\)\?N[äa]e\?chste Phase:\?[[:space:]]*$/I,/^#\+[[:space:]]/p')
  [ -n "$NP" ] || \
    zurueck "naechste-phase-fehlt verletzt. Phase $PHASE ohne Block 'Nächste Phase:' mit den Zeilen 'Gemessen wird:', 'Nicht angefasst:' und 'Umfang:'."
  for feld in 'Gemessen wird:' 'Nicht angefasst:' 'Umfang:'; do
    printf '%s' "$NP" | grep -qiE "^${feld}[[:space:]]*[^[:space:]]" || \
      zurueck "naechste-phase-fehlt verletzt. Block 'Nächste Phase:' ohne ausgefuellte Zeile '${feld}'."
  done
fi

# --- R5: Der gemeldete Bezeichner muss in Eingabe und Gegenprobe 1 auftauchen ---
BEZ=$(printf '%s' "$TEXT" | grep -iE '^Bezeichner:' | head -1 | sed -E 's/^[Bb]ezeichner:[[:space:]]*//' | sed 's/[[:space:]]*$//')
if [ -z "$BEZ" ] || printf '%s' "$BEZ" | grep -qiE '^(FEHLT|<|\.\.\.)'; then
  [ "$PHASE" = "A" ] && hat '^Anforderung an den Auftraggeber:' || \
    zurueck "bezeichner-fehlt verletzt. Kein gemeldeter Fall unter 'Bezeichner'. Anforderung an den Auftraggeber stellen, bevor weitergearbeitet wird."
else
  if [ "$PHASE" = "B" ] || [ "$PHASE" = "C" ]; then
    printf '%s' "$TEXT" | grep -iE '^Eingabe:' | grep -qF "$BEZ" || \
      zurueck "bezeichner-fehlt verletzt. Der gemeldete Bezeichner '$BEZ' steht nicht woertlich unter 'Eingabe'."
  fi
  if [ "$PHASE" = "C" ]; then
    printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Gegenprobe/,/^#\+[[:space:]]/p' | grep -qF "$BEZ" || \
      zurueck "bezeichner-fehlt verletzt. Der gemeldete Bezeichner '$BEZ' fehlt in Gegenprobe 1. Genau diese Probe faengt eine Hypothese, die den gemeldeten Fall nicht trifft."
  fi
fi

# --- R8: Gegenprobe 1 mit Ergebnis NEIN heisst, die Hypothese trifft den gemeldeten Fall nicht ---
if [ "$PHASE" = "C" ]; then
  GP1=$(printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Gegenprobe/,/^#\+[[:space:]]/p' \
        | sed -n '/^[[:space:]]*1\./,/^[[:space:]]*2\./p' | grep -vE '^[[:space:]]*2\.')
  if printf '%s' "$GP1" | grep -qE '(Ergebnis:[[:space:]]*NEIN|\bNEIN\b)' \
     && ! printf '%s' "$GP1" | grep -qE '(Ergebnis:[[:space:]]*JA|\bJA\b)'; then
    zurueck "gegenprobe-nein verletzt. Gegenprobe 1 ergibt NEIN: der gemeldete Fall liegt nicht im eigenen Filter. Die Hypothese erklaert den Fall nicht und darf nicht als Ursache vorgelegt werden."
  fi
fi

# --- R6: Geschlossen braucht einen pruefbaren Filter ---
if hat '^#+[[:space:]]*Geschlossen'; then
  printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Geschlossen/,/^#\+[[:space:]]/p' \
    | grep -qiE '^Filter:' || \
    zurueck "filter-fehlt verletzt. 'Geschlossen' ohne Zeile, die mit 'Filter:' beginnt. Die Hypothese muss als pruefbare Menge formuliert sein."
fi

# --- R7: Phase C braucht die unabhaengige Pruefung ---
if [ "$PHASE" = "C" ]; then
  hat '^#+[[:space:]]*Unabhängige Prüfung' || hat '^#+[[:space:]]*Unabhaengige Pruefung' || \
    zurueck "unabhaengige-pruefung-fehlt verletzt. Phase C ohne Abschnitt 'Unabhängige Prüfung'."
  printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Unabh/,/^#\+[[:space:]]/p' | grep -qiE '^Urteil:' || \
    zurueck "unabhaengige-pruefung-fehlt verletzt. 'Unabhängige Prüfung' ohne Zeile 'Urteil:'."
fi

log "PASS Phase=$PHASE"
zaehler_setzen 0

# Marker-Pflege (wer schreibt, deklariert Ziel und Lebensdauer).
# Ziel: die Marker-Datei. Lebensdauer: 24 Stunden ab der letzten durchgelassenen Phase.
# Ende: Phase C mit ausgefuellter Entscheidung des Auftraggebers.
ENTSCHEIDUNG=$(printf '%s' "$TEXT" | sed -n '/^#\+[[:space:]]*Entscheidung des Auftraggebers/,/^#\+[[:space:]]/p' \
               | grep -vE '^#|^[[:space:]]*$|^<leer' | head -1)
if [ "$PHASE" = "C" ] && [ -n "$ENTSCHEIDUNG" ]; then
  rm -f "$MARKER" && log "MARKER entfernt, Diagnose abgeschlossen"
else
  marker_schreiben && log "MARKER verlaengert"
fi
exit 0
