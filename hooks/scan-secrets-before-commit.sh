#!/bin/bash
# Hook: scan-secrets-before-commit.sh
# Event: PreToolUse (Bash)
# Purpose: Scan staged files for secrets before git commit
# Exit 0 = allow, Exit 2 = block

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git commit commands
if ! echo "$CMD" | grep -qE '^\s*git\s+commit'; then
    exit 0
fi

# Get list of staged files
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)

if [ -z "$STAGED_FILES" ]; then
    exit 0
fi

FOUND_ISSUES=""

# === CHECK 1: Dangerous file names ===
DANGEROUS_FILES=$(echo "$STAGED_FILES" | grep -iE '\.(env|pem|key|p12|pfx|jks)$|credentials|secrets\.json|\.htpasswd')
if [ -n "$DANGEROUS_FILES" ]; then
    FOUND_ISSUES="${FOUND_ISSUES}Sensitive files staged:\n${DANGEROUS_FILES}\n\n"
fi

# === CHECK 2: Scan staged content for secret patterns ===
SECRET_PATTERNS=(
    'API_KEY\s*=\s*["\x27][A-Za-z0-9_-]{20,}'
    'SECRET_KEY\s*=\s*["\x27][A-Za-z0-9_-]{20,}'
    'PRIVATE_KEY\s*=\s*["\x27][A-Za-z0-9_-]{20,}'
    'password\s*=\s*["\x27][^\x27"]{8,}'
    'sshpass\s+-p\s+["\x27]'
    'Bearer\s+[A-Za-z0-9_-]{20,}'
    'sk_live_[A-Za-z0-9]{20,}'
    'sk_test_[A-Za-z0-9]{20,}'
    'ghp_[A-Za-z0-9]{36,}'
    'm0-[A-Za-z0-9]{30,}'
)

STAGED_DIFF=$(git diff --cached 2>/dev/null)

for PATTERN in "${SECRET_PATTERNS[@]}"; do
    MATCHES=$(echo "$STAGED_DIFF" | grep -nE "^\+" | grep -iE "$PATTERN" | head -5)
    if [ -n "$MATCHES" ]; then
        FOUND_ISSUES="${FOUND_ISSUES}Potential secret found (pattern: ${PATTERN%%\\*}):\n${MATCHES}\n\n"
    fi
done

# === DECISION ===
if [ -n "$FOUND_ISSUES" ]; then
    echo "BLOCKED: Potential secrets detected in staged files!" >&2
    echo -e "$FOUND_ISSUES" >&2
    echo "Remove sensitive files with: git reset HEAD <file>" >&2
    echo "Or add to .gitignore if they should never be committed." >&2
    exit 2
fi

# All checks passed
exit 0
