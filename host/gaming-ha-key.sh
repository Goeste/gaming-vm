#!/usr/bin/env bash
# =============================================================================
# gaming-ha-key  –  Proxmox-Host (als root)
#
# Erzeugt einen SSH-Schlüssel für die Home-Assistant-App "Spielebibliothek":
#  - trägt den öffentlichen Teil in /root/.ssh/authorized_keys ein, beschränkt auf
#    game-disk-sync.sh (Status, Verteilen, Master/Kinder-VMs starten/herunterfahren)
#  - entfernt dabei alte Einträge der Spielebibliothek
#  - gibt den privaten Teil aus: in der App unter Konfiguration -> ssh_private_key einfügen
# Der private Schlüssel wird danach auf dem Host gelöscht.
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen."; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N '' -C spielebibliothek-ha -f "$tmp/key"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -v 'spielebibliothek-ha$' /root/.ssh/authorized_keys > "$tmp/ak" || true
echo "command=\"/usr/local/sbin/game-disk-sync.sh\",restrict $(cat "$tmp/key.pub")" >> "$tmp/ak"
cat "$tmp/ak" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "Eingetragen in /root/.ssh/authorized_keys (alte Spielebibliothek-Schlüssel entfernt)."
echo
echo "In Home Assistant: Spielebibliothek -> Konfiguration -> ssh_private_key"
echo "alles zwischen den Linien einfügen (inklusive BEGIN/END):"
echo "------------------------------------------------------------------"
cat "$tmp/key"
echo "------------------------------------------------------------------"
