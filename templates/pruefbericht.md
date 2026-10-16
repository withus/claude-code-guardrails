# Prüfbericht (Schema für Prüfer-Agenten, Stand 2026-09-22)

Die letzte Nachricht eines Prüfers ist der Bericht, auch wenn maxTurns erreicht ist. Kein Abbruch ohne Bericht.
Die Form prüft im Ursprungs-Setup ein SubagentStop-Gate, das in diesem Repository nicht enthalten ist (README, Limits).

    Urteil: PASS | FLAG | GAP
    Regel: <Regel-ID, etwa R-07 oder B13>   (bei GAP erlaubt: keine trifft)
    Beleg: <Pfad:Zeile oder [B-n]>          (mehrere Belege: eine Zeile je Beleg)
    Begründung: <ein Satz>

Bedeutung: PASS = die Regel erlaubt das. FLAG = verstößt gegen die genannte Regel, geht an den Umsetzer zurück.
GAP = keine Regel entscheidet den Fall, der Auftraggeber entscheidet.
Übergehung einer Formregel: Zeile `Übergehung: <regelname>, <Grund>`, etwa `Übergehung: beleg-fehlt, Beleg liegt beim Auftraggeber`.
