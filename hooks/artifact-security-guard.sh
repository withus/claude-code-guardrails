#!/bin/bash
# Hook: artifact-security-guard.sh
# Event: PreToolUse (Artifact)
# Purpose: Prevent publishing security/audit content as a (default-shareable) Artifact.
#          Security reports must stay local files.
# Exit 0 = allow, Exit 2 = block

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# If no file_path, nothing to inspect -> allow
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# If file is not readable, we cannot inspect -> allow (conservative)
if [ ! -r "$FILE_PATH" ]; then
    exit 0
fi

# === Scan file content for security/audit markers (case-insensitive) ===
SENSITIVE_PATTERN='security-audit|schwachstelle|vulnerabilit|sql.?injection|penetration|exploit|klartext-passw|credential|sshpass|sk_live'

if grep -qiE "$SENSITIVE_PATTERN" "$FILE_PATH" 2>/dev/null; then
    echo "BLOCKED: Security-/Audit-Inhalte NIE als Artifact veröffentlichen, als lokale Datei speichern." >&2
    exit 2
fi

# All checks passed
exit 0
