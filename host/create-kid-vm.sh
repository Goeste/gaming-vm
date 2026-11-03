#!/usr/bin/env bash
# =============================================================================
# create-kid-vm.sh  –  Proxmox-Host (als root)
#
# Erstellt eine Kinder-VM als Linked Clone des Templates und hängt die
# Spieleplatte D: als eigenen, beschreibbaren ZFS-Clone des Masters ein
# (Name vm-<ID>-games). gaming-nightly.sh erkennt die VM daran automatisch.
#
# Aufruf:
#   create-kid-vm.sh <VMID> [NAME] [Optionen]
#
# Optionen:
#   --gpu <PCI>        vGPU durch eine dedizierte GPU ersetzen (z.B. 0000:81:00)
#   --template <ID>    anderes Template verwenden (Standard: 2199)
#   --new-snapshot     neuen Snapshot vom Master ziehen (Master muss aus sein),
#                      statt den neuesten nightly-Snapshot zu verwenden
#   --data-disk <GB>   Größe der dauerhaften Datenplatte Z: (Standard: 64, 0 = keine)
#   --start            VM nach dem Erstellen starten
#
# Beispiele:
#   create-kid-vm.sh 2194 kind1
#   create-kid-vm.sh 2193 kind-gpu --gpu 0000:81:00
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------------------------- Konfiguration ----------------------------------
TEMPLATE_VMID=2199
MASTER_VMID=2190
MASTER_VOLUME="vm-2190-disk-3"      # D: des Masters
STORAGE="data"
GAMES_SLOT="scsi1"
GAMES_OPTS="cache=writeback,discard=on,iothread=1,ssd=1,backup=0"
SNAP_PREFIX="nightly"
DATA_SLOT="scsi2"                   # dauerhafte Datenplatte Z: (bleibt beim Nachtlauf unberührt)
DATA_DISK_GB=64
DATA_OPTS="cache=writeback,discard=on,iothread=1,ssd=1"
# -----------------------------------------------------------------------------
# Eigene Einstellungen (bleiben bei gaming-update erhalten) überschreiben die Werte oben
[[ -f /etc/gaming-vm.conf ]] && source /etc/gaming-vm.conf

log()   { echo "$(date '+%F %T') [create-kid-vm] $*"; }
die()   { log "FEHLER: $*"; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

VMID=""; NAME=""; GPU=""; START=0; NEW_SNAP=0
while (( $# )); do
  case "$1" in
    --gpu)          GPU="${2:?--gpu braucht eine PCI-Adresse}"; shift 2 ;;
    --template)     TEMPLATE_VMID="${2:?--template braucht eine VMID}"; shift 2 ;;
    --new-snapshot) NEW_SNAP=1; shift ;;
    --data-disk)    DATA_DISK_GB="${2:?--data-disk braucht eine Größe in GB}"; shift 2 ;;
    --start)        START=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "Unbekannte Option: $1" ;;
    *)
      if   [[ -z "$VMID" ]]; then VMID="$1"
      elif [[ -z "$NAME" ]]; then NAME="$1"
      else die "Zu viele Argumente: $1"; fi
      shift ;;
  esac
done

[[ $EUID -eq 0 ]]          || die "Bitte als root ausführen."
[[ "$VMID" =~ ^[0-9]+$ ]]  || { usage; die "VMID fehlt oder ist ungültig."; }
NAME="${NAME:-kind-$VMID}"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Ungültiger Name '$NAME' (nur Buchstaben, Ziffern, '-' und '.')."

vm_status() { qm status "$1" | awk '{print $2}'; }

# ---------------------------- Prüfungen --------------------------------------
if qm status "$VMID" >/dev/null 2>&1; then
  die "VM $VMID existiert bereits."
fi
qm config "$TEMPLATE_VMID" 2>/dev/null | grep -q '^template: 1' \
  || die "VM $TEMPLATE_VMID ist kein Template."

SRC_DEV=$(pvesm path "${STORAGE}:${MASTER_VOLUME}") || die "Volume ${STORAGE}:${MASTER_VOLUME} nicht gefunden."
SRC_DS=${SRC_DEV#/dev/zvol/}
PARENT_DS=${SRC_DS%/*}
CLONE_NAME="vm-${VMID}-games"
CLONE_DS="${PARENT_DS}/${CLONE_NAME}"
zfs list -H -o name "$SRC_DS" >/dev/null 2>&1 || die "ZFS-Dataset $SRC_DS existiert nicht."
if zfs list -H -o name "$CLONE_DS" >/dev/null 2>&1; then
  die "$CLONE_DS existiert bereits (Rest einer alten VM?). Bitte prüfen und ggf. mit 'zfs destroy' entfernen."
fi

if [[ -n "$GPU" ]]; then
  [[ "$GPU" == *:*:* ]] || GPU="0000:${GPU}"      # 81:00 -> 0000:81:00
  GPU="${GPU%.*}"                                   # Funktion abschneiden -> alle Funktionen
  lspci -s "$GPU" >/dev/null 2>&1 && [[ -n "$(lspci -s "$GPU")" ]] \
    || die "PCI-Gerät $GPU nicht gefunden (lspci -nn | grep -iE 'vga|3d')."
  if ! lspci -nnk -s "${GPU}.0" | grep -q 'Kernel driver in use: vfio-pci'; then
    log "WARNUNG: ${GPU}.0 ist nicht an vfio-pci gebunden – der Start der VM wird vermutlich scheitern."
  fi
fi

# ---------------------------- Aufräumen bei Fehler ---------------------------
CREATED_VM=0; CREATED_DS=0
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    log "Abbruch – räume halbfertige Schritte auf"
    if (( CREATED_VM )); then
      qm destroy "$VMID" --purge >/dev/null 2>&1 || log "VM $VMID bitte manuell prüfen."
    fi
    if (( CREATED_DS )) && zfs list -H -o name "$CLONE_DS" >/dev/null 2>&1; then
      zfs destroy "$CLONE_DS" || log "$CLONE_DS bitte manuell entfernen."
    fi
  fi
}
trap cleanup EXIT

# ---------------------------- Snapshot wählen --------------------------------
SNAP=$(zfs list -H -t snapshot -o name -s creation -d 1 "$SRC_DS" \
       | grep "@${SNAP_PREFIX}-" | tail -n 1 || true)

if (( NEW_SNAP )) || [[ -z "$SNAP" ]]; then
  [[ "$(vm_status "$MASTER_VMID")" == "stopped" ]] \
    || die "Master $MASTER_VMID läuft – für einen neuen Snapshot muss er ausgeschaltet sein."
  SNAP="${SRC_DS}@${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  zfs snapshot "$SNAP"
  log "Neuer Snapshot: $SNAP"
else
  log "Verwende neuesten Snapshot: $SNAP"
fi

# ---------------------------- VM klonen --------------------------------------
log "Erstelle Linked Clone $VMID ($NAME) von Template $TEMPLATE_VMID"
qm clone "$TEMPLATE_VMID" "$VMID" --name "$NAME" --full 0
CREATED_VM=1

# ---------------------------- D: einbinden -----------------------------------
zfs clone "$SNAP" "$CLONE_DS"
CREATED_DS=1
udevadm settle
qm set "$VMID" --"$GAMES_SLOT" "${STORAGE}:${CLONE_NAME},${GAMES_OPTS}" >/dev/null
log "D: eingebunden: $GAMES_SLOT -> ${STORAGE}:${CLONE_NAME}"

# ---------------------------- Datenplatte Z: ---------------------------------
[[ "$DATA_DISK_GB" =~ ^[0-9]+$ ]] || die "--data-disk muss eine Zahl sein."
if (( DATA_DISK_GB > 0 )); then
  qm set "$VMID" --"$DATA_SLOT" "${STORAGE}:${DATA_DISK_GB},${DATA_OPTS}" >/dev/null
  log "Datenplatte Z: angelegt: $DATA_SLOT, ${DATA_DISK_GB} GB (in Windows mit init-z.ps1 einrichten)"
fi

# ---------------------------- Dedizierte GPU ---------------------------------
if [[ -n "$GPU" ]]; then
  qm set "$VMID" --delete hostpci0 >/dev/null
  qm set "$VMID" --hostpci0 "${GPU},pcie=1" --balloon 0 >/dev/null
  log "vGPU ersetzt durch dedizierte GPU $GPU (alle Funktionen, PCIe, Ballooning aus)"
fi

trap - EXIT

if (( START )); then
  qm start "$VMID"
  log "VM $VMID gestartet"
fi

cat <<EOF

Fertig: VM $VMID ($NAME)
  C: Linked Clone von Template $TEMPLATE_VMID
  D: ${STORAGE}:${CLONE_NAME}  (Stand: ${SNAP#*@})
$( [[ -n "$GPU" ]] && echo "  GPU: $GPU (dediziert)" || echo "  GPU: vGPU aus dem Template" )

Nächste Schritte in Windows (als admin, siehe ANLEITUNG.md, Abschnitt 6):
$( [[ -n "$GPU" ]] && echo "  setup-kid-vm.ps1 -ComputerName <NAME> -KidUser <kind> -DedicatedGpu
  danach: GRID-Treiber entfernen (DDU), Treiber der Karte installieren, Dummy-Stecker" \
                   || echo "  setup-kid-vm.ps1 -ComputerName <NAME> -KidUser <kind> -FixLicenseTask" )
  dann Neustart, persist\init-z.ps1 (Laufwerk Z:), Sunshine einrichten, Moonlight koppeln, libvirtualhid aktivieren
EOF
