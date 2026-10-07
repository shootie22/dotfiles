#!/usr/bin/env python3
"""Alert relay: one notification per event, through the first channel that
takes it (Pushover, then email). Design: docs/ha/alerting.md in the
infrastructure repo.

POST /alert          {"title", "message", "key"?, "emergency"?: bool}
POST /alertmanager   Alertmanager's webhook format. Alerts labelled
                     page="true" are emergencies.

Emergencies go out with Pushover's emergency priority (repeats until
acknowledged, respects Do Not Disturb because Critical Alerts are off). If
nobody acknowledges within ack_timeout, the next channel gets it too. When
the alert resolves, its repeats are cancelled and it isn't escalated.
"""

import json
import os
import re
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


def watch_receipt(receipt, title, message, tag=None):
    """If an emergency isn't acknowledged in time, try the next channels too."""
    time.sleep(CFG["ack_timeout"])
    with lock:
        if tag in resolved:
            return
    try:
        if acknowledged(receipt):
            return
    except Exception as e:
        log(f"receipt check failed ({e}), escalating anyway")
    log(f"not acknowledged after {CFG['ack_timeout']}s, escalating: {title}")
    deliver(title, message, emergency=True, skip=("pushover",))


def deliver(title, message, emergency=False, skip=(), tag=None):
    for name, send in CHANNELS:
        if name in skip:
            continue
        try:
            receipt = send(title, message, emergency, tag)
            log(f"sent via {name}: {title}")
            if name == "pushover" and emergency and receipt:
                threading.Thread(target=watch_receipt, args=(receipt, title, message, tag),
                                 daemon=True).start()
            return True
        except Exception as e:
            log(f"{name} failed ({e}), trying the next channel")
    log(f"every channel failed: {title}")
    return False


def accept(title, message, key=None, emergency=False, tag=None):
    now = time.time()
    key = key or title
    with lock:
        if now - recent.get(key, 0) < CFG["dedup_window"]:
            log(f"duplicate within the window, dropped: {key}")
            return
        sent_times[:] = [t for t in sent_times if now - t < 3600]
        if len(sent_times) >= CFG["max_per_hour"] and not emergency:
            log(f"hourly cap reached, dropped: {title}")
            return
        recent[key] = now
        sent_times.append(now)
        if emergency:
            resolved.discard(tag)
    threading.Thread(target=deliver, args=(title, message, emergency, (), tag),
                     daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        if self.path == "/alert":
            accept(body["title"], body["message"], body.get("key"), bool(body.get("emergency")))
        elif self.path == "/alertmanager":
            for a in body.get("alerts", []):
                labels, notes = a.get("labels", {}), a.get("annotations", {})
                name = labels.get("alertname", "alert")
                state = "resolved" if a.get("status") == "resolved" else "firing"
                title = f"{name} {state}"
                message = notes.get("summary") or notes.get("description") or name
                key = f"{name}/{labels.get('instance', '')}/{state}"
                page = labels.get("page") == "true"
                # Pushover tags: letters, digits and a few marks only.
                tag = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{name}-{labels.get('instance', '')}")
                if page and state == "resolved":
                    with lock:
                        resolved.add(tag)
                    threading.Thread(target=cancel, args=(tag,), daemon=True).start()
                accept(title, message, key, page and state == "firing", tag if page else None)
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
    threading.Thread(target=heartbeat, daemon=True).start()
    log(f"alert relay listening on {CFG['listen']}")
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
