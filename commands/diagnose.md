---
name: diagnose
description: "Startet eine Fehlerdiagnose nach dem Drei-Phasen-Schema. Setzt den Marker für das Schema-Gate und liefert die Vorlage."
category: utility
complexity: basic
mcp-servers: []
allowed-tools: Bash(bash ~/.claude/guardrails/scripts/diagnose-start.sh:*), Bash(true), Bash(cat ~/.claude/guardrails/templates/diagnose.md)
---

# /diagnose

Startet eine Fehlerdiagnose nach dem Drei-Phasen-Schema der Vorlage unten.

## Status

!`bash ~/.claude/guardrails/scripts/diagnose-start.sh 2>&1 || true`

## Vorlage

!`cat ~/.claude/guardrails/templates/diagnose.md`

## Arbeitsauftrag

Symptom und Angaben des Auftraggebers: $ARGUMENTS

Arbeite ausschließlich nach der Vorlage oben. Liefere zuerst **nur Phase A**, also die Karte, und ende mit der Zeile "Fehlt eine Stelle?". Keine Ursache, keine Hypothese, keine Lösungsvorschläge in Phase A.

Der vollständige Bericht kommt als Datei nach `.claude/diagnosen/<JJJJ-MM-TT>-<kurzname>.md` im Projekt. Die Chat-Antwort ist nur die Kurzfassung aus dem Kopfkommentar der Vorlage (Stand:, Belegt:, Offen:, Vorschlag:, Von dir:) mit dem Pfad zur Datei. Jede Aussage unter Belegt: trägt ein [B-n], das in der Datei steht. Keine Tabellen, keine Befehle, höchstens 30 Zeilen.

Fehlt ein konkreter Bezeichner des gemeldeten Falls (Datensatz-ID, Request-ID, Logzeile), trage unter "Bezeichner" das Wort FEHLT ein, fülle "Anforderung an den Auftraggeber" aus und beende den Bericht dort.

Ein Stop-Hook prüft jede Antwort auf Form und Vollständigkeit. Weist er eine Antwort zurück, nennt er die verletzte Regel. Behebe genau diese Stelle.

Soll eine Regel bewusst übergangen werden, schreibe eine Zeile `Übergehung: <regelname>, <Begründung>` in den Bericht oder in die Kurzfassung, etwa `Übergehung: gemessen-ohne-beleg, wörtliches Zitat des Auftraggebers`. Der Regelname steht in der Meldung des Gates. Das wird im TASKLOG des Projekts gezählt. Übergehungen sind Ausnahmen mit Begründung, keine Abkürzung.
