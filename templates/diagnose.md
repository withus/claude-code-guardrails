# Diagnose: <Kurzname>
Phase: A | B | C
Projekt: <Pfad>   Branch/HEAD: <...>   Modus: Karte+Bugfix | Begrenzter Umbau | Vollmodell

<!--
  VORLAGE FUER DIAGNOSEBERICHTE (Schema 2, seit 2026-09-22)
  Drei Phasen, jede endet mit einem Stopp. Die naechste Phase beginnt erst nach Freigabe.
  Eine Antwort, die mit "Rückfrage:" beginnt und keinen Karte-, Gemessen-, Ursache- oder
  Geschlossen-Abschnitt enthaelt, ist kein Bericht und geht am Gate vorbei.
  Kein Abschnitt darf frueher stehen, als er hingehoert.
  Der Stop-Hook prueft nur Form und Vollstaendigkeit, nie Inhalt.
  Hook: ~/.claude/guardrails/hooks/diagnose-schema-gate.sh

  ZWEI EBENEN (seit 2026-09-25):
  1. Dieser vollstaendige Bericht liegt als Datei unter <projekt>/.claude/diagnosen/<JJJJ-MM-TT>-<kurzname>.md.
     Das Gate prueft die Datei mit allen Regeln unten.
  2. Die Chat-Antwort ist nur die Kurzfassung (Vorlage ganz unten) und nennt den Pfad zur Datei.
     Pflicht: Stand:, Belegt:, Offen:, Vorschlag:, Von dir: am Zeilenanfang, als Liste oder fett erlaubt.
     Jede Aussage unter Belegt: traegt ein [B-n], das in der Datei als Beleg steht ("Belegt: keine" wenn nichts).
     Keine Tabellen, keine Codebloecke oder Befehlszeilen, hoechstens 30 Zeilen.
     Kurzfassung (nur im Chat, nie in dieser Datei):
       Stand: <ein bis zwei Saetze in Alltagssprache: welche Phase, was jetzt feststeht>
       Belegt:
       - <Aussage mit Zahl und Deutung> [B-n]
       Offen: <was noch nicht geklaert ist>
       Vorschlag: <naechster Schritt>
       Von dir: <was der Auftraggeber tun oder entscheiden soll>
       Bericht: .claude/diagnosen/<JJJJ-MM-TT>-<kurzname>.md
-->

## Gemeldeter Fall
Symptom (wörtlich vom Auftraggeber): "..."
Bezeichner: <Produkt-ID / Request-ID / Log-Zeile>
Meldung der Gegenstelle (wörtlich): "..."
Anforderung an den Auftraggeber: <nur wenn etwas fehlt>

<!-- Bezeichner ist Pflicht. Fehlt er, hier FEHLT eintragen und die Anforderung
     ausfuellen. Dann endet der Bericht hier, Phase A beginnt nicht. -->

## Belege
[B-1] Befehl: `...`
      Ausgabe: (roh, gekürzt, aber wörtlich)
[B-2] Befehl: `...`
      Ausgabe: ...

---

# Phase A: Karte

## Suchraum
Verzeichnisse: ...
Ausgeschlossen: <was und warum>

<!-- Ausschluesse sind Pflicht. Eine Zahl ohne Abgrenzung ist nicht pruefbar. -->

## Karte

| Nr | Pfad | Zeilen | Was dort mit dem Wert passiert | Erreicht über (Route/URL/Loader/Cron) | Live-Hash = lokal? | Beleg |
|---|---|---|---|---|---|---|
| 1 | ... | ... | ... | ... | ja / nein / nicht geprüft weil ... | [B-n] |

## Nächste Phase
Gemessen wird: <was in Phase B gemessen wird>
Nicht angefasst: <was unverändert bleibt: Live, DB, Dateien>
Umfang: <ungefähr: Befehle, Dauer, Zugänge>

<!-- Pflicht in jeder Freigabe-Anfrage (Phase A und B), alle drei Zeilen ausgefuellt. Regel naechste-phase-fehlt. -->

## Frage an den Auftraggeber
Fehlt eine Stelle?

<!-- Pflicht, letzte nichtleere Zeile von Phase A.
     In Phase A ist kein Abschnitt "Ursache" oder "Geschlossen" erlaubt. -->

---

# Phase B: Reproduktion

## Karte-Freigabe
Antwort des Auftraggebers: "..." (Datum: JJJJ-MM-TT)

<!-- Pflicht. Ohne Freigabe der Karte keine Phase B. -->

## Reproduktion
Eingabe: <der Bezeichner aus "Gemeldeter Fall", wörtlich>
Versuch 1
Pfad aus der Karte: Nr <n>
Befehl: `...`
Ausgabe: ...
Soll: ...
Ist: ...
Ergebnis: reproduziert JA | NEIN
Wenn NEIN: <was fehlt, um zu reproduzieren>   <- Pflicht direkt nach jedem NEIN
Versuch 2
...

<!-- Mehrere Versuche sind erlaubt, jeder mit eigenem Ergebnis. Phase C ist frei, sobald ein
     Versuch JA hat und jedes NEIN mit "Wenn NEIN:" dokumentiert ist. Nur NEIN: Bericht endet hier. -->

## Nächste Phase
Gemessen wird: <was in Phase C gemessen wird>
Nicht angefasst: <was unverändert bleibt>
Umfang: <ungefähr>

---

# Phase C: Ursache

## Gemessen
- <Aussage> [B-n]
- <Aussage> [B-n]

<!-- Jede Zeile braucht einen Belegverweis. Eine Aussage ohne [B-n] gehoert
     nicht unter Gemessen, sondern unter Vermutet. -->

## Geschlossen
Hypothese: ...
Filter: <betrifft alle X, für die Y gilt>

<!-- Der Filter ist Pflicht und muss pruefbar formuliert sein, also so, dass
     man mit einem Befehl entscheiden kann, ob ein Fall darunter faellt. -->

## Gegenprobe
1. Liegt der gemeldete Fall <Bezeichner> im Filter?
   Befehl: `...`   Ausgabe: ...   Ergebnis: JA | NEIN   [B-n]
2. Ein Fall außerhalb des Filters, der den Fehler NICHT zeigt: <Bezeichner>
   Befehl: `...`   Ausgabe: ...   [B-n]
3. Erklärt die Hypothese den Ist-Wert aus Phase B exakt, nicht nur "ein" Fehler?
   JA | NEIN, Beleg: [B-n]

<!-- Gegenprobe 1 ist die wichtigste. Liegt der gemeldete Fall nicht im eigenen
     Filter, faellt die Hypothese, bevor sie den Auftraggeber erreicht. -->

## Vermutet
- <was offen ist und womit es sich klären ließe>

## Unabhängige Prüfung
Prüfer: <Agentname>
Bekam: Hypothese, Belege, gemeldeter Fall. NICHT die Argumentation.
Urteil: erklärt den gemeldeten Fall JA | NEIN | UNKLAR
Begründung: <ein Satz>

## Optionen

| Nr | Option | Berührt (Pfade) | Aufwand | Risiko / Nebenwirkung | Braucht Modus |
|---|---|---|---|---|---|
| 1 | ... | ... | ... | ... | ... |

## Empfehlung
<ein Satz>

## Entscheidung des Auftraggebers
<leer, bis entschieden>
