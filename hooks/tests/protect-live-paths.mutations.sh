#!/usr/bin/env bash
# Mutationsproben fuer protect-live-paths.sh. Kopie mit eingebautem Fehler, die Suite muss die genannten Faelle rot melden.
# Aufruf: bash hooks/tests/protect-live-paths.mutations.sh (im Repository)
export GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKRIPT="$GUARDRAILS_DIR/hooks/protect-live-paths.sh"
TEST="$GUARDRAILS_DIR/hooks/tests/protect-live-paths.test.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; gesamt=0
ausgang=$(bash "$TEST" "$SKRIPT" 2>/dev/null | tail -1)
case "$ausgang" in "Alle "*) echo "Ausgangslage gruen: $ausgang";; *) echo "FEHL Ausgangslage nicht gruen: $ausgang"; exit 1;; esac
mutation() { local name="$1" erwartet="$2" ausdruck="$3"
  local kopie="$TMP/$name.sh"
  sed -e "$ausdruck" "$SKRIPT" > "$kopie"
  if cmp -s "$SKRIPT" "$kopie"; then printf '  FEHL  %-52s Mutation hat nichts veraendert\n' "$name"; gesamt=$((gesamt+1)); return; fi
  local rot; rot=$(bash "$TEST" "$kopie" 2>/dev/null | grep -E '^  FEHL' | sed -E 's/^  FEHL +[0-9]+ ([^ ]+).*/\1/' | sort -u | tr '\n' ' ')
  printf '  %-54s rot: %s\n' "$name" "${rot:-KEINER}"
  for f in $erwartet; do printf ' %s ' "$rot" | grep -q " $f " || { printf '  FEHL  %-52s Fall %s blieb gruen\n' "$name" "$f"; gesamt=$((gesamt+1)); }; done
}
echo "Mutationsproben gegen $SKRIPT"; echo
mutation "zugangsdaten-regel-entfernt" "zugangsdaten-datei-gesperrt zugangsdaten-auch-im-erlaubten-pfad-gesperrt" 's/^if MUSTER=\$(treffer credentials); then$/if false; then/'
mutation "allow-vor-zugangsdaten" "zugangsdaten-auch-im-erlaubten-pfad-gesperrt" '/^# === BLOCK: credentials files/i if treffer allow >/dev/null; then exit 0; fi'
mutation "live-regel-entfernt" "live-pfad-gesperrt zweiter-live-pfad-gesperrt ohne-eigene-datei-gelten-beispielregeln eigene-datei-wird-angewendet" 's/^if MUSTER=\$(treffer live); then$/if false; then/'
mutation "nur-erstes-muster-geprueft" "zweiter-live-pfad-gesperrt" 's/^    done < <(eintraege "\$1")$/    done < <(eintraege "$1" | head -1)/'
mutation "allow-ignoriert" "erlaubter-pfad-vor-live-sperre-frei" 's/^if treffer allow >\/dev\/null; then$/if false; then/'
mutation "stale-regel-entfernt" "veralteter-ordner-gesperrt veralteter-ordner-nennt-hinweis" 's/^if MUSTER=\$(treffer stale); then$/if false; then/'
mutation "hinweis-fehlt" "veralteter-ordner-nennt-hinweis" 's/^    HINWEISE=\$(eintraege hint)$/    HINWEISE=""/'
mutation "fehlende-datei-laesst-durch" "gesetzte-fehlende-datei-sperrt-alles ohne-jede-konfiguration-gesperrt" '/Konfiguration der geschuetzten Pfade nicht lesbar/{n;s/    exit 2/    exit 0/}'
mutation "regulaere-datei-nicht-geprueft" "konfiguration-als-verzeichnis-sperrt-alles" 's/^if \[ ! -f "\$KONFIG" \]; then$/if false; then/'
mutation "gesetzte-datei-faellt-auf-beispiel-zurueck" "gesetzte-fehlende-datei-sperrt-alles" 's/^if \[ -n "\${PROTECTED_PATHS_CONF:-}" \]; then$/if [ -r "${PROTECTED_PATHS_CONF:-}" ]; then/'
mutation "eigene-datei-nicht-bevorzugt" "eigene-datei-ersetzt-beispielregeln eigene-datei-wird-angewendet" 's/^elif \[ -r "\$GUARDRAILS_DIR\/config\/protected-paths.conf" \]; then$/elif false; then/'
mutation "zeilenpruefung-entfernt" "unbekannte-art-sperrt art-ohne-muster-sperrt" 's/^if \[ -n "\$FEHLERZEILE" \]; then$/if false; then/'
mutation "musterpruefung-entfernt" "ungueltiger-ausdruck-sperrt" 's/^    if \[ \$? -gt 1 \]; then$/    if false; then/'
mutation "settings-secret-ignoriert" "settings-mit-klartext-secret-gesperrt" "s/^    if echo \"\$WRITE_CONTENT\" | grep -qE .*; then$/    if false; then/"
echo; if [ "$gesamt" -eq 0 ]; then echo "Alle Mutationen von der Suite gefangen."; exit 0; else echo "$gesamt Mutationsproben fehlgeschlagen."; exit 1; fi
