# Spielebibliothek

Zeigt die Steam-Spiele aller eingetragenen Konten und merkt Installieren/Entfernen für den
Gaming-Master vor. Einrichtung und Ablauf: ANLEITUNG.md, Abschnitt 13.

| Option | Bedeutung |
|---|---|
| `steam_api_key` | Steam-Web-API-Key (steamcommunity.com/dev/apikey) |
| `accounts` | Name + SteamID64 jedes Kontos; Spieldetails im Profil müssen öffentlich sein |
| `library_folder` | Ordner `Bibliothek` auf der Netzwerkfreigabe, z. B. `/share/gaming/Bibliothek` |
| `proxmox_host` | IP des Proxmox-Hosts für den Knopf „Jetzt installieren und verteilen“ (leer = nur nachts) |
| `proxmox_user` | SSH-Benutzer auf dem Host (`root`) |

Der SSH-Schlüssel wird beim ersten Start erzeugt; die Zeile für `authorized_keys` steht unten auf der Seite.
