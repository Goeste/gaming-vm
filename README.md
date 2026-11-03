# Gaming-VM

Proxmox-Gaming-Server: Spiele nur im Master installieren, nachts per ZFS-Clone an die
Kinder-VMs verteilen, Streaming mit Sunshine/Moonlight. Alles Weitere: [ANLEITUNG.md](ANLEITUNG.md).

## Aktualisieren

**Proxmox-Host** (als root):
```bash
# erstes Mal
curl -fsSL https://raw.githubusercontent.com/Goeste/gaming-vm/main/host/gaming-update.sh | bash
# danach
gaming-update
```

**Master und Kinder-VMs** (PowerShell als Administrator):
```powershell
# erstes Mal
irm https://raw.githubusercontent.com/Goeste/gaming-vm/main/update.ps1 | iex
# danach
C:\Scripts\gaming-update.ps1
```
Aktualisiert nur die Skripte, die in der VM schon in `C:\Scripts` liegen. Einrichtungen werden nicht erneut ausgeführt.

**Home Assistant** (App „Spielebibliothek“): Einstellungen → Apps → App-Store → ⋮ → Repositories →
`https://github.com/Goeste/gaming-vm` hinzufügen. Updates erscheinen dann automatisch.

## Inhalt
| Ordner | |
|---|---|
| `host/` | Proxmox-Skripte (Nachtlauf, Kinder-VM anlegen, Verteilen, Update) |
| `master/` | Nachtupdate und Spielebibliothek im Master |
| `kind-vm/` | Einrichtung einer neuen Kinder-VM |
| `persist/` | Dauerhafte Daten auf Z:, Spielstand-Scan |
| `sunshine/` | Sunshine-Einstellungen |
| `spielebibliothek/` | Home-Assistant-App |

Hier stehen keine Passwörter oder Schlüssel. Zugangsdaten bleiben verschlüsselt in den VMs bzw. in Home Assistant.
