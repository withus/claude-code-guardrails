#!/usr/bin/env bash
# Mutationsproben fuer geheimnis-gate.py. Kopie mit eingebautem Fehler, die Suite muss die genannten Faelle rot melden.
# Aufruf: bash gates/tests/geheimnis-gate.mutations.sh (im Repository)
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKRIPT="$GUARDRAILS_DIR/gates/geheimnis-gate.py"
TEST="$GUARDRAILS_DIR/gates/tests/geheimnis-gate.test.sh"
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
mutation "maske-ersetzt-nichts" "formfeld-type-bleibt-unveraendert zitierter-wert-mit-leerzeichen-ganz-maskiert passwort-in-bash-ausgabe-wird-maskiert form-der-ausgabe-bleibt-erhalten token-zeile-wird-maskiert passwort-im-fliesstext-wird-maskiert verschachtelte-agentenantwort-wird-maskiert read-ausgabe-wird-maskiert-zahl-bleibt-zahl" \
  's/            text = text\.replace(wert, ERSATZ)/            text = text/'
mutation "fliesstext-passwort-ignoriert" "passwort-im-fliesstext-wird-maskiert" 's/        for f in FLIESSTEXT\.finditer(zeile):/        for f in []:/'
mutation "kurze-werte-als-teiltext" "kurzer-wert-nur-als-ganzes-wort-maskiert" 's/^MIN_LAENGE_TEILTEXT = 6/MIN_LAENGE_TEILTEXT = 0/'
mutation "form-geht-verloren" "formfeld-type-bleibt-unveraendert label-key-nur-als-eigenes-wort zitierter-wert-mit-leerzeichen-ganz-maskiert ausgabe-ohne-geheimnis-bleibt-unberuehrt passwort-in-bash-ausgabe-wird-maskiert form-der-ausgabe-bleibt-erhalten token-zeile-wird-maskiert passwort-im-fliesstext-wird-maskiert kurzer-wert-nur-als-ganzes-wort-maskiert verschachtelte-agentenantwort-wird-maskiert read-ausgabe-wird-maskiert-zahl-bleibt-zahl" \
  's/    neu = maskiere(antwort, werte)/    neu = maskiere(json.dumps(antwort), werte)/'
mutation "fehlende-quelle-still" "fehlende-quelle-meldet-sich-statt-still nicht-utf8-quelle-meldet-sich-statt-abbruch" '/"systemMessage": "Geheimnis-Gate: servers.md nicht lesbar/d'
mutation "bash-sperre-aus" "bash-cat-servers-md-gesperrt bash-awk-servers-md-gesperrt bash-python-open-servers-md-gesperrt bash-umleitung-aus-servers-md-gesperrt bash-grep-l-mit-weiterleitung-gesperrt" \
  's/    if werkzeug == "Bash":/    if False:/'
mutation "grep-l-ausnahme-auch-mit-weiterleitung" "bash-grep-l-mit-weiterleitung-gesperrt" \
  's/        if BASH_NUR_NAMEN\.match(befehl) and not re\.search(r"\[|;&\]", befehl):/        if BASH_NUR_NAMEN.match(befehl):/'
mutation "umleitung-nicht-erkannt" "bash-umleitung-aus-servers-md-gesperrt" \
  's/        return bool(BASH_LESEND\.search(befehl)) or bool(re\.search(r"<\\s\*\\S\*servers\\\.md", befehl, re\.I))/        return bool(BASH_LESEND.search(befehl))/'
mutation "dateiwerkzeuge-ungesperrt" "read-auf-servers-md-gesperrt edit-auf-servers-md-gesperrt" 's/    if werkzeug in DATEI_WERKZEUGE:/    if False:/'
mutation "grep-werkzeug-ungesperrt" "grep-werkzeug-auf-servers-md-gesperrt" 's/    if werkzeug in ("Grep", "Glob"):/    if False:/'
mutation "label-key-ohne-wortgrenze" "label-key-nur-als-eigenes-wort" 's/\[^:|\]{0,30}?(?<!\[A-Za-z\])(pass/[^:|]{0,30}?(pass/'
mutation "zitat-nur-erstes-wort" "zitierter-wert-mit-leerzeichen-ganz-maskiert" 's/            elif zitiert:/            elif False:/'
mutation "formfelder-werden-maskiert" "formfeld-type-bleibt-unveraendert" 's/^FORMFELDER = {.*}/FORMFELDER = set()/'
mutation "nicht-utf8-bricht-ab" "nicht-utf8-quelle-meldet-sich-statt-abbruch" 's/    except (OSError, ValueError) as exc:/    except OSError as exc:/'
mutation "leere-quelle-still" "leere-quelle-meldet-sich-statt-still" 's/    if not werte:/    if False:/'
echo; if [ "$gesamt" -eq 0 ]; then echo "Alle Mutationen von der Suite gefangen."; exit 0; else echo "$gesamt Mutationsproben fehlgeschlagen."; exit 1; fi
