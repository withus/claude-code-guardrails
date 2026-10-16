#!/usr/bin/env bash
# Testfaelle fuer freigabe-gate.py. Verlaeufe werden im Temp gebaut.
# Aufruf: bash gates/tests/freigabe-gate.test.sh [pfad/zu/freigabe-gate.py] (im Repository)

GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GATE="${1:-$GUARDRAILS_DIR/gates/freigabe-gate.py}"
TMP=$(mktemp -d) || { echo "FEHL mktemp"; exit 1; }; trap 'rm -rf "$TMP"' EXIT
export AGENTS_STATE_DIR="$TMP/state" FREIGABE_LOG="$TMP/state/freigabe.log"
mkdir -p "$AGENTS_STATE_DIR"
ECHT_STATE="$HOME/.claude/state"
echte_ziele() { find "$ECHT_STATE" -maxdepth 1 -name 'freigabe-gate*' -type f 2>/dev/null | sort | xargs -r sha256sum | sha256sum | cut -c1-16; }
ZIELE_VORHER=$(echte_ziele)
fehler=0; nr=0
ok()   { printf '  OK    %2d %-58s %s\n' "$nr" "$1" "$2"; }
fehl() { printf '  FEHL  %2d %-58s %s\n' "$nr" "$1" "$2"; fehler=$((fehler+1)); }

# Verlaufszeilen
eingabe()  { jq -cn --arg t "$1" '{type:"user", message:{role:"user", content:$t}}'; }
meta()     { jq -cn --arg t "$1" '{type:"user", isMeta:true, message:{role:"user", content:[{type:"text", text:$t}]}}'; }
frage()    { jq -cn --arg id "$1" --arg q "$2" '{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:"AskUserQuestion", input:{questions:[{question:$q}]}}]}}'; }
antwort()  { jq -cn --arg id "$1" --arg q "$2" --arg a "$3" '{type:"user", message:{content:[{type:"tool_result", tool_use_id:$id, content:("Your questions have been answered: \"" + $q + "\"=\"" + $a + "\". You can now continue.")}]}}'; }
verlauf()  { local f="$TMP/verlauf-$1.jsonl"; shift; : > "$f"; for z in "$@"; do printf '%s\n' "$z" >> "$f"; done; printf '%s' "$f"; }

lauf() { # befehl verlauf [werkzeug] -> FREI | regelname | HOOK-ABBRUCH-n
  local out rc; out=$(jq -cn --arg c "$1" --arg t "$2" --arg w "${3:-Bash}" '{tool_name:$w, tool_input:{command:$c}, transcript_path:$t}' | python3 "$GATE" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && { printf 'HOOK-ABBRUCH-%s' "$rc"; return; }
  if [ -z "$out" ]; then printf 'FREI'; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -oE '(deploy-ohne-freigabe|db-schreiben-ohne-freigabe)' | head -1; fi
}
pruefe() { nr=$((nr+1)); local ist; ist=$(lauf "$3" "$4" "${5:-Bash}"); if [ "$ist" = "$2" ]; then ok "$1" "$ist"; else fehl "$1" "erwartet=$2 ist=$ist"; fi; }

DQ='Deploy von product.php nach Live, Rollback per --rollback. Freigabe?'
BQ='Darf ich in die Datenbank schreiben (UPDATE orders, Backup liegt vor)?'
LEER=$(verlauf leer "$(eingabe 'deploy bitte vorbereiten')")
DEPLOY_JA=$(verlauf deploy-ja "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")" "$(antwort t1 "$DQ" 'Ja, deployen (Recommended)')")
DEPLOY_NEIN=$(verlauf deploy-nein "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")" "$(antwort t1 "$DQ" 'Nein, erst morgen')")
OHNE_STICHWORT=$(verlauf ohne-stichwort "$(eingabe 'mach weiter')" "$(frage t1 'Weiter mit Teil zwei?')" "$(antwort t1 'Weiter mit Teil zwei?' 'Ja')")
VERFALLEN=$(verlauf verfallen "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")" "$(antwort t1 "$DQ" 'Ja, deployen')" "$(eingabe 'und jetzt noch die zweite Datei')")
META_DANACH=$(verlauf meta-danach "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")" "$(antwort t1 "$DQ" 'Ja, deployen')" "$(meta 'Systemhinweis')")
DB_JA=$(verlauf db-ja "$(eingabe 'mach weiter')" "$(frage t2 "$BQ")" "$(antwort t2 "$BQ" 'Ja, schreiben')")
JA_DANN_NEIN=$(verlauf ja-dann-nein "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")" "$(antwort t1 "$DQ" 'Ja, deployen')" "$(frage t3 "$DQ")" "$(antwort t3 "$DQ" 'Nein, doch nicht')")
KAPUTT=$(verlauf kaputt "$(eingabe 'mach weiter')" '{"type":"assistant","message":{"content":[1,"x",null]}}' '{"type":"user","message":"kein objekt"}' '[1,2]' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":"kein array"}}]}}')
UNBEANTWORTET=$(verlauf unbeantwortet "$(eingabe 'mach weiter')" "$(frage t1 "$DQ")")

TS='python3 /opt/deploy/shop/deploy.py --target production'
echo "Freigabe-Gate, Testlauf gegen $GATE"
echo
echo "A) Deploy (Regel deploy-ohne-freigabe)"
pruefe "deploy-check-auch-mit-yes-ist-frei" FREI "$TS --check --yes a.php" "$LEER"
pruefe "deploy-dry-run-auch-mit-yes-ist-frei" FREI "$TS --dry-run --yes a.php" "$LEER"
pruefe "deploy-ohne-yes-fragt-selbst-und-ist-frei" FREI "$TS a.php" "$LEER"
pruefe "deploy-mit-yes-ohne-frage-gesperrt" deploy-ohne-freigabe "$TS --yes a.php" "$LEER"
pruefe "deploy-mit-yes-nach-ja-frei" FREI "$TS --yes a.php" "$DEPLOY_JA"
pruefe "deploy-mit-yes-nach-nein-gesperrt" deploy-ohne-freigabe "$TS --yes a.php" "$DEPLOY_NEIN"
pruefe "ja-auf-frage-ohne-stichwort-gibt-nicht-frei" deploy-ohne-freigabe "$TS --yes a.php" "$OHNE_STICHWORT"
pruefe "unbeantwortete-frage-gibt-nicht-frei" deploy-ohne-freigabe "$TS --yes a.php" "$UNBEANTWORTET"
pruefe "freigabe-verfaellt-mit-neuer-eingabe" deploy-ohne-freigabe "$TS --yes a.php" "$VERFALLEN"
pruefe "systemhinweis-laesst-freigabe-bestehen" FREI "$TS --yes a.php" "$META_DANACH"
pruefe "rollback-mit-yes-ohne-frage-gesperrt" deploy-ohne-freigabe "$TS --rollback /x/protokoll.json --yes" "$LEER"
pruefe "fehlender-verlauf-gibt-nicht-frei" deploy-ohne-freigabe "$TS --yes a.php" "$TMP/gibt-es-nicht.jsonl"
pruefe "sftp-deploy-modul-mit-yes-gesperrt" deploy-ohne-freigabe "cd /opt/deploy/lib && python3 -m sftp_deploy --target x --yes a" "$LEER"
pruefe "spaeteres-nein-nimmt-ja-zurueck" deploy-ohne-freigabe "$TS --yes a.php" "$JA_DANN_NEIN"
pruefe "check-in-anderem-befehlsteil-hebt-sperre-nicht-auf" deploy-ohne-freigabe "echo --check; $TS --yes a.php" "$LEER"
pruefe "relativer-deploy-pfad-gesperrt" deploy-ohne-freigabe "cd /opt/deploy/shop && python3 ./deploy.py --target production --yes a.php" "$LEER"
pruefe "unerwarteter-verlaufsaufbau-bricht-nicht-ab" deploy-ohne-freigabe "$TS --yes a.php" "$KAPUTT"
pruefe "db-freigabe-deckt-keinen-deploy" deploy-ohne-freigabe "$TS --yes a.php" "$DB_JA"

echo
echo "B) Datenbank (Regel db-schreiben-ohne-freigabe)"
pruefe "update-ueber-ssh-gesperrt" db-schreiben-ohne-freigabe "ssh u@h \"mysql shop -e 'UPDATE orders SET status=1'\"" "$LEER"
pruefe "insert-auf-fremdem-host-gesperrt" db-schreiben-ohne-freigabe "mysql -h db.example.org shop -e \"INSERT INTO t VALUES (1)\"" "$LEER"
pruefe "host-mit-langer-option-gesperrt" db-schreiben-ohne-freigabe "mysql --host=db.example.org shop -e 'DELETE FROM t'" "$LEER"
pruefe "update-lokal-ohne-host-frei" FREI "mysql shop -e 'UPDATE t SET a=1'" "$LEER"
pruefe "update-auf-127-0-0-1-frei" FREI "mysql -h 127.0.0.1 shop -e 'UPDATE t SET a=1'" "$LEER"
pruefe "update-in-docker-exec-mit-containerhost-frei" FREI "docker exec app mysql -h db shop -e 'UPDATE t SET a=1'" "$LEER"
pruefe "select-ueber-ssh-frei" FREI "ssh u@h \"mysql shop -e 'SELECT id FROM orders LIMIT 5'\"" "$LEER"
pruefe "show-create-auf-fremdem-host-frei" FREI "mysql -h db.example.org shop -e 'SHOW CREATE TABLE orders'" "$LEER"
pruefe "mysqldump-auf-fremdem-host-frei" FREI "mysqldump -h db.example.org shop orders > /tmp/x.sql" "$LEER"
pruefe "schreiben-nach-ja-zur-datenbank-frei" FREI "ssh u@h \"mysql shop -e 'UPDATE orders SET status=1'\"" "$DB_JA"
pruefe "deploy-freigabe-deckt-kein-db-schreiben" db-schreiben-ohne-freigabe "ssh u@h \"mysql shop -e 'UPDATE orders SET status=1'\"" "$DEPLOY_JA"
pruefe "deploy-und-db-in-einem-befehl-beide-geprueft" db-schreiben-ohne-freigabe "$TS --yes a.php && ssh u@h \"mysql shop -e 'UPDATE t SET a=1'\"" "$DEPLOY_JA"
pruefe "docker-exec-in-anderem-befehlsteil-hebt-sperre-nicht-auf" db-schreiben-ohne-freigabe "docker exec app ls; mysql -h db.example.org shop -e 'UPDATE t SET a=1'" "$LEER"
pruefe "sql-aus-datei-auf-fremdem-host-gesperrt" db-schreiben-ohne-freigabe "mysql -h db.example.org shop < migration.sql" "$LEER"
pruefe "load-data-auf-fremdem-host-gesperrt" db-schreiben-ohne-freigabe "mysql -h db.example.org shop -e \"LOAD DATA INFILE '/tmp/x' INTO TABLE t\"" "$LEER"
pruefe "anderes-werkzeug-bleibt-frei" FREI "$TS --yes a.php" "$LEER" Read

echo
nr=$((nr+1))
out=$(printf '[]' | python3 "$GATE" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then ok "eingabe-ohne-objekt-bricht-nicht-ab" "rc=0"; else fehl "eingabe-ohne-objekt-bricht-nicht-ab" "rc=$rc"; fi
nr=$((nr+1))
if grep -q 'deploy-ohne-freigabe gesperrt' "$FREIGABE_LOG" 2>/dev/null; then ok "sperre-wird-geloggt" "ja"; else fehl "sperre-wird-geloggt" "kein Eintrag"; fi
nr=$((nr+1))
if [ "$(echte_ziele)" = "$ZIELE_VORHER" ]; then ok "unberuehrt-echter-zustandsordner" "gleich"; else fehl "unberuehrt-echter-zustandsordner" "veraendert"; fi
echo
if [ "$fehler" -eq 0 ]; then echo "Alle $nr Faelle bestanden."; exit 0; else echo "$fehler von $nr Faellen fehlgeschlagen."; exit 1; fi
