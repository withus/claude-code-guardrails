#!/usr/bin/env bash
# Testfaelle fuer geheimnis-gate.py. Erfundene servers.md im Temp, echte Werte nie.
# Aufruf: bash gates/tests/geheimnis-gate.test.sh [pfad/zu/geheimnis-gate.py] (im Repository)

GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GATE="${1:-$GUARDRAILS_DIR/gates/geheimnis-gate.py}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export AGENTS_STATE_DIR="$TMP/state" GEHEIMNIS_LOG="$TMP/state/geheimnis.log" GEHEIMNIS_QUELLE="$TMP/servers.md"
mkdir -p "$AGENTS_STATE_DIR"
cat > "$GEHEIMNIS_QUELLE" <<'EOF'
# Server-Zugaenge
## SFTP Testhost
- **Host:** test.example.org
- **User:** testnutzer
- **Passwort:** `Lang3sGeheim!`
## API
- **API-Key:** tok_FAKE0815TESTWERT
## Kurz
- **Pass:** ab12
## Notiz
Das Passwort fuer den Router ist "RouterWort99", bitte nicht weitergeben.
## Zitat
- **Passwort:** "Alpha Beta"
## Obst
- Monkey: bananenbrot
## Formwert
- **PW:** text
EOF

ECHT_STATE="$HOME/.claude/state"
echte_ziele() { find "$ECHT_STATE" -maxdepth 1 -name 'geheimnis-gate*' -type f 2>/dev/null | sort | xargs -r sha256sum | sha256sum | cut -c1-16; }
ZIELE_VORHER=$(echte_ziele)
fehler=0; nr=0
ok()   { printf '  OK    %2d %-58s %s\n' "$nr" "$1" "$2"; }
fehl() { printf '  FEHL  %2d %-58s %s\n' "$nr" "$1" "$2"; fehler=$((fehler+1)); }

maske() { local out rc; out=$(printf '%s' "$1" | python3 "$GATE" maske 2>/dev/null); rc=$?; [ "$rc" -ne 0 ] && { printf 'HOOK-ABBRUCH-%s' "$rc"; return; }; printf '%s' "$out"; }
# PostToolUse-Eingabe mit Bash-Antwort
bash_antwort() { jq -cn --arg o "$1" '{tool_name:"Bash", tool_response:{stdout:$o, stderr:"", interrupted:false, isImage:false}}'; }
sperre() { # werkzeug tool_input-json -> GESPERRT | FREI
  local out rc; out=$(jq -cn --arg w "$1" --argjson i "$2" '{tool_name:$w, tool_input:$i}' | python3 "$GATE" sperre 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && { printf 'HOOK-ABBRUCH-%s' "$rc"; return; }
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then printf 'GESPERRT'; else printf 'FREI'; fi
}
pruefe_sperre() { nr=$((nr+1)); local ist; ist=$(sperre "$3" "$4"); if [ "$ist" = "$2" ]; then ok "$1" "$ist"; else fehl "$1" "erwartet=$2 ist=$ist"; fi; }
pruefe_wert() { nr=$((nr+1)); if [ "$3" = "$2" ]; then ok "$1" "$3"; else fehl "$1" "erwartet=$2 ist=$3"; fi; }

echo "Geheimnis-Gate, Testlauf gegen $GATE"
echo
echo "A) Maske (PostToolUse)"
out=$(maske "$(bash_antwort 'Login mit Lang3sGeheim! ok')")
pruefe_wert "passwort-in-bash-ausgabe-wird-maskiert" "Login mit [maskiert] ok" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
pruefe_wert "form-der-ausgabe-bleibt-erhalten" "interrupted,isImage,stderr,stdout false" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput | (keys|join(",")) + " " + (.interrupted|tostring)')"
pruefe_wert "ausgabe-ohne-geheimnis-bleibt-unberuehrt" "" "$(maske "$(bash_antwort 'nur test.example.org und testnutzer')")"
out=$(maske "$(bash_antwort 'key=tok_FAKE0815TESTWERT')")
pruefe_wert "token-zeile-wird-maskiert" "key=[maskiert]" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
out=$(maske "$(bash_antwort 'router: RouterWort99')")
pruefe_wert "passwort-im-fliesstext-wird-maskiert" "router: [maskiert]" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
out=$(maske "$(bash_antwort 'pw ab12 und xab12y')")
pruefe_wert "kurzer-wert-nur-als-ganzes-wort-maskiert" "pw [maskiert] und xab12y" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
out=$(maske "$(jq -cn '{tool_name:"Agent", agent_type:"general-purpose", tool_response:{status:"completed", content:[{type:"text", text:"Bericht: Passwort ist Lang3sGeheim!"}]}}')")
pruefe_wert "verschachtelte-agentenantwort-wird-maskiert" "Bericht: Passwort ist [maskiert]" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text')"
out=$(maske "$(jq -cn '{tool_name:"Read", tool_response:{type:"text", file:{filePath:"/x", content:"1\tLang3sGeheim!", numLines:1}}}')")
pruefe_wert "read-ausgabe-wird-maskiert-zahl-bleibt-zahl" "1	[maskiert] 1" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.file | .content + " " + (.numLines|tostring)')"
out=$(GEHEIMNIS_QUELLE="$TMP/gibt-es-nicht.md" maske "$(bash_antwort 'Lang3sGeheim!')")
pruefe_wert "fehlende-quelle-meldet-sich-statt-still" "ja" "$(printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1 && echo ja || echo nein)"
out=$(maske "$(bash_antwort 'x Alpha Beta y')")
pruefe_wert "zitierter-wert-mit-leerzeichen-ganz-maskiert" "x [maskiert] y" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
pruefe_wert "label-key-nur-als-eigenes-wort" "" "$(maske "$(bash_antwort 'Rezept bananenbrot')")"
out=$(maske "$(jq -cn '{tool_name:"Read", tool_response:{type:"text", file:{filePath:"/x", content:"text Lang3sGeheim!", numLines:1}}}')")
pruefe_wert "formfeld-type-bleibt-unveraendert" "text [maskiert] [maskiert]" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput | .type + " " + .file.content')"
printf 'Passwort: \xff\xfe kaputt\n' > "$TMP/nicht-utf8.md"
out=$(GEHEIMNIS_QUELLE="$TMP/nicht-utf8.md" maske "$(bash_antwort 'irgendwas')")
pruefe_wert "nicht-utf8-quelle-meldet-sich-statt-abbruch" "ja" "$(printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1 && echo ja || echo nein)"
: > "$TMP/leer.md"
out=$(GEHEIMNIS_QUELLE="$TMP/leer.md" maske "$(bash_antwort 'irgendwas')")
pruefe_wert "leere-quelle-meldet-sich-statt-still" "ja" "$(printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1 && echo ja || echo nein)"
nr=$((nr+1))
if grep -qE 'Lang3sGeheim|tok_ABCDEF|RouterWort|ab12' "$GEHEIMNIS_LOG" 2>/dev/null; then fehl "log-enthaelt-keinen-wert" "Wert im Log"
elif grep -q 'geheimnis-maskiert' "$GEHEIMNIS_LOG" 2>/dev/null; then ok "log-enthaelt-keinen-wert" "nur Anzahl und Werkzeug"
else fehl "log-enthaelt-keinen-wert" "kein Log-Eintrag"; fi

echo
echo "B) Sperre (PreToolUse)"
S='/srv/beispiel/.claude/servers.md'
pruefe_sperre "read-auf-servers-md-gesperrt" GESPERRT Read "$(jq -cn --arg p "$S" '{file_path:$p}')"
pruefe_sperre "read-auf-andere-datei-frei" FREI Read '{"file_path":"/srv/beispiel/.claude/MEMORY.md"}'
pruefe_sperre "edit-auf-servers-md-gesperrt" GESPERRT Edit "$(jq -cn --arg p "$S" '{file_path:$p, old_string:"a", new_string:"b"}')"
pruefe_sperre "grep-werkzeug-auf-servers-md-gesperrt" GESPERRT Grep "$(jq -cn --arg p "$S" '{pattern:"Pass", path:$p}')"
pruefe_sperre "grep-werkzeug-nach-dem-wort-servers-md-frei" FREI Grep '{"pattern":"servers.md","path":"/srv/beispiel/.claude/agents"}'
pruefe_sperre "bash-cat-servers-md-gesperrt" GESPERRT Bash "$(jq -cn --arg p "$S" '{command:("cat " + $p)}')"
pruefe_sperre "bash-awk-servers-md-gesperrt" GESPERRT Bash "$(jq -cn --arg p "$S" '{command:("awk \"/Pass/{print $NF}\" " + $p)}')"
PY_BEFEHL="python3 -c \"print(open('/srv/x/servers.md').read())\""
pruefe_sperre "bash-python-open-servers-md-gesperrt" GESPERRT Bash "$(jq -cn --arg c "$PY_BEFEHL" '{command:$c}')"
pruefe_sperre "bash-umleitung-aus-servers-md-gesperrt" GESPERRT Bash '{"command":"while read z; do echo $z; done < ~/.claude/servers.md"}'
PASS_BEFEHL="sshpass -p \"\$(python3 ~/.claude/lib/zugang_lesen.py 'SFTP Test')\" ssh u@h ls"
pruefe_sperre "bash-servers-pass-im-befehl-frei" FREI Bash "$(jq -cn --arg c "$PASS_BEFEHL" '{command:$c}')"
pruefe_sperre "bash-grep-l-nach-verweisen-frei" FREI Bash '{"command":"grep -rln servers.md ~/.claude/agents"}'
pruefe_sperre "bash-grep-l-mit-weiterleitung-gesperrt" GESPERRT Bash '{"command":"grep -l servers.md ~/.claude/memory/* | xargs cat"}'
pruefe_sperre "agent-briefing-mit-servers-md-frei" FREI Agent '{"prompt":"servers.md NICHT lesen","description":"x"}'

echo
nr=$((nr+1))
if [ "$(echte_ziele)" = "$ZIELE_VORHER" ]; then ok "unberuehrt-echter-zustandsordner" "gleich"; else fehl "unberuehrt-echter-zustandsordner" "veraendert"; fi
echo
if [ "$fehler" -eq 0 ]; then echo "Alle $nr Faelle bestanden."; exit 0; else echo "$fehler von $nr Faellen fehlgeschlagen."; exit 1; fi
