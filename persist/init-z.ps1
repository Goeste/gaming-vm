<#
init-z.ps1  -  einmalig in JEDER VM (Master und Kinder-VMs) als admin ausfuehren

  1. Die leere Datenplatte (vom Host angelegt) als Laufwerk Z: einrichten
  2. Ordner Z:\Persist anlegen, Gruppe "Benutzer" darf schreiben
  3. ensure-z-folders.ps1 nach C:\Scripts kopieren und als Aufgabe
     "Gaming Z-Ordner" bei Systemstart und Anmeldung einrichten

Voraussetzung auf dem Proxmox-Host (bei neuen Kinder-VMs macht das create-kid-vm.sh):
  qm set <ID> --scsi2 data:64,cache=writeback,discard=on,iothread=1,ssd=1

Kann gefahrlos mehrfach ausgefuehrt werden.
#>
#Requires -RunAsAdministrator
param(
    [string]$Letter    = 'Z',
    [string]$Label     = 'Daten',
    [string]$ScriptDir = 'C:\Scripts'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Step([string]$t) { Write-Host $t -ForegroundColor Cyan }

# 1 ------------------------------------------------------------------------
Step "1/3 Laufwerk ${Letter}: einrichten..."
if (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue) {
    Write-Host "    existiert bereits"
} else {
    # Nur eine komplett leere Platte (RAW) wird angefasst - C: und D: sind nie RAW.
    $disk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Number | Select-Object -First 1
    if (-not $disk) {
        throw "Keine leere Platte gefunden. Auf dem Host zuerst anlegen: qm set <ID> --scsi2 data:64,cache=writeback,discard=on,iothread=1,ssd=1"
    }
    if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $Letter |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
    Write-Host ("    OK: Platte {0} ({1:N0} GB) ist jetzt {2}:" -f $disk.Number, ($disk.Size / 1GB), $Letter)
}

# 2 ------------------------------------------------------------------------
Step "2/3 ${Letter}:\Persist anlegen..."
$root = "${Letter}:\Persist"
New-Item -ItemType Directory -Force -Path $root | Out-Null
icacls $root /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
Write-Host "    OK: Benutzer duerfen in $root schreiben"

# 3 ------------------------------------------------------------------------
Step '3/3 Startaufgabe "Gaming Z-Ordner" einrichten...'
New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
Copy-Item -Path (Join-Path $here 'ensure-z-folders.ps1') -Destination $ScriptDir -Force
Copy-Item -Path (Join-Path $here 'redirect-to-z.ps1')    -Destination $ScriptDir -Force   # wird nur im Master benutzt
Copy-Item -Path (Join-Path $here 'scan-spielstaende.ps1') -Destination $ScriptDir -Force
$arg       = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\ensure-z-folders.ps1`" -Letter $Letter"
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$triggers  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Gaming Z-Ordner' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
Write-Host '    OK: laeuft bei jedem Start und jeder Anmeldung'

& "$ScriptDir\ensure-z-folders.ps1" -Letter $Letter
Write-Host ''
Write-Host 'Fertig.' -ForegroundColor Green
