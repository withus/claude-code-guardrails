#!/usr/bin/env python3
# Freigabe-Gate (PreToolUse, Bash): Deploy und Datenbank-Schreiben nur nach dem Ja des Nutzers im selben Zug.
# Stand 2026-09-25.
#
#   deploy-ohne-freigabe        deploy.py (sftp_deploy, ftps_deploy) mit --yes, also Upload oder Rollback ohne
#                               Rueckfrage. --check und --dry-run lesen nur und bleiben frei.
#   db-schreiben-ohne-freigabe  mysql/mariadb mit schreibendem SQL gegen einen fremden Host oder ueber ssh.
#                               Lokale Datenbanken (ohne Host, localhost, 127.0.0.1, docker exec) bleiben frei.
#
# Freigabe: seit der letzten echten Nutzereingabe eine AskUserQuestion-Frage, deren Text das Stichwort enthaelt
# (deploy bzw. datenbank/db), und die Antwort des Nutzers darauf beginnt mit "Ja". Das Transcript der Hauptsitzung reicht
# auch fuer Unteragenten, deren Hook-Eingabe denselben transcript_path traegt.
# Faellt ZU aus: fehlt oder ist das Transcript unlesbar, gilt keine Freigabe. Nur eine Huerde gegen Umwege
# (python-Skripte mit eigener Verbindung), die schriftliche Regel bleibt die Grundlage.

import sys
sys.dont_write_bytecode = True
import os
import re
import json
import datetime

STATE_DIR = os.environ.get("AGENTS_STATE_DIR") or os.path.expanduser("~/.claude/state")
LOG_PFAD = os.environ.get("FREIGABE_LOG") or os.path.join(STATE_DIR, "freigabe-gate.log")

DEPLOY_AUFRUF = re.compile(r"(\bdeploy\.py|sftp_deploy\.py|ftps_deploy\.py|-m\s+(sftp|ftps)_deploy)\b")
NUR_LESEND = re.compile(r"(^|\s)--(check|dry-run)\b")
MIT_YES = re.compile(r"(^|\s)--yes\b")
# Befehlsteile getrennt pruefen, sonst hebt ein --check oder docker exec in einem Teil die Sperre fuer alle auf
BEFEHLSTRENNER = re.compile(r"\s*(?:;|&&|\|\||\||\n)\s*")
DB_CLIENT = re.compile(r"\b(mysql|mariadb)\b")
DB_SCHREIBEND = re.compile(
    r"\b(insert|update|delete|replace|alter|drop|create|truncate|rename|grant|revoke|call)\b|\bload\s+data\b|"
    r"\bset\s+global\b", re.I)
# SQL aus einer Datei ist nicht einsehbar und gilt als schreibend
SQL_AUS_DATEI = re.compile(r"<\s*[^<\s]+")
# Lesende SQL-Formen mit schreibendem Wort
DB_LESEND_AUSNAHMEN = re.compile(r"\bshow\s+create\b|\bfor\s+update\b", re.I)
HOST_ANGABE = re.compile(r"(?:\s-h\s*|--host[= ])['\"]?([^\s'\";]+)")
LOKALE_HOSTS = {"localhost", "127.0.0.1", "::1"}
ANTWORT_JA = re.compile(r"^\s*ja\b", re.I)

REGELN = {
    "deploy": ("deploy-ohne-freigabe", re.compile(r"deploy", re.I),
               "Deploy mit --yes nur nach dem Ja des Nutzers: erst per AskUserQuestion fragen (Frage nennt 'Deploy', "
               "was wohin geht und den Rollback-Weg; erste Option beginnt mit 'Ja'), dann erneut ausfuehren. "
               "Lesend geht ohne Freigabe: --check oder --dry-run."),
    "db": ("db-schreiben-ohne-freigabe", re.compile(r"datenbank|\bdb\b", re.I),
           "Schreibendes SQL auf einer nicht lokalen Datenbank nur nach dem woertlichen Ja des Nutzers: erst per "
           "AskUserQuestion fragen (Frage nennt 'Datenbank', Tabelle, Aenderung und Backup; erste Option beginnt "
           "mit 'Ja'), dann erneut ausfuehren."),
}


def log(text):
    try:
        os.makedirs(os.path.dirname(LOG_PFAD), exist_ok=True)
        with open(LOG_PFAD, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), text))
    except OSError as exc:
        sys.stderr.write("freigabe-gate: Log nicht schreibbar: %s\n" % exc)


def befehlsteile(befehl):
    return [t for t in BEFEHLSTRENNER.split(befehl) if t.strip()]


def ist_deploy_mit_yes(befehl):
    return any(DEPLOY_AUFRUF.search(t) and MIT_YES.search(t) and not NUR_LESEND.search(t) for t in befehlsteile(befehl))


def teil_schreibt_fremde_db(teil):
    if not DB_CLIENT.search(teil):
        return False
    if not (DB_SCHREIBEND.search(DB_LESEND_AUSNAHMEN.sub(" ", teil)) or SQL_AUS_DATEI.search(teil)):
        return False
    if re.search(r"\bssh\b", teil):
        return True
    if re.search(r"\bdocker\s+exec\b", teil):
        return False
    hosts = {h.strip("'\"").lower() for h in HOST_ANGABE.findall(teil)}
    return bool(hosts - LOKALE_HOSTS)


def ist_fremdes_db_schreiben(befehl):
    # ssh mit SQL in Anfuehrungszeichen darf nicht an Semikolons im SQL zerfallen: ganzer Befehl zusaetzlich
    if re.search(r"\bssh\b", befehl) and teil_schreibt_fremde_db(befehl):
        return True
    return any(teil_schreibt_fremde_db(t) for t in befehlsteile(befehl))


def antworten_text(block):
    inhalt = block.get("content")
    if isinstance(inhalt, str):
        return inhalt
    if isinstance(inhalt, list):
        return " ".join(b.get("text", "") for b in inhalt if isinstance(b, dict))
    return ""


def freigabe_im_zug(transcript_pfad, stichwort):
    """True, wenn seit der letzten echten Nutzereingabe eine AskUserQuestion-Frage mit dem Stichwort gestellt
    und mit einer Antwort beantwortet wurde, die mit "Ja" beginnt. False sonst, auch bei fehlendem Transcript."""
    if not transcript_pfad or not os.path.isfile(transcript_pfad):
        return False
    try:
        return _freigabe_lesen(transcript_pfad, stichwort)
    except Exception as exc:  # unerwarteter Aufbau: keine Freigabe statt Absturz, der Claude Code durchlassen wuerde
        log("verlauf-unlesbar %s" % exc.__class__.__name__)
        return False


def _freigabe_lesen(transcript_pfad, stichwort):
    offene_fragen = {}
    freigegeben = False
    with open(transcript_pfad, encoding="utf-8", errors="replace") as fh:
        for zeile in fh:
            # Vorfilter: nur Nutzerzeilen und Fragen werden geparst, sonst wird ein grosser Verlauf zu langsam
            if '"user"' not in zeile and "AskUserQuestion" not in zeile:
                continue
            try:
                d = json.loads(zeile)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            nachricht = d.get("message")
            inhalt = nachricht.get("content") if isinstance(nachricht, dict) else None
            if d.get("type") == "assistant" and isinstance(inhalt, list):
                for b in inhalt:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion":
                        fragen_liste = (b.get("input") or {}).get("questions")
                        fragen = [q.get("question", "") for q in fragen_liste if isinstance(q, dict)] \
                            if isinstance(fragen_liste, list) else []
                        offene_fragen[b.get("id")] = [f for f in fragen if isinstance(f, str) and stichwort.search(f)]
            elif d.get("type") == "user" and not d.get("isMeta") and not d.get("isCompactSummary"):
                if isinstance(inhalt, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in inhalt):
                    for b in inhalt:
                        if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                            continue
                        passende = offene_fragen.pop(b.get("tool_use_id"), None)
                        if not passende:
                            continue
                        text = antworten_text(b)
                        for frage in passende:
                            m = re.search(re.escape('"' + frage + '"') + r'="([^"]*)"', text)
                            if m:
                                # die letzte Antwort zaehlt, ein spaeteres Nein nimmt ein Ja zurueck
                                freigegeben = bool(ANTWORT_JA.match(m.group(1)))
                elif isinstance(inhalt, str) or isinstance(inhalt, list):
                    # echte Nutzereingabe: Freigaben davor gelten nicht mehr
                    freigegeben = False
                    offene_fragen.clear()
    return freigegeben


def main():
    try:
        eingabe = json.load(sys.stdin)
    except ValueError:
        log("eingabe-kein-json")
        return 0
    if not isinstance(eingabe, dict) or eingabe.get("tool_name") != "Bash":
        return 0
    werkzeug_eingabe = eingabe.get("tool_input")
    befehl = str(werkzeug_eingabe.get("command") or "") if isinstance(werkzeug_eingabe, dict) else ""
    arten = [a for a, trifft in (("deploy", ist_deploy_mit_yes(befehl)), ("db", ist_fremdes_db_schreiben(befehl))) if trifft]
    agent = eingabe.get("agent_type") or "haupt"
    for art in arten:
        regel, stichwort, anweisung = REGELN[art]
        if freigabe_im_zug(eingabe.get("transcript_path"), stichwort):
            log("%s freigegeben agent=%s" % (regel, agent))
            continue
        log("%s gesperrt agent=%s" % (regel, agent))
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": "Freigabe-Gate %s: %s" % (regel, anweisung)}}))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
