#!/usr/bin/env bash
# Mutationsproben fuer freigabe-gate.py. Kopie mit eingebautem Fehler, die Suite muss genau die genannten Faelle rot melden.
# Aufruf: bash gates/tests/freigabe-gate.mutations.sh (im Repository)
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKRIPT="$GUARDRAILS_DIR/gates/freigabe-gate.py"
TEST="$GUARDRAILS_DIR/gates/tests/freigabe-gate.test.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; gesamt=0
ausgang=$(bash "$TEST" "$SKRIPT" 2>/dev/null | tail -1)
case "$ausgang" in "Alle "*) echo "Ausgangslage gruen: $ausgang";; *) echo "FEHL Ausgangslage nicht gruen: $ausgang"; exit 1;; esac
mutation() { local name="$1" erwartet="$2" ausdruck="$3"
  local kopie="$TMP/$name.py"
  sed -e "$ausdruck" "$SKRIPT" > "$kopie"
  if cmp -s "$SKRIPT" "$kopie"; then printf '  FEHL  %-52s Mutation hat nichts veraendert\n' "$name"; gesamt=$((gesamt+1)); return; fi
  local rot; rot=$(bash "$TEST" "$kopie" 2>/dev/null | grep -E '^  FEHL' | sed -E 's/^  FEHL +[0-9]+ ([^ ]+).*/\1/' | sort -u | tr '\n' ' ')
  printf '  %-54s rot: %s\n' "$name" "${rot:-KEINER}"
  for f in $erwartet; do printf ' %s ' "$rot" | grep -q " $f " || { printf '  FEHL  %-52s Fall %s blieb gruen\n' "$name" "$f"; gesamt=$((gesamt+1)); }; done
  for f in $rot; do printf ' %s ' "$erwartet" | grep -q " $f " || { printf '  FEHL  %-52s unerwartet rot: %s\n' "$name" "$f"; gesamt=$((gesamt+1)); }; done
}
echo "Mutationsproben gegen $SKRIPT"; echo
mutation "check-nicht-mehr-lesend" "deploy-check-auch-mit-yes-ist-frei" 's/^NUR_LESEND = re\.compile(r"(^|\\s)--(check|dry-run)\\b")/NUR_LESEND = re.compile(r"(^|\\s)--(dry-run)\\b")/'
mutation "antwort-nicht-geprueft" "deploy-mit-yes-nach-nein-gesperrt spaeteres-nein-nimmt-ja-zurueck" 's/                                freigegeben = bool(ANTWORT_JA\.match(m\.group(1)))/                                freigegeben = True/'
mutation "stichwort-nicht-geprueft" "deploy-und-db-in-einem-befehl-beide-geprueft ja-auf-frage-ohne-stichwort-gibt-nicht-frei db-freigabe-deckt-keinen-deploy deploy-freigabe-deckt-kein-db-schreiben" 's/ if isinstance(f, str) and stichwort\.search(f)\]/ if isinstance(f, str)]/'
mutation "neue-eingabe-setzt-nicht-zurueck" "freigabe-verfaellt-mit-neuer-eingabe" 's/^                    freigegeben = False$/                    pass/'
mutation "systemhinweis-setzt-zurueck" "systemhinweis-laesst-freigabe-bestehen" 's/            elif d\.get("type") == "user" and not d\.get("isMeta") and not d\.get("isCompactSummary"):/            elif d.get("type") == "user":/'
mutation "fehlender-verlauf-gibt-frei" "fehlender-verlauf-gibt-nicht-frei" '/    if not transcript_pfad or not os\.path\.isfile(transcript_pfad):/{n;s/        return False/        return True/}'
mutation "ssh-nicht-als-fremd-erkannt" "update-ueber-ssh-gesperrt deploy-freigabe-deckt-kein-db-schreiben deploy-und-db-in-einem-befehl-beide-geprueft" 's/    if re\.search(r"\\bssh\\b", teil):/    if False:/'
mutation "docker-exec-nicht-ausgenommen" "update-in-docker-exec-mit-containerhost-frei" 's/    if re\.search(r"\\bdocker\\s+exec\\b", teil):/    if False:/'
mutation "lokale-hosts-nicht-ausgenommen" "update-auf-127-0-0-1-frei" 's/^LOKALE_HOSTS = .*/LOKALE_HOSTS = set()/'
mutation "lesende-sql-formen-nicht-ausgenommen" "show-create-auf-fremdem-host-frei" 's/DB_SCHREIBEND\.search(DB_LESEND_AUSNAHMEN\.sub(" ", teil))/DB_SCHREIBEND.search(teil)/'
mutation "sperre-ohne-log" "sperre-wird-geloggt" 's/    log("%s gesperrt agent=%s" % (regel, agent))/    pass/'
mutation "spaeteres-nein-ignoriert" "spaeteres-nein-nimmt-ja-zurueck" 's/                                freigegeben = bool(ANTWORT_JA\.match(m\.group(1)))/                                freigegeben = freigegeben or bool(ANTWORT_JA.match(m.group(1)))/'
mutation "befehlsteile-nicht-getrennt" "check-in-anderem-befehlsteil-hebt-sperre-nicht-auf docker-exec-in-anderem-befehlsteil-hebt-sperre-nicht-auf" 's/    return \[t for t in BEFEHLSTRENNER\.split(befehl) if t\.strip()\]/    return [befehl]/'
mutation "nur-deploy-ordner-erkannt" "relativer-deploy-pfad-gesperrt" 's#r"(\\bdeploy\\\.py#r"(/deploy/[^/ ]+/deploy\\.py#'
mutation "sql-aus-datei-nicht-erkannt" "sql-aus-datei-auf-fremdem-host-gesperrt" 's/ or SQL_AUS_DATEI\.search(teil))/)/'
mutation "load-data-nicht-erkannt" "load-data-auf-fremdem-host-gesperrt" 's/|\\bload\\s+data\\b|"/|"/'
mutation "eingabe-ohne-objekt-bricht-ab" "eingabe-ohne-objekt-bricht-nicht-ab" 's/    if not isinstance(eingabe, dict) or eingabe\.get("tool_name") != "Bash":/    if eingabe.get("tool_name") != "Bash":/'
mutation "nur-erste-regel-geprueft" "deploy-und-db-in-einem-befehl-beide-geprueft" 's/^            continue$/            return 0/'
echo; if [ "$gesamt" -eq 0 ]; then echo "Alle Mutationen von der Suite gefangen."; exit 0; else echo "$gesamt Mutationsproben fehlgeschlagen."; exit 1; fi
