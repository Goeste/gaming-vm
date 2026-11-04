# Proxmox-Gaming-Server für die Kinder – Gesamtanleitung

Stand: 02.11.2026. Alle Befehle verwenden die echten IDs dieses Systems.

---

## 1. Überblick

**Prinzip:** Spiele werden nur im **Master** installiert und aktualisiert, auf dessen Platte D:.
Jede Nacht macht Proxmox einen ZFS-Snapshot dieser Platte. Jede Kinder-VM bekommt daraus einen
eigenen, **beschreibbaren Clone** als D:. Ein Clone kostet fast keinen Platz und wird jede Nacht
durch einen frischen ersetzt.
Jedes Kind hat eine eigene, dauerhafte C:-Platte (Linked Clone eines Templates) mit Windows-Konto,
Spielständen, Minecraft-Welten und Moonlight-Kopplung.

| Was | Wert |
|---|---|
| Proxmox-Host | `joey` |
| Master-VM | **2190** (Windows 11, lokales Konto `admin`) |
| Master C: | `data:vm-2190-disk-1` (scsi0, 128 GB) |
| Master D: (Spiele) | **`data:vm-2190-disk-3`** (scsi1, 512 GB) – *nicht* disk-1! |
| Template | **2199** (Linked-Clone-Basis für alle Kinder-VMs) |
| Kinder-VMs mit vGPU | 2194, 2195 |
| Kinder-VM mit eigener GPU | 2193 (Quadro RTX 4000, durchgereicht) |
| D: der Kinder-VMs | `data:vm-<ID>-games` an scsi1, wird nachts ersetzt |
| vGPU-Profil | `nvidia-57` = GRID P40-4A, per Override 6 GB, 4K, FRL aus |
| Max. gleichzeitige vGPU-VMs | **4** (24 GB / 6 GB), 2193 zählt nicht mit |

### Was wo gespeichert wird

| Daten | Ort | Bleibt erhalten? |
|---|---|---|
| Spiele (Steam-Bibliothek) | D:\SteamLibrary | kommt jede Nacht neu vom Master |
| Alles, was ein Kind auf D: ändert | D: | **nein**, wird nachts verworfen |
| Umgeleitete Ordner von D: (Abschnitt 6.8) | Z: (eigene Platte pro VM) | ja |
| Spielstände, Steam-Login, Einstellungen | C: (Profil des Kindes) | ja |
| Minecraft Java | `C:\Users\<kind>\AppData\Roaming\.minecraft` | ja |
| Minecraft Bedrock | `C:\Users\<kind>\AppData\Roaming\Minecraft Bedrock\Users\<Nr>\games\com.mojang` | ja |

---

## 2. Inhalt des Pakets

```
ANLEITUNG.md                      diese Datei
host/
  install-host.sh                 installiert die Host-Skripte + Cronjob, prüft alles
  gaming-nightly.sh               Nachtlauf / sofort verteilen / Status
  create-kid-vm.sh                neue Kinder-VM anlegen (Linked Clone + D:)
  game-disk-sync.sh               nur D: an die Kinder verteilen (z. B. aus Home Assistant)
  gaming-update.sh                neueste Version von GitHub holen und installieren (Abschnitt 14)
  vgpu-profile-override.toml      Referenz für /etc/vgpu_unlock/profile_override.toml
master/
  setup-master.ps1                einmalige Einrichtung im Master
  master-update.ps1               Nachtupdate der Spiele im Master
  library-queue.ps1               Aufträge der Spielebibliothek ausführen (Abschnitt 13)
kind-vm/
  setup-kid-vm.ps1                einmalige Einrichtung jeder neuen Kinder-VM
persist/
  init-z.ps1                      dauerhafte Datenplatte Z: einrichten (jede VM, auch Master)
  redirect-to-z.ps1               Ordner auf D: dauerhaft nach Z: umleiten (nur im Master)
  ensure-z-folders.ps1            legt die Zielordner auf Z: an (läuft automatisch)
  scan-spielstaende.ps1           prüft alle Spiele: Wo landen Spielstände und Mods?
  setup-scan-task.ps1             täglichen Scan einrichten (Kinder-VMs) bzw. Freigabe (Master)
  scan-task.ps1                   täglicher Scan, Ergebnis auf die Netzwerkfreigabe
  apply-redirects.ps1             Master übernimmt die Listen aller Kinder-VMs (Nachtlauf)
spielebibliothek/               Home-Assistant-App "Spielebibliothek" (Abschnitt 13)
update.ps1                      Windows: neueste Skripte von GitHub holen (Abschnitt 14)
repository.yaml                 macht das GitHub-Repository zur App-Quelle für Home Assistant
sunshine/
  sunshine-p40.conf               Sunshine-Einstellungen für vGPU-VMs
  sunshine-rtx4000.conf           Sunshine-Einstellungen für VM 2193
```

---

## 3. Proxmox-Host einrichten

### 3.1 Skripte installieren
Ordner `host` auf den Host kopieren (z. B. per `scp`), dann:
```bash
cd host
bash install-host.sh
```
Das installiert `gaming-nightly.sh`, `create-kid-vm.sh` und `game-disk-sync.sh` nach `/usr/local/sbin`.
Es legt außerdem den Cronjob `/etc/cron.d/gaming-nightly` an (täglich **02:30**) und zeigt den aktuellen Status.

### 3.2 vGPU-Override (60-FPS-Bremse aus)
In `/etc/vgpu_unlock/profile_override.toml` muss beim Profil `nvidia-57` stehen:
```toml
frl_enabled = 0
```
Die vollständige Referenz steht in `host/vgpu-profile-override.toml`. Nach einer Änderung die VMs
**ausschalten und neu starten**, ein Windows-Neustart reicht nicht.

### 3.3 Optional: faire GPU-Verteilung (Equal Share)
Nur nötig, wenn ein Kind ruckelt, während das andere spielt:
```bash
echo 'options nvidia NVreg_RegistryDwords="RmPVMRL=0x01"' > /etc/modprobe.d/nvidia-vgpu-scheduler.conf
update-initramfs -u -k all && reboot
```
Falls in `/etc/modprobe.d/` schon eine `NVreg_RegistryDwords`-Zeile existiert, die Werte mit `;`
in **einer** Zeile zusammenführen.

---

## 4. Master (VM 2190) einrichten

1. Ordner `master` in den Master kopieren, z. B. über eine Netzwerkfreigabe.
2. PowerShell **als Administrator** im Ordner öffnen:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\setup-master.ps1
   ```
   Das Skript erledigt:
   - Schnellstart und Ruhezustand aus. D: wird beim Herunterfahren sauber geschlossen.
   - Schreibrechte für die Gruppe „Benutzer“ auf `D:\SteamLibrary`. Ohne die Rechte gibt es bei den Kindern „Datenträgerschreibfehler“.
   - `master-update.ps1` nach `C:\Scripts` kopieren.
   - Die geplante Aufgabe **„Gaming Nachtupdate“** anlegen.
3. Von Hand:
   - **Autologon** für `admin` mit Sysinternals Autologon. Steam braucht eine angemeldete Sitzung.
   - **Steam:** mit dem Konto anmelden, dem die Spiele gehören (Steam-Families-Organisator), „Angemeldet bleiben“.
   - **Steam → Einstellungen → Downloads:** keine Zeitbeschränkung für automatische Updates. Bei jedem Spiel unter Eigenschaften → Updates „Immer aktuell halten“.
   - **Alte Update-Aufgaben** (PSWindowsUpdate/SteamCMD) löschen. Die Aufgabe `pull_license.ps1` bleibt.
4. **Testlauf** (fährt nicht herunter):
   ```powershell
   & 'C:\Scripts\master-update.ps1' -Force -NoShutdown
   ```
   Protokoll: `C:\ProgramData\GamingMaster\master-update.log`

**Verhalten von `master-update.ps1`:**
- Es wird nur **zwischen 01:00 und 06:00 Uhr** aktiv und nur auf dem Computer, auf dem es eingerichtet wurde. Tagsüber kannst du dich normal anmelden und Spiele installieren.
- Vor dem Start von Steam setzt es alle Spiele auf D: auf Update-Priorität **„Hoch“** und hebt geplante Update-Termine auf.
  Sonst verschiebt Steam Updates selten gespielter Spiele auf einen späteren Tag („Update geplant am …“).
  Mit dem Parameter `-KeepUpdateSettings` lässt sich das abschalten.
- Es startet Steam und wartet 5 Minuten, damit Steam nach Updates sucht. Danach wartet es, bis alle Spiele auf D: fertig sind (höchstens 3 Stunden).
- Zum Schluss beendet es Steam sauber und fährt Windows herunter.
- **Eine Nacht aussetzen:** die leere Datei `C:\ProgramData\GamingMaster\SKIP` anlegen.
- Windows-Updates des Masters macht es bewusst nicht. Jede Kinder-VM aktualisiert ihr eigenes Windows selbst.

**Minecraft** wird im Master nicht aktualisiert. Der Launcher lädt Spieldaten pro Benutzer auf C:.
Im Master muss nur der Launcher als Programm installiert sein.

---

## 5. Template (VM 2199)

Das Template **2199 existiert bereits**. Es enthält noch die Sunshine-Identität des Masters.
Das ist kein Problem, weil `setup-kid-vm.ps1` sie in jeder neuen VM zurücksetzt.

Ein Template kann nicht mehr gestartet oder verändert werden. Für eine neue Vorlage:
```bash
qm clone 2199 2198 --name win11-kids-template-v2 --full 1
# 2198 starten, ändern, aufräumen (Steam abmelden, Sunshine-Identität löschen),
# herunterfahren, dann:
qm template 2198
```
Danach in `/usr/local/sbin/create-kid-vm.sh` `TEMPLATE_VMID=2198` setzen.
**2199 nie löschen**, solange Kinder-VMs davon abstammen. Proxmox verhindert das ohnehin.

<details><summary>So wurde 2199 ursprünglich erstellt (nur zur Referenz)</summary>

```bash
# Master ausgeschaltet
qm set 2190 --delete scsi1
qm clone 2190 2199 --name win11-kids-template --full 1
qm set 2190 --scsi1 data:vm-2190-disk-3,backup=0,cache=writeback,discard=on,iothread=1
# in 2199: Steam abmelden, Update-Aufgabe löschen, Sunshine-Identität löschen
qm template 2199
```
</details>

---

## 6. Neue Kinder-VM anlegen

### 6.1 Auf dem Host
```bash
create-kid-vm.sh 2194 emma                          # mit vGPU
create-kid-vm.sh 2193 kind-gpu --gpu 0000:XX:00     # mit eigener GPU (XX: lspci -nn | grep -iE 'vga|3d')
```
Optionen: `--start` (gleich starten), `--new-snapshot` (frischen Stand vom ausgeschalteten Master).
Das Skript erstellt einen Linked Clone von 2199 und hängt `data:vm-<ID>-games` als D: ein.
Bei einem Fehler räumt es selbst auf. Die VM wird nachts automatisch erkannt.

### 6.2 In Windows als admin
Ordner `kind-vm` in die VM kopieren, PowerShell **als Administrator**:
```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-kid-vm.ps1 -ComputerName EMMA -KidUser emma -FixLicenseTask -SetAdminPassword
# VM 2193 mit eigener GPU stattdessen:
.\setup-kid-vm.ps1 -ComputerName KIND-GPU -KidUser <name> -DedicatedGpu -SetAdminPassword
Restart-Computer
```
Das Skript erledigt:
- Sunshine-Identität zurücksetzen. Sonst hält Moonlight die VM für den Master.
- Die Nachtupdate-Aufgabe des Masters entfernen, falls mitgeklont.
- Das Kinderkonto als **Standardbenutzer** anlegen. Von Hand und weitere Verwaltung: Abschnitt 6.7.
- Ein neues admin-Passwort setzen.
- Die vGPU-Lizenzaufgabe auf **SYSTEM + beim Systemstart** stellen, bei eigener GPU abschalten.
- Prüfen, ob D: da ist.
- Den Computer umbenennen.

### 6.3 Nach dem Neustart, als admin
1. **Sunshine:** `https://localhost:47990` öffnen, neuen Login anlegen. Einstellungen nach Abschnitt 8 setzen.
2. **libvirtualhid** im Lizenzprogramm aktivieren. 5 Aktivierungen pro Schlüssel, nur in Kinder-VMs aktivieren, nicht im Master.
3. **NVIDIA-Systemsteuerung** nach Abschnitt 9.
4. **vGPU-Lizenz prüfen** (nicht bei 2193):
   ```powershell
   nvidia-smi -q | findstr /i license
   ```
5. **Optional Autologon** für das Kinderkonto (Abschnitt 6.7). Die VM landet dann direkt auf dem Desktop des Kindes.

### 6.4 Am Mac des Kindes (Moonlight)
- Einen alten Eintrag mit dem Namen des Masters löschen, falls vorhanden.
- Die neue VM hinzufügen (erscheint automatisch oder über „Host hinzufügen“ mit IP) und koppeln.

### 6.5 Als Kind anmelden
1. **Steam:** mit dem eigenen Konto anmelden (Mitglied der Steam Family). Die Spiele auf D: erscheinen als installiert. Sonst: Einstellungen → Speicher → Laufwerk hinzufügen → D:. Ein Spiel kurz starten, um die Schreibrechte zu prüfen.
2. **Minecraft Launcher:** mit dem Microsoft-Konto anmelden. Bei der Windows-Abfrage **„Nur Microsoft-Apps“** wählen, damit das Windows-Konto lokal bleibt.
3. **Desktop-Verknüpfung:** `Win + R` → `shell:AppsFolder` → Rechtsklick auf „Minecraft Launcher“ → „Verknüpfung erstellen“ → „Ja“.

### 6.6 Nur für VM 2193 (Quadro RTX 4000)
- Auf dem Host muss die Karte an `vfio-pci` gebunden sein (`create-kid-vm.sh` warnt sonst).
- In Windows den GRID-Treiber mit **DDU** entfernen und den normalen Quadro/RTX-Enterprise-Treiber installieren.
- Einen **HDMI/DP-Dummy-Stecker** in die Karte stecken. Für 120 FPS muss er „1080p 120Hz“ können.
- Sunshine nach `sunshine-rtx4000.conf`.

### 6.7 Lokales Kinderkonto einrichten und verwalten

Jedes Kind bekommt in seiner VM ein **lokales Windows-Konto als Standardbenutzer**. Lokal heißt: Es ist nicht mit
einem Microsoft-Konto verknüpft. Das Microsoft-Konto des Kindes wird nur in einzelnen Apps (Minecraft, Xbox) genutzt.
Standardbenutzer heißt: keine Admin-Rechte, das Kind kann keine Programme installieren und keine Systemeinstellungen ändern.
Der `admin` bleibt dein Konto für die Verwaltung.

`setup-kid-vm.ps1` legt das Konto automatisch an. Von Hand geht es so (alles als **admin**):

**Anlegen per PowerShell** (als Administrator):
```powershell
$pw = Read-Host -AsSecureString "Passwort für emma"
New-LocalUser -Name "emma" -FullName "Emma" -Password $pw -PasswordNeverExpires
Add-LocalGroupMember -SID "S-1-5-32-545" -Member "emma"     # Gruppe "Benutzer"
```
Die SID statt des Gruppennamens funktioniert unabhängig von der Windows-Sprache.

**Oder über die Einstellungen:**
1. Einstellungen → Konten → **Andere Benutzer** → **Konto hinzufügen**.
2. „Ich kenne die Anmeldeinformationen für diese Person nicht“.
3. „**Benutzer ohne Microsoft-Konto hinzufügen**“.
4. Benutzername, Passwort und Sicherheitsfragen eingeben. Der Kontotyp bleibt „Standardbenutzer“, nicht ändern.

**Prüfen, dass das Kind kein Administrator ist:**
```powershell
Get-LocalGroupMember -SID "S-1-5-32-544"      # nur admin (und ggf. "Administrator") dürfen hier stehen
```

**Das Konto lokal halten:**
- In Apps (Minecraft Launcher, Xbox-App, Store) bei der Windows-Abfrage immer „**Nur Microsoft-Apps**“ bzw. „**Nur diese App**“ wählen.
- Unter Einstellungen → Konten → Ihre Infos **nicht** auf „Stattdessen mit einem Microsoft-Konto anmelden“ klicken.
- Steam braucht kein Microsoft-Konto, dort meldet sich das Kind mit seinem Steam-Konto an.

**Automatische Anmeldung** (empfohlen, sonst startet der Stream am Sperrbildschirm):
1. **Autologon** von Microsoft Sysinternals herunterladen und als admin starten.
2. Username: `emma`, Domain: Computername der VM (z. B. `EMMA`), Passwort eingeben → **Enable**.
3. Abschalten: Autologon erneut starten → **Disable**.

Das Passwort wird verschlüsselt gespeichert. Du kommst weiterhin als admin dran, über „Benutzer wechseln“ oder die Proxmox-Konsole.

**Verwalten** (PowerShell als Administrator):

| Aufgabe | Befehl |
|---|---|
| Passwort ändern | `Set-LocalUser -Name emma -Password (Read-Host -AsSecureString)`, danach **Autologon neu setzen** |
| Konto sperren / entsperren | `Disable-LocalUser emma` / `Enable-LocalUser emma` |
| Konto löschen | `Remove-LocalUser emma`. Der Profilordner `C:\Users\emma` bleibt, löschen über Systemsteuerung → System → Erweiterte Systemeinstellungen → Benutzerprofile |
| Anmeldezeiten begrenzen | `net user emma /times:Mo-Fr,14-19;Sa-So,9-20`, aufheben mit `net user emma /times:all` |

Anmeldezeiten verhindern nur **neue** Anmeldungen außerhalb der Zeiten. Eine laufende Sitzung wird nicht beendet.
Die Bildschirmzeit-Funktionen von Microsoft Family greifen bei einem lokalen Windows-Konto nicht. Nur die
Einstellungen für Xbox und Minecraft (Mehrspieler, Chat, Käufe) gelten über das Microsoft-Konto des Kindes.

### 6.8 Dauerhafte Daten auf Z: (Spielstände/Mods im Spielordner)

Manche Spiele schreiben in ihren eigenen Installationsordner auf D:. Das ist alles, was nachts verworfen wird.
Dafür bekommt **jede VM, auch der Master,** eine eigene dauerhafte Platte **Z:**. Solche Ordner werden
**einmal im Master** nach Z: umgeleitet. Die Umleitung kommt mit D: automatisch in alle Kinder-VMs und zeigt dort auf
deren eigenes Z:. Z: bleibt beim Nachtlauf unberührt und ist in Proxmox-Backups enthalten.

**So funktioniert es:** Im Master wird z. B. `D:\…\FSD\Saved` zu einer Verknüpfung (Junction) auf
`Z:\Persist\D\…\FSD\Saved`. Die Liste aller Umleitungen steht in `D:\_persist\map.txt`. In jeder VM legt die Aufgabe
„Gaming Z-Ordner“ beim Start die fehlenden Zielordner auf Z: an. Der Nachtlauf prüft im Master die Umleitungen und
repariert sie, falls ein Spiele-Update einen Ordner neu angelegt hat.

**Einrichtung einer neuen Kinder-VM:** `create-kid-vm.sh` legt Z: (64 GB) automatisch an. In Windows nur `init-z.ps1` ausführen.

**Einmalig für bestehende VMs:**

1. **Auf dem Host** die Platten anlegen (VMs dürfen dabei aus sein):
   ```bash
   qm set 2190 --scsi2 data:16,cache=writeback,discard=on,iothread=1,ssd=1   # Master, klein reicht
   for id in 2193 2194 2195 2196; do
     qm set $id --scsi2 data:64,cache=writeback,discard=on,iothread=1,ssd=1
   done
   ```
2. **In jeder VM, auch dem Master,** den Ordner `persist` hineinkopieren, dann PowerShell als Administrator:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\init-z.ps1
   ```
3. **Im Master umleiten.** Steam und das Spiel müssen geschlossen sein. Beispiel Deep Rock Galactic:
   ```powershell
   & C:\Scripts\redirect-to-z.ps1 'D:\SteamLibrary\steamapps\common\Deep Rock Galactic\FSD\Saved','D:\SteamLibrary\steamapps\common\Deep Rock Galactic\FSD\Mods'
   & C:\Scripts\redirect-to-z.ps1 -List
   ```
4. Master herunterfahren und verteilen: `game-disk-sync.sh --shutdown-running` auf dem Host, oder bis zum Nachtlauf warten.

**Automatisch prüfen, welche Spiele betroffen sind:** `scan-spielstaende.ps1` geht alle installierten Spiele von
Steam, GOG und Epic durch. Ausführen in einer **Kinder-VM als Administrator**, am besten nach einem Spielenachmittag und
**vor** dem Nachtlauf:
```powershell
& C:\Scripts\scan-spielstaende.ps1
```
Das Skript prüft pro Spiel drei Dinge:
- ob seit dem Start der VM Dateien im Spielordner auf D: geändert wurden,
- ob es typische Ordner wie `Saved`, `Saves` oder `Mods` gibt,
- ob Spielstände auf C: liegen (Steam Cloud, Dokumente, Gespeicherte Spiele, AppData).

Auf dem Desktop landen drei Dateien:
- `spielstaende-bericht.txt`: Ergebnis pro Spiel
- `spielstaende.csv`: dasselbe als Tabelle
- `umleiten-vorschlaege.ps1`: fertige Befehle für die Umleitung. Die Datei **in den Master kopieren** und dort als Administrator ausführen.
  Aktive Zeilen gehören zu Spielen, die heute in ihren Ordner geschrieben haben. Auskommentierte Zeilen sind nur ein Verdacht und sollten erst geprüft werden.

| Status | Bedeutung |
|---|---|
| UMLEITEN | hat heute in den Spielordner auf D: geschrieben, das geht nachts verloren |
| PRUEFEN | typischer Spielstand- oder Mod-Ordner im Spielordner, heute aber nichts geschrieben |
| OK (C:) | Spielstände liegen auf C: oder in der Steam Cloud |
| UMGELEITET | bereits auf Z: umgeleitet |
| OK | nicht auf D: installiert |
| UNKLAR | keine Hinweise, vermutlich noch nicht gespielt. Nach einer Spielrunde erneut prüfen |

Mit `-NoDynamic` prüft das Skript nur die Ordnernamen. Das ist schneller, aber weniger genau.

**Weitere Befehle** (im Master):

| Zweck | Befehl |
|---|---|
| Alle Umleitungen anzeigen | `& C:\Scripts\redirect-to-z.ps1 -List` |
| Alle prüfen und reparieren | `& C:\Scripts\redirect-to-z.ps1 -Repair` (macht auch der Nachtlauf) |
| Ordner mit Startinhalt umleiten, den jede VM einmal bekommt (z. B. mitgelieferte Konfiguration) | `… redirect-to-z.ps1 '<Pfad>' -Seed` |
| Umleitung aufheben, Daten zurück nach D: | `… redirect-to-z.ps1 '<Pfad>' -Remove` |

**Hinweise:**
- **Nur Ordner umleiten, die das Spiel selbst anlegt** (Spielstände, Einstellungen, Mods), nicht Ordner mit Spieldateien.
- **`steamapps\workshop` umleiten** behält die Workshop-Mods der Kinder. Dann kommen aber Mods, die du im Master abonnierst, nicht mehr bei den Kindern an.
- Wo ein Spiel speichert, steht auf pcgamingwiki.com unter „Save game data location“.
- Ob die Zielordner angelegt wurden, steht in `C:\ProgramData\GamingPersist\ensure.log`.

### 6.9 Automatisch: täglicher Scan und Umleitung über eine Netzwerkfreigabe

So musst du nichts mehr von Hand umleiten:
1. **01:30:** Jede **laufende** Kinder-VM scannt alle Spiele und kopiert die heutigen Daten der sicheren Fälle schon auf ihr Z:.
   Das Ergebnis legt sie auf der Freigabe unter `Spielstaende\<VM-Name>\` ab.
2. **02:30 (Nachtlauf):** Der Master geht die Listen aller Kinder-VMs nacheinander durch und richtet die Umleitungen ein.
3. Danach wird verteilt. Ab dann schreiben die Spiele direkt auf Z:.

**Sicherheit:** Die Kinder-VMs schreiben nur eine Liste von Ordnern (`umleiten.txt`). Der Master führt von der Freigabe
**keinen Code** aus und prüft jeden Eintrag. Erlaubt ist er nur, wenn:
- er auf D: liegt, ohne `..` und nicht in `D:\_persist`,
- der Ordnername ein bekannter Spielstand-, Mod- oder Einstellungsordner ist (`Saved`, `Saves`, `Mods`, `Config` …),
- das Spiel im Master installiert ist.

Alles andere wird abgelehnt und protokolliert. Automatisch kommen nur die sicheren Fälle in die Liste. Unklare Fälle
(z. B. ein Spiel schreibt in `Binaries` oder nur Logs) stehen auskommentiert in `umleiten-vorschlaege.ps1`
im VM-Ordner auf der Freigabe. Die schaust du dir bei Gelegenheit selbst an.

**Einrichtung.** Die Freigabe muss als **Netzwerkadresse** angegeben werden, nicht als `S:`, weil geplante Aufgaben keine
verbundenen Laufwerke sehen. Die Adresse zu `S:` zeigt `net use` (z. B. `\\NAS\gaming`).

1. **In jeder Kinder-VM** (PowerShell als Administrator, im Ordner `persist`; `init-z.ps1` muss vorher gelaufen sein):
   ```powershell
   .\setup-scan-task.ps1 -Share '\\NAS\gaming'
   ```
   Das Skript fragt nur nach **Benutzer und Passwort der Freigabe** (z. B. des NAS-Benutzers).
   Ein Windows-Passwort ist nicht nötig, auch nicht bei Anmeldung per PIN. Die Aufgabe läuft als Systemkonto.

   Testen: `Start-ScheduledTask 'Gaming Spielstand-Scan'`, danach in `C:\ProgramData\GamingPersist\scan-task.log` nachsehen.
2. **Im Master:**
   ```powershell
   .\setup-scan-task.ps1 -Share '\\NAS\gaming' -Master
   & C:\Scripts\apply-redirects.ps1 -WhatIf      # zeigt, was übernommen würde, ohne etwas zu ändern
   ```
   Außerdem die neue `master-update.ps1` nach `C:\Scripts` kopieren. Sie ruft `apply-redirects.ps1` im Nachtlauf auf.

**Protokolle:**
- Kinder-VM: `C:\ProgramData\GamingPersist\scan-task.log`
- Master: `C:\ProgramData\GamingPersist\apply.log`, Zusammenfassung zusätzlich als `_master.log` auf der Freigabe
- Berichte pro VM: `Spielstaende\<VM-Name>\spielstaende-bericht.txt` auf der Freigabe

**Gut zu wissen:**
- Der Scan läuft nur, wenn die VM um 01:30 an ist. Eine ausgeschaltete VM holt das in einer späteren Nacht nach. Die Liste auf der Freigabe wird dabei nie verkleinert.
- Die Zugangsdaten der Freigabe werden an die VM gebunden verschlüsselt. Lesen können sie nur Administratoren und das Systemkonto dieser VM, die Kinder nicht.
- Uhrzeit ändern: `.\setup-scan-task.ps1 -Share '…' -At '00:45'`. Der Scan muss vor dem Nachtlauf um 02:30 liegen.

---

## 7. Täglicher Betrieb

### Nachtlauf (automatisch, 02:30)
1. Proxmox startet den Master. Autologon startet `master-update.ps1`, das die Spiele aktualisiert und Windows herunterfährt.
2. `gaming-nightly.sh` macht einen Snapshot von D: und ersetzt den D:-Clone jeder Kinder-VM.
   - Laufende Kinder-VMs werden kurz heruntergefahren und danach wieder gestartet.
   - Fährt der Master nicht innerhalb von 4 Stunden selbst herunter, wird **nichts** verteilt. Die Kinder behalten den alten Stand.
   - Die letzten 3 Snapshots bleiben erhalten.

Protokoll: `/var/log/gaming-nightly.log` (Host) und `C:\ProgramData\GamingMaster\master-update.log` (Master).

### Befehle auf dem Host
```bash
gaming-nightly.sh --status          # Stand jeder Kinder-VM: "aktuell" oder "VERALTET"
gaming-nightly.sh --rollout-only    # Master-Stand sofort verteilen (Master muss aus sein)
gaming-nightly.sh                   # kompletten Nachtlauf jetzt starten (siehe unten)
gaming-nightly.sh --now             # wie der Knopf in der Spielebibliothek: Master starten, laufende Kinder-VMs nicht stören
```

**Kompletter Lauf tagsüber:** `master-update.ps1` arbeitet nur zwischen 01:00 und 06:00. Tagsüber startet
`gaming-nightly.sh` den Master und wartet dann. Es meldet sich alle 10 Minuten und gibt am Anfang einen Hinweis aus.
Melde dich in dieser Zeit am Master an und führe `& 'C:\Scripts\master-update.ps1' -Force` aus.
Der Master aktualisiert und fährt herunter, danach verteilt das Host-Skript D:.
Die Meldungen `swtpm_setup: Not overwriting existing state file` und `vfio … Could not enable error recovery`
beim Start des Masters sind harmlos.
Brichst du mit Strg+C ab, läuft der Master weiter. Dann `qm shutdown 2190` ausführen.

### Neues Spiel installieren
Am bequemsten über die **Spielebibliothek** in Home Assistant (Abschnitt 13). Von Hand:
1. Im Master als admin in Steam auf `D:\SteamLibrary` installieren.
2. Steam beenden, Master herunterfahren.
3. Auf dem Host `gaming-nightly.sh --rollout-only` ausführen. Laufende Kinder-VMs bekommen das Spiel in der nächsten Nacht.
   Ohne diesen Schritt kommt das Spiel automatisch in der nächsten Nacht.

### Spieleplatte nur verteilen: `game-disk-sync.sh`
Unabhängig vom Nachtlauf: Das Skript macht einen Snapshot der Master-Spieleplatte und gibt den Kinder-VMs frische Clones.
Es startet den Master nicht und aktualisiert keine Spiele. **Der Master muss ausgeschaltet sein.**
```bash
game-disk-sync.sh                      # alle Kinder-VMs, laufende werden übersprungen
game-disk-sync.sh 2194 2195            # nur diese VMs
game-disk-sync.sh --shutdown-running   # laufende herunterfahren, aktualisieren, wieder starten
game-disk-sync.sh --detach             # im Hintergrund, kehrt sofort zurück
game-disk-sync.sh --status             # Stand als JSON
```
- Hat sich die Master-Platte seit dem letzten Snapshot nicht geändert, wird kein neuer angelegt. VMs, die schon aktuell sind, werden nicht angefasst. Mehrfaches Ausführen schadet also nicht.
- Läuft gerade der Nachtlauf, bricht es ab. Beide nutzen dieselbe Sperre.
- Exit-Code: `0` = alle aktuell, `2` = einige übersprungen (liefen), `1` = Fehler (z. B. Master an).
- Ergebnis des letzten Laufs: `/var/lib/game-disk-sync/last.json`, Log: `/var/log/game-disk-sync.log`.

### Home Assistant anbinden
Home Assistant ruft das Skript per SSH auf. Der Schlüssel darf **nur dieses eine Skript** ausführen, sonst nichts auf dem Host.

**1. Schlüssel in Home Assistant erzeugen.** Im Add-on „Terminal & SSH“. Der Konfigurationsordner heißt dort je nach Version `/config` oder `/homeassistant`, für Home Assistant selbst ist er immer `/config`:
```bash
mkdir -p /config/.ssh
ssh-keygen -t ed25519 -f /config/.ssh/proxmox_gaming -N "" -C homeassistant
cat /config/.ssh/proxmox_gaming.pub
```

**2. Schlüssel auf dem Proxmox-Host freigeben**, eingeschränkt auf das Skript. In `/root/.ssh/authorized_keys` eine Zeile anhängen:
```
command="/usr/local/sbin/game-disk-sync.sh",restrict ssh-ed25519 AAAA…(Inhalt der .pub-Datei)… homeassistant
```
`restrict` verbietet Weiterleitungen und Terminal. Erlaubt sind nur VM-Nummern und die Optionen `--detach`, `--shutdown-running` und `--status`.

**3. Einmal testen** (aus dem Terminal-Add-on, Host-Schlüssel mit „yes“ bestätigen):
```bash
ssh -i /config/.ssh/proxmox_gaming -o UserKnownHostsFile=/config/.ssh/known_hosts root@<IP-des-Hosts> game-disk-sync --status
```
Es muss eine JSON-Zeile kommen.

**4. In `configuration.yaml`** (`<IP-des-Hosts>` ersetzen, danach Home Assistant neu starten):
```yaml
shell_command:
  gaming_sync: >-
    ssh -i /config/.ssh/proxmox_gaming -o UserKnownHostsFile=/config/.ssh/known_hosts
    root@<IP-des-Hosts> game-disk-sync --detach
  gaming_sync_alle: >-
    ssh -i /config/.ssh/proxmox_gaming -o UserKnownHostsFile=/config/.ssh/known_hosts
    root@<IP-des-Hosts> game-disk-sync --detach --shutdown-running

command_line:
  - sensor:
      name: Gaming Spielestand
      unique_id: gaming_spielestand
      command: >-
        ssh -i /config/.ssh/proxmox_gaming -o UserKnownHostsFile=/config/.ssh/known_hosts
        root@<IP-des-Hosts> game-disk-sync --status
      value_template: "{{ value_json.vms | rejectattr('current') | list | count }}"
      unit_of_measurement: "veraltet"
      json_attributes:
        - master
        - latest_snapshot
        - master_changed_bytes
        - vms
        - last_run
      scan_interval: 600
```
- **Aktionen** `shell_command.gaming_sync` bzw. `shell_command.gaming_sync_alle` z. B. auf einen Dashboard-Button legen.
  `--detach` ist wichtig: Home Assistant bricht Befehle nach 60 Sekunden ab, das Skript läuft im Hintergrund weiter.
- **Sensor** „Gaming Spielestand“ zeigt die Anzahl veralteter Kinder-VMs. In den Attributen stehen der Zustand des Masters,
  die Änderungen seit dem letzten Snapshot und das Ergebnis des letzten Laufs (`last_run.result`: `ok`, `partial` oder `error`).

### Einstellungen im Nacht-Skript (`/usr/local/sbin/gaming-nightly.sh`)
- `SHUTDOWN_RUNNING_PLAYERS=0`: Wer um 02:30 noch spielt, wird nicht rausgeworfen. Seine VM wird dann übersprungen.
- `KEEP_SNAPSHOTS`, `MASTER_TIMEOUT`: Anzahl der aufgehobenen Snapshots und Zeitlimit für den Master.
- Uhrzeit: in `/etc/cron.d/gaming-nightly`. Muss im Fenster 01:00–06:00 von `master-update.ps1` liegen.

---

## 8. Sunshine-Einstellungen (Weboberfläche)

Werte für die vGPU-VMs stehen in `sunshine/sunshine-p40.conf`, für 2193 in `sunshine/sunshine-rtx4000.conf`.

| Reiter | Einstellung | vGPU (P40) | 2193 (RTX 4000) |
|---|---|---|---|
| Audio/Video | Grafikadapter | GRID P40-4A | Quadro RTX 4000 |
| Audio/Video | Display-Konfiguration | Einziger Bildschirm (`ensure_only_display`) | gleich |
| Audio/Video | Auflösung / Bildwiederholrate | Automatisch | Automatisch |
| Audio/Video | HDR | Deaktiviert | Deaktiviert |
| Audio/Video | Maximale Bitrate | 40000 | 80000 |
| Eingabe | Gamepad-Treiber | virtualhid | virtualhid |
| Eingabe | Gamepad | Automatisch | Automatisch |
| Netzwerk | LAN-Verschlüsselung / UPnP | 0 / aus | 0 / aus |
| Erweitert | Encoder / Capture | NVENC / DDX | NVENC / DDX |
| Erweitert | HEVC / AV1 | 2 / 1 (kein AV1) | 0 / 1 (kein AV1) |
| NVENC | Preset / Two-Pass | P1 / Quarter Res | P1 / Quarter Res |
| NVENC | Spatial AQ | aus | aus (bei WLAN: an) |
| NVENC | VBV-Erhöhung | 0 | 0 |
| NVENC | Latenz vor Energiesparen | an | an |
| NVENC | OpenGL/Vulkan auf DXGI | an | an |

### Moonlight auf den Macs
| | vGPU-VMs | 2193 |
|---|---|---|
| Auflösung | 1920×1080 | 1920×1080 |
| Bildrate | 60 FPS | 120 FPS (nur MacBook Pro mit ProMotion + 120-Hz-Dummy), sonst 60 |
| Codec | HEVC | HEVC |
| Bitrate | 20–30 Mbit/s | 40–60 Mbit/s bei 120 FPS |
| Spieleinstellungen optimieren | an | an |
| V-Sync | aus | aus |

Statistik-Overlay: **Strg+Alt+Shift+S**. Liegt die Encoder-Zeit dauerhaft über 10 ms, ist die GPU ausgelastet.
Dann die Grafikdetails im Spiel senken.

---

## 9. NVIDIA-Systemsteuerung

Als admin unter 3D-Einstellungen verwalten → Globale Einstellungen, **in jeder VM einzeln**.

| Einstellung | vGPU (P40) | 2193 (RTX 4000) |
|---|---|---|
| Max. Bildfrequenz | **60 FPS** | gleich der Stream-Bildrate (60/120) |
| Modus für geringe Latenz | Ein (Ultra geht auch) | Ultra |
| Vertikale Synchronisierung | Aus | Aus |
| Energieverwaltungsmodus | Maximale Leistung bevorzugen | Maximale Leistung bevorzugen |
| OpenGL-rendernde GPU | GRID P40-4A | Quadro RTX 4000 |
| Vulkan/OpenGL-Darstellungsmethode | Geschichtet auf DXGI Swapchain bevorzugen | gleich |
| Shader-Cache-Größe | 10 GB oder Unbegrenzt | 10 GB oder Unbegrenzt |
| Texturfilterung – Qualität | Hohe Leistung | Hohe Leistung oder Qualität |
| Threaded-Optimierung | Auto | Auto |
| Dreifach-Puffer, FXAA, MFAA, Umgebungsverdeckung | Aus | Aus |
| Antialiasing, Anisotrope Filterung | Anwendungsgesteuert | Anwendungsgesteuert |

Bei 2193 zusätzlich unter Anzeige → Auflösung ändern die höchste Bildwiederholrate des Dummy-Steckers wählen.

---

## 10. Minecraft: Welten umziehen

### Java Edition
**Auf dem alten PC** (Minecraft geschlossen):
```powershell
Compress-Archive -Path "$env:APPDATA\.minecraft\saves","$env:APPDATA\.minecraft\resourcepacks","$env:APPDATA\.minecraft\options.txt" -DestinationPath "$env:USERPROFILE\Desktop\minecraft-backup.zip"
```
Bei Mod-Welten zusätzlich `mods` sichern. Die Anmeldedaten (`launcher_accounts*`, `launcher_msa*`) **nicht** mitnehmen.

**In der Kinder-VM, als das Kind angemeldet:**
1. Die ZIP nach `C:\Users\Public` legen.
2. Den Launcher einmal starten und die gleiche oder eine neuere Version einmal öffnen, dann schließen.
3. Entpacken:
   ```powershell
   Expand-Archive "C:\Users\Public\minecraft-backup.zip" -DestinationPath "$env:APPDATA\.minecraft" -Force
   ```

### Bedrock Edition
- **Empfohlen:** Welt im Spiel → Stift-Symbol → ganz unten „Welt exportieren“ ergibt eine `.mcworld`-Datei. Auf dem Klon als Kind per Doppelklick importieren. Selbst installierte Add-ons der Welt kommen mit.
- **Komplettsicherung** aller Welten:
  ```powershell
  Compress-Archive -Path "$env:APPDATA\Minecraft Bedrock\Users" -DestinationPath "$env:USERPROFILE\Desktop\bedrock-backup.zip"
  ```
  Die alte Version speichert unter `%LOCALAPPDATA%\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang`.
  Beim Wiederherstellen die Ordner aus `minecraftWorlds` in den Kontoordner des Kindes kopieren:
  `%APPDATA%\Minecraft Bedrock\Users\<Nr>\games\com.mojang\minecraftWorlds`.
  Den Ordner gibt es erst nach dem ersten Start mit dem Konto des Kindes.
- **Marketplace-Inhalte** sind an das Microsoft-Konto gebunden. Das Kind lädt sie im Marketplace unter „Meine Inhalte“ neu herunter.

**Nie Minecraft-Daten auf D: legen.** D: wird jede Nacht ersetzt.

---

## 11. Fehlerbehebung

| Problem | Ursache / Lösung |
|---|---|
| Moonlight zeigt die neue VM als „Master“ an | Sunshine-Identität mitgeklont → `setup-kid-vm.ps1` ausführen, in Moonlight den alten Eintrag löschen, neu koppeln |
| Nach ca. 20 Min. ruckelt alles extrem | vGPU nicht lizenziert → `nvidia-smi -q \| findstr /i license`, Lizenzaufgabe mit `-FixLicenseTask` korrigieren, neu starten |
| Steam: „Datenträgerschreibfehler“ | Rechte auf D: fehlen → im Master `setup-master.ps1` erneut ausführen, dann `gaming-nightly.sh --rollout-only` |
| Kind sieht ein Spiel nicht / kann es nicht starten | Spiel nicht in der Steam Family geteilt, oder die Kopie wird gerade von jemand anderem gespielt (eine Kopie = ein Spieler gleichzeitig) |
| Minecraft startet minutenlang nicht | Anmeldefenster hinter dem Launcher (Alt+Tab); erster Download (Task-Manager); Bedrock: als admin „Gaming Services“ aus dem Store; Kinderkonto: Freigabe in Microsoft Family Safety |
| Nur 60 FPS trotz Leistung | `frl_enabled = 0` im Override fehlt (oder die VM wurde nur in Windows neu gestartet); „Max. Bildfrequenz“ in der NVIDIA-Systemsteuerung |
| Kinder-VM hat alten Spielestand | `gaming-nightly.sh --status`; die VM lief beim Rollout → `--rollout-only`, wenn sie aus ist |
| Neue vGPU-VM startet nicht | Bereits 4 vGPU-VMs aktiv (6 GB × 4 = 24 GB) → eine ausschalten |
| Nachtlauf hat nichts verteilt | Master nicht selbst heruntergefahren → `master-update.log` prüfen (Steam nicht angemeldet? SKIP-Datei? Autologon?) |
| Master morgens noch an | Ein Schritt im Master hing, z. B. an der Netzwerkfreigabe. Seit dieser Version gilt: Übernahme und Reparatur laufen mit 15 Minuten Zeitlimit. `setup-master.ps1` erneut ausführen, damit Windows blockierende Programme beim Herunterfahren selbst beendet. Notfalls schaltet der Host den Master hart aus (`FORCE_STOP_MASTER=1`). Protokolle: `master-update.log`, `C:\ProgramData\GamingMaster\step-*.log`, `/var/log/gaming-nightly.log` |

---

## 12. Wichtig zu wissen

- **Steam Families:** Eine gekaufte Kopie kann nur von einer Person gleichzeitig gespielt werden. Free-to-Play-Spiele sind unbegrenzt.
- **Spiele-Updates tagsüber** lädt Steam in der Kinder-VM selbst in deren Clone. Das funktioniert, nachts kommt die Version dann vom Master.
- **Windows-Updates** der Kinder-VMs laufen in jeder VM selbst, nicht über den Master.
- **Programme auf C:** (Treiber, neue Launcher) in jeder Kinder-VM einzeln installieren, oder ein neues Template bauen (Abschnitt 5).
- **libvirtualhid:** 5 Aktivierungen pro Lizenz. Beim Löschen einer VM vorher deaktivieren oder im Polar-Kundenportal von LizardByte freigeben.
- **Lifetime- statt Jahreslizenz** für libvirtualhid lohnt sich hier: Eine Jahreslizenz braucht nach jedem Neustart erst Internet, bevor Controller gehen.

---

## 13. Spielebibliothek in Home Assistant (Steam)

Eine Seite in Home Assistant zeigt alle Steam-Spiele **aller eingetragenen Konten** (deins und die der Kinder) in einer Liste.
Du klickst **Installieren** oder **Entfernen**, und der Master erledigt das im Nachtlauf. Mit
**Jetzt installieren und verteilen** startet der Master sofort. Nach dem Download wird D: an die Kinder-VMs verteilt.

```
Home Assistant (App "Spielebibliothek")
   │  schreibt  Bibliothek\auftrag.json  ──►  Netzwerkfreigabe  ◄── liest
   │  liest     Bibliothek\status.json   ◄──                    ──► schreibt     Master (library-queue.ps1)
   └─ SSH (nur game-disk-sync.sh) ──► Proxmox: Master starten ──► Steam lädt ──► Master aus ──► D: verteilen
```

**Wie das Installieren funktioniert:** Der Master legt für das Spiel ein Steam-Manifest an (`appmanifest_<ID>.acf`,
Status „Update nötig“). Beim nächsten Start lädt Steam das Spiel herunter. Das ist kein offizieller Weg von Valve,
funktioniert aber zuverlässig. Steam lädt nur Spiele, die das **Steam-Konto des Masters** spielen darf:
- eigene Spiele des Master-Kontos,
- Spiele der Kinder über **Steam Families**, sofern der Herausgeber das Spiel für die Familie freigegeben hat.

Lädt Steam ein Spiel nicht einmal an (keine Lizenz), trägt der Master es nach dem Lauf wieder aus. Die Seite zeigt dann
„fehler: Steam hat den Download nicht begonnen …“.

**Entfernen** löscht das Spiel nur aus `D:\SteamLibrary\steamapps\common`. Umleitungen nach Z: werden dabei nicht
verfolgt, die Spielstände auf Z: bleiben erhalten. Pro Lauf werden höchstens 10 Spiele entfernt.

**Sicherheit:**
- Die Seite ist nur über Home Assistant erreichbar (Anmeldung) und nur für **Administratoren** sichtbar.
- Der Master führt von der Freigabe keinen Code aus. Aus `auftrag.json` liest er nur App-Nummern und Namen und prüft sie.
- Der SSH-Schlüssel der App darf auf dem Host nur `game-disk-sync.sh` aufrufen (Status, verteilen, Master starten).

### 13.1 Steam-Konten vorbereiten
1. **Steam-API-Key** holen: <https://steamcommunity.com/dev/apikey>. Als Domain kannst du `localhost` eintragen.
   Den Key hältst du geheim.
2. **SteamID64** jedes Kontos herausfinden: Im Steam-Profil die URL ansehen (`…/profiles/7656119…`). Bei eigenen
   Profil-Namen zeigt z. B. steamid.io die 17-stellige Nummer.
3. In **jedem Konto**: Profil → Profil bearbeiten → Privatsphäre: **Spieldetails = Öffentlich**.
   Sonst liefert Steam für dieses Konto keine Spieleliste.

### 13.2 Freigabe in Home Assistant einbinden
Die App braucht dieselbe Freigabe, die auch der Master nutzt (Abschnitt 6.9).
1. Home Assistant → Einstellungen → System → Speicher → **Netzwerkspeicher hinzufügen**.
2. Name `gaming`, Verwendung **Share**, Server und Freigabename wie bei `\\NAS\gaming`, Benutzer und Passwort der Freigabe.
3. Sie erscheint in Home Assistant als `/share/gaming`. Der Ordner für die App ist dann `/share/gaming/Bibliothek`.

Wichtig: `Bibliothek` liegt direkt in der Freigabe, die du im Master bei `setup-scan-task.ps1 -Share` angegeben hast.

### 13.3 App installieren
1. Einstellungen → Apps → **App-Store** (unten rechts) → oben rechts ⋮ → **Repositories**.
2. `https://github.com/Goeste/gaming-vm` eintragen → **Hinzufügen** → schließen, Seite neu laden.
3. Im App-Store erscheint der Abschnitt **Gaming-VM (Goeste)** mit **Spielebibliothek** → **Installieren**.
   Home Assistant baut die App selbst (1–3 Minuten). Neue Versionen erscheinen später als normales Update.
4. Reiter **Konfiguration**:
   ```yaml
   steam_api_key: "DEIN-KEY"
   accounts:
     - name: Papa
       steamid: "76561198000000001"
     - name: Emma
       steamid: "76561198000000002"
   library_folder: /share/gaming/prep_savegames/Bibliothek   # Ordner "Bibliothek" in der Freigabe aus share.json
   proxmox_host: 192.168.2.12        # IP des Proxmox-Hosts, leer lassen = nur nachts
   proxmox_user: root
   ssh_private_key: ""               # siehe 13.4
   master_vmid: 2190
   shutdown_running_kids: false      # true = laufende Kinder-VMs beim Knopf kurz herunterfahren und neu starten
   vms:                              # Kinder-VMs, die die App anzeigt und steuert
     - vmid: 2193
       name: Felix
     - vmid: 2194
       name: Emma
     - vmid: 2195
     - vmid: 2196
   ```
   `name` ist optional, ohne Namen zeigt die App den Namen aus Proxmox.
5. Starten, **In Seitenleiste anzeigen** einschalten.

### 13.4 Verbindung zum Proxmox-Host (SSH-Schlüssel)
Über SSH zeigt die App die VMs, startet und stoppt sie, verteilt D: und startet den Master für
„Jetzt installieren und verteilen“. Der Schlüssel darf auf dem Host **nur** `game-disk-sync.sh` aufrufen, und dieses
Skript akzeptiert nur den Master und die Kinder-VMs (Frigate 2067 o. ä. lehnt es ab).

1. Auf dem Host die neuen Skripte holen und den Schlüssel erzeugen:
   ```bash
   gaming-update
   gaming-ha-key
   ```
   `gaming-ha-key` trägt den öffentlichen Teil in `/root/.ssh/authorized_keys` ein (alte Einträge der Spielebibliothek
   werden ersetzt) und zeigt den privaten Teil an.
2. In Home Assistant: Spielebibliothek → **Konfiguration** → `ssh_private_key`: den ganzen angezeigten Block einfügen,
   von `-----BEGIN OPENSSH PRIVATE KEY-----` bis `-----END OPENSSH PRIVATE KEY-----`. Fehlende Zeilenumbrüche
   sind egal. Speichern, App neu starten.
3. Auf der Seite steht jetzt der Bereich **VMs** mit Master und Kinder-VMs.

Ohne `ssh_private_key` erzeugt die App selbst einen Schlüssel; die Zeile für `authorized_keys` steht dann im
**Protokoll** der App. Ein Schlüssel aus Abschnitt 7 (Home-Assistant-Automationen) kann bleiben.

**Was die App auf dem Host darf:**
| Knopf | Befehl auf dem Host |
|---|---|
| Jetzt installieren und verteilen | `gaming-nightly.sh --now <VMs aus der Konfiguration>` |
| Nur verteilen | `game-disk-sync.sh <VMs>` – nur ausgeschaltete VMs, Master muss aus sein |
| Starten / Herunterfahren | `qm start` bzw. `qm shutdown` – nur Master und Kinder-VMs, nicht während des Nachtlaufs |
| Host-Skripte aktualisieren | `gaming-update` – neueste Skripte von GitHub, nicht während des Nachtlaufs (Log: `/var/log/gaming-update.log`) |

### 13.5 Master
Im Master als Administrator (die Freigabe muss nach 6.9 mit `-Master` eingerichtet sein):
```powershell
Copy-Item .\master\master-update.ps1, .\master\library-queue.ps1 C:\Scripts -Force
```
Oder `setup-master.ps1` erneut ausführen. Das schadet nicht.

Testen, ohne etwas zu ändern:
```powershell
& C:\Scripts\library-queue.ps1 -Apply -WhatIf     # zeigt die Aufträge (Steam muss beendet sein)
& C:\Scripts\library-queue.ps1 -Export            # schreibt die Liste der installierten Spiele
```
Danach zeigt die Seite bei „Auf dem Master installiert“ die richtige Zahl.

### 13.6 Ablauf
**Nachts (02:30):** Der Master führt die Aufträge aus, Steam lädt neue Spiele und Updates, der Master meldet den Stand und
fährt herunter. Danach wird wie immer verteilt.

**Knopf:** Die App merkt den Zeitpunkt in `auftrag.json` vor und startet über SSH `gaming-nightly.sh --now`.
Der Master startet, erkennt den Sofort-Auftrag (gültig 3 Stunden) und arbeitet wie nachts.
**Laufende Kinder-VMs werden dabei nicht heruntergefahren.** Sie bekommen das neue Spiel in der nächsten Nacht. Ausgeschaltete VMs bekommen es sofort.

Große Spiele: Der Master lädt höchstens 3 Stunden (`-TimeoutMin` in `master-update.ps1`). Nicht fertige Downloads
macht Steam in der nächsten Nacht weiter. Die Seite zeigt so lange „Wird geladen“.

### 13.7 Protokolle und Fehler
| Wo | Was |
|---|---|
| Master `C:\ProgramData\GamingMaster\library.log` | ausgeführte Aufträge |
| Master `C:\ProgramData\GamingMaster\step-library-queue-*.log` | Ausgabe des letzten Laufs |
| Freigabe `Bibliothek\status.json` | installierte Spiele, freier Platz, Ergebnisse |
| Host `/var/log/gaming-nightly.log` | Sofort-Lauf und Nachtlauf |
| Home Assistant: App → Protokoll | Fehler der App |

| Meldung | Ursache |
|---|---|
| „Konto: keine Spiele sichtbar“ | Spieldetails des Steam-Profils nicht öffentlich (13.1) |
| „Ordner … nicht erreichbar“ | Netzwerkspeicher in Home Assistant fehlt oder anderer Name (13.2) |
| „Permission denied (publickey)“ | Schlüsselzeile fehlt auf dem Host (13.4) |
| „Unzulässiges Argument: --full-now“ | alte `game-disk-sync.sh`, `install-host.sh` erneut ausführen |
| „Master 2190 läuft“ | Der Master ist an. Herunterfahren, dann erneut drücken |
| Spiel bleibt „Vorgemerkt“ | Master noch nicht gelaufen. Freigabe im Master nicht eingerichtet (`share.json` fehlt)? |

**GOG** kommt später. Die Aufträge enthalten schon ein Feld `platform`, GOG-Einträge lehnt der Master bis dahin ab.

---

## 14. Updates von GitHub

Das Paket liegt öffentlich unter <https://github.com/Goeste/gaming-vm>. Statt Dateien von Hand zu verteilen,
holt jede Maschine die neueste Version mit einem Befehl. Im Repository stehen keine Passwörter oder Schlüssel.

**Proxmox-Host** (als root):
```bash
curl -fsSL https://raw.githubusercontent.com/Goeste/gaming-vm/main/host/gaming-update.sh | bash   # erstes Mal
gaming-update                                                                                         # danach
```
Das lädt das Paket nach `/opt/gaming-vm` und führt `install-host.sh` aus. Die Skripte in `/usr/local/sbin` werden
dabei überschrieben. **Eigene Einstellungen** (z. B. `SHUTDOWN_RUNNING_PLAYERS=0`) gehören deshalb in
`/etc/gaming-vm.conf`. Die Datei legt `install-host.sh` beim ersten Mal mit allen Werten auskommentiert an und lässt
sie danach in Ruhe.

**Master und jede Kinder-VM** (PowerShell als Administrator):
```powershell
irm https://raw.githubusercontent.com/Goeste/gaming-vm/main/update.ps1 | iex     # erstes Mal
C:\Scripts\gaming-update.ps1                                                    # danach
```
- Aktualisiert nur Skripte, die in der VM schon in `C:\Scripts` liegen (im Master zusätzlich `library-queue.ps1`).
- Einrichtungsskripte (`setup-*.ps1`, `init-z.ps1`) werden **nicht** ausgeführt, die Moonlight-Kopplung bleibt.
- Das ganze Paket liegt danach in `C:\GamingVM`, z. B. für eine neue Einrichtung.
- **Automatisch beim Start:** Der Befehl richtet die Aufgabe **„Gaming Update“** ein. Sie holt eine Minute nach jedem
  Start der VM still als Systemkonto die neueste Version. Ohne Internet oder bei einem Fehler bleibt die bisherige
  Version. Log: `C:\ProgramData\GamingVM\update.log`.
  Abschalten: `C:\Scripts\gaming-update.ps1 -AutoOff`, wieder an: `C:\Scripts\gaming-update.ps1 -AutoOn`.
- `C:\Scripts` und `C:\GamingVM` sind danach nur für Administratoren beschreibbar. Die Skripte dort laufen als
  Systemkonto; dürften die Kinder sie ändern, könnten sie sich damit Administratorrechte verschaffen.
- **Hinweis:** Die Automatik führt Code aus diesem GitHub-Repository mit vollen Rechten aus. Das GitHub-Konto deshalb
  mit Zwei-Faktor-Anmeldung schützen.

**Home Assistant:** Ist das Repository als App-Quelle eingetragen (13.3), zeigt Home Assistant neue Versionen der
Spielebibliothek als Update an. Wer die App vorher von Hand nach `local_apps` kopiert hat: die lokale App deinstallieren
und den Ordner `local_apps/spielebibliothek` löschen, dann aus dem Repository installieren. Die Konfiguration neu eintragen
und die **neue** SSH-Schlüsselzeile auf dem Host in `/root/.ssh/authorized_keys` eintragen (die alte Zeile löschen).
