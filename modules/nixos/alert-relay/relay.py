#!/usr/bin/env python3
"""Alert relay: one notification per event, through the first channel that
takes it (Pushover, then email). Design: docs/ha/alerting.md in the
infrastructure repo.

POST /alert          {"title", "message", "key"?, "emergency"?: bool,
                      "tag"?, "resolves"?: bool}: an emergency with a tag is
                     cancelled by a later message with the same tag and
                     resolves set.
POST /alertmanager   Alertmanager's webhook format. Alerts labelled
                     page="true" are emergencies.
GET  /events?after=N  The journal: every alert received and what happened to
                     it (sent, which channel, duplicate, capped, held back as
                     the standby, escalated), oldest first, for Hub
                     (infra-hub #36). Kept 30 days.
GET  /health         200 while the relay runs.

A standby relay (standby_for set to the main relay's /health) gets the same
alerts but only sends them on while the main one doesn't answer, so there's
a way out when the edge is down without every alert arriving twice.

Emergencies go out with Pushover's emergency priority (repeats until
acknowledged, respects Do Not Disturb because Critical Alerts are off). If
nobody acknowledges within ack_timeout, the next channel gets it too. When
the alert resolves, its repeats are cancelled and it isn't escalated.
"""

import json
import os
import re
import socket
import smtplib
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG = json.load(open(sys.argv[1]))
CRED_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")
recent = {}          # dedup key -> time last sent
sent_times = []      # for the hourly cap
resolved = set()     # emergency tags whose alert has resolved since
lock = threading.Lock()


def log(msg):
    print(msg, flush=True)


# The journal (infra-hub #36): every alert that comes in, and what
# happened to it, appended to a file, so Hub's incident list matches what
# reached the phone. Readable at GET /events?after=<seq>. Writing it can
# never stop an alert: every error here is logged and swallowed.
JOURNAL = os.path.join(os.environ.get("STATE_DIRECTORY", "/tmp"), "journal.jsonl")
KEEP_DAYS = 30
journal_lock = threading.Lock()
journal_seq = 0
HOST = socket.gethostname()
ROLE = "standby" if CFG.get("standby_for") else "main"


def journal_start():
    """Find the last sequence number and drop entries older than KEEP_DAYS."""
    global journal_seq
    try:
        if not os.path.exists(JOURNAL):
            return
        cutoff = time.time() - KEEP_DAYS * 86400
        kept = []
        with open(JOURNAL) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                journal_seq = max(journal_seq, e.get("seq", 0))
                if e.get("at", 0) >= cutoff:
                    kept.append(line if line.endswith("\n") else line + "\n")
        tmp = JOURNAL + ".tmp"
        with open(tmp, "w") as f:
            f.writelines(kept)
        os.replace(tmp, JOURNAL)
    except Exception as e:
        log(f"journal: can't read {JOURNAL}: {e}")


def journal(kind, **fields):
    """Append one entry; returns its sequence number (0 when it failed)."""
    global journal_seq
    try:
        with journal_lock:
            journal_seq += 1
            entry = {"seq": journal_seq, "at": time.time(), "relay": HOST, "role": ROLE, "kind": kind, **fields}
            with open(JOURNAL, "a") as f:
                f.write(json.dumps(entry, separators=(",", ":")) + "\n")
            return journal_seq
    except Exception as e:
        log(f"journal: can't write: {e}")
        return 0


def journal_read(after, limit):
    out = []
    try:
        with open(JOURNAL) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("seq", 0) > after:
                    out.append(e)
                    if len(out) >= limit:
                        break
    except FileNotFoundError:
        pass
    return out


def journal_compact():
    while True:
        time.sleep(86400)
        with journal_lock:
            journal_start()


def credential(name):
    with open(os.path.join(CRED_DIR, name)) as f:
        return f.read().strip()


def post(url, data, headers=None, timeout=10):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def pushover(title, message, emergency, tag=None):
    fields = {
        "token": credential("pushover_app_token"),
        "user": credential("pushover_user_key"),
        "title": title,
        "message": message,
    }
    if emergency:
        fields.update(priority="2", retry="60", expire="3600")
        if tag:
            fields["tags"] = tag
    status, body = post("https://api.pushover.net/1/messages.json",
                        urllib.parse.urlencode(fields).encode())
    reply = json.loads(body)
    if status != 200 or reply.get("status") != 1:
        raise RuntimeError(f"pushover refused: {reply}")
    return reply.get("receipt")


def email(title, message, emergency, tag=None):
    """Deliver straight to Mailfence, like any mail server would. No login:
    the edge is allowed to send for radunenu.com through its SPF record."""
    from email.message import EmailMessage
    msg = EmailMessage()
    msg["From"] = f"Infra alerts <{CFG['email']}>"
    msg["To"] = CFG["email"]
    msg["Subject"] = ("[infra, urgent] " if emergency else "[infra] ") + title
    msg.set_content(message)
    last = None
    for mx in CFG["mail_servers"]:
        try:
            with smtplib.SMTP(mx, 25, timeout=20) as s:
                s.starttls()
                s.send_message(msg)
            return
        except Exception as e:
            last = e
    raise RuntimeError(f"no mail server took it: {last}")


CHANNELS = [("pushover", pushover), ("email", email)]


def acknowledged(receipt):
    url = (f"https://api.pushover.net/1/receipts/{receipt}.json?"
           + urllib.parse.urlencode({"token": credential("pushover_app_token")}))
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r).get("acknowledged") == 1


def cancel(tag):
    """Stop the repeats of every emergency sent with this tag."""
    try:
        post(f"https://api.pushover.net/1/receipts/cancel_by_tag/{tag}.json",
             urllib.parse.urlencode({"token": credential("pushover_app_token")}).encode())
        log(f"cancelled the repeats of {tag}")
    except Exception as e:
        log(f"cancelling {tag} failed: {e}")


def watch_receipt(receipt, title, message, tag=None, ref=0):
    """If an emergency isn't acknowledged in time, try the next channels too."""
    time.sleep(CFG["ack_timeout"])
    with lock:
        if tag in resolved:
            return
    try:
        if acknowledged(receipt):
            journal("acknowledged", ref=ref)
            return
    except Exception as e:
        log(f"receipt check failed ({e}), escalating anyway")
    log(f"not acknowledged after {CFG['ack_timeout']}s, escalating: {title}")
    journal("escalated", ref=ref, after=CFG["ack_timeout"])
    deliver(title, message, emergency=True, skip=("pushover",), ref=ref)


def deliver(title, message, emergency=False, skip=(), tag=None, ref=0):
    errors = []
    for name, send in CHANNELS:
        if name in skip:
            continue
        try:
            receipt = send(title, message, emergency, tag)
            log(f"sent via {name}: {title}" + (f" (receipt {receipt})" if receipt else ""))
            journal("delivered", ref=ref, via=name, emergency=emergency, failed_first=errors)
            if name == "pushover" and emergency and receipt:
                threading.Thread(target=watch_receipt, args=(receipt, title, message, tag, ref),
                                 daemon=True).start()
            return True
        except Exception as e:
            log(f"{name} failed ({e}), trying the next channel")
            errors.append(f"{name}: {e}")
    log(f"every channel failed: {title}")
    journal("failed", ref=ref, errors=errors)
    return False


def resolve(tag):
    """The alert behind an emergency is over: stop its repeats, don't escalate."""
    with lock:
        resolved.add(tag)
    journal("cancelled", tag=tag)
    threading.Thread(target=cancel, args=(tag,), daemon=True).start()


def main_relay_up():
    try:
        with urllib.request.urlopen(CFG["standby_for"], timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


def accept(title, message, key=None, emergency=False, tag=None, resolving=False, meta=None):
    """Decide whether to send, journal the decision, send if so."""
    entry = {"title": title, "message": message, "key": key or title, "emergency": emergency,
             "tag": tag, "resolves": resolving, **(meta or {})}
    if CFG.get("standby_for") and main_relay_up():
        journal("received", decision="held", why="the main relay answers", **entry)
        return
    now = time.time()
    key = key or title
    with lock:
        if now - recent.get(key, 0) < CFG["dedup_window"]:
            log(f"duplicate within the window, dropped: {key}")
            decision = "duplicate"
        else:
            sent_times[:] = [t for t in sent_times if now - t < 3600]
            # Emergencies, and the all-clear for one, always go out.
            if len(sent_times) >= CFG["max_per_hour"] and not (emergency or resolving):
                log(f"hourly cap reached, dropped: {title}")
                decision = "capped"
            else:
                recent[key] = now
                sent_times.append(now)
                if emergency:
                    resolved.discard(tag)
                decision = "send"
    ref = journal("received", decision=decision, **entry)
    if decision == "send":
        threading.Thread(target=deliver, args=(title, message, emergency, (), tag, ref),
                         daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/events":
            q = urllib.parse.parse_qs(url.query)
            try:
                after = int(q.get("after", ["0"])[0])
                limit = max(1, min(int(q.get("limit", ["500"])[0]), 2000))
            except ValueError:
                self.send_response(400)
                self.end_headers()
                return
            body = json.dumps({"relay": HOST, "role": ROLE, "last": journal_seq,
                               "events": journal_read(after, limit)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200 if url.path == "/health" else 404)
        self.end_headers()

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        if self.path == "/alert":
            tag = body.get("tag")
            if tag and body.get("resolves"):
                resolve(tag)
            accept(body["title"], body["message"], body.get("key"), bool(body.get("emergency")),
                   tag, resolving=bool(tag and body.get("resolves")),
                   meta={"source": body.get("source") or self.client_address[0]})
        elif self.path == "/alertmanager":
            for a in body.get("alerts", []):
                labels, notes = a.get("labels", {}), a.get("annotations", {})
                name = labels.get("alertname", "alert")
                state = "resolved" if a.get("status") == "resolved" else "firing"
                title = f"{name} {state}"
                message = notes.get("summary") or notes.get("description") or name
                # The fingerprint tells apart alerts that share a name and
                # instance (the node alerts all come from kube-state-metrics).
                ident = a.get("fingerprint") or labels.get("instance", "")
                key = f"{name}/{ident}/{state}"
                page = labels.get("page") == "true"
                # Pushover tags go into a URL path when cancelled: letters,
                # digits, - and _ only (a dot there gave a 404).
                tag = re.sub(r"[^A-Za-z0-9_-]", "_", f"{name}-{ident}")
                if page and state == "resolved":
                    resolve(tag)
                accept(title, message, key, page and state == "firing", tag if page else None,
                       resolving=page and state == "resolved",
                       meta={"source": "alertmanager", "alertname": name, "status": state,
                             "fingerprint": a.get("fingerprint", ""), "labels": labels,
                             "startsAt": a.get("startsAt"), "endsAt": a.get("endsAt")})
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(202)
        self.end_headers()

    def log_message(self, *args):
        pass


def heartbeat():
    """Tell healthchecks.io we're alive; silence there means the relay died."""
    url_file = os.path.join(CRED_DIR, "healthchecks_url")
    while True:
        if os.path.exists(url_file):
            try:
                urllib.request.urlopen(open(url_file).read().strip(), timeout=10)
            except Exception as e:
                log(f"heartbeat failed: {e}")
        time.sleep(60)


def main():
    host, port = CFG["listen"].rsplit(":", 1)
    journal_start()
    threading.Thread(target=journal_compact, daemon=True).start()
    threading.Thread(target=heartbeat, daemon=True).start()
    log(f"alert relay listening on {CFG['listen']}, journal {JOURNAL} at {journal_seq}")
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
