# claude-code-guardrails

Hooks, gates, agents and slash commands that enforce working rules for AI-assisted development with
[Claude Code](https://code.claude.com/docs/en/hooks). The rules are not only written into a prompt or a
`CLAUDE.md`: shell and Python hooks check every relevant tool call and block or correct it. The diagnosis gate,
`protect-live-paths.sh` and the two Python gates ship with a test suite and a mutation probe that proves the tests
actually catch a broken gate; `session-context-loader.sh` and the command headers have a test suite without a
probe. The remaining hooks have no tests of their own yet (see [Tests and mutation probes](#tests-and-mutation-probes)).

## Problem and approach

A rule in a prompt is a request. The model follows it most of the time, and then one day it runs
`git push origin main -f`, edits a file on the live server path, reads a credentials file into the transcript,
or writes to a production database because the context made it look reasonable. Repeating the rule louder does
not change that.

This repository moves the rules that must not be broken into the harness:

- **PreToolUse hooks** inspect the tool input (command, file path, briefing text) and deny the call before it runs.
- **PostToolUse hooks** inspect or rewrite the tool output, for example to mask secrets before the model sees them.
- **Stop hooks** check the form of the final answer and send it back with the name of the violated rule.
- **Agents and commands** carry the review and diagnosis procedures the hooks rely on.

The two gates in `gates/`, the diagnosis gate and the briefing gate name the violated rule in their message (for
example `db-schreiben-ohne-freigabe`, `ursache-in-phase-a` or `pruefer-vorlage-fehlt`), so the model can fix exactly
that point; the other blocking hooks state the reason in plain text. Where a rule may legitimately be skipped, the skip is an explicit line with a
reason that gets logged, not a disabled hook.

## What is included

### Hooks (`hooks/`)

| Hook | Event (matcher) | Blocks or checks | Example |
|---|---|---|---|
| `protect-live-paths.sh` | PreToolUse (`Edit\|Write`) | Writes to credential files, production paths and stale project folders listed in `config/protected-paths.*`; clear-text secrets written into `.claude/settings*.json`. Unreadable or invalid config blocks every write (fail secure). | Edit of `/var/www/production/index.php` is denied with exit code 2. |
| `auto-backup.sh` | PreToolUse (`Edit\|Write`) | Never blocks. Copies an existing file below `$PROJEKTE_WURZEL` (default `~/projekte`) to `<file>.backup_<timestamp>` before it is changed. Skips `node_modules`, `vendor`, caches, `.git`. | Editing `~/projekte/shop/app.php` leaves `app.php.backup_<timestamp>` next to it. |
| `block-dangerous-commands.sh` | PreToolUse (`Bash`) | `rm` with recursive and force flags on `/`, `/*`, `/root`, `~`, `/home`, `/etc`, `/usr`, `/var`, `/bin`, `/sbin`, `..` (also with split flags or a trailing `; true`); force push to `main`/`master`; `git reset --hard`; `git clean -f`; `DROP`/`TRUNCATE` sent over `ssh`. | `git push origin main -f` is denied, `git push --force origin feature/x` passes. |
| `scan-secrets-before-commit.sh` | PreToolUse (`Bash`) | On `git commit`: staged files such as `.env`, `*.pem`, `*.key`, `credentials*`, `.htpasswd`, and added lines that look like API keys, Stripe keys, GitHub tokens, bearer tokens or `sshpass -p`. | Committing a staged `.env` is denied with the file name. |
| `codex-precommit-review.sh` | PreToolUse (`Bash`) | On `git commit`: runs the adversarial review of the OpenAI Codex Claude Code plugin on the staged changes and blocks on the verdict `needs-attention`. Fails open on timeout or error. Bypass: `[skip-review]` in the message. | Needs the plugin; without it the hook warns and lets the commit through. |
| `artifact-security-guard.sh` | PreToolUse (`Artifact`) | Publishing a file as an Artifact when it contains security or audit markers (vulnerability, SQL injection, exploit, credential, `sk_live`, ...). Such reports stay local files. | Only relevant where Claude Code offers an Artifact tool. |
| `dry-briefing-gate.sh` | PreToolUse (`Agent\|SendMessage`) | Subagent briefings that introduce new fields, labels or language keys without a documented inventory ("Bestandsaufnahme") and the phrase "nichts doppelt" / "keine zweite Quelle". Briefings for reviewer agents that do not name `templates/pruefbericht.md`. | A briefing "neues Feld anlegen" without an inventory is denied. |
| `php-syntax-check.sh` | PostToolUse (`Edit\|Write`) | Runs `php -l` on edited `.php` files and reports syntax errors. Never blocks. | Needs `php` on the path. |
| `pre-compact-save.sh` | PreCompact | Writes a checkpoint (cwd, project, branch, last three commits) to `~/.claude/hooks/last-checkpoint.json`. | |
| `session-context-loader.sh` | SessionStart (`startup`) | Adds a hint to read role files `~/.claude/ROLLE-*.md` if they exist. With `STARTKONTEXT_VOLL=1` also the last checkpoint, `.claude/context/current-task.md` and a warning when the branch is behind `origin`. | |
| `diagnose-schema-gate.sh` | Stop | Active only while a `/diagnose` marker exists. Checks diagnosis reports for structure, never content: phase A must not contain a cause, ends with "Fehlt eine Stelle?"; every measured statement needs an evidence id `[B-n]` with command and output; phase C needs a reproduction, a testable filter, a counter-check that includes the reported case and an independent review. The full report lives in `.claude/diagnosen/`, the chat answer is a short summary pointing to it. After three rejections in a row it gives up and says so. | A phase A answer with a "## Ursache" section is sent back as `ursache-in-phase-a`. |

### Gates (`gates/`)

| Gate | Event (matcher) | Blocks or checks | Example |
|---|---|---|---|
| `geheimnis-gate.py sperre` | PreToolUse (`Read\|Edit\|Write\|MultiEdit\|NotebookEdit\|Grep\|Glob\|Bash`) | Direct access to the secrets file `servers.md` by file tools, Grep/Glob, and reading or copying shell commands. `grep -l` for references stays allowed. A hurdle, not a wall: the mask below is the tight layer. | `cat ~/.claude/servers.md` is denied. |
| `geheimnis-gate.py maske` | PostToolUse (`*`) | Replaces every credential value found in the secrets file (`GEHEIMNIS_QUELLE`, default `~/.claude/servers.md`) with `[maskiert]` in any tool output, keeping the output structure intact. Values are never logged. | A command that prints a password shows `[maskiert]` instead. |
| `freigabe-gate.py` | PreToolUse (`Bash`) | `deploy.py` (also `sftp_deploy`, `ftps_deploy`) with `--yes`, and writing SQL via `mysql`/`mariadb` against a non-local host or over `ssh`. Allowed only if, since the last real user prompt, an AskUserQuestion mentioning "deploy" or "Datenbank"/"db" was answered with an option starting with "Ja". `--check`, `--dry-run`, local databases and `docker exec` stay free. | `mysql -h db.example.org shop -e 'DELETE FROM t'` is denied until the user said yes in this turn. |

Without a readable secrets file the mask does not fail silently: it reports "servers.md nicht lesbar" as a system
message on every tool call. Create the file (or point `GEHEIMNIS_QUELLE` at yours) or leave both
`geheimnis-gate.py` entries out of `settings.json`.

`gates/pruefbericht.conf.json` lists the reviewer agent types; `dry-briefing-gate.sh` reads `pruefer_typen` from it.

### Agents (`agents/`)

| Agent | Model | Purpose |
|---|---|---|
| `adversarial-verifier` | opus | Fresh-context skeptic that tries to refute that an implementation meets its spec before merge, deploy or a "done" message. Read-only, every verdict needs its own tool evidence. |
| `codex-output-reviewer` | sonnet | Mandatory cross-review of code produced by Codex before it is applied: security, logic, conventions, scope creep, callers. Read-only. |
| `db-migration-checker` | opus | Risk rating for database migrations before they run: reversibility, admin lockout, data loss, locks on large tables, ID and type traps. Never runs DDL or DML. |

All three end with a report in the format of `templates/pruefbericht.md` (`Urteil: PASS|FLAG|GAP`, `Regel:`, `Beleg:`, `Begründung:`).

### Commands (`commands/`)

| Command | Purpose |
|---|---|
| `/diagnose` | Starts a diagnosis: `scripts/diagnose-start.sh` sets the session marker for the Stop gate, the template `templates/diagnose.md` is shown, the model delivers phase A (the map of affected code) first. |
| `/ship` | Stage, commit and push in one step: branch guard for `main`/`master`, secret filter before `git add`, conventional commit message, no force push. |
| `/stand` | Read-only status recap: branch, last commits, uncommitted changes, ahead/behind, last task note. |

### Other files

- `config/protected-paths.example`: default rules for `protect-live-paths.sh` and documentation of the format.
- `scripts/diagnose-start.sh`: writes the diagnosis marker, refuses invalid session ids and never overwrites a valid marker of another session.
- `templates/diagnose.md`, `templates/pruefbericht.md`: the report formats the gates and agents expect.
- `settings.example.json`: hook registration for Claude Code.
- `install.sh`: copies everything into place without overwriting anything unbacked.

## Installation

Requirements: `bash`, `jq`, `python3`, `git`, GNU coreutils (`date -d`, `stat -c`, `realpath`) and `flock` from
util-linux.
Optional: `php` for the PHP lint hook, `node` and the OpenAI Codex plugin for the pre-commit review.

### With the script

```bash
git clone <this repository> && cd claude-code-guardrails
bash install.sh --dry-run   # shows what would be created or replaced
bash install.sh
```

The script copies the repository to `~/.claude/guardrails` (override with `GUARDRAILS_DIR`), the agents to
`~/.claude/agents/` and the commands to `~/.claude/commands/`. An existing file with different content is first
saved as `<file>.backup_<timestamp>`. It does not touch `~/.claude/settings.json`.

### Manually

1. Copy the repository to `~/.claude/guardrails`.
2. Copy `agents/*.md` to `~/.claude/agents/` and `commands/*.md` to `~/.claude/commands/`.
3. Merge the `hooks` block of `settings.example.json` into `~/.claude/settings.json`. Keep your existing hook
   entries; Claude Code runs all matching hooks.
4. Optional: copy `config/protected-paths.example` to `config/protected-paths.conf` and adapt it.

If you install somewhere else than `~/.claude/guardrails`, adjust the paths in `settings.json`,
`commands/diagnose.md` and the template path in the three agents.

### Configuration

| Variable | Used by | Default |
|---|---|---|
| `GUARDRAILS_DIR` | hooks and tests, to find `config/`, `gates/`, `scripts/` | the directory above the script |
| `PROTECTED_PATHS_CONF` | `protect-live-paths.sh` | `config/protected-paths.conf`, else `config/protected-paths.example` |
| `PROJEKTE_WURZEL` | `auto-backup.sh`, `session-context-loader.sh` | `~/projekte` |
| `AGENTS_STATE_DIR` | gates and the diagnosis gate (logs, counters) | `~/.claude/state` |
| `GEHEIMNIS_QUELLE` | `geheimnis-gate.py` | `~/.claude/servers.md` |
| `CODEX_COMPANION` | `codex-precommit-review.sh` | the Codex plugin path below `~/.claude/plugins/` |
| `STARTKONTEXT_VOLL` | `session-context-loader.sh` | off; `1` enables the full start context |
| `PRUEFBERICHT_CONF` | `dry-briefing-gate.sh` | `gates/pruefbericht.conf.json` |

Hook commands run in a shell, so a variable can also be set in front of the command in `settings.json`, for
example `"command": "PROJEKTE_WURZEL=$HOME/code $HOME/.claude/guardrails/hooks/auto-backup.sh"`.

### Protected paths

`config/protected-paths.example` documents the format. One rule per line, `<kind> <pattern>`, patterns are
extended regular expressions matched against the file path:

```
credentials application/config/database\.php$
allow ^/srv/arbeit/shop-spiegel/
live /var/www/production/
stale /shop-alt/
hint Aktueller Projektordner: ~/projekte/shop/
```

`credentials` always blocks, `allow` lifts the following `live` and `stale` rules, `hint` lines are shown when a
`stale` rule blocks. Your own `protected-paths.conf` replaces the example completely, so an own file that is
empty or holds only comments switches off every rule, `credentials` included. Copy at least the `credentials`
lines from the example into it. An unknown kind, a line without pattern or an invalid expression blocks every
write until it is fixed.

## Tests and mutation probes

Run everything from the repository root. The suites redirect all write targets to temporary directories and
compare hashes of the real targets before and after; running them with a throwaway `HOME` keeps your own
`~/.claude` out of it entirely:

```bash
(
  export HOME="$(mktemp -d)"
  for t in hooks/tests/*.test.sh gates/tests/*.test.sh; do bash "$t" > /dev/null && echo "ok   $t" || echo "FAIL $t"; done
  for m in hooks/tests/*.mutations.sh gates/tests/*.mutations.sh; do bash "$m" > /dev/null && echo "ok   $m" || echo "FAIL $m"; done
)
```

A single suite prints one line per case with the expected and actual result, for example
`bash hooks/tests/protect-live-paths.test.sh`.

| Suite | Covers | Mutation probe |
|---|---|---|
| `hooks/tests/diagnose-schema-gate.test.sh` | every rule of the diagnosis gate, marker lifetime and ownership, loop protection, session id validation, `scripts/diagnose-start.sh`, isolation | `diagnose-schema-gate.mutations.sh` |
| `hooks/tests/protect-live-paths.test.sh` | each rule kind, config selection, fail-secure cases | `protect-live-paths.mutations.sh` |
| `hooks/tests/session-context-loader.test.sh` | role hint, output schema, start context switch | |
| `hooks/tests/commands-allowed-tools.test.sh` | every command with inline bash declares `allowed-tools` | |
| `gates/tests/geheimnis-gate.test.sh` | masking, output shape, access block, logging without values | `geheimnis-gate.mutations.sh` |
| `gates/tests/freigabe-gate.test.sh` | deploy and database rules, approval in the transcript, broken transcripts | `freigabe-gate.mutations.sh` |

`block-dangerous-commands.sh`, `scan-secrets-before-commit.sh`, `dry-briefing-gate.sh`,
`artifact-security-guard.sh`, `auto-backup.sh`, `codex-precommit-review.sh`, `php-syntax-check.sh` and
`pre-compact-save.sh` have no test suite of their own.

A mutation probe copies the gate, injects one specific defect with `sed` (a removed check, an inverted
condition, a loosened pattern), runs the suite against the copy and requires the named test cases to turn red.
If a defect stays green, the probe fails: the suite would not have noticed a broken gate. The diagnosis probe runs
the full suite once per mutation and takes several minutes.

## Limits

- Hooks are pattern checks. They stop the usual mistakes and the obvious shortcuts, not a model that is
  determined to get around them (a Python one-liner can still open a file the Bash rules did not anticipate).
  They do not replace code review, permission settings or OS-level isolation.
- Messages, comments and several keywords are German. The approval gate expects an answer starting with "Ja",
  the diagnosis gate expects sections such as `Phase:`, `Karte`, `Gemessen`, `Belege`.
- Developed and tested on Linux with GNU tools. macOS needs GNU `date` and `stat` from coreutils and a separate
  `flock`.
- Fail behaviour differs on purpose: the diagnosis gate and the Codex review fail open (their own error must not
  block work). `protect-live-paths.sh` fails closed on a missing, unreadable or invalid configuration. The approval
  gate treats a missing or unreadable transcript as "no approval" and blocks, but it lets the call through when its
  own hook input is not valid JSON.
- `php-syntax-check.sh` and `pre-compact-save.sh` print a top-level `additionalContext` field as in the original
  setup. The current hook documentation places `additionalContext` inside `hookSpecificOutput`, so their message
  may not reach the model.
- The original setup also checked the form of reviewer reports at `SubagentStop`. That gate depends on an
  agent budget gate that is not part of this repository, so it is not included; the report template and the
  briefing check remain.

## Origin

Extracted from a private agent setup built in 2026 for shop and web projects, with all project,
customer and server references removed. Rules that only matched specific hosts or deploy tools were dropped
rather than generalised. That includes a configurable block on deploy source folders, which was removed because
it was bound to private deploy tools.

## License

MIT, see `LICENSE`.
