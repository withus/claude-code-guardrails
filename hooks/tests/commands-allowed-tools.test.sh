#!/bin/bash
# Prueft: jede Slash-Command-Datei mit Inline-Bash (!`...`) nennt allowed-tools im Frontmatter.
# Ohne diese Freigabe fuehrt Claude Code den Befehl im Auto-Modus nicht beim Laden aus, sondern
# reicht ihn als Anweisung ans Modell weiter; ein Gate auf Modell-Aufrufe kann ihn dann sperren
# (Diagnose 2026-10-16). Ordner per COMMANDS_DIR umlenkbar (Mutationsprobe).
GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ordner="${COMMANDS_DIR:-$GUARDRAILS_DIR/commands}"
rot=0; n=0
for datei in "$ordner"/*.md; do
  grep -q '^!`' "$datei" || continue
  n=$((n+1))
  frontmatter=$(sed -n '2,/^---$/p' "$datei")
  if printf '%s\n' "$frontmatter" | grep -q '^allowed-tools:'; then
    echo "OK   $(basename "$datei"): allowed-tools vorhanden"
  else
    echo "ROT  $(basename "$datei"): Inline-Bash ohne allowed-tools"; rot=$((rot+1))
  fi
done
echo "Geprueft: $n Dateien mit Inline-Bash, $rot ohne Freigabe"
[ "$rot" -eq 0 ]
