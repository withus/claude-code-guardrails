---
name: ship
description: "Stage, Commit und Push in einem sicheren Schritt (Branch-Guard, Secret-Filter, Conventional Commit)"
category: utility
complexity: standard
mcp-servers: []
---

# /ship: Sicher committen und pushen

> Ein-Schritt-Workflow fuer Solo-Entwickler: prueft die Aenderungen, filtert Secrets aus,
> schuetzt `main`/`master`, generiert eine Conventional-Commit-Message und pusht.
> Setzt die Git- und Sicherheitsregeln aus der `CLAUDE.md` bzw. den Regeldateien des Nutzers um
> (nicht neu erfinden, dort nachschlagen).

## Usage

```
/ship                 # Stage + Commit + Push mit auto-generierter Message
/ship --changelog     # Zusaetzlich CHANGELOG.md-Eintrag ergaenzen (falls Datei existiert)
```

---

## PHASE 0: KONTEXT PRUEFEN (read-only)

Fuehre in exakter Reihenfolge aus:

1. `git rev-parse --is-inside-work-tree`: sicherstellen, dass ein Repo vorliegt. Sonst abbrechen.
2. `git status`: Ueberblick was sich geaendert hat (staged + unstaged + untracked).
3. `git diff` und `git diff --staged`: die inhaltlichen Aenderungen lesen.
4. Fasse dem User in 2-4 Zeilen zusammen: welche Dateien, welche Art von Aenderung.

Wenn es **nichts zu committen** gibt (working tree clean): melde das und beende ohne Aktion.

---

## PHASE 1: SECRET-FILTER (KRITISCH)

Grundregel: sensible Dateien duerfen NIE gestaged oder committet werden.

Pruefe alle geaenderten/neuen Dateien gegen diese Muster:

| Muster | Beispiel |
|--------|----------|
| `.env`, `.env.*` | `.env`, `.env.local` |
| `*.key`, `*.pem` | `private.key`, `cert.pem` |
| `credentials*` | `credentials.json` |
| `settings.local.json` | Claude-Local-Settings |
| `servers.md` | Server-Zugangsdaten |
| `secrets*`, `*secret*` | `secrets.php` |

Zusaetzlich: scanne den Diff-Inhalt oberflaechlich auf offensichtliche Klartext-Secrets
(API-Keys, Tokens, Passwoerter, `BEGIN PRIVATE KEY`).

**Verhalten bei Treffer:**
- Die betroffene Datei **NICHT** stagen (explizit aus dem `git add` heraushalten).
- Den User klar warnen: welche Datei, warum ausgeschlossen.
- Falls ein Secret bereits im Klartext im Diff einer sonst harmlosen Datei steht:
  Commit **stoppen** und den User bitten, das Secret erst zu entfernen.
- Niemals ein Secret in Commit-Message, Log-Ausgabe oder CHANGELOG schreiben.

---

## PHASE 2: BRANCH-GUARD

Ermittle den aktuellen Branch: `git branch --show-current`.

- **Ist der Branch `main` oder `master`:**
  - NICHT direkt auf `main`/`master` committen.
  - Lege einen Feature-Branch an, abgeleitet aus der Art der Aenderung:
    - Bugfix → `fix/<kurz-beschreibung>`
    - Feature/sonstiges → `feature/<kurz-beschreibung>`
    - `<kurz-beschreibung>` in kebab-case aus dem Diff ableiten (Englisch, praegnant).
  - `git checkout -b <branch>` und den neuen Branch nennen.
- **Ist der Branch bereits ein Arbeits-Branch:** direkt weiter, kein Wechsel.

Kein Force-Push, niemals auf `main`/`master` pushen ohne Branch.

---

## PHASE 3: CHANGELOG (nur bei `--changelog`)

Nur ausfuehren wenn das Argument `--changelog` gesetzt ist:

1. Pruefen ob `CHANGELOG.md` im Repo-Root existiert. Falls nicht: Hinweis ausgeben und Schritt ueberspringen (kein Fehler).
2. Falls vorhanden: einen kurzen Eintrag oben (unter der neuesten Version/`Unreleased`-Sektion) ergaenzen,
   der die Aenderung in einer Zeile zusammenfasst (Englisch, Stil an bestehende Eintraege anpassen).
3. Diese Aenderung wird im selben Commit mitgestaged (vor Phase 4 committen).

---

## PHASE 4: STAGE + COMMIT

1. Die geprueften, unbedenklichen Dateien stagen (`git add <datei> ...`, gezielt, NICHT blind `git add -A`,
   damit Secrets aus Phase 1 draussen bleiben).
2. Generiere eine **Conventional-Commit-Message** aus dem Diff:
   - Format: `<type>(<scope>): <summary>`, z.B. `fix(checkout): correct tax rounding`.
   - `type`: `feat` / `fix` / `refactor` / `docs` / `chore` / `test` / `perf` / `style`.
   - Summary auf Englisch, praegnant, imperativ, klein geschrieben.
   - Bei Bedarf ein kurzer Body mit dem Warum.
3. Committen.

> **Hinweis Precommit-Review-Hook:** Der Codex-Precommit-Review-Hook laeuft beim Commit automatisch.
> Wird der Commit **geblockt**, zuerst die gemeldeten Findings beheben und erneut committen.
> `[skip-review]` in der Commit-Message NUR verwenden, wenn der User es ausdruecklich verlangt.

---

## PHASE 5: PUSH

1. `git push -u origin <branch>` (setzt Upstream fuer neue Branches).
2. Bei Push-Fehler (kein Netz, abgelehnt): den Fehler klar melden, nicht verschleiern. Kein Force-Push.

---

## PHASE 6: ABSCHLUSS

Gib eine kompakte Bestaetigung aus:

```
Committed:  <git log -1 --oneline>
Branch:     <branch> (pushed to origin)
Excluded:   <ausgeschlossene Secret-Dateien oder "keine">
```

Zeige dazu `git log -1 --oneline` und bestaetige den erfolgreichen Push.

---

## Boundaries

### WILL:
- `git status`/`git diff` vor jeder Aktion pruefen und zusammenfassen
- Sensible Dateien (`.env`, `*.key`, `*.pem`, `credentials*`, `settings.local.json`, `servers.md`, Secrets) vom Staging ausschliessen und warnen
- Auf `main`/`master` zuerst einen `fix/`- bzw. `feature/`-Branch anlegen
- Eine praegnante Conventional-Commit-Message auf Englisch erzeugen
- Mit `-u origin <branch>` pushen und das Ergebnis bestaetigen
- Bei `--changelog` einen CHANGELOG.md-Eintrag ergaenzen (falls Datei existiert)

### WILL NOT:
- Secrets/Credentials stagen, committen, loggen oder in die Message schreiben: NIEMALS
- Direkt auf `main`/`master` committen: NIEMALS
- Force-Push auf `main`/`master`: NIEMALS
- Blind `git add -A` ohne Secret-Filter
- `[skip-review]` ohne expliziten User-Wunsch setzen
- CHANGELOG.md neu anlegen wenn sie nicht existiert
