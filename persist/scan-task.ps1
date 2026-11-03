<#
scan-task.ps1  -  laeuft taeglich in jeder Kinder-VM (Aufgabe "Gaming Spielstand-Scan")

1. Scannt alle Spiele (scan-spielstaende.ps1 -Rescue): heutige Daten der sicheren
   Faelle werden schon nach Z: kopiert
2. Verbindet die Netzwerkfreigabe und legt das Ergebnis ab unter
   <Freigabe>\Spielstaende\<Computername>\
   umleiten.txt wird mit der bisherigen Liste zusammengefuehrt (nichts geht verloren)

Einrichtung: setup-scan-task.ps1
Log: C:\ProgramData\GamingPersist\scan-task.log
#>
param([string]$ConfigFile = 'C:\ProgramData\GamingPersist\share.json')

$StateDir = 'C:\ProgramData\GamingPersist'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile = Join-Path $StateDir 'scan-task.log'
function Write-Log([string]$m) { Add-Content -Path $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

function Get-ShareRoot([string]$share) {
    $p = @($share -split '\\' | Where-Object { $_ })
    return "\\$($p[0])\$($p[1])"
}
function Get-ShareCred([string]$credFile) {
    # Zugangsdaten sind rechnergebunden verschluesselt (lesbar fuer Administratoren und SYSTEM dieser VM)
    if (-not (Test-Path $credFile)) { return $null }
    Add-Type -AssemblyName System.Security
    $j = Get-Content -Raw $credFile | ConvertFrom-Json
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($j.Password), $null,
             [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [pscustomobject]@{ User = $j.User; Password = [Text.Encoding]::UTF8.GetString($bytes) }
}
function Connect-Share([string]$share, [string]$credFile) {
    if (Test-Path $share) { return $true }
    $root = Get-ShareRoot $share
    $c = Get-ShareCred $credFile
    if (-not $c) { return $false }       # ohne Zugangsdaten kein "net use" - es wuerde unsichtbar nach einem Passwort fragen und haengen
    # $null als Eingabe: net use kann nie auf eine Eingabe warten
    $null | net use $root $c.Password /user:$($c.User) /persistent:no 2>&1 | Out-Null
    return (Test-Path $share)
}

Write-Log '=== Scan gestartet ==='
if (-not (Test-Path $ConfigFile)) { Write-Log "FEHLER: $ConfigFile fehlt - setup-scan-task.ps1 ausfuehren"; exit 1 }
$cfg      = Get-Content -Raw $ConfigFile | ConvertFrom-Json
$credFile = Join-Path $StateDir 'share-cred.json'
$local    = Join-Path $StateDir 'scan'
New-Item -ItemType Directory -Force -Path $local | Out-Null

# 1. Scannen (lokal)
try {
    & (Join-Path $PSScriptRoot 'scan-spielstaende.ps1') -OutDir $local -Rescue *>&1 | Out-Null
    Write-Log 'Scan fertig'
} catch {
    Write-Log "FEHLER beim Scan: $_"; exit 1
}

# 2. Auf die Freigabe kopieren
if (-not (Connect-Share $cfg.Share $credFile)) { Write-Log "FEHLER: Freigabe $($cfg.Share) nicht erreichbar"; exit 1 }
$dest = Join-Path (Join-Path $cfg.Share $cfg.Folder) $env:COMPUTERNAME
try {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $old = @()
    $destList = Join-Path $dest 'umleiten.txt'
    if (Test-Path $destList) { $old = @(Get-Content $destList | Where-Object { $_ }) }
    $new = @(Get-Content (Join-Path $local 'umleiten.txt') | Where-Object { $_ })
    $merged = @($old + $new | Sort-Object -Unique)
    foreach ($f in 'spielstaende-bericht.txt', 'spielstaende.csv', 'umleiten-vorschlaege.ps1') {
        Copy-Item -Path (Join-Path $local $f) -Destination $dest -Force
    }
    [IO.File]::WriteAllLines($destList, [string[]]$merged)
    Write-Log "Ergebnis nach $dest geschrieben ($($new.Count) neu, $($merged.Count) insgesamt)"
} catch {
    Write-Log "FEHLER beim Schreiben auf die Freigabe: $_"; exit 1
} finally {
    if (Test-Path $credFile) { net use (Get-ShareRoot $cfg.Share) /delete /y 2>&1 | Out-Null }
}
exit 0
