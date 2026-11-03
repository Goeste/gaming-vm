<#
setup-scan-task.ps1  -  einmalig als admin ausfuehren, im Ordner "persist"

Kinder-VM:  .\setup-scan-task.ps1 -Share '\\NAS\gaming'
            -> taegliche Aufgabe "Gaming Spielstand-Scan" (Standard 01:30, vor dem Nachtlauf)
Master:     .\setup-scan-task.ps1 -Share '\\NAS\gaming' -Master
            -> nur Freigabe und Zugangsdaten speichern; der Nachtlauf (master-update.ps1)
               uebernimmt danach die Listen aller Kinder-VMs

-Share muss eine Netzwerkadresse sein (\\Server\Freigabe[\Unterordner]), kein Laufwerksbuchstabe:
geplante Aufgaben sehen keine verbundenen Laufwerke. Die Adresse zu S: zeigt "net use".

Die Aufgabe laeuft als SYSTEM - ein Windows-Passwort ist nicht noetig (auch nicht bei PIN-Anmeldung).
Abgefragt werden nur die Zugangsdaten der Freigabe (Benutzer/Passwort des NAS). Sie werden
rechnergebunden verschluesselt in C:\ProgramData\GamingPersist\share-cred.json gespeichert;
der Ordner ist nur fuer Administratoren und SYSTEM lesbar - die Kinder kommen nicht heran.
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $true)][string]$Share,
    [string]$Folder    = 'Spielstaende',
    [string]$At        = '01:30',
    [string]$ScriptDir = 'C:\Scripts',
    [switch]$Master
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir = 'C:\ProgramData\GamingPersist'
function Step([string]$t) { Write-Host $t -ForegroundColor Cyan }

if ($Share -notmatch '^\\\\[^\\]+\\[^\\]+') {
    throw "Bitte eine Netzwerkadresse wie \\NAS\gaming angeben, keinen Laufwerksbuchstaben. 'net use' zeigt die Adresse zu S:."
}
$Share = $Share.TrimEnd('\')

Step '1/4 Skripte nach C:\Scripts kopieren...'
New-Item -ItemType Directory -Force -Path $ScriptDir, $StateDir | Out-Null
foreach ($f in 'scan-spielstaende.ps1', 'scan-task.ps1', 'apply-redirects.ps1', 'redirect-to-z.ps1', 'ensure-z-folders.ps1') {
    Copy-Item -Path (Join-Path $here $f) -Destination $ScriptDir -Force
}
icacls $StateDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null   # nur Administratoren und SYSTEM

Step '2/4 Freigabe speichern...'
@{ Share = $Share; Folder = $Folder } | ConvertTo-Json | Set-Content -Path (Join-Path $StateDir 'share.json') -Encoding ASCII
$credFile = Join-Path $StateDir 'share-cred.json'
Remove-Item (Join-Path $StateDir 'share-cred.xml') -Force -ErrorAction SilentlyContinue   # alte Version
$cred = $null
try { $cred = Get-Credential -Message "Benutzer und Passwort der Freigabe $Share (z.B. NAS-Benutzer)" } catch { $cred = $null }
if ($cred) {
    Add-Type -AssemblyName System.Security
    $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($cred.GetNetworkCredential().Password),
           $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    @{ User = $cred.UserName; Password = [Convert]::ToBase64String($enc) } | ConvertTo-Json | Set-Content -Path $credFile -Encoding ASCII
    Write-Host '    Zugangsdaten verschluesselt gespeichert'
} else {
    if (Test-Path $credFile) { Remove-Item $credFile -Force }
    Write-Warning 'Ohne Zugangsdaten muss die Freigabe Gastzugriff erlauben - das blockiert Windows 11 meist.'
}

Step '3/4 Freigabe testen...'
$root = '\\' + (@($Share -split '\\' | Where-Object { $_ })[0..1] -join '\')
if ($cred) { $null | net use $root $cred.GetNetworkCredential().Password /user:$($cred.UserName) /persistent:no 2>&1 | Out-Null }
$target = Join-Path $Share $Folder
New-Item -ItemType Directory -Force -Path $target | Out-Null
$probe = Join-Path $target ".test-$env:COMPUTERNAME"
Set-Content -Path $probe -Value 'ok'; Remove-Item $probe -Force
if ($cred) { net use $root /delete /y 2>&1 | Out-Null }
Write-Host "    OK: $target ist beschreibbar"

if ($Master) {
    Step '4/4 Master: keine Aufgabe noetig'
    Write-Host '    Der Nachtlauf ruft apply-redirects.ps1 automatisch auf.'
    Write-Host "    Testen ohne Aenderungen:  & '$ScriptDir\apply-redirects.ps1' -WhatIf"
} else {
    Step "4/4 Aufgabe 'Gaming Spielstand-Scan' taeglich um $At einrichten..."
    $arg      = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\scan-task.ps1`""
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -Daily -At $At
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Gaming Spielstand-Scan' -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Force | Out-Null
    Write-Host "    OK. Jetzt testen: Start-ScheduledTask 'Gaming Spielstand-Scan'"
    Write-Host '    Log: C:\ProgramData\GamingPersist\scan-task.log'
}
Write-Host ''
Write-Host 'Fertig.' -ForegroundColor Green
