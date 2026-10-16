#!/bin/bash
# Hook: auto-backup.sh
# Event: PreToolUse (Edit|Write)
# Purpose: Automatically create .backup_TIMESTAMP before editing project files
# Exit 0 = allow (never blocks, only creates backups)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# If no file_path, skip
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Only backup files in project directories (Wurzel per PROJEKTE_WURZEL, wie im session-context-loader)
PROJECT_DIRS=(
    "${PROJEKTE_WURZEL:-$HOME/projekte}/"
)

IN_PROJECT=false
for DIR in "${PROJECT_DIRS[@]}"; do
    if echo "$FILE_PATH" | grep -q "^$DIR"; then
        IN_PROJECT=true
        break
    fi
done

if [ "$IN_PROJECT" = false ]; then
    exit 0
fi

# Skip non-essential files (node_modules, vendor, cache, backups, plans)
if echo "$FILE_PATH" | grep -qE '(node_modules|vendor|\.cache|\.backup_|\.git/|/plans/)'; then
    exit 0
fi

# Skip if file doesn't exist yet (new file creation)
if [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

# Create backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${FILE_PATH}.backup_${TIMESTAMP}"

cp "$FILE_PATH" "$BACKUP_PATH" 2>/dev/null

if [ $? -eq 0 ]; then
    # Success - silently allow (no output needed)
    exit 0
else
    # Backup failed - warn but don't block
    echo "WARNING: Could not create backup at ${BACKUP_PATH}" >&2
    exit 0
fi
