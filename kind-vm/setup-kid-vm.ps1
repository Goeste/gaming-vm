<#
setup-kid-vm.ps1  -  einmalig in jeder NEUEN Kinder-VM als admin ausfuehren
(PowerShell "Als Administrator ausfuehren")

  1. Sunshine-Identitaet zuruecksetzen (sonst haelt Moonlight die VM fuer den Master)
  2. Nachtupdate-Aufgabe des Masters entfernen, falls mitgeklont
  3. Kinderkonto als Standardbenutzer anlegen (fragt nach dem Passwort)
  4. Optional: neues Passwort fuer den admin
  5. vGPU-Lizenzaufgabe pruefen / reparieren / bei eigener GPU abschalten
  6. Pruefen, ob D:\SteamLibrary da ist
  7. Computer umbenennen (danach Neustart)

Beispiele:
  .\setup-kid-vm.ps1 -ComputerName EMMA -KidUser emma -FixLicenseTask
  .\setup-kid-vm.ps1 -ComputerName KIND-GPU -KidUser max -DedicatedGpu
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $true)][string]$ComputerName,
    [Parameter(Mandatory = $true)][string]$KidUser,
    [string]$KidFullName = '',
    [switch]$SetAdminPassword,   # neues Passwort fuer das ausfuehrende Admin-Konto setzen
    [switch]$FixLicenseTask,     # pull_license-Aufgabe auf SYSTEM + "beim Systemstart" umstellen
    [switch]$DedicatedGpu        # VM hat eine eigene GPU: pull_license-Aufgabe deaktivieren
)
$ErrorActionPreference = 'Stop'
if (-not $KidFullName) { $KidFullName = $KidUser }
function Step([string]$t) { Write-Host $t -ForegroundColor Cyan }

# 1 ------------------------------------------------------------------------
Step '1/7 Sunshine-Identitaet zuruecksetzen...'
$cfg = Join-Path $env:ProgramFiles 'Sunshine\config'
if (Test-Path $cfg) {
    $svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
    if (-not $svc) { $svc = Get-Service | Where-Object { $_.Name -like '*sunshine*' } | Select-Object -First 1 }
    if ($svc) { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    Remove-Item (Join-Path $cfg 'sunshine_state.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $cfg 'credentials\*') -Force -ErrorAction SilentlyContinue
    $conf = Join-Path $cfg 'sunshine.conf'
    if (Test-Path $conf) {
        $lines = Get-Content $conf | Where-Object { $_ -notmatch '^\s*sunshine_name\s*=' }
        [IO.File]::WriteAllLines($conf, [string[]]$lines)   # UTF-8 ohne BOM
    }
    if ($svc) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
    Write-Host '    OK: neue Identitaet wird erzeugt, Web-Login muss neu angelegt werden'
} else {
    Write-Warning "Sunshine-Konfiguration nicht gefunden ($cfg)"
}

# 2 ------------------------------------------------------------------------
Step '2/7 Nachtupdate-Aufgabe des Masters entfernen (falls vorhanden)...'
$master = Get-ScheduledTask | Where-Object { ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'master-update\.ps1' }
foreach ($t in $master) {
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
    Write-Host "    entfernt: $($t.TaskPath)$($t.TaskName)"
}
if (-not $master) { Write-Host '    OK: keine vorhanden' }

# 3 ------------------------------------------------------------------------
Step "3/7 Kinderkonto '$KidUser' anlegen..."
if (Get-LocalUser -Name $KidUser -ErrorAction SilentlyContinue) {
    Write-Host '    existiert bereits'
} else {
    $pw = Read-Host -AsSecureString "Passwort fuer $KidUser"
    New-LocalUser -Name $KidUser -FullName $KidFullName -Password $pw -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $KidUser -ErrorAction SilentlyContinue
    Write-Host '    OK: Standardbenutzer angelegt'
}
$admins = Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.Name -like "*\$KidUser" }
if ($admins) { Write-Warning "$KidUser ist Administrator! Bitte aus der Gruppe Administratoren entfernen." }

# 4 ------------------------------------------------------------------------
Step '4/7 Admin-Passwort...'
if ($SetAdminPassword) {
    $apw = Read-Host -AsSecureString "Neues Passwort fuer $env:USERNAME"
    Set-LocalUser -Name $env:USERNAME -Password $apw
    Write-Host '    OK: geaendert'
} else {
    Write-Host '    uebersprungen (Parameter -SetAdminPassword)'
}

# 5 ------------------------------------------------------------------------
Step '5/7 vGPU-Lizenzaufgabe...'
$lic = Get-ScheduledTask | Where-Object { ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match 'pull_license' }
if (-not $lic) {
    Write-Warning 'Keine Aufgabe mit pull_license gefunden.'
}
foreach ($t in $lic) {
    $name = "$($t.TaskPath)$($t.TaskName)"
    if ($DedicatedGpu) {
        Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null
        Write-Host "    deaktiviert (eigene GPU): $name"
    } elseif ($FixLicenseTask) {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtStartup) | Out-Null
        Write-Host "    OK: $name laeuft jetzt als SYSTEM beim Systemstart"
    } else {
        $trig = ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace 'MSFT_Task','' -replace 'Trigger','' }) -join ','
        Write-Host "    $name : Benutzer=$($t.Principal.UserId), Ausloeser=$trig"
        if ($trig -notmatch 'Boot' -or $t.Principal.UserId -notmatch 'SYSTEM') {
            Write-Warning 'Sollte als SYSTEM beim Systemstart laufen -> Skript mit -FixLicenseTask erneut starten.'
        }
    }
}

# 6 ------------------------------------------------------------------------
Step '6/7 Spieleplatte D: pruefen...'
if (Test-Path 'D:\SteamLibrary\steamapps') {
    $n = (Get-ChildItem 'D:\SteamLibrary\steamapps' -Filter 'appmanifest_*.acf').Count
    Write-Host "    OK: D:\SteamLibrary mit $n Spielen"
} else {
    Write-Warning 'D:\SteamLibrary nicht gefunden. Datentraegerverwaltung oeffnen und der 512-GB-Platte den Buchstaben D: geben.'
}

# 7 ------------------------------------------------------------------------
Step "7/7 Computername '$ComputerName'..."
if ($env:COMPUTERNAME -ieq $ComputerName) {
    Write-Host '    bereits gesetzt'
    Write-Host ''
    Write-Host 'Fertig.' -ForegroundColor Green
} else {
    Rename-Computer -NewName $ComputerName -Force
    Write-Host ''
    Write-Host 'Fertig. Bitte jetzt neu starten: Restart-Computer' -ForegroundColor Green
}
Write-Host 'Weiter mit ANLEITUNG.md, Abschnitt 6 (Sunshine, Moonlight, libvirtualhid, Kinderkonto).'
