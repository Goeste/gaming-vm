"""Spielebibliothek - Home-Assistant-App

Zeigt die Steam-Spiele aller eingetragenen Konten, merkt Installieren/Entfernen in
<Freigabe>/Bibliothek/auftrag.json vor und kann den Master auf dem Proxmox-Host per
SSH sofort starten (game-disk-sync.sh --full-now). Der Master liest den Auftrag und
schreibt status.json zurueck (master/library-queue.ps1).

Zugriff nur ueber Home-Assistant-Ingress (Anmeldung + nur Administratoren).
"""
import json
import os
import re

import subprocess
import threading
import time
from datetime import datetime, timezone

import requests
from flask import Flask, abort, jsonify, redirect, request, send_from_directory

DATA = os.environ.get("SB_DATA", "/data")
OPTIONS_FILE = os.path.join(DATA, "options.json")
CACHE_FILE = os.path.join(DATA, "owned.json")
IMAGE_FILE = os.path.join(DATA, "images.json")        # Bildadressen aus dem Steam-Store (zwischengespeichert)
STORE_API = os.environ.get("SB_STORE_API", "https://store.steampowered.com")
ICONS = {}                                             # appid -> Icon-Kennung aus GetOwnedGames
SSH_DIR = os.path.join(DATA, "ssh")
SSH_KEY = os.path.join(SSH_DIR, "id_ed25519")          # selbst erzeugt, falls ssh_private_key leer
SSH_KEY_CFG = os.path.join(SSH_DIR, "id_config")       # aus der Konfiguration (ssh_private_key)
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
    o.setdefault("ssh_private_key", "")
    o.setdefault("master_vmid", 2190)
    o.setdefault("vms", [])
    return o


def kid_vms(o=None):
    """Kinder-VMs aus der Konfiguration: [(vmid, name), ...]"""
    o = o or options()
    out = []
    for v in o["vms"]:
        try:
            out.append((int(v["vmid"]), str(v.get("name") or "")))
        except (KeyError, TypeError, ValueError):
            pass
    return out


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
             "playtime": int(g.get("playtime_forever", 0)), "icon": g.get("img_icon_url") or ""}
            for g in resp["games"]]


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
def normalize_key(k):
    """Privaten Schlüssel aus der Konfiguration wieder in Form bringen (Zeilenumbrüche gehen beim Einfügen oft verloren)."""
    m = re.search(r"-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----", k or "", re.S)
    if not m:
        return None
    body = re.sub(r"\s+", "", m.group(2))
    lines = [body[i:i + 70] for i in range(0, len(body), 70)]
    return f"-----BEGIN {m.group(1)}-----\n" + "\n".join(lines) + f"\n-----END {m.group(1)}-----\n"


def ensure_key():
    """Liefert (Pfad zum privaten Schlüssel, Fehler). Vorrang hat ssh_private_key aus der Konfiguration."""
    os.makedirs(SSH_DIR, mode=0o700, exist_ok=True)
    cfg = options().get("ssh_private_key", "")
    if cfg.strip():
        key = normalize_key(cfg)
        if not key:
            return None, "ssh_private_key in der Konfiguration ist kein gültiger privater Schlüssel"
        old = open(SSH_KEY_CFG, encoding="utf-8").read() if os.path.exists(SSH_KEY_CFG) else None
        if old != key:
            fd = os.open(SSH_KEY_CFG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(key)
        return SSH_KEY_CFG, None
    if not os.path.exists(SSH_KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "spielebibliothek-ha",
                        "-f", SSH_KEY], check=True)
    return SSH_KEY, None


def ssh(arg, timeout=20):
    o = options()
    if not o["proxmox_host"]:
        return None, "Kein Proxmox-Host konfiguriert"
    key, err = ensure_key()
    if err:
        return None, err
    cmd = ["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "IdentitiesOnly=yes",
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
        msg = err or out or f"Exit-Code {p.returncode}"
        if "Permission denied" in msg:
            msg += " - auf dem Host 'gaming-ha-key' ausführen und die Ausgabe in der Konfiguration bei ssh_private_key einfügen (Anleitung 13.4)"
        return None, msg
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
            if g.get("icon"):
                ICONS[g["appid"]] = g["icon"]
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
        "vms_configured": len(kid_vms(o)) > 0,
    })


# ---------------------------------------------------------------- Spielbilder
image_lock = threading.Lock()


@app.get("/api/img/<int:appid>")
def image(appid):
    """Fuer Spiele, deren Bild nicht unter der alten Steam-Adresse liegt: richtige Adresse im Store
    nachschlagen (neuere Spiele haben ein Kennwort im Pfad) und dorthin weiterleiten.
    Ohne Store-Eintrag (z. B. aus dem Shop entfernt): das kleine Spiel-Icon aus der Bibliothek."""
    with image_lock:
        cache = read_json(IMAGE_FILE, {})
        e = cache.get(str(appid))
    if not e or (not e.get("url") and time.time() - e.get("t", 0) > 7 * 86400):
        url = None
        try:
            r = requests.get(f"{STORE_API}/api/appdetails", params={"appids": appid, "filters": "basic"}, timeout=10)
            if r.status_code == 200:
                d = (r.json() or {}).get(str(appid)) or {}
                if d.get("success"):
                    url = (d.get("data") or {}).get("header_image")
            else:
                url = False                              # z. B. 429 - nichts merken, spaeter erneut
        except (requests.RequestException, ValueError):
            url = False
        if url is not False:
            e = {"url": url, "t": time.time()}
            with image_lock:
                cache = read_json(IMAGE_FILE, {})
                cache[str(appid)] = e
                write_json_atomic(IMAGE_FILE, cache)
    if e and (e.get("url") or "").startswith("https://"):
        return redirect(e["url"], code=302)
    icon = ICONS.get(appid)
    if icon and re.fullmatch(r"[0-9a-f]{40}", icon):
        return redirect(f"https://media.steampowered.com/steamcommunity/public/images/apps/{appid}/{icon}.jpg", code=302)
    abort(404)


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
    ids = " ".join(str(v) for v, _ in kid_vms())
    out, err = ssh(f"--full-now {ids}".strip(), timeout=30)
    if err:
        return jsonify({"ok": False, "error": err})
    return jsonify({"ok": True, "message": out or "Master wird gestartet."})


HOST_CACHE = {"time": 0.0, "status": None, "error": None, "ok_time": 0.0}
host_lock = threading.Lock()


def host_status(max_age=10):
    """Status vom Host holen - nie mehrere SSH-Abfragen gleichzeitig, kurze Zeit zwischenspeichern.
    Schlaegt eine Abfrage fehl, wird ein zweites Mal versucht; danach bleibt der letzte gute Stand sichtbar."""
    with host_lock:
        if time.time() - HOST_CACHE["time"] < max_age:
            return HOST_CACHE
        err = None
        for attempt in range(2):
            out, err = ssh("--status", timeout=30)
            if not err:
                try:
                    HOST_CACHE.update(status=json.loads(out), error=None, ok_time=time.time())
                    break
                except ValueError:
                    err = out[:300]
            if attempt == 0:
                time.sleep(2)
        if err:
            HOST_CACHE["error"] = err
        HOST_CACHE["time"] = time.time()
        return HOST_CACHE


@app.get("/api/host")
def host():
    if not options()["proxmox_host"]:
        return jsonify({"ok": False, "error": "nicht konfiguriert"})
    c = host_status()
    st = c["status"]
    if st is None:
        return jsonify({"ok": False, "error": c["error"] or "keine Antwort"})
    stale = bool(c["error"])
    o = options()
    host_vms = {int(v["vmid"]): v for v in st.get("vms") or []}
    rows = [{"vmid": int(o["master_vmid"]), "name": "Master", "role": "master",
             "status": st.get("master"), "snapshot": None, "current": None, "known": True}]
    wanted = kid_vms(o) or [(vid, "") for vid in sorted(host_vms)]
    for vid, name in wanted:
        h = host_vms.get(vid)
        rows.append({"vmid": vid, "name": name or (h or {}).get("name") or str(vid), "role": "kind",
                     "status": h.get("status") if h else "unbekannt", "snapshot": h.get("snapshot") if h else None,
                     "current": h.get("current") if h else None, "known": bool(h)})
    return jsonify({"ok": True, "stale": stale, "error": c["error"] if stale else None,
                    "age": int(time.time() - c["ok_time"]), "busy": st.get("busy"), "latest_snapshot": st.get("latest_snapshot"),
                    "master_changed_bytes": st.get("master_changed_bytes"), "last_run": st.get("last_run"),
                    "rows": rows})


@app.post("/api/vm")
def vm_action():
    body = request.get_json(silent=True) or {}
    action = body.get("action")
    o = options()
    allowed = {int(o["master_vmid"])} | {v for v, _ in kid_vms(o)}
    try:
        ids = [int(x) for x in body.get("vmids") or []]
    except (TypeError, ValueError):
        abort(400)
    if action == "sync":
        ids = [i for i in ids if i != int(o["master_vmid"])]
    if action not in ("start", "shutdown", "sync") or not ids or any(i not in allowed for i in ids):
        return jsonify({"ok": False, "error": "VM nicht in der Konfiguration (master_vmid / vms)"}), 400
    arg = "--detach" if action == "sync" else f"--{action}"
    out, err = ssh(f"{arg} " + " ".join(map(str, ids)), timeout=30)
    HOST_CACHE["time"] = 0.0
    if err:
        return jsonify({"ok": False, "error": err})
    return jsonify({"ok": True, "message": out})


def auto_refresh():
    while True:
        time.sleep(6 * 3600)
        try:
            refresh_cache()
        except Exception:                            # pylint: disable=broad-except
            pass


if __name__ == "__main__":
    try:
        path, err = ensure_key()
        if err:
            print("SSH-Schlüssel:", err, flush=True)
        elif path == SSH_KEY:
            with open(SSH_KEY + ".pub", encoding="utf-8") as f:
                pub = f.read().strip()
            print("Kein ssh_private_key konfiguriert - selbst erzeugter Schlüssel. Zeile für /root/.ssh/authorized_keys:", flush=True)
            print(f'command="/usr/local/sbin/game-disk-sync.sh",restrict {pub}', flush=True)
            print("Einfacher: auf dem Host 'gaming-ha-key' ausführen und die Ausgabe bei ssh_private_key eintragen.", flush=True)
        else:
            print("SSH-Schlüssel aus der Konfiguration (ssh_private_key) wird verwendet.", flush=True)
    except Exception as e:                           # pylint: disable=broad-except
        print("SSH-Schlüssel:", e, flush=True)
    threading.Thread(target=auto_refresh, daemon=True).start()
    app.run(host="0.0.0.0", port=int(os.environ.get("SB_PORT", "8099")), threaded=True)
