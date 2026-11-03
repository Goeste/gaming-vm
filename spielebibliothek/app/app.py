"""Spielebibliothek - Home-Assistant-App

Zeigt die Steam-Spiele aller eingetragenen Konten, merkt Installieren/Entfernen in
<Freigabe>/Bibliothek/auftrag.json vor und kann den Master auf dem Proxmox-Host per
SSH sofort starten (game-disk-sync.sh --full-now). Der Master liest den Auftrag und
schreibt status.json zurueck (master/library-queue.ps1).

Zugriff nur ueber Home-Assistant-Ingress (Anmeldung + nur Administratoren).
"""
import json
import os

import subprocess
import threading
import time
from datetime import datetime, timezone

import requests
from flask import Flask, abort, jsonify, request, send_from_directory

DATA = os.environ.get("SB_DATA", "/data")
OPTIONS_FILE = os.path.join(DATA, "options.json")
CACHE_FILE = os.path.join(DATA, "owned.json")
SSH_DIR = os.path.join(DATA, "ssh")
SSH_KEY = os.path.join(SSH_DIR, "id_ed25519")
STEAM_API = os.environ.get("SB_STEAM_API", "https://api.steampowered.com")
DEV = os.environ.get("SB_DEV") == "1"          # nur für lokale Tests: ohne Ingress-Pruefung
INGRESS_IP = "172.30.32.2"

app = Flask(__name__, static_folder=None)
lock = threading.Lock()


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def options():
    with open(OPTIONS_FILE, encoding="utf-8") as f:
        o = json.load(f)
    o.setdefault("accounts", [])
    o.setdefault("library_folder", "/share/gaming/Bibliothek")
    o.setdefault("proxmox_host", "")
    o.setdefault("proxmox_user", "root")
    return o


def read_json(path, default):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def bib_dir():
    return options()["library_folder"].rstrip("/")


def order_path():
    return os.path.join(bib_dir(), "auftrag.json")


def load_order():
    o = read_json(order_path(), {})
    o.setdefault("version", 1)
    o.setdefault("jetzt", None)
    o.setdefault("items", [])
    return o


# ---------------------------------------------------------------- Zugriffsschutz
@app.before_request
def only_ingress():
    if DEV:
        return
    if request.remote_addr != INGRESS_IP:
        abort(403)


@app.after_request
def no_cache(resp):
    resp.headers["Cache-Control"] = "no-store"
    return resp


# ---------------------------------------------------------------- Steam
def fetch_owned(account, key):
    sid = str(account.get("steamid", ""))
    if sid == "76561190000000000":
        raise RuntimeError("Beispiel-SteamID - in der Konfiguration die echte 17-stellige SteamID64 eintragen")
    try:
        r = requests.get(
            f"{STEAM_API}/IPlayerService/GetOwnedGames/v1/",
            params={"key": key, "steamid": sid, "include_appinfo": 1,
                    "include_played_free_games": 1, "format": "json"},
            timeout=20,
        )
    except requests.RequestException as e:
        # Meldung ohne URL, damit der API-Key nicht auf der Seite erscheint
        raise RuntimeError(f"Steam nicht erreichbar ({type(e).__name__})") from None
    if r.status_code in (401, 403):
        raise RuntimeError("API-Key ungültig")
    if r.status_code == 400:
        raise RuntimeError(f"Steam lehnt die SteamID {sid} ab - ist es die 17-stellige SteamID64 (beginnt mit 7656119)?")
    if r.status_code != 200:
        raise RuntimeError(f"Steam antwortet mit Fehler {r.status_code}")
    resp = r.json().get("response", {})
    if "games" not in resp:
        raise RuntimeError("keine Spiele sichtbar - Steam-Profil: Spieldetails auf 'Öffentlich' stellen")
    return [{"appid": int(g["appid"]), "name": g.get("name") or f"App {g['appid']}",
             "playtime": int(g.get("playtime_forever", 0))} for g in resp["games"]]


def refresh_cache():
    o = options()
    key = o.get("steam_api_key", "")
    cache = {"time": now_iso(), "accounts": {}, "errors": {}}
    if not key:
        cache["errors"]["*"] = "Kein Steam-API-Key in der Konfiguration"
    for acc in o["accounts"]:
        if not key:
            break
        try:
            cache["accounts"][acc["name"]] = fetch_owned(acc, key)
        except Exception as e:                       # pylint: disable=broad-except
            cache["errors"][acc["name"]] = str(e)
            old = read_json(CACHE_FILE, {}).get("accounts", {}).get(acc["name"])
            if old:
                cache["accounts"][acc["name"]] = old
    write_json_atomic(CACHE_FILE, cache)
    return cache


# ---------------------------------------------------------------- SSH zum Host
def ensure_key():
    os.makedirs(SSH_DIR, mode=0o700, exist_ok=True)
    if not os.path.exists(SSH_KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "spielebibliothek-ha",
                        "-f", SSH_KEY], check=True)
    with open(SSH_KEY + ".pub", encoding="utf-8") as f:
        return f.read().strip()


def ssh(arg, timeout=20):
    o = options()
    if not o["proxmox_host"]:
        return None, "Kein Proxmox-Host konfiguriert"
    cmd = ["ssh", "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
           "-o", "StrictHostKeyChecking=accept-new",
           "-o", f"UserKnownHostsFile={os.path.join(SSH_DIR, 'known_hosts')}",
           # "--" und ein Befehlsname vorne: sonst liest ssh "--status" als eigene Option
           "--", f"{o['proxmox_user']}@{o['proxmox_host']}", f"game-disk-sync {arg}"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "Zeitüberschreitung bei der SSH-Verbindung"
    except FileNotFoundError:
        return None, "ssh nicht installiert"
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if p.returncode != 0:
        return None, err or out or f"Exit-Code {p.returncode}"
    return out, None


# ---------------------------------------------------------------- Abgleich
def reconcile(order, status):
    """Erledigte Aufträge aus der Warteschlange nehmen."""
    if not status:
        return order, False
    installed = {int(g["appid"]): g for g in status.get("installed") or [] if str(g.get("appid", "")).isdigit()}
    results = {}
    for r in status.get("results") or []:
        try:
            results[int(r["appid"])] = r
        except (KeyError, TypeError, ValueError):
            pass
    keep, changed = [], False
    for it in order["items"]:
        req = parse_iso(it.get("requested"))
        res = results.get(it["appid"])
        res_time = parse_iso(res.get("time")) if res else None
        processed = bool(res_time and req and res_time >= req and res.get("action") == it["action"])
        g = installed.get(it["appid"])
        if it["action"] == "install" and g and g.get("state") == 4:
            changed = True
            continue
        if it["action"] == "remove" and processed and not g:
            changed = True
            continue
        if processed and res.get("result") in ("abgelehnt", "fehler", "nicht vorhanden"):
            changed = True
            continue  # Ergebnis bleibt in status.json sichtbar
        keep.append(it)
    if changed:
        order["items"] = keep
    return order, changed


# ---------------------------------------------------------------- API
@app.get("/")
def index():
    return send_from_directory(os.path.join(os.path.dirname(__file__), "static"), "index.html")


@app.get("/api/state")
def state():
    o = options()
    cache = read_json(CACHE_FILE, None)
    if cache is None:
        cache = refresh_cache()
    status = read_json(os.path.join(bib_dir(), "status.json"), None)
    folder_ok = os.path.isdir(bib_dir())
    with lock:
        order = load_order()
        if folder_ok:
            order, changed = reconcile(order, status)
            if changed:
                write_json_atomic(order_path(), order)

    games = {}
    for acc_name, lst in cache.get("accounts", {}).items():
        for g in lst:
            e = games.setdefault(g["appid"], {"appid": g["appid"], "name": g["name"], "owners": [], "playtime": 0})
            e["owners"].append(acc_name)
            e["playtime"] += g.get("playtime", 0)
    installed = {}
    for g in (status or {}).get("installed") or []:
        try:
            installed[int(g["appid"])] = g
        except (KeyError, TypeError, ValueError):
            pass
    for appid, g in installed.items():   # installiert, aber in keinem Konto (z.B. Demo, Gratis-Spiel)
        games.setdefault(appid, {"appid": appid, "name": g.get("name") or f"App {appid}", "owners": [], "playtime": 0})
    results = {}
    for r in (status or {}).get("results") or []:
        try:
            results[int(r["appid"])] = r
        except (KeyError, TypeError, ValueError):
            pass
    queue = {it["appid"]: it for it in order["items"]}
    out = []
    for appid, g in games.items():
        i = installed.get(appid)
        g["installed"] = bool(i)
        g["state"] = i.get("state") if i else None
        g["size"] = i.get("size") if i else 0
        g["queued"] = queue.get(appid, {}).get("action")
        r = results.get(appid)
        g["result"] = {"result": r.get("result"), "message": r.get("message"), "time": r.get("time")} if r else None
        out.append(g)
    out.sort(key=lambda x: x["name"].lower())

    try:
        pub = ensure_key()
    except Exception as e:                           # pylint: disable=broad-except
        pub = f"(Schlüssel konnte nicht erzeugt werden: {e})"
    return jsonify({
        "games": out,
        "accounts": [a["name"] for a in o["accounts"]],
        "cache_time": cache.get("time"),
        "errors": cache.get("errors", {}),
        "jetzt": order.get("jetzt"),
        "queue_count": len(order["items"]),
        "status": {k: (status or {}).get(k) for k in ("time", "computer", "free_bytes", "total_bytes", "jetzt_erledigt")} if status else None,
        "folder": bib_dir(),
        "folder_ok": folder_ok,
        "host_configured": bool(o["proxmox_host"]),
        "authorized_key": f'command="/usr/local/sbin/game-disk-sync.sh",restrict {pub}',
    })


@app.post("/api/refresh")
def refresh():
    cache = refresh_cache()
    return jsonify({"ok": True, "errors": cache.get("errors", {})})


@app.post("/api/queue")
def queue():
    body = request.get_json(silent=True) or {}
    action = body.get("action")
    try:
        appid = int(body.get("appid"))
    except (TypeError, ValueError):
        abort(400)
    if action not in ("install", "remove", "cancel") or not 0 < appid < 2 ** 32:
        abort(400)
    if not os.path.isdir(bib_dir()):
        return jsonify({"ok": False, "error": f"Ordner {bib_dir()} nicht erreichbar"}), 409
    name = str(body.get("name") or f"App {appid}")[:200]
    with lock:
        order = load_order()
        order["items"] = [it for it in order["items"] if it.get("appid") != appid]
        if action != "cancel":
            order["items"].append({"platform": "steam", "appid": appid, "name": name,
                                   "action": action, "requested": now_iso()})
        write_json_atomic(order_path(), order)
    return jsonify({"ok": True})


@app.post("/api/now")
def run_now():
    if not os.path.isdir(bib_dir()):
        return jsonify({"ok": False, "error": f"Ordner {bib_dir()} nicht erreichbar"}), 409
    with lock:
        order = load_order()
        order["jetzt"] = now_iso()
        write_json_atomic(order_path(), order)
    if not options()["proxmox_host"]:
        return jsonify({"ok": True, "message": "Vorgemerkt - wird im nächsten Nachtlauf erledigt (kein Proxmox-Host eingetragen)."})
    ensure_key()
    out, err = ssh("--full-now", timeout=30)
    if err:
        return jsonify({"ok": False, "error": err})
    return jsonify({"ok": True, "message": out or "Master wird gestartet."})


@app.get("/api/host")
def host():
    if not options()["proxmox_host"]:
        return jsonify({"ok": False, "error": "nicht konfiguriert"})
    ensure_key()
    out, err = ssh("--status")
    if err:
        return jsonify({"ok": False, "error": err})
    try:
        return jsonify({"ok": True, "status": json.loads(out)})
    except ValueError:
        return jsonify({"ok": False, "error": out[:300]})


def auto_refresh():
    while True:
        time.sleep(6 * 3600)
        try:
            refresh_cache()
        except Exception:                            # pylint: disable=broad-except
            pass


if __name__ == "__main__":
    try:
        ensure_key()
    except Exception as e:                           # pylint: disable=broad-except
        print("SSH-Schlüssel:", e)
    threading.Thread(target=auto_refresh, daemon=True).start()
    app.run(host="0.0.0.0", port=int(os.environ.get("SB_PORT", "8099")), threaded=True)
