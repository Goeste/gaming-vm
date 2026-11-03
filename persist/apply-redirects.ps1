<#
apply-redirects.ps1  -  NUR IM MASTER; wird vom Nachtlauf (master-update.ps1) aufgerufen

Liest von der Netzwerkfreigabe die Listen der Kinder-VMs
  <Freigabe>\Spielstaende\<VM>\umleiten.txt
nacheinander ein, prueft jeden Eintrag streng und richtet die Umleitung mit
redirect-to-z.ps1 ein. Von der Freigabe wird KEIN Code ausgefuehrt - nur Ordnerpfade
gelesen, die alle Pruefungen bestehen:
  - liegt auf D:, kein "..", nicht D:\_persist
  - der Ordnername ist ein bekannter Spielstand-/Mod-/Einstellungsordner
  - der uebergeordnete Ordner existiert im Master (das Spiel ist hier installiert)

Von Hand testen (Steam geschlossen):  & C:\Scripts\apply-redirects.ps1 -WhatIf
Log: C:\ProgramData\GamingPersist\apply.log  (Zusammenfassung auch auf der Freigabe: _master.log)
#>
#Requires -RunAsAdministrator
param(
    [string]$ConfigFile = 'C:\ProgramData\GamingPersist\share.json',
    [switch]$WhatIf
)

$StateDir = 'C:\ProgramData\GamingPersist'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile = Join-Path $StateDir 'apply.log'
$summary = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $LogFile -Value $line; $summary.Add($line); Write-Host $m
}

$AllowedNames = @('saved','saves','save','savegames','savegame','savedata','savedgames','saveddata','profiles','profile',
                  'userdata','mods','mod','config','configs','settings','cfg','userconfig')

function Test-SafePath([string]$p) {
    if ($p -notmatch '^[Dd]:\\[^<>:"|?*/]+$')  { return 'kein gueltiger Pfad auf D:' }
    if ($p -match '\\\.\.(\\|$)')            { return 'enthaelt ".."' }
    if ($p -match '^[Dd]:\\_persist')         { return 'interner Ordner' }
    $parts = @($p.Substring(3) -split '\\' | Where-Object { $_ })
    if ($parts.Count -lt 3)                   { return 'zu nah am Laufwerk' }
    if ($AllowedNames -notcontains $parts[-1].ToLowerInvariant()) { return "Ordnername '$($parts[-1])' ist nicht freigegeben" }
    if (-not (Test-Path -LiteralPath (Split-Path $p -Parent))) { return 'Spiel im Master nicht vorhanden' }
    return $null
}

function Get-ShareRoot([string]$share) {
    $x = @($share -split '\\' | Where-Object { $_ })
    return "\\$($x[0])\$($x[1])"
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

if (-not (Test-Path $ConfigFile)) { Write-Host "$ConfigFile fehlt - setup-scan-task.ps1 -Master ausfuehren"; exit 1 }
$cfg      = Get-Content -Raw $ConfigFile | ConvertFrom-Json
$credFile = Join-Path $StateDir 'share-cred.json'
$redirect = Join-Path $PSScriptRoot 'redirect-to-z.ps1'
if (-not (Test-Path $redirect)) { Write-Host "$redirect fehlt"; exit 1 }

Write-Log '=== Umleitungs-Vorschlaege uebernehmen ==='
if (-not (Connect-Share $cfg.Share $credFile)) { Write-Log "FEHLER: Freigabe $($cfg.Share) nicht erreichbar"; exit 1 }
$base = Join-Path $cfg.Share $cfg.Folder

try {
    $done = @{}
    foreach ($vm in Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
        $list = Join-Path $vm.FullName 'umleiten.txt'
        if (-not (Test-Path $list)) { continue }
        $entries = @(Get-Content $list | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        Write-Log "$($vm.Name): $($entries.Count) Eintrag/Eintraege"
        foreach ($p in $entries) {
            $key = $p.ToLowerInvariant()
            if ($done.ContainsKey($key)) { continue }
            $done[$key] = 1
            $why = Test-SafePath $p
            if ($why) { Write-Log "  abgelehnt ($why): $p"; continue }
            if ($WhatIf) { Write-Log "  wuerde umleiten: $p"; continue }
            try   { & $redirect -Path $p *>&1 | ForEach-Object { Write-Log "  $_" } }
            catch { Write-Log "  FEHLER bei $p : $_" }
        }
    }
    if (-not $WhatIf) {
        try   { & $redirect -Repair *>&1 | ForEach-Object { Write-Log "  $_" } }
        catch { Write-Log "  FEHLER bei der Reparatur: $_" }
    }
    try { [IO.File]::WriteAllLines((Join-Path $base '_master.log'), [string[]]$summary) } catch {}
} finally {
    if (Test-Path $credFile) { net use (Get-ShareRoot $cfg.Share) /delete /y 2>&1 | Out-Null }
}
exit 0
