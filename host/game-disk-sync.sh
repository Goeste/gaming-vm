#!/usr/bin/env bash
# =============================================================================
# game-disk-sync.sh  –  Proxmox-Host (als root)
#
# Verteilt den aktuellen Stand der Master-Spieleplatte (D:) an die Kinder-VMs:
# ZFS-Snapshot der Master-Platte, dann pro Kinder-VM ein frischer Clone als D:.
# Startet den Master NICHT und aktualisiert keine Spiele – dafür ist gaming-nightly.sh da.
# Der Master muss ausgeschaltet sein.
#
# Aufruf:
#   game-disk-sync.sh [Optionen] [VMID ...]
#     ohne VMID            alle Kinder-VMs (automatisch erkannt)
#     --shutdown-running   laufende Kinder-VMs herunterfahren, D: tauschen, wieder starten
#                          (Standard: laufende VMs überspringen)
#     --detach             im Hintergrund weiterlaufen, sofort zurückkehren (für Home Assistant)
#     --status             aktuellen Stand als JSON ausgeben (für einen Home-Assistant-Sensor)
#     --start VMID..       VMs starten (nur Master und Kinder-VMs; im Hintergrund)
#     --shutdown VMID..    VMs sauber herunterfahren (nur Master und Kinder-VMs; im Hintergrund)
#     --full-now [VMID..]  Master JETZT starten (Spiele installieren/aktualisieren) und danach
#                          verteilen: startet "gaming-nightly.sh --now" im Hintergrund
#                          (Knopf der Spielebibliothek). Laufende Kinder-VMs werden übersprungen.
#
# Exit-Codes: 0 = alle aktuell, 2 = einige übersprungen (liefen), 1 = Fehler
# Ergebnis des letzten Laufs: /var/lib/game-disk-sync/last.json
# Log: /var/log/game-disk-sync.log
#
# Über SSH mit erzwungenem Befehl (authorized_keys "command=...") werden die Argumente
# aus SSH_ORIGINAL_COMMAND übernommen – siehe ANLEITUNG.md, Abschnitt 7.
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------------------------- Konfiguration ----------------------------------
MASTER_VMID=2190
MASTER_VOLUME="vm-2190-disk-3"      # D: des Masters
STORAGE="data"
PVE_CONF_DIR="/etc/pve/qemu-server"   # VM-Konfigurationen dieses Hosts
PLAYER_SLOT="scsi1"
DISK_OPTS="cache=writeback,discard=on,iothread=1,ssd=1,backup=0"
PLAYER_SHUTDOWN_TIMEOUT=300
KEEP_SNAPSHOTS=3
SNAP_PREFIX="nightly"               # gleicher Präfix wie gaming-nightly.sh (gemeinsames Aufräumen/Status)
LOCKFILE=/run/gaming-nightly.lock   # gemeinsames Lock: nie gleichzeitig mit dem Nachtlauf
LOGFILE=/var/log/game-disk-sync.log
STATEDIR=/var/lib/game-disk-sync
# -----------------------------------------------------------------------------
# Eigene Einstellungen (bleiben bei gaming-update erhalten) überschreiben die Werte oben
[[ -f /etc/gaming-vm.conf ]] && source /etc/gaming-vm.conf

log() {
  local line
  line="$(date '+%F %T') [game-disk-sync] $*"
  echo "$line"
  echo "$line" >> "$LOGFILE" 2>/dev/null || true
}
die() { log "FEHLER: $*"; write_result "error" "$*"; exit 1; }
usage() { sed -n '4,29p' "$0" | sed 's/^# \{0,1\}//'; }

UPDATED=(); SKIPPED=(); CURRENT=(); SNAP=""
json_list() { local IFS=,; echo "[${*:-}]"; }
write_result() {   # $1 = ok|partial|error, $2 = Meldung
  mkdir -p "$STATEDIR" 2>/dev/null || return 0
  local msg=${2//\"/\'}
  cat > "$STATEDIR/last.json" <<EOF
{"time":"$(date -Iseconds)","result":"$1","message":"$msg","snapshot":"${SNAP#*@}","updated":$(json_list "${UPDATED[@]}"),"already_current":$(json_list "${CURRENT[@]}"),"skipped":$(json_list "${SKIPPED[@]}")}
EOF
}

# ---------------------------- Argumente --------------------------------------
ARGS=("$@")
if (( ${#ARGS[@]} == 0 )) && [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  # Aufruf per SSH mit erzwungenem Befehl: nur Zahlen und bekannte Optionen zulassen
  read -r -a words <<< "$SSH_ORIGINAL_COMMAND"
  for w in "${words[@]}"; do
    case "$w" in
      game-disk-sync|*/game-disk-sync.sh|game-disk-sync.sh) ;;
      --shutdown-running|--detach|--status|--full-now|--start|--shutdown|[0-9]*) ARGS+=("$w") ;;
      *) echo "Unzulässiges Argument: $w" >&2; exit 1 ;;
    esac
  done
fi

SHUTDOWN_RUNNING=0; DETACH=0; MODE=sync; TARGETS=()
for a in "${ARGS[@]}"; do
  case "$a" in
    --shutdown-running) SHUTDOWN_RUNNING=1 ;;
    --detach)           DETACH=1 ;;
    --status)           MODE=status ;;
    --full-now)         MODE=full ;;
    --start)            MODE=start ;;
    --shutdown)         MODE=shutdown ;;
    -h|--help)          usage; exit 0 ;;
    *[!0-9]*|"")        usage; echo "Unbekanntes Argument: $a" >&2; exit 1 ;;
    *)                  TARGETS+=("$a") ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen." >&2; exit 1; }

# ---------------------------- Sofort-Lauf (Master + Verteilen) --------------
if [[ "$MODE" == "full" ]]; then
  if ! flock -n "$LOCKFILE" true 2>/dev/null; then
    echo "Nachtlauf oder Sync läuft bereits – nichts gestartet." >&2; exit 2
  fi
  [[ "$(qm status "$MASTER_VMID" 2>/dev/null | awk '{print $2}')" == "stopped" ]] \
    || { echo "Master $MASTER_VMID läuft – bitte erst herunterfahren." >&2; exit 2; }
  setsid nohup /usr/local/sbin/gaming-nightly.sh --now "${TARGETS[@]}" >> /var/log/gaming-nightly.log 2>&1 < /dev/null &
  echo "Master wird gestartet – Fortschritt: /var/log/gaming-nightly.log"
  exit 0
fi

# ---------------------------- Hintergrundmodus -------------------------------
if (( DETACH )) && [[ "$MODE" == "sync" ]]; then
  rest=()
  for a in "${ARGS[@]}"; do [[ "$a" == "--detach" ]] || rest+=("$a"); done
  setsid nohup bash "$(readlink -f "$0")" "${rest[@]}" >/dev/null 2>&1 < /dev/null &
  echo "Gestartet im Hintergrund. Ergebnis: $STATEDIR/last.json, Log: $LOGFILE"
  exit 0
fi

# ---------------------------- Hilfsfunktionen --------------------------------
vm_status() { qm status "$1" 2>/dev/null | awk '{print $2}'; }

wait_stopped() {
  local vmid=$1 remaining=$2
  while (( remaining > 0 )); do
    [[ "$(vm_status "$vmid")" == "stopped" ]] && return 0
    sleep 5; remaining=$(( remaining - 5 ))
  done
  [[ "$(vm_status "$vmid")" == "stopped" ]]
}

SRC_DEV=$(pvesm path "${STORAGE}:${MASTER_VOLUME}" 2>/dev/null) || die "Volume ${STORAGE}:${MASTER_VOLUME} nicht gefunden"
SRC_DS=${SRC_DEV#/dev/zvol/}
PARENT_DS=${SRC_DS%/*}
zfs list -H -o name "$SRC_DS" >/dev/null 2>&1 || die "ZFS-Dataset $SRC_DS existiert nicht"

latest_snap() {
  zfs list -H -t snapshot -o name -s creation -d 1 "$SRC_DS" | grep "@${SNAP_PREFIX}-" | tail -n 1 || true
}

# VM-Konfigurationen direkt lesen statt "qm list"/"qm config" pro VM (die fragen jede VM ab und
# brauchen bei vielen VMs oder einer hängenden VM viele Sekunden). Nur der aktuelle Stand, keine Snapshots.
vm_conf() { awk '/^\[/ {exit} {print}' "${PVE_CONF_DIR}/$1.conf" 2>/dev/null; }

discover_players() {
  local f id
  for f in "${PVE_CONF_DIR}"/*.conf; do
    [[ -e "$f" ]] || continue
    id=$(basename "$f" .conf)
    [[ "$id" =~ ^[0-9]+$ && "$id" != "$MASTER_VMID" ]] || continue
    if vm_conf "$id" | grep -qE "^${PLAYER_SLOT}: ${STORAGE}:vm-${id}-games(,|$)"; then
      echo "$id"
    fi
  done
}

# Schneller Status ohne "qm": läuft der QEMU-Prozess dieser VM?
vm_running_fast() {
  local pid
  pid=$(cat "/var/run/qemu-server/$1.pid" 2>/dev/null) || return 1
  [[ -n "$pid" ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "-id $1 "
}
vm_status_fast() { if vm_running_fast "$1"; then echo running; else echo stopped; fi; }

mapfile -t ALL_PLAYERS < <(discover_players)

# ---------------------------- Starten / Herunterfahren -----------------------
if [[ "$MODE" == "start" || "$MODE" == "shutdown" ]]; then
  (( ${#TARGETS[@]} > 0 )) || { echo "Keine VMID angegeben." >&2; exit 1; }
  if ! flock -n "$LOCKFILE" true 2>/dev/null; then
    echo "Nachtlauf oder Sync läuft gerade – bitte später." >&2; exit 2
  fi
  for id in "${TARGETS[@]}"; do
    ok=0; [[ "$id" == "$MASTER_VMID" ]] && ok=1
    for p in "${ALL_PLAYERS[@]}"; do [[ "$p" == "$id" ]] && ok=1; done
    (( ok )) || { echo "VM $id ist weder Master noch Kinder-VM – abgelehnt." >&2; exit 1; }
  done
  for id in "${TARGETS[@]}"; do
    st=$(vm_status "$id")
    if [[ "$MODE" == "start" ]]; then
      if [[ "$st" == "running" ]]; then echo "VM $id läuft bereits"; continue; fi
      # Start mit langer Wartezeit (VMs mit durchgereichter Grafikkarte brauchen länger)
      setsid nohup qm start "$id" --timeout 300 >> "$LOGFILE" 2>&1 < /dev/null &
      log "VM $id wird gestartet (Spielebibliothek)"; echo "VM $id wird gestartet"
    else
      if [[ "$st" != "running" ]]; then echo "VM $id ist bereits aus"; continue; fi
      setsid nohup qm shutdown "$id" --timeout "$PLAYER_SHUTDOWN_TIMEOUT" >> "$LOGFILE" 2>&1 < /dev/null &
      log "VM $id wird heruntergefahren (Spielebibliothek)"; echo "VM $id wird heruntergefahren"
    fi
  done
  exit 0
fi

# ---------------------------- Status (JSON) ----------------------------------
if [[ "$MODE" == "status" ]]; then
  latest=$(latest_snap)
  written=$(zfs get -H -p -o value written "$SRC_DS" 2>/dev/null || echo 0)
  vms=()
  for id in "${ALL_PLAYERS[@]}"; do
    name=$(vm_conf "$id" | awk '/^name:/ {print $2}')
    origin=$(zfs get -H -o value origin "${PARENT_DS}/vm-${id}-games" 2>/dev/null || echo "-")
    cur=false; [[ -n "$latest" && "$origin" == "$latest" ]] && cur=true
    vms+=("{\"vmid\":$id,\"name\":\"$name\",\"status\":\"$(vm_status_fast "$id")\",\"snapshot\":\"${origin#*@}\",\"current\":$cur}")
  done
  last="null"; [[ -f "$STATEDIR/last.json" ]] && last=$(tr -d '\n' < "$STATEDIR/last.json")
  busy=false; flock -n "$LOCKFILE" true 2>/dev/null || busy=true
  echo "{\"busy\":$busy,\"master_vmid\":$MASTER_VMID,\"master\":\"$(vm_status_fast "$MASTER_VMID")\",\"latest_snapshot\":\"${latest#*@}\",\"master_changed_bytes\":${written:-0},\"vms\":$(json_list "${vms[@]}"),\"last_run\":$last}"
  exit 0
fi

# ---------------------------- Synchronisieren --------------------------------
exec 9>"$LOCKFILE"
flock -n 9 || die "Nachtlauf oder ein anderer Sync läuft gerade."
trap '' HUP   # Abbruch der SSH-Verbindung soll den Lauf nicht unterbrechen

if (( ${#TARGETS[@]} == 0 )); then
  TARGETS=("${ALL_PLAYERS[@]}")
else
  for id in "${TARGETS[@]}"; do
    found=0
    for p in "${ALL_PLAYERS[@]}"; do [[ "$p" == "$id" ]] && found=1; done
    (( found )) || die "VM $id ist keine Kinder-VM (kein ${PLAYER_SLOT}: ${STORAGE}:vm-${id}-games)"
  done
fi
(( ${#TARGETS[@]} > 0 )) || die "Keine Kinder-VMs gefunden."

[[ "$(vm_status "$MASTER_VMID")" == "stopped" ]] || die "Master $MASTER_VMID läuft – bitte erst herunterfahren."

# Snapshot: neuen nur anlegen, wenn sich die Master-Platte seit dem letzten geändert hat
latest=$(latest_snap)
written=$(zfs get -H -p -o value written "$SRC_DS" 2>/dev/null || echo 1)
if [[ -n "$latest" && "$written" == "0" ]]; then
  SNAP="$latest"
  log "Master-Platte unverändert – verwende ${SNAP#*@}"
else
  SNAP="${SRC_DS}@${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  zfs snapshot "$SNAP"
  log "Snapshot ${SNAP#*@} erstellt"
fi

for vmid in "${TARGETS[@]}"; do
  clone="vm-${vmid}-games"
  clone_ds="${PARENT_DS}/${clone}"
  was_running=0

  if [[ "$(zfs get -H -o value origin "$clone_ds" 2>/dev/null || true)" == "$SNAP" ]]; then
    log "VM $vmid: bereits aktuell"
    CURRENT+=("$vmid"); continue
  fi

  if [[ "$(vm_status "$vmid")" != "stopped" ]]; then
    if (( SHUTDOWN_RUNNING )); then
      log "VM $vmid läuft – fahre sauber herunter"
      qm shutdown "$vmid" --timeout "$PLAYER_SHUTDOWN_TIMEOUT" || true
      if ! wait_stopped "$vmid" 60; then
        log "VM $vmid ließ sich nicht stoppen – übersprungen"
        SKIPPED+=("$vmid"); continue
      fi
      was_running=1
    else
      log "VM $vmid läuft – übersprungen"
      SKIPPED+=("$vmid"); continue
    fi
  fi

  if zfs list -H -o name "${clone_ds}-new" >/dev/null 2>&1; then zfs destroy "${clone_ds}-new"; fi
  zfs clone "$SNAP" "${clone_ds}-new"
  if zfs list -H -o name "$clone_ds" >/dev/null 2>&1; then zfs destroy "$clone_ds"; fi
  zfs rename "${clone_ds}-new" "$clone_ds"
  udevadm settle
  qm set "$vmid" --"$PLAYER_SLOT" "${STORAGE}:${clone},${DISK_OPTS}" >/dev/null
  log "VM $vmid: D: aktualisiert (${SNAP#*@})"
  UPDATED+=("$vmid")

  if (( was_running )); then
    qm start "$vmid" && log "VM $vmid wieder gestartet" || log "FEHLER: VM $vmid konnte nicht gestartet werden"
  fi
done

# Alte Snapshots aufräumen (in Benutzung befindliche bleiben automatisch erhalten)
mapfile -t snaps < <(zfs list -H -t snapshot -o name -s creation -d 1 "$SRC_DS" | grep "@${SNAP_PREFIX}-" || true)
count=${#snaps[@]}
if (( count > KEEP_SNAPSHOTS )); then
  for s in "${snaps[@]:0:count-KEEP_SNAPSHOTS}"; do
    zfs destroy "$s" 2>/dev/null && log "Alter Snapshot ${s#*@} gelöscht" || true
  done
fi

if (( ${#SKIPPED[@]} > 0 )); then
  log "Fertig – aktualisiert: ${UPDATED[*]:-keine}, übersprungen: ${SKIPPED[*]}"
  write_result "partial" "übersprungen: ${SKIPPED[*]}"
  exit 2
fi
log "Fertig – aktualisiert: ${UPDATED[*]:-keine}, bereits aktuell: ${CURRENT[*]:-keine}"
write_result "ok" "alle aktuell"
exit 0
