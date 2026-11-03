#!/usr/bin/env bash
# =============================================================================
# gaming-nightly.sh  –  Proxmox-Host (als root)
#
# Aufruf:
#   gaming-nightly.sh                 Nachtlauf: Master starten, er aktualisiert die Spiele
#                                     und fährt sich selbst herunter; danach Snapshot von D:
#                                     und frischer D:-Clone für jede Kinder-VM.
#   gaming-nightly.sh --rollout-only  Ohne Master-Start: den aktuellen Stand der (ausgeschalteten)
#                                     Master-Platte sofort verteilen, z.B. nach einer neuen
#                                     Spiel-Installation am Tag. Laufende Kinder-VMs werden
#                                     übersprungen und bekommen den Stand beim nächsten Lauf.
#   gaming-nightly.sh --now [VMID..]  Wie der Nachtlauf, aber tagsüber per Knopf (Spielebibliothek):
#                                     laufende Kinder-VMs werden NICHT heruntergefahren, sondern
#                                     übersprungen und bekommen den Stand in der nächsten Nacht.
#   gaming-nightly.sh --status        Zeigt, welchen D:-Stand jede Kinder-VM hat.
#
# Kinder-VMs werden automatisch erkannt: jede VM, die als ${PLAYER_SLOT} die Platte
# <storage>:vm-<ID>-games eingehängt hat (so legt create-kid-vm.sh sie an).
#
# Cron: 30 2 * * * root /usr/local/sbin/gaming-nightly.sh >> /var/log/gaming-nightly.log 2>&1
# =============================================================================
set -euo pipefail
# cron startet mit minimalem PATH – Proxmox-Befehle (qm, pvesm, zfs) liegen in /usr/sbin bzw. /sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------------------------- Konfiguration ----------------------------------
MASTER_VMID=2190
MASTER_VOLUME="vm-2190-disk-3"      # D: des Masters
STORAGE="data"
PVE_CONF_DIR="/etc/pve/qemu-server"   # VM-Konfigurationen dieses Hosts
PLAYERS=()                          # leer = automatisch erkennen (empfohlen)
PLAYER_SLOT="scsi1"
DISK_OPTS="cache=writeback,discard=on,iothread=1,ssd=1,backup=0"
MASTER_TIMEOUT=$((4 * 3600))        # max. Dauer der Update-Session des Masters (Sekunden)
PLAYER_SHUTDOWN_TIMEOUT=300         # ACPI-Shutdown-Timeout für Kinder-VMs
SHUTDOWN_RUNNING_PLAYERS=1          # Nachtlauf: laufende Kinder-VMs herunterfahren (1) oder überspringen (0)
RESTART_PLAYERS=1                   # danach wieder starten, wenn sie vorher liefen
KEEP_SNAPSHOTS=3
SNAP_PREFIX="nightly"
FORCE_STOP_MASTER=1                 # reagiert der Master auch auf den Notfall-Shutdown nicht: hart ausschalten (1) oder anlassen (0)
# -----------------------------------------------------------------------------
# Eigene Einstellungen (bleiben bei gaming-update erhalten) überschreiben die Werte oben
[[ -f /etc/gaming-vm.conf ]] && source /etc/gaming-vm.conf

log() { echo "$(date '+%F %T') [gaming-nightly] $*"; }
die() { log "FEHLER: $*"; exit 1; }
usage() { sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=full
NOW=0
ONLY=()                             # nur diese Kinder-VMs (bei --now / --rollout-only)
case "${1:-}" in
  "")              ;;
  --now)           NOW=1; SHUTDOWN_RUNNING_PLAYERS=0 ;;
  --rollout-only)  MODE=rollout ;;
  --status)        MODE=status ;;
  -h|--help)       usage; exit 0 ;;
  *)               usage; die "Unbekannte Option: $1" ;;
esac
shift || true
for a in "$@"; do
  [[ "$a" =~ ^[0-9]+$ ]] || die "Ungültige VMID: $a"
  [[ "$MODE" == "status" ]] && die "--status nimmt keine VMIDs"
  ONLY+=("$a")
done

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

vm_status() { qm status "$1" | awk '{print $2}'; }

wait_stopped() {
  local vmid=$1 remaining=$2 report=${3:-0} waited=0
  while (( remaining > 0 )); do
    [[ "$(vm_status "$vmid")" == "stopped" ]] && return 0
    sleep 20
    remaining=$(( remaining - 20 ))
    waited=$(( waited + 20 ))
    if (( report > 0 && waited % report == 0 )); then
      log "… VM $vmid läuft noch (seit $(( waited / 60 )) min, Abbruch in $(( remaining / 60 )) min)"
    fi
  done
  [[ "$(vm_status "$vmid")" == "stopped" ]]
}

SRC_DEV=$(pvesm path "${STORAGE}:${MASTER_VOLUME}") || die "Volume ${STORAGE}:${MASTER_VOLUME} nicht gefunden"
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

if (( ${#PLAYERS[@]} == 0 )); then
  mapfile -t PLAYERS < <(discover_players)
fi
if (( ${#ONLY[@]} > 0 )); then
  for id in "${ONLY[@]}"; do
    [[ " ${PLAYERS[*]} " == *" $id "* ]] || die "VM $id ist keine Kinder-VM (kein ${PLAYER_SLOT}: ${STORAGE}:vm-${id}-games)"
  done
  PLAYERS=("${ONLY[@]}")
fi

# ---------------------------- Status -----------------------------------------
if [[ "$MODE" == "status" ]]; then
  latest=$(latest_snap)
  echo "Master $MASTER_VMID: $(vm_status "$MASTER_VMID")"
  if [[ -z "$latest" ]]; then
    echo "Neuester Snapshot:  – noch keiner –"
  else
    echo "Neuester Snapshot:  ${latest#*@}"
    echo "Seitdem im Master geändert: $(zfs get -H -o value written "$SRC_DS")" \
         "(größer als ein paar MB = neue Spiele/Updates noch nicht verteilt)"
  fi
  echo
  if (( ${#PLAYERS[@]} == 0 )); then
    echo "Keine Kinder-VMs mit ${PLAYER_SLOT}: ${STORAGE}:vm-<ID>-games gefunden."
    exit 0
  fi
  printf '%-6s %-18s %-9s %-24s %s\n' VMID NAME STATUS "D:-STAND" ""
  for id in "${PLAYERS[@]}"; do
    name=$(vm_conf "$id" | awk '/^name:/ {print $2}')
    origin=$(zfs get -H -o value origin "${PARENT_DS}/vm-${id}-games" 2>/dev/null || echo "-")
    mark="aktuell"
    [[ "$origin" != "$latest" ]] && mark="VERALTET"
    printf '%-6s %-18s %-9s %-24s %s\n' "$id" "$name" "$(vm_status "$id")" "${origin#*@}" "$mark"
  done
  exit 0
fi

LOCKFILE=/run/gaming-nightly.lock
exec 9>"$LOCKFILE"
flock -n 9 || die "Skript läuft bereits."

(( ${#PLAYERS[@]} > 0 )) || log "WARNUNG: keine Kinder-VMs gefunden – es wird nur der Snapshot erstellt."
(( NOW )) && log "Sofort-Lauf (Spielebibliothek): laufende Kinder-VMs werden übersprungen"
log "Modus: $MODE – Kinder-VMs: ${PLAYERS[*]:-keine}"

# ---------------------------- 1) Master-Update -------------------------------
if [[ "$(vm_status "$MASTER_VMID")" != "stopped" ]]; then
  die "Master-VM $MASTER_VMID läuft – bitte erst herunterfahren (kein Snapshot einer laufenden Platte)."
fi

if [[ "$MODE" == "full" ]]; then
  log "Starte Master-VM $MASTER_VMID"
  qm start "$MASTER_VMID"
  sleep 60
  log "Warte auf selbstständigen Shutdown (max. $((MASTER_TIMEOUT / 60)) min)"
  hour=$((10#$(date +%H)))
  if (( !NOW && (hour < 1 || hour >= 6) )); then
    log "HINWEIS: Es ist außerhalb von 01:00–06:00 – master-update.ps1 tut dann nichts."
    log "         Im Master von Hand ausführen:  & 'C:\\Scripts\\master-update.ps1' -Force"
    log "         Danach fährt er herunter und dieses Skript macht weiter."
  fi
  if ! wait_stopped "$MASTER_VMID" "$MASTER_TIMEOUT" 600; then
    log "Timeout – Master wird per ACPI heruntergefahren"
    qm shutdown "$MASTER_VMID" --timeout 600 || true
    if ! wait_stopped "$MASTER_VMID" 60; then
      if (( FORCE_STOP_MASTER )); then
        log "Master reagiert nicht – wird hart ausgeschaltet (qm stop)"
        qm stop "$MASTER_VMID" || true
        wait_stopped "$MASTER_VMID" 60 || log "Master lässt sich nicht ausschalten!"
      else
        log "Master lässt sich nicht herunterfahren!"
      fi
    fi
    die "Update-Session nicht sauber beendet – kein Rollout, Kinder behalten den alten Stand."
  fi
  log "Master ist heruntergefahren"
fi

# ---------------------------- 2) Snapshot ------------------------------------
SNAP="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
zfs snapshot "${SRC_DS}@${SNAP}"
log "Snapshot ${SRC_DS}@${SNAP} erstellt"

# ---------------------------- 3) Rollout -------------------------------------
for vmid in "${PLAYERS[@]}"; do
  clone="vm-${vmid}-games"
  clone_ds="${PARENT_DS}/${clone}"
  was_running=0

  if [[ "$(vm_status "$vmid")" != "stopped" ]]; then
    if [[ "$MODE" == "full" ]] && (( SHUTDOWN_RUNNING_PLAYERS )); then
      log "VM $vmid läuft – fahre sauber herunter"
      qm shutdown "$vmid" --timeout "$PLAYER_SHUTDOWN_TIMEOUT" || true
      if ! wait_stopped "$vmid" 40; then
        log "VM $vmid ließ sich nicht stoppen – übersprungen (behält alten Stand)"
        continue
      fi
      was_running=1
    else
      log "VM $vmid läuft – übersprungen (bekommt den Stand beim nächsten Lauf)"
      continue
    fi
  fi

  # Neuen Clone erst anlegen, dann alten ersetzen (bei Fehler bleibt der alte erhalten)
  if zfs list -H -o name "${clone_ds}-new" >/dev/null 2>&1; then
    zfs destroy "${clone_ds}-new"
  fi
  zfs clone "${SRC_DS}@${SNAP}" "${clone_ds}-new"
  if zfs list -H -o name "$clone_ds" >/dev/null 2>&1; then
    zfs destroy "$clone_ds"
  fi
  zfs rename "${clone_ds}-new" "$clone_ds"
  udevadm settle

  qm set "$vmid" --"$PLAYER_SLOT" "${STORAGE}:${clone},${DISK_OPTS}" >/dev/null
  log "VM $vmid: $PLAYER_SLOT -> ${STORAGE}:${clone} (Stand ${SNAP})"

  if (( was_running && RESTART_PLAYERS )); then
    qm start "$vmid"
    log "VM $vmid wieder gestartet"
  fi
done

# ---------------------------- 4) Aufräumen -----------------------------------
mapfile -t snaps < <(zfs list -H -t snapshot -o name -s creation -d 1 "$SRC_DS" \
                     | grep "@${SNAP_PREFIX}-" || true)
count=${#snaps[@]}
if (( count > KEEP_SNAPSHOTS )); then
  for s in "${snaps[@]:0:count-KEEP_SNAPSHOTS}"; do
    if zfs destroy "$s" 2>/dev/null; then
      log "Alter Snapshot $s gelöscht"
    else
      log "Snapshot $s wird noch von einer Kinder-VM genutzt – bleibt erhalten"
    fi
  done
fi

log "Fertig."
