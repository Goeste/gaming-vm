#!/usr/bin/env bash
# =============================================================================
# install-host.sh  –  Proxmox-Host (als root), aus dem entpackten Paketordner "host" starten
#
# Installiert gaming-nightly.sh, create-kid-vm.sh, game-disk-sync.sh und gaming-update nach /usr/local/sbin,
# legt den nächtlichen Cronjob an (02:30) und prüft die wichtigsten Voraussetzungen.
# Kann gefahrlos mehrfach ausgeführt werden (Cronjob wird jedes Mal neu geschrieben).
# =============================================================================
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen."; exit 1; }

install -m 0755 "$DIR/gaming-nightly.sh" /usr/local/sbin/gaming-nightly.sh
install -m 0755 "$DIR/create-kid-vm.sh"  /usr/local/sbin/create-kid-vm.sh
install -m 0755 "$DIR/game-disk-sync.sh"  /usr/local/sbin/game-disk-sync.sh
[[ -f "$DIR/gaming-update.sh" ]] && install -m 0755 "$DIR/gaming-update.sh" /usr/local/sbin/gaming-update
[[ -f "$DIR/gaming-ha-key.sh" ]] && install -m 0755 "$DIR/gaming-ha-key.sh" /usr/local/sbin/gaming-ha-key

# Eigene Einstellungen: wird nur beim ersten Mal angelegt, danach nie überschrieben
if [[ ! -f /etc/gaming-vm.conf ]]; then
  cat > /etc/gaming-vm.conf <<'CONFEOF'
# Eigene Einstellungen der Gaming-Skripte (gaming-nightly.sh, game-disk-sync.sh, create-kid-vm.sh).
# Diese Datei überschreibt gaming-update nie. Zeile entkommentieren und Wert ändern.
#MASTER_VMID=2190
#MASTER_VOLUME="vm-2190-disk-3"
#STORAGE="data"
#TEMPLATE_VMID=2199
#PLAYERS=()                    # leer = Kinder-VMs automatisch erkennen
#SHUTDOWN_RUNNING_PLAYERS=1    # Nachtlauf: laufende Kinder-VMs herunterfahren
#KEEP_SNAPSHOTS=3
#FORCE_STOP_MASTER=1
#MASTER_TIMEOUT=$((4 * 3600))
CONFEOF
  echo "OK: /etc/gaming-vm.conf angelegt (eigene Einstellungen)"
else
  echo "OK: /etc/gaming-vm.conf vorhanden – bleibt unverändert"
fi
mkdir -p /var/lib/game-disk-sync
echo "OK: Skripte nach /usr/local/sbin installiert"

CRON=/etc/cron.d/gaming-nightly
cat > "$CRON" <<'CRONEOF'
# Nachtlauf Gaming-VMs (angelegt von install-host.sh)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root /usr/local/sbin/gaming-nightly.sh >> /var/log/gaming-nightly.log 2>&1
CRONEOF
echo "OK: Cronjob geschrieben ($CRON, täglich 02:30)"

echo
echo "--- Prüfungen ---"
if pvesm path data:vm-2190-disk-3 >/dev/null 2>&1; then
  echo "OK: D: des Masters (data:vm-2190-disk-3) gefunden"
else
  echo "WARNUNG: data:vm-2190-disk-3 nicht gefunden – MASTER_VOLUME in beiden Skripten anpassen"
fi
if qm config 2199 2>/dev/null | grep -q '^template: 1'; then
  echo "OK: Template 2199 vorhanden"
else
  echo "Hinweis: Template 2199 existiert (noch) nicht – siehe ANLEITUNG.md, Abschnitt 5"
fi
OVR=/etc/vgpu_unlock/profile_override.toml
if [[ -f "$OVR" ]]; then
  if grep -qE '^\s*frl_enabled\s*=\s*0' "$OVR"; then
    echo "OK: Frame Rate Limiter in $OVR ist aus"
  else
    echo "Hinweis: in $OVR steht nicht frl_enabled = 0 (60-FPS-Bremse aktiv)"
  fi
fi

echo
/usr/local/sbin/gaming-nightly.sh --status || true
