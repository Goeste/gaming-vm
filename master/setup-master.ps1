<#
setup-master.ps1  -  einmalig im MASTER (VM 2190) als admin ausfuehren
(PowerShell "Als Administrator ausfuehren", im entpackten Ordner "master")

  1. Schnellstart/Ruhezustand aus (D: wird beim Herunterfahren sauber geschlossen)
  2. Schreibrechte fuer die Gruppe "Benutzer" auf D:\SteamLibrary
  3. master-update.ps1 und library-queue.ps1 nach C:\Scripts kopieren
  4. Geplante Aufgabe "Gaming Nachtupdate" anlegen (bei Anmeldung dieses Benutzers)

Danach von Hand: Autologon fuer diesen Benutzer, Steam-Einstellungen (siehe ANLEITUNG.md).
#>
#Requires -RunAsAdministrator
param(
    [string]$Library   = 'D:\SteamLibrary',
    [string]$ScriptDir = 'C:\Scripts',
    [string]$TaskName  = 'Gaming Nachtupdate'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$user = "$env:USERDOMAIN\$env:USERNAME"

Write-Host '1/4 Schnellstart und Ruhezustand abschalten, Herunterfahren erzwingen...' -ForegroundColor Cyan
powercfg /h off
# Ohne diese Einstellung wartet Windows beim Herunterfahren auf einen Klick, wenn ein Programm blockiert
# ("Diese App verhindert das Herunterfahren") - nachts klickt niemand.
$desk = 'HKCU:\Control Panel\Desktop'
Set-ItemProperty -Path $desk -Name AutoEndTasks         -Value '1'    -Type String
Set-ItemProperty -Path $desk -Name WaitToKillAppTimeout -Value '5000' -Type String
Set-ItemProperty -Path $desk -Name HungAppTimeout       -Value '5000' -Type String

Write-Host '2/4 Schreibrechte fuer "Benutzer" auf der Steam-Bibliothek...' -ForegroundColor Cyan
if (Test-Path $Library) {
    # Nur am obersten Ordner setzen - Windows vererbt das Recht an alle Unterordner und Dateien.
    # (Frueher mit /T: ging jede Datei einzeln durch und dauerte bei grossen Bibliotheken sehr lange.)
    $has = $false
    foreach ($r in (Get-Acl -Path $Library).Access) {
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($sid -eq 'S-1-5-32-545' -and $r.AccessControlType -eq 'Allow' -and
            ($r.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify -and
            ($r.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit)) { $has = $true }
    }
    if ($has) {
        Write-Host "    OK: Recht ist schon gesetzt ($Library)"
    } else {
        icacls $Library /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q | Out-Null
        Write-Host "    OK: $Library (wird an alle Unterordner vererbt)"
    }
} else {
    Write-Warning "$Library nicht gefunden - Schritt uebersprungen."
}

Write-Host "3/4 master-update.ps1 und library-queue.ps1 nach $ScriptDir kopieren..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
Copy-Item -Path (Join-Path $here 'master-update.ps1') -Destination $ScriptDir -Force
if (Test-Path (Join-Path $here 'library-queue.ps1')) { Copy-Item -Path (Join-Path $here 'library-queue.ps1') -Destination $ScriptDir -Force }

Write-Host "4/4 Geplante Aufgabe '$TaskName' anlegen..." -ForegroundColor Cyan
$arg       = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\master-update.ps1`" -MasterName $env:COMPUTERNAME"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "    OK: laeuft bei Anmeldung von $user, aktiv nur 01:00-06:00, nur auf $env:COMPUTERNAME"

Write-Host ''
Write-Host 'Noch von Hand erledigen:' -ForegroundColor Yellow
Write-Host "  - Autologon fuer $user einrichten (Sysinternals Autologon)"
Write-Host '  - Steam: mit dem Konto anmelden, dem die Spiele gehoeren, "Angemeldet bleiben"'
Write-Host '  - Steam > Einstellungen > Downloads: keine Zeitbeschraenkung fuer Auto-Updates'
Write-Host '  - Alte Update-Aufgaben (PSWindowsUpdate/SteamCMD) loeschen, pull_license bleibt'
Write-Host ''
Write-Host 'Testlauf ohne Herunterfahren:' -ForegroundColor Yellow
Write-Host "  & '$ScriptDir\master-update.ps1' -Force -NoShutdown"
Write-Host '  Protokoll: C:\ProgramData\GamingMaster\master-update.log'
