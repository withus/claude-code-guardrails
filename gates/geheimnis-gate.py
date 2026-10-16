#!/usr/bin/env python3
# Geheimnis-Gate: Zugangsdaten aus servers.md gelangen weder ins Modell noch in den Sitzungsverlauf.
# Stand 2026-09-25.
#
#   maske   (PostToolUse, alle Werkzeuge)  Regel geheimnis-maskiert: jeder Wert aus servers.md wird in der
#           Werkzeugausgabe durch [maskiert] ersetzt. Die Ausgabe behaelt ihre Form, sonst verwirft Claude Code
#           die Ersetzung still und nimmt die Originalausgabe (gemessen 2026-09-25).
#   sperre  (PreToolUse)  Regel servers-md-direktzugriff: Read, Edit, Write, Grep, Glob und lesende Bash-Befehle
#           auf servers.md werden abgewiesen. Nur eine Huerde (python -c mit Import umgeht sie), die Maske ist
#           die dichte Schicht. Erlaubter Weg: ein eigenes Hilfsskript liest den Wert und setzt ihn im Befehl ein.
#
# Werte werden nie geloggt, nur Anzahlen. Die Maske faellt OFFEN aus (ohne lesbare Quelle keine Werte),
# meldet das aber im Log und als systemMessage.

import sys
sys.dont_write_bytecode = True
import os
import re
import json
import datetime

QUELLE = os.environ.get("GEHEIMNIS_QUELLE") or os.path.expanduser("~/.claude/servers.md")
STATE_DIR = os.environ.get("AGENTS_STATE_DIR") or os.path.expanduser("~/.claude/state")
LOG_PFAD = os.environ.get("GEHEIMNIS_LOG") or os.path.join(STATE_DIR, "geheimnis-gate.log")
ERSATZ = "[maskiert]"
# Formfelder bleiben unveraendert, sonst verwirft Claude Code die Ersetzung und zeigt das Original
FORMFELDER = {"type", "status", "mimeType", "media_type"}
# Kuerzere Werte nur als ganzes Wort ersetzen, sonst zerschneidet die Maske gewoehnlichen Text
MIN_LAENGE_TEILTEXT = 6
LABEL = re.compile(r"^\s*[-*|]?\s*[^:|]{0,30}?(?<![A-Za-z])(pass\w*|pw|token|api[ _-]?key|key|secret|bearer)\s*:\s*(.+)$", re.I)
FLIESSTEXT = re.compile(r"(?i)(passwort|password|pw)\b[^:]{0,20}\s[`'\"]([^`'\"]{4,})[`'\"]")
DATEINAME = re.compile(r"servers\.md", re.I)
# Bash: Befehl, der servers.md als Argument eines lesenden oder kopierenden Programms nennt
BASH_LESEND = re.compile(
    r"\b(cat|less|more|head|tail|awk|gawk|sed|grep|egrep|rg|cp|mv|ln|base64|xxd|od|strings|python3?|perl|ruby|node|"
    r"php|vim?|nano|tee|dd|cut|sort|uniq|diff|tr|jq|source)\b[^|;&]*servers\.md", re.I)
# grep/rg, die nur Dateinamen oder Anzahlen ausgeben, bleiben erlaubt (Suche nach Verweisen)
BASH_NUR_NAMEN = re.compile(r"^\s*(grep|rg)\s+(-\w*[lLc]\w*\s+)", re.I)
DATEI_WERKZEUGE = ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit")


def log(text):
    try:
        os.makedirs(os.path.dirname(LOG_PFAD), exist_ok=True)
        with open(LOG_PFAD, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), text))
    except OSError:
        pass


def werte_aus(text):
    """Alle Zugangswerte aus dem Text von servers.md: Label-Zeilen (Passwort, Token, Key, Secret) und
    Passwoerter im Fliesstext in Anfuehrungszeichen. Rueckgabe: Menge der Werte, laengste zuerst sortierbar."""
    gefunden = set()
    for roh in text.splitlines():
        zeile = roh.replace("**", "")
        m = LABEL.match(zeile)
        if m:
            wert = m.group(2).strip()
            in_backticks = re.findall(r"`([^`]+)`", wert)
            zitiert = re.match(r"([\"'])(.+?)\1", wert)
            if in_backticks:
                kandidaten = in_backticks
            elif zitiert:
                kandidaten = [zitiert.group(2)]
            else:
                kandidaten = wert.split()[:1]
            gefunden.update(k.strip("`").strip() for k in kandidaten)
        for f in FLIESSTEXT.finditer(zeile):
            gefunden.add(f.group(2))
    return {w for w in gefunden if len(w) >= 3}


def lade_werte():
    with open(QUELLE, encoding="utf-8") as fh:
        return werte_aus(fh.read())


def maskiere_text(text, werte):
    for wert in sorted(werte, key=len, reverse=True):
        if len(wert) >= MIN_LAENGE_TEILTEXT:
            text = text.replace(wert, ERSATZ)
        else:
            text = re.sub(r"(?<![\w])" + re.escape(wert) + r"(?![\w])", ERSATZ, text)
    return text


def maskiere(objekt, werte):
    if isinstance(objekt, str):
        return maskiere_text(objekt, werte)
    if isinstance(objekt, list):
        return [maskiere(v, werte) for v in objekt]
    if isinstance(objekt, dict):
        return {k: (v if k in FORMFELDER else maskiere(v, werte)) for k, v in objekt.items()}
    return objekt


def hook_maske(eingabe):
    antwort = eingabe.get("tool_response")
    if antwort is None:
        return
    try:
        werte = lade_werte()
    except (OSError, ValueError) as exc:
        log("maske quelle-nicht-lesbar %s: %s" % (QUELLE, exc.__class__.__name__))
        print(json.dumps({"systemMessage": "Geheimnis-Gate: servers.md nicht lesbar, Werkzeugausgaben ungemasked."}))
        return
    if not werte:
        log("maske quelle-ohne-werte %s" % QUELLE)
        print(json.dumps({"systemMessage": "Geheimnis-Gate: in servers.md keine Werte erkannt, Werkzeugausgaben ungemasked."}))
        return
    neu = maskiere(antwort, werte)
    if neu == antwort:
        return
    log("maske geheimnis-maskiert werkzeug=%s agent=%s" % (eingabe.get("tool_name"), eingabe.get("agent_type") or "haupt"))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": neu}}))


def greift_zu(werkzeug, eingabe_werkzeug):
    """True, wenn der Aufruf servers.md direkt liest oder beschreibt."""
    if werkzeug in DATEI_WERKZEUGE:
        pfad = str(eingabe_werkzeug.get("file_path") or eingabe_werkzeug.get("notebook_path") or "")
        return bool(DATEINAME.search(os.path.basename(pfad)))
    if werkzeug in ("Grep", "Glob"):
        ziele = " ".join(str(eingabe_werkzeug.get(k) or "") for k in ("path", "glob"))
        return bool(DATEINAME.search(ziele))
    if werkzeug == "Bash":
        befehl = str(eingabe_werkzeug.get("command") or "")
        if not DATEINAME.search(befehl):
            return False
        if BASH_NUR_NAMEN.match(befehl) and not re.search(r"[|;&]", befehl):
            return False
        return bool(BASH_LESEND.search(befehl)) or bool(re.search(r"<\s*\S*servers\.md", befehl, re.I))
    return False


def hook_sperre(eingabe):
    werkzeug = eingabe.get("tool_name") or ""
    if not greift_zu(werkzeug, eingabe.get("tool_input") or {}):
        return
    log("sperre servers-md-direktzugriff werkzeug=%s agent=%s" % (werkzeug, eingabe.get("agent_type") or "haupt"))
    grund = ("Geheimnis-Gate servers-md-direktzugriff: servers.md liest keine Sitzung und kein Unteragent direkt. "
             "Passwort nur ueber ein eigenes Hilfsskript im Befehl einsetzen, das den Wert selbst liest, "
             "oder das eigene Deploy-Werkzeug nutzen. Keinen Ersatzweg suchen; "
             "fehlt ein Zugang, den Nutzer fragen.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": grund}}))


def main():
    einstieg = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        eingabe = json.load(sys.stdin)
    except ValueError:
        log("%s eingabe-kein-json" % einstieg)
        return 0
    if einstieg == "maske":
        hook_maske(eingabe)
    elif einstieg == "sperre":
        hook_sperre(eingabe)
    else:
        log("unbekannter-einstieg %s" % einstieg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
