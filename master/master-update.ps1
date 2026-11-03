<#
master-update.ps1  -  laeuft NUR im Master (VM 2190)

Startet Steam, wartet bis alle Spiele auf D: aktuell sind, beendet Steam sauber
und faehrt Windows herunter. Danach erstellt gaming-nightly.sh auf dem
Proxmox-Host den Snapshot und verteilt D: an die Kinder-VMs.

Wird per Aufgabenplanung bei der Anmeldung von "admin" gestartet (Autologon),
arbeitet aber nur im Nachtfenster - oder tagsueber, wenn in der Spielebibliothek
(Home Assistant) "Jetzt installieren und verteilen" gedrueckt wurde. Tagsueber passiert nichts, du kannst also
normal im Master arbeiten und Spiele installieren.

Log:     C:\ProgramData\GamingMaster\master-update.log
Pause:   Datei C:\ProgramData\GamingMaster\SKIP anlegen -> Skript tut nichts
Testen:  .\master-update.ps1 -Force -NoShutdown
#>
param(
    [string]$MasterName  = '',                # Computername des Masters (Schutz vor Ausfuehrung in Klonen)
    [string]$Library     = 'D:\SteamLibrary',
    [string]$WindowStart = '01:00',           # Nachtfenster, in dem das Skript aktiv wird
    [string]$WindowEnd   = '06:00',
    [int]$LoginWaitMin   = 10,                # max. Wartezeit auf die Steam-Anmeldung
    [int]$CheckWaitMin   = 5,                 # Zeit fuer Steam, nach Updates zu suchen
    [int]$StableMin      = 10,                # so lange muss alles aktuell bleiben
    [int]$TimeoutMin     = 180,               # max. Dauer der Downloads
    [switch]$Force,                           # Zeitfenster ignorieren
    [switch]$NoShutdown,                      # am Ende nicht herunterfahren
    [switch]$KeepUpdateSettings               # Update-Prioritaet der Spiele NICHT auf "Hoch" setzen
)

$ErrorActionPreference = 'Continue'
$StateDir = 'C:\ProgramData\GamingMaster'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile = Join-Path $StateDir 'master-update.log'

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# Startet ein Hilfsskript als eigenen Prozess mit Zeitlimit. Haengt es (z.B. an einer
# Netzwerkfreigabe), wird es beendet - der Master faehrt danach trotzdem herunter.
function Invoke-Step([string]$script, [string]$arguments, [int]$minutes) {
    $tag = ($arguments -replace '[^A-Za-z]', '')
    $out = Join-Path $StateDir ('step-' + [IO.Path]::GetFileNameWithoutExtension($script) + $(if ($tag) { "-$tag" } else { '' }) + '.log')
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
         -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" $arguments" `
         -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle      # sonst liefert ExitCode spaeter nichts
    if (-not $p.WaitForExit($minutes * 60 * 1000)) {
        Write-Log "WARNUNG: $([IO.Path]::GetFileName($script)) nach $minutes min abgebrochen (haengt)"
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        $p.WaitForExit(10000) | Out-Null
    }
    foreach ($f in $out, "$out.err") {
        if (Test-Path $f) { Get-Content $f | Where-Object { $_ } | ForEach-Object { Write-Log "  $_" } }
    }
    if ($p.HasExited) { return $p.ExitCode } else { return -1 }
}

$Library2  = Join-Path $PSScriptRoot 'library-queue.ps1'
$HasLibrary = (Test-Path $Library2) -and (Test-Path 'C:\ProgramData\GamingPersist\share.json')

# ---------------- Schutz: nur im Master, nur nachts ----------------
if ($MasterName -and ($env:COMPUTERNAME -ne $MasterName)) {
    Write-Log "Nicht der Master ($env:COMPUTERNAME statt $MasterName) - nichts zu tun."
    exit 0
}
if (Test-Path (Join-Path $StateDir 'SKIP')) {
    Write-Log 'SKIP-Datei vorhanden - kein Update, kein Shutdown.'
    exit 0
}
$now   = (Get-Date).TimeOfDay
$start = [TimeSpan]::Parse($WindowStart)
$end   = [TimeSpan]::Parse($WindowEnd)
if ($start -le $end) { $inWindow = ($now -ge $start) -and ($now -lt $end) }
else                 { $inWindow = ($now -ge $start) -or  ($now -lt $end) }
# Tagsueber: Knopf "Jetzt installieren und verteilen" in der Spielebibliothek gedrueckt?
if (-not $inWindow -and -not $Force -and $HasLibrary) {
    if ((Invoke-Step $Library2 '-CheckNow' 3) -eq 0) {
        Write-Log 'Sofort-Lauf aus der Spielebibliothek - arbeite wie im Nachtfenster.'
        $Force = $true
    }
}
if (-not $inWindow -and -not $Force) {
    Write-Log "Ausserhalb des Nachtfensters ($WindowStart-$WindowEnd) - kein Update, kein Shutdown."
    exit 0
}

# ---------------- Hilfsfunktionen ----------------
function Get-SteamExe {
    $candidates = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p -and $p.SteamExe)    { $candidates += $p.SteamExe }
        if ($p -and $p.InstallPath) { $candidates += (Join-Path $p.InstallPath 'steam.exe') }
    }
    $candidates += 'C:\Program Files (x86)\Steam\steam.exe'
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Get-SteamActiveUser {
    $v = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -ErrorAction SilentlyContinue).ActiveUser
    if ($v) { return [int64]$v } else { return 0 }
}

$SteamApps = Join-Path $Library 'steamapps'

# Liefert alle Spiele auf D:, die nicht vollstaendig aktuell sind (StateFlags 4 = fertig installiert)
function Get-PendingGames {
    $pending = @()
    foreach ($f in Get-ChildItem -Path $SteamApps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
        $txt = Get-Content -Raw -Path $f.FullName -ErrorAction SilentlyContinue
        if (-not $txt) { continue }
        $flags = -1
        if ($txt -match '"StateFlags"\s+"(\d+)"') { $flags = [int]$Matches[1] }
        $name = $f.BaseName
        if ($txt -match '"name"\s+"([^"]+)"') { $name = $Matches[1] }
        if ($flags -ne 4) { $pending += "$name ($flags)" }
    }
    return ,$pending
}

# Setzt alle Spiele auf D: auf "Hohe Prioritaet" (AutoUpdateBehavior 2) und hebt
# geplante Update-Termine auf (ScheduledAutoUpdate 0). Damit laedt Steam sofort,
# statt auf einen spaeteren Update-Tag zu warten. Steam muss dafuer beendet sein,
# es liest die Manifeste beim Start.
function Set-UpdatesHighPriority {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $insert = '$1$2$3$1$2"AutoUpdateBehavior"' + "`t`t" + '"2"'
    $changed = 0
    foreach ($f in Get-ChildItem -Path $SteamApps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
        $txt = [IO.File]::ReadAllText($f.FullName)
        $new = $txt
        if ($new -match '"AutoUpdateBehavior"\s+"\d+"') {
            $new = $new -replace '("AutoUpdateBehavior"\s+)"\d+"', '$1"2"'
        } else {
            $new = $new -replace '(\r?\n)([ \t]*)("StateFlags"[ \t]+"\d+")', $insert
        }
        $new = $new -replace '("ScheduledAutoUpdate"\s+)"\d+"', '$1"0"'
        if ($new -ne $txt) {
            [IO.File]::WriteAllText($f.FullName, $new, $utf8)
            $changed++
        }
    }
    return $changed
}

function Stop-SteamGracefully([string]$SteamExe) {
    if (-not (Get-Process -Name steam -ErrorAction SilentlyContinue)) { return }
    Start-Process -FilePath $SteamExe -ArgumentList '-shutdown'
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Process -Name steam -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Seconds 5 }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Write-Log 'Steam reagiert nicht - wird hart beendet.'
        Stop-Process -Name steam -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

# ---------------- Ablauf ----------------
Write-Log '=== Nachtupdate gestartet ==='
if (-not (Test-Path $SteamApps)) { Write-Log "WARNUNG: $SteamApps nicht gefunden." }

$steam = Get-SteamExe
$steamLoggedIn = $false
if (-not $steam) {
    Write-Log 'FEHLER: steam.exe nicht gefunden - keine Spiele-Updates.'
} else {
    # Steam laeuft evtl. schon per Autostart -> erst beenden, damit die Manifeste geaendert werden koennen
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Write-Log 'Steam laeuft bereits - wird fuer die Prioritaetsaenderung kurz beendet.'
        Stop-SteamGracefully $steam
    }
    # Auftraege der Spielebibliothek: neue Spiele einplanen / entfernen (Steam ist jetzt beendet)
    if ($HasLibrary) {
        Write-Log 'Spielebibliothek: Auftraege ausfuehren ...'
        Invoke-Step $Library2 '-Apply' 30 | Out-Null
    }
    if (-not $KeepUpdateSettings) {
        $n = Set-UpdatesHighPriority
        Write-Log "Update-Prioritaet 'Hoch' bei $n Spielen gesetzt, geplante Update-Termine aufgehoben."
    }
    Write-Log "Starte Steam: $steam"
    Start-Process -FilePath $steam -ArgumentList '-silent'

    $deadline = (Get-Date).AddMinutes($LoginWaitMin)
    while (((Get-SteamActiveUser) -eq 0) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Seconds 15 }

    if ((Get-SteamActiveUser) -eq 0) {
        Write-Log 'FEHLER: Steam ist nicht angemeldet - keine Spiele-Updates moeglich.'
    } else {
        $steamLoggedIn = $true
        Write-Log "Steam angemeldet. Warte $CheckWaitMin min, bis Steam nach Updates gesucht hat."
        Start-Sleep -Seconds ($CheckWaitMin * 60)

        $deadline    = (Get-Date).AddMinutes($TimeoutMin)
        $stableSince = $null
        $lastReport  = ''
        $done        = $false
        while ((Get-Date) -lt $deadline) {
            $pending = Get-PendingGames
            if ($pending.Count -eq 0) {
                if (-not $stableSince) {
                    $stableSince = Get-Date
                    Write-Log "Alle Spiele aktuell - pruefe noch $StableMin min."
                } elseif (((Get-Date) - $stableSince).TotalMinutes -ge $StableMin) {
                    Write-Log 'Alle Spiele sind aktuell.'
                    $done = $true
                    break
                }
            } else {
                $stableSince = $null
                $report = $pending -join ', '
                if ($report -ne $lastReport) { Write-Log "Laeuft noch: $report"; $lastReport = $report }
            }
            Start-Sleep -Seconds 30
        }
        if (-not $done) {
            Write-Log "WARNUNG: Zeitlimit von $TimeoutMin min erreicht. Nicht fertig: $((Get-PendingGames) -join ', ')"
        }
    }

    Write-Log 'Beende Steam sauber...'
    Stop-SteamGracefully $steam
}

# Spielebibliothek: installierte Spiele und Ergebnisse melden
if ($HasLibrary) {
    $exportArgs = '-Export'
    if ($steamLoggedIn) { $exportArgs = '-Export -CheckStubs' }
    Invoke-Step $Library2 $exportArgs 5 | Out-Null
}

# Vorschlaege der Kinder-VMs uebernehmen (apply-redirects.ps1, Anleitung 6.9) - prueft und repariert danach auch alle Umleitungen.
# Ohne Netzwerkfreigabe nur die Umleitungen pruefen (ein Spiele-Update kann einen umgeleiteten Ordner neu anlegen).
$apply = Join-Path $PSScriptRoot 'apply-redirects.ps1'
$redir = Join-Path $PSScriptRoot 'redirect-to-z.ps1'
if ((Test-Path $apply) -and (Test-Path 'C:\ProgramData\GamingPersist\share.json')) {
    Write-Log 'Uebernehme Umleitungs-Vorschlaege der Kinder-VMs ...'
    Invoke-Step $apply '' 15 | Out-Null
} elseif ((Test-Path $redir) -and (Test-Path 'D:\_persist\map.txt')) {
    Write-Log 'Pruefe Umleitungen nach Z: ...'
    Invoke-Step $redir '-Repair' 15 | Out-Null
}

if ($NoShutdown) {
    Write-Log 'NoShutdown gesetzt - Master bleibt an.'
    exit 0
}
Write-Log 'Fahre den Master herunter.'
& shutdown.exe /s /t 10 /f /d p:0:0 /c "Nachtupdate fertig"
