#!/usr/bin/env bash
# Mutationsproben fuer die Schema-2-Regeln in diagnose-schema-gate.sh (seit 2026-09-22).
# Aufruf: bash hooks/tests/diagnose-schema-gate.mutations.sh (im Repository)
export GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOK="$GUARDRAILS_DIR/hooks/diagnose-schema-gate.sh"
TEST="$GUARDRAILS_DIR/hooks/tests/diagnose-schema-gate.test.sh"
TMP=$(mktemp -d) || { echo "mktemp fehlgeschlagen" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "Temp-Verzeichnis fehlt" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT; gesamt=0
# Ohne gruene Ausgangslage sagt eine Mutationsprobe nichts aus (Codex-Review 2026-09-25).
bash "$TEST" >/dev/null 2>&1 || { echo "Ausgangslage rot, Mutationsprobe nicht aussagekraeftig."; exit 1; }
mutation() { local name="$1" erwartet="$2" ausdruck="$3"
  local kopie="$TMP/$name.sh" testkopie="$TMP/$name.test.sh"
  sed -e "$ausdruck" "$HOOK" > "$kopie"
  if cmp -s "$HOOK" "$kopie"; then printf '  FEHL  %-46s Mutation hat nichts veraendert\n' "$name"; gesamt=$((gesamt+1)); return; fi
  # Die Suite kennt den Hook nur ueber $GUARDRAILS_DIR/hooks/...; die Kopie wird per Pfadersetzung eingesetzt.
  sed -e "s|^HOOK=.*|HOOK=\"$kopie\"|" "$TEST" > "$testkopie"
  local rot; rot=$(bash "$testkopie" 2>/dev/null | grep -E '^  FEHL' | sed -E 's/^  FEHL +[0-9]+ ([^ ]+).*/\1/' | sort -u | tr '\n' ' ')
  printf '  %-48s rot: %s\n' "$name" "${rot:-KEINER}"
  for f in $erwartet; do printf ' %s ' "$rot" | grep -q " $f " || { printf '  FEHL  %-46s Fall %s blieb gruen\n' "$name" "$f"; gesamt=$((gesamt+1)); }; done
}
echo "Mutationsproben gegen $HOOK"; echo
mutation "schemakennung-nicht-in-marker-geschrieben" "schema-2-marker-verlaengerung-behaelt-kennung marker-ohne-kennung-bekommt-bei-verlaengerung-schema-3" '/^    printf .schema=%s\\n. "\$MARKER_SCHEMA"$/d'
mutation "wenn-nein-pruefung-entfernt" "schema-2-phase-b-nein-ohne-wenn-nein-zeile schema-2-phase-b-wenn-nein-leer schema-2-phase-c-nein-am-ende-ohne-wenn-nein" 's/^  \[ -z "\$NEIN_OHNE" \] || \\$/  true || \\/'
mutation "r9-ohne-feldpruefung" "schema-2-naechste-phase-block-ohne-umfang schema-2-naechste-phase-block-mit-leerem-feld" "s/  for feld in 'Gemessen wird:' 'Nicht angefasst:' 'Umfang:'; do/  for feld in; do/"
mutation "rueckfrage-ohne-abschnittspruefung" "schema-2-rueckfrage-mit-karte-abschnitt-ist-ein-bericht schema-2-rueckfrage-mit-gemessen-abschnitt-ist-ein-bericht" 's/   && ! printf .%s. "\$TEXT" | grep -qiE .\^#+\[\[:space:\]\]\*(Karte|Gemessen|Ursache|Geschlossen).; then/   ; then/'
mutation "pfadpflicht-entfernt" "kurzfassung-ohne-pfad pfad-ausserhalb-von-diagnosen" '/nennt keinen Pfad auf eine Datei unter/s/^.*$/  true/'
mutation "projektgrenze-entfernt" "absoluter-pfad-in-fremdes-projekt pfad-mit-punkt-punkt-aus-dem-projekt symlink-aus-dem-projekt-heraus" 's/^  if \[ -z "\$ECHT" \] || .*; then$/  if false; then/'
mutation "existenzpruefung-entfernt" "pfad-auf-fehlende-datei" '/gibt es nicht\."$/s/^.*$/    true/'
mutation "groessengrenze-entfernt" "datei-ueber-einem-megabyte" '/ist groesser als 1 MB/s/^.*$/    true/'
mutation "zwei-ebenen-auch-fuer-schema-2" "schema-2-vorgang-bleibt-im-chat" 's/-ge "\$AKTUELLES_SCHEMA"/-ge 0/'
mutation "rueckfrage-mit-kurzfassungsfeldern-erlaubt" "rueckfrage-mit-stand-feld-geht-nicht-als-rueckfrage-durch" '/grep -qiE "\$KURZ_FELDER" \&\& BERICHT_IM_CHAT=1/d'
mutation "rueckfrage-mit-berichtspfad-erlaubt" "rueckfrage-mit-berichtspfad-ist-ein-bericht" "/grep -qF '.claude\/diagnosen\/' \&\& BERICHT_IM_CHAT=1/d"
mutation "leere-pflichtfelder-erlaubt" "leeres-stand-feld leeres-belegt-feld" 's/^  \[ -n "\$INHALT" \] || \\$/  true || \\/'
mutation "rueckfall-nimmt-ersten-pfad" "rueckfall-nimmt-pfad-der-letzten-antwort" 's/PFAD=\$(printf .%s\\n. "\$PFADE" | tail -1)/PFAD=$(printf "%s\\n" "$PFADE" | head -1)/'
mutation "zeilengrenze-entfernt" "kurzfassung-mit-31-zeilen" 's/^\[ "\$KURZ_ZEILEN" -le 30 \] || \\$/true || \\/'
mutation "tabellenpruefung-entfernt" "kurzfassung-mit-tabelle" '/enthaelt eine Tabelle\./s/^.*$/  true/'
mutation "befehlszeilenpruefung-entfernt" "kurzfassung-mit-codeblock kurzfassung-mit-befehlszeile" '/enthaelt einen Codeblock oder eine Befehlszeile/s/^.*$/  true/'
mutation "stichwortpruefung-entfernt" "kurzfassung-ohne-von-dir kurzfassung-ohne-stand stichwort-mitten-im-satz-zaehlt-nicht" "s/^for feld in 'Stand' 'Belegt' 'Offen' 'Vorschlag' 'Von dir'; do$/for feld in; do/"
mutation "aussage-ohne-nummer-erlaubt" "belegt-aussage-ohne-nummer belegt-zweite-zeile-ohne-nummer" 's/^\[ -z "\$OHNE_NR" \] || \\$/true || \\/'
mutation "belegnummer-nicht-gegen-datei-geprueft" "belegnummer-nicht-in-datei" 's/^for ref in \$BELEG_REFS; do$/for ref in; do/'
mutation "chat-statt-datei-geprueft" "dateiregel-greift-trotz-gueltiger-kurzfassung" 's/^TEXT="\$BERICHT_TEXT"$/TEXT="$KURZ"/'
mutation "startzeit-nicht-geprueft" "datei-vor-dem-start-zuletzt-geaendert" '/vor dem Start dieser Diagnose zuletzt/s/^.*$/    true/'
mutation "startzeit-bei-verlaengerung-verloren" "verlaengerung-behaelt-startzeit" '/printf .gestartet=%s\\n. "\$MARKER_START"/d'
mutation "uebergehung-nur-in-alter-form" "uebergehung-mit-regelnamen-laesst-durch uebergehung-in-kurzfassung-mit-regelnamen" 's/UEBERGEHUNG_NAMEN_ERLAUBT=1/UEBERGEHUNG_NAMEN_ERLAUBT=0/'
mutation "regelname-gross-klein-unterschieden" "uebergehung-mit-regelnamen-in-anderer-schreibweise" '/      ziel="\${ziel,,}"/d'
echo; if [ "$gesamt" -eq 0 ]; then echo "Alle Mutationen von der Suite gefangen."; exit 0; else echo "$gesamt Mutationsproben fehlgeschlagen."; exit 1; fi
