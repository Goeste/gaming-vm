# Änderungen

## 1.3.1
- Neue Aufteilung: **VMs** oben im festen Kopfbereich, darunter die **Meldungen**.
- **Suche und Filter** stehen jetzt direkt über der Spieleliste.
- Auf niedrigen Bildschirmen scrollt der Kopf mit, damit genug Platz für die Liste bleibt.

## 1.3.0
- **Listenansicht** für die Spiele, jetzt Standard. Umschalten zwischen *Liste* und *Kacheln* neben dem Konten-Filter; die Wahl wird im Browser gemerkt.
- Liste zeigt Bild, Name, Konten, Status, Größe auf dem Master und Spielzeit.
- Dieses Änderungsprotokoll.

## 1.2.0
- Knopf **Host-Skripte aktualisieren**: holt die neuesten Skripte von GitHub auf den Proxmox-Host (`gaming-update`). Ergebnis im VM-Bereich.
- Host lehnt das Update während Nachtlauf/Verteilen ab.

## 1.1.2
- **Spielbilder** auch für neuere Spiele: Fehlt das Bild unter der alten Steam-Adresse, schlägt die App die richtige Adresse im Steam-Store nach. Ohne Store-Eintrag wird das Spiel-Icon gezeigt.

## 1.1.1
- Verbindung zum Host robuster: Statusabfrage auf dem Host viel schneller, die App fragt nie parallel, wiederholt bei Fehlern und zeigt sonst den letzten Stand mit Hinweis.

## 1.1.0
- **VMs in der Konfiguration** (`master_vmid`, `vms` mit optionalem Namen) – genutzt für Anzeige, Verteilen und den Sofort-Lauf.
- Bereich **VMs**: Starten, Herunterfahren, *Alle Kinder-VMs herunterfahren*, *Nur verteilen*.
- **SSH-Schlüssel in der Konfiguration** (`ssh_private_key`, erzeugt mit `gaming-ha-key` auf dem Host) statt auf der Seite.
- Der Host akzeptiert nur Master und Kinder-VMs (andere VMs wie Frigate bleiben unangetastet).

## 1.0.2
- Verständliche Steam-Fehlermeldungen (z. B. falsche SteamID); der API-Key erscheint nicht mehr in Meldungen.

## 1.0.1
- SSH-Aufruf zum Host korrigiert.

## 1.0.0
- Erste Version: Steam-Spiele aller Konten, Installieren/Entfernen vormerken, Knopf *Jetzt installieren und verteilen*, Stand des Masters (installierte Spiele, freier Platz auf D:).
