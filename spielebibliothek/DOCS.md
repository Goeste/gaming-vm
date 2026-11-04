# Spielebibliothek

Zeigt die Steam-Spiele aller eingetragenen Konten, merkt Installieren/Entfernen für den
Gaming-Master vor und steuert Master und Kinder-VMs. Einrichtung: ANLEITUNG.md, Abschnitt 13.

| Option | Bedeutung |
|---|---|
| `steam_api_key` | Steam-Web-API-Key (steamcommunity.com/dev/apikey) |
| `accounts` | Name + SteamID64 jedes Kontos; Spieldetails im Profil müssen öffentlich sein |
| `library_folder` | Ordner `Bibliothek` auf der Netzwerkfreigabe, z. B. `/share/gaming/prep_savegames/Bibliothek` |
| `proxmox_host` | IP des Proxmox-Hosts (leer = nur Nachtlauf, keine VM-Steuerung) |
| `proxmox_user` | SSH-Benutzer auf dem Host (`root`) |
| `ssh_private_key` | privater Schlüssel aus `gaming-ha-key` auf dem Host (leer = App erzeugt selbst einen, Zeile steht im Protokoll) |
| `master_vmid` | VMID des Masters (2190) |
| `shutdown_running_kids` | `true`: laufende Kinder-VMs beim Sofort-Lauf und bei „Nur verteilen“ kurz herunterfahren, aktualisieren und wieder starten. `false` (Standard): laufende VMs überspringen |
| `vms` | Kinder-VMs (`vmid`, optional `name`), die angezeigt, gestartet, heruntergefahren und beim Verteilen berücksichtigt werden |
