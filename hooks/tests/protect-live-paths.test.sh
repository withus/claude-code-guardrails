#!/usr/bin/env bash
# Testfaelle fuer protect-live-paths.sh und seine Konfigurationsdatei. Alle Konfigurationen liegen im Temp,
# der Hook liest weder die echte noch die mitgelieferte Datei, ausser im Fall, der genau das prueft.
# Aufruf: bash hooks/tests/protect-live-paths.test.sh [pfad/zum/hook] (im Repository)
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOK="${1:-$GUARDRAILS_DIR/hooks/protect-live-paths.sh}"
TMP=$(mktemp -d) || { echo "FEHL mktemp"; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fehler=0; nr=0
ok()   { printf '  OK    %2d %-58s %s\n' "$nr" "$1" "$2"; }
fehl() { printf '  FEHL  %2d %-58s %s\n' "$nr" "$1" "$2"; fehler=$((fehler+1)); }

KONF="$TMP/regeln.conf"
cat > "$KONF" <<'EOF'
# Testregeln
credentials application/config/database\.php$
allow ^/srv/arbeit/public-live/
live /public-live/
live /staging-live/
stale /shop-alt/
hint Richtiger Ordner: /srv/arbeit/shop/
EOF

# Aufruf mit Edit-Eingabe; Ausgabe: Exitcode und stderr in $TMP/err
lauf() { # pfad [inhalt]
  jq -cn --arg p "$1" --arg c "${2:-}" '{tool_name:"Edit", tool_input:{file_path:$p, new_string:$c}}' \
    | GUARDRAILS_DIR="${LAUF_DIR:-$TMP/leer}" PROTECTED_PATHS_CONF="${LAUF_KONF-$KONF}" bash "$HOOK" 2>"$TMP/err" >/dev/null
  echo $?
}
pruefe() { nr=$((nr+1)); local ist; ist=$(lauf "$3" "${4:-}"); if [ "$ist" = "$2" ]; then ok "$1" "exit $ist"; else fehl "$1" "erwartet=$2 ist=$ist $(head -c 100 "$TMP/err")"; fi; }
mkdir -p "$TMP/leer"

echo "Protect-Live-Paths, Testlauf gegen $HOOK"
echo
echo "A) Regeln aus der Konfiguration"
nr=$((nr+1)); ist=$(printf '{"tool_name":"Write","tool_input":{}}' | GUARDRAILS_DIR="$TMP/leer" PROTECTED_PATHS_CONF="$KONF" bash "$HOOK" 2>/dev/null; echo $?)
[ "$ist" = 0 ] && ok "ohne-dateipfad-frei" "exit 0" || fehl "ohne-dateipfad-frei" "ist=$ist"
pruefe "gewoehnlicher-pfad-frei" 0 /srv/arbeit/shop/app/Controller.php
pruefe "zugangsdaten-datei-gesperrt" 2 /srv/arbeit/shop/application/config/database.php
pruefe "zugangsdaten-auch-im-erlaubten-pfad-gesperrt" 2 /srv/arbeit/public-live/application/config/database.php
pruefe "aehnlicher-dateiname-frei" 0 /srv/arbeit/shop/application/config/database.php.dist
pruefe "live-pfad-gesperrt" 2 /var/www/public-live/index.php
pruefe "zweiter-live-pfad-gesperrt" 2 /var/www/staging-live/index.php
pruefe "erlaubter-pfad-vor-live-sperre-frei" 0 /srv/arbeit/public-live/index.php
pruefe "veralteter-ordner-gesperrt" 2 /srv/shop-alt/index.php
nr=$((nr+1)); lauf /srv/shop-alt/index.php >/dev/null
grep -q 'Richtiger Ordner: /srv/arbeit/shop/' "$TMP/err" && ok "veralteter-ordner-nennt-hinweis" "Hinweis" || fehl "veralteter-ordner-nennt-hinweis" "$(head -c 100 "$TMP/err")"
pruefe "settings-mit-klartext-secret-gesperrt" 2 /srv/arbeit/.claude/settings.json 'export SSHPASS=geheim'
pruefe "settings-ohne-secret-frei" 0 /srv/arbeit/.claude/settings.json '{"model":"x"}'

echo
echo "B) Auswahl der Konfiguration und sicherer Standard"
mkdir -p "$TMP/nur-beispiel/config" "$TMP/mit-eigener/config" "$TMP/ohne-beides/config"
printf 'live /beispiel-live/\n' > "$TMP/nur-beispiel/config/protected-paths.example"
printf 'live /beispiel-live/\n' > "$TMP/mit-eigener/config/protected-paths.example"
printf 'live /eigene-live/\n' > "$TMP/mit-eigener/config/protected-paths.conf"
# Gueltige Beispielregeln liegen bereit: die gesetzte, fehlende Datei darf trotzdem nicht auf sie zurueckfallen
LAUF_DIR="$TMP/nur-beispiel" LAUF_KONF="$TMP/gibt-es-nicht.conf" pruefe "gesetzte-fehlende-datei-sperrt-alles" 2 /srv/arbeit/shop/a.php
# Ein Verzeichnis ist fuer -r lesbar, liefert aber keine Regeln: ohne -f-Pruefung waere alles frei
mkdir -p "$TMP/verzeichnis.conf"
LAUF_DIR="$TMP/nur-beispiel" LAUF_KONF="$TMP/verzeichnis.conf" pruefe "konfiguration-als-verzeichnis-sperrt-alles" 2 /srv/arbeit/shop/a.php
LAUF_DIR="$TMP/nur-beispiel" LAUF_KONF="" pruefe "ohne-eigene-datei-gelten-beispielregeln" 2 /x/beispiel-live/a.php
LAUF_DIR="$TMP/mit-eigener" LAUF_KONF="" pruefe "eigene-datei-ersetzt-beispielregeln" 0 /x/beispiel-live/a.php
LAUF_DIR="$TMP/mit-eigener" LAUF_KONF="" pruefe "eigene-datei-wird-angewendet" 2 /x/eigene-live/a.php
LAUF_DIR="$TMP/ohne-beides" LAUF_KONF="" pruefe "ohne-jede-konfiguration-gesperrt" 2 /x/a.php
LAUF_DIR="$GUARDRAILS_DIR" LAUF_KONF="" pruefe "mitgeliefertes-beispiel-ist-gueltig" 0 /srv/arbeit/shop/a.php
printf 'liev /tippfehler/\n' > "$TMP/tippfehler.conf"
LAUF_KONF="$TMP/tippfehler.conf" pruefe "unbekannte-art-sperrt" 2 /srv/arbeit/shop/a.php
printf 'live\n' > "$TMP/ohne-muster.conf"
LAUF_KONF="$TMP/ohne-muster.conf" pruefe "art-ohne-muster-sperrt" 2 /srv/arbeit/shop/a.php
printf 'live /kaputt(/\n' > "$TMP/kaputt.conf"
LAUF_KONF="$TMP/kaputt.conf" pruefe "ungueltiger-ausdruck-sperrt" 2 /srv/arbeit/shop/a.php
printf '# nur Kommentar\n\n   \n' > "$TMP/leer.conf"
LAUF_KONF="$TMP/leer.conf" pruefe "leere-konfiguration-sperrt-nichts" 0 /srv/arbeit/shop/a.php

echo
if [ "$fehler" -eq 0 ]; then echo "Alle $nr Faelle bestanden."; exit 0; else echo "$fehler von $nr Faellen fehlgeschlagen."; exit 1; fi
