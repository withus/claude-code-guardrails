---
name: stand
description: "Read-only Status-Recap: Branch, letzte Commits, offene Aenderungen, letzter Task und Deploy"
category: utility
complexity: basic
mcp-servers: []
---

# /stand: Wo stehen wir?

> Kompakter, **read-only** Statusbericht fuer das aktuelle Projekt. Aendert nichts,
> pusht nichts. Beantwortet: welcher Branch, was ist committet, was ist offen,
> was war der letzte Task und der letzte Deploy.

## Usage

```
/stand        # Status-Recap fuer das Projekt im aktuellen Verzeichnis
```

---

## PHASE 0: PROJEKT ERMITTELN

1. Aktuelles Verzeichnis pruefen (`pwd`).
2. **Wenn cwd das Home-Verzeichnis ist** (kein konkretes Projekt): nicht raten.
   - Den User fragen, an welchem Projekt er den Stand sehen will.
     Danach in den Projektordner wechseln (nur lesend arbeiten).
3. **Wenn cwd in einem Projektordner liegt:** dieses Projekt verwenden.
4. Sicherstellen, dass es ein Git-Repo ist (`git rev-parse --is-inside-work-tree`). Sonst darauf hinweisen und mit Datei-Recap (Phase 2) fortfahren, soweit moeglich.

---

## PHASE 1: GIT-STATUS (read-only)

Fuehre diese Befehle aus (alle rein lesend):

1. `git fetch origin --quiet`, offline-tolerant: schlaegt der Fetch fehl (kein Netz), NICHT abbrechen,
   sondern mit den lokalen Refs weiterarbeiten und einen kurzen Hinweis notieren.
2. `git branch --show-current`: aktueller Branch.
3. `git log --oneline -5`: letzte 5 Commits.
4. `git status --short`: offene Aenderungen (staged/unstaged/untracked), Anzahl zaehlen.
5. Ahead/Behind vs. Upstream: `git rev-list --left-right --count @{upstream}...HEAD` (falls Upstream existiert),
   sonst als "kein Upstream" vermerken.

---

## PHASE 2: PROJEKT-KONTEXT (read-only, falls vorhanden)

Nur lesen, wenn die Dateien existieren:

1. `.claude/context/current-task.md`: letzten Stand und offene Punkte in 1-3 Zeilen zusammenfassen.
2. `.claude/memory/deployment-log.md`: den letzten Deploy-Eintrag (Datum/Ziel) herausziehen.

Fehlen die Dateien: einfach weglassen, kein Fehler.

---

## PHASE 3: RECAP AUSGEBEN

Gib einen kompakten Recap in diesem Format aus:

```
Projekt:      <name>
Branch:       <branch> @ <letzter-commit-hash+summary>
Sync:         <N ahead / M behind origin  |  up to date  |  kein Upstream>
Uncommitted:  <N Dateien geaendert>  (<kurze Auflistung oder "keine">)
Letzte Commits:
  <git log --oneline -5>
Zuletzt (Task):  <Kurzfassung aus current-task.md oder "keine Notiz">
Offen:           <offene Punkte aus current-task.md oder "-">
Letzter Deploy:  <Eintrag aus deployment-log.md oder "keine Notiz">
```

Halte es knapp: ein Bildschirm, keine langen Zitate.

---

## Boundaries

### WILL:
- Projekt aus cwd ermitteln, im Home-Verzeichnis nachfragen
- Branch, letzte 5 Commits, offene Aenderungen und Ahead/Behind vs. origin zeigen
- `current-task.md` und `deployment-log.md` zusammenfassen, falls vorhanden
- Nur `git fetch origin --quiet` als einzige Netz-Operation (offline-tolerant)

### WILL NOT:
- Dateien aendern, stagen, committen oder pushen: NIEMALS (strikt read-only)
- Bei fehlgeschlagenem Fetch abbrechen, stattdessen lokal weiterarbeiten
- Im Home-Verzeichnis das Projekt raten, immer nachfragen
- Credentials oder Secret-Dateiinhalte ausgeben
