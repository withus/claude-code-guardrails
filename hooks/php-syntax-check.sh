#!/bin/bash
# Hook: php-syntax-check.sh
# Event: PostToolUse (Edit|Write)
# Purpose: Run php -l after editing PHP files to catch syntax errors early
# Exit 0 = always (PostToolUse hooks are informational, not blocking)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# If no file_path, skip
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Only check PHP files
if ! echo "$FILE_PATH" | grep -qE '\.php$'; then
    exit 0
fi

# Skip if file doesn't exist
if [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

# Run PHP lint check
LINT_OUTPUT=$(php -l "$FILE_PATH" 2>&1)
LINT_EXIT=$?

if [ $LINT_EXIT -ne 0 ]; then
    # Syntax error found - use jq for safe JSON escaping
    FILENAME=$(basename "$FILE_PATH")
    jq -n --arg msg "PHP SYNTAX ERROR in ${FILENAME}: ${LINT_OUTPUT}" \
        '{"additionalContext": $msg}'
    exit 0
fi

# No errors
exit 0
