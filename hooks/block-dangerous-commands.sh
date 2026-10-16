#!/bin/bash
# Hook: block-dangerous-commands.sh
# Event: PreToolUse (Bash)
# Purpose: Block destructive commands (rm -rf, force push, hard reset, git clean, destructive SQL via SSH)
# Exit 0 = allow, Exit 2 = block

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# If no command, allow
if [ -z "$CMD" ]; then
    exit 0
fi

# === BLOCK: rm -rf targeting critical paths ===
# Block: rm -rf /, rm -rf /*, rm -rf ~, rm -rf /root, rm -rf /home, rm -rf ..
# Allow: rm -rf ./node_modules/, rm -rf /srv/app/specific-dir/build/
# Codex-Fund 2026-09-22: die alte Regex verlangte -r und -f im selben Token (traf 'rm -r -f /root'
# nicht) und ankerte /root nur ans Stringende (traf 'rm -rf /root; true' nicht). Jetzt getrennte
# Flag-Erkennung (beliebige Reihenfolge/Aufteilung, nur rm-eigene Buchstaben f/i/I/r/R/d/v) und ein
# trennzeichen-bewusster Ziel-Anker (Stringende ODER ; & | statt nur Stringende).
if echo "$CMD" | grep -qE '\brm\b'; then
    HAT_R=0; HAT_F=0
    echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[fiIrRdv]*[rR][fiIrRdv]*|--recursive)([[:space:]]|$)' && HAT_R=1
    echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[fiIrRdv]*f[fiIrRdv]*|--force)([[:space:]]|$)' && HAT_F=1
    if [ "$HAT_R" = "1" ] && [ "$HAT_F" = "1" ]; then
        ENDE='([[:space:]]*(;|&&|&|\||$))'
        # /root(/)?$ENDE: /root mit oder ohne Schraegstrich (gleichwertig zu den frueheren zwei Alternativen)
        ZIEL="/$ENDE|/\*|/root(/)?$ENDE|/home|/etc|/usr|/var|/bin|/sbin|\.\.|~/?$ENDE|~/?\*"
        # Ziel muss unmittelbar nach 'rm' und der zusammenhaengenden Flag-Kette stehen (sonst
        # matcht z.B. die abschliessende '/' von './node_modules/' faelschlich den Anker '/$ENDE').
        if echo "$CMD" | grep -qE "rm(\s+(-[fiIrRdv]+|--recursive|--force))+\s+($ZIEL)"; then
            echo "BLOCKED: Destructive 'rm -rf' (auch getrennt geschrieben, z.B. -r -f, oder mit Nachsatz wie '; true') targeting critical system paths. Be more specific with the target directory." >&2
            exit 2
        fi
    fi
fi

# === BLOCK: git push --force to main/master ===
# Codex-Fund 2026-09-22: 'git push -f' verlangte -f direkt hinter push, dadurch lief
# 'git push origin main -f' durch. Jetzt -f/--force an beliebiger Token-Position nach push.
if echo "$CMD" | grep -qE '\bgit\s+push\b'; then
    if echo "$CMD" | grep -qE -- '(^|[[:space:]])(-f|--force)([[:space:]]|$)'; then
        if echo "$CMD" | grep -qE '\b(main|master)\b'; then
            echo "BLOCKED: Force push to main/master is forbidden! This can destroy shared history." >&2
            exit 2
        fi
    fi
fi

# === BLOCK: git reset --hard ===
if echo "$CMD" | grep -qE 'git\s+reset\s+--hard'; then
    echo "BLOCKED: 'git reset --hard' can destroy uncommitted work. Use 'git stash' instead, or confirm explicitly." >&2
    exit 2
fi

# === BLOCK: git clean -fd (removes untracked files permanently) ===
if echo "$CMD" | grep -qE 'git\s+clean\s+(-[a-zA-Z]*f|-f)'; then
    echo "BLOCKED: 'git clean -f' permanently removes untracked files. Use 'git stash -u' or review untracked files first." >&2
    exit 2
fi

# === BLOCK: DROP TABLE/DATABASE via SSH ===
if echo "$CMD" | grep -qiE 'ssh.*(DROP\s+(TABLE|DATABASE)|TRUNCATE\s+TABLE)'; then
    echo "BLOCKED: Destructive SQL command (DROP/TRUNCATE) via SSH is forbidden! Use SELECT only for diagnostics." >&2
    exit 2
fi

# All checks passed
exit 0
