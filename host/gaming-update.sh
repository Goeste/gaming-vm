#!/usr/bin/env bash
# =============================================================================
# gaming-update.sh  –  Proxmox-Host (als root)
#
# Holt die neueste Version des Pakets von GitHub nach /opt/gaming-vm und
# installiert die Host-Skripte neu (install-host.sh). Kein git nötig.
#
# Erster Aufruf:
#   curl -fsSL https://raw.githubusercontent.com/Goeste/gaming-vm/main/host/gaming-update.sh | bash
# Danach einfach:
#   gaming-update
# =============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

REPO="Goeste/gaming-vm"
BRANCH="main"
DEST="/opt/gaming-vm"

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen."; exit 1; }

STATE=/var/lib/game-disk-sync/update.json      # Ergebnis für die Spielebibliothek (Home Assistant)
tmp=$(mktemp -d)
finish() {
  local rc=$?
  rm -rf "$tmp"
  mkdir -p "$(dirname "$STATE")"
  local res=ok; (( rc == 0 )) || res=error
  echo "{\"time\":\"$(date -Iseconds)\",\"result\":\"$res\",\"exit\":$rc}" > "$STATE"
}
trap finish EXIT
echo "Lade $REPO ($BRANCH) von GitHub ..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}" | tar -xz -C "$tmp"
src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -f "$src/host/install-host.sh" ]] || { echo "FEHLER: Download unvollständig"; exit 1; }

rm -rf "${DEST}.new"
mv "$src" "${DEST}.new"
rm -rf "${DEST}.old"
[[ -d "$DEST" ]] && mv "$DEST" "${DEST}.old"
mv "${DEST}.new" "$DEST"
rm -rf "${DEST}.old"
echo "Paket liegt in $DEST"
echo
bash "$DEST/host/install-host.sh"
