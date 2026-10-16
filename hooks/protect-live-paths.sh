#!/bin/bash
# Hook: protect-live-paths.sh
# Event: PreToolUse (Edit|Write)
# Purpose: Block edits to live server paths and wrong project folders
# Exit 0 = allow, Exit 2 = block
#
# Die geschuetzten Pfade stehen nicht im Skript, sondern in genau einer Konfigurationsdatei:
#   $PROTECTED_PATHS_CONF, sonst $GUARDRAILS_DIR/config/protected-paths.conf,
#   sonst die mitgelieferten Regeln $GUARDRAILS_DIR/config/protected-paths.example.
# Ist die gewaehlte Datei nicht lesbar, keine regulaere Datei oder enthaelt sie eine ungueltige Zeile oder ein
# ungueltiges Muster, wird jedes Edit/Write gesperrt (fail secure). Format: siehe config/protected-paths.example.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# If no file_path (e.g. Write without path), allow
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

GUARDRAILS_DIR="${GUARDRAILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -n "${PROTECTED_PATHS_CONF:-}" ]; then
    # Ausdruecklich gesetzte Datei: kein stiller Rueckfall auf die Beispielregeln
    KONFIG="$PROTECTED_PATHS_CONF"
elif [ -r "$GUARDRAILS_DIR/config/protected-paths.conf" ]; then
    KONFIG="$GUARDRAILS_DIR/config/protected-paths.conf"
else
    KONFIG="$GUARDRAILS_DIR/config/protected-paths.example"
fi

if [ ! -r "$KONFIG" ]; then
    echo "BLOCKED: Konfiguration der geschuetzten Pfade nicht lesbar ($KONFIG). Edit/Write bleibt gesperrt, bis die Datei existiert." >&2
    exit 2
fi
# Ein Verzeichnis oder eine Geraetedatei gilt fuer -r ebenfalls als lesbar. awk liest daraus keine Zeile,
# es gaebe keine Regel und jede Sperre waere still abgeschaltet.
if [ ! -f "$KONFIG" ]; then
    echo "BLOCKED: Konfiguration der geschuetzten Pfade ist keine regulaere Datei ($KONFIG). Edit/Write bleibt gesperrt, bis dort eine lesbare Datei liegt." >&2
    exit 2
fi

# Eintraege einer Art, einer je Zeile: alles hinter dem ersten Wort. Kommentar- und Leerzeilen zaehlen nicht.
eintraege() {
    awk -v art="$1" '/^[[:space:]]*(#|$)/ { next }
        $1 == art { sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' "$KONFIG"
}

# Unbekannte Art oder fehlendes Muster: ein Tippfehler darf keine Regel still abschalten
FEHLERZEILE=$(awk '/^[[:space:]]*(#|$)/ { next }
    $1 !~ /^(credentials|allow|live|stale|hint)$/ || NF < 2 { print NR; exit }' "$KONFIG")
if [ -n "$FEHLERZEILE" ]; then
    echo "BLOCKED: Ungueltige Zeile $FEHLERZEILE in $KONFIG (erlaubt: credentials|allow|live|stale|hint, danach Muster oder Text). Edit/Write bleibt gesperrt." >&2
    exit 2
fi

# Ungueltiger regulaerer Ausdruck: grep meldet Status 2, die Regel wuerde sonst nie greifen
while IFS= read -r MUSTER; do
    printf '' | grep -qE -- "$MUSTER" 2>/dev/null
    if [ $? -gt 1 ]; then
        echo "BLOCKED: Ungueltiges Muster '$MUSTER' in $KONFIG. Edit/Write bleibt gesperrt." >&2
        exit 2
    fi
done < <(for ART in credentials allow live stale; do eintraege "$ART"; done)

# Erstes Muster der Art, das auf den Pfad passt (grep -E); Rueckgabe 1, wenn keines passt
treffer() {
    local muster
    while IFS= read -r muster; do
        if printf '%s\n' "$FILE_PATH" | grep -qE -- "$muster"; then
            printf '%s' "$muster"
            return 0
        fi
    done < <(eintraege "$1")
    return 1
}

# === BLOCK: credentials files (any project) ===
# e.g. application/config/database.php holds live DB credentials. Gilt auch fuer erlaubte Pfade.
if MUSTER=$(treffer credentials); then
    echo "BLOCKED: Zugangsdaten-Datei ('$MUSTER'), Änderungen nur nach expliziter User-Freigabe." >&2
    exit 2
fi

# === BLOCK: Clear-text secrets in settings.json / settings.local.json ===
# Only block when the written content actually contains obvious secrets.
# Normal config changes must pass through.
if echo "$FILE_PATH" | grep -qE '\.claude/settings(\.local)?\.json$'; then
    # Combine potential write payloads (Edit -> new_string, Write -> content)
    WRITE_CONTENT=$(echo "$INPUT" | jq -r '(.tool_input.new_string // "") + "\n" + (.tool_input.content // "")')
    if echo "$WRITE_CONTENT" | grep -qE 'sshpass|SSHPASS=|PASSWORD=|sk_live|m0-|SFTP_PW='; then
        echo "BLOCKED: Keine Klartext-Secrets in settings-Dateien, Env-Vars oder eine Secret-Datei nutzen." >&2
        exit 2
    fi
fi

# === ALLOW: freigegebene Pfade vor den Sperren ===
# Etwa ein lokaler Ordner, der denselben Namen traegt wie ein Live-Verzeichnis.
if treffer allow >/dev/null; then
    exit 0
fi

# === BLOCKED PATHS: Live/Production servers ===
if MUSTER=$(treffer live); then
    echo "BLOCKED: Edit in production path '$MUSTER' is forbidden! Use local workflow: Edit locally -> test -> SFTP upload." >&2
    exit 2
fi

# === BLOCKED PATHS: Wrong/old project folders ===
if MUSTER=$(treffer stale); then
    echo "BLOCKED: '$MUSTER' is an old/wrong project folder!" >&2
    HINWEISE=$(eintraege hint)
    if [ -n "$HINWEISE" ]; then
        echo "Use the correct folders:" >&2
        printf '%s\n' "$HINWEISE" | sed 's/^/  /' >&2
    fi
    exit 2
fi

# All checks passed
exit 0
