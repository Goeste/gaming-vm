<#
update.ps1  -  Windows (Master und Kinder-VMs), PowerShell als Administrator

Holt die neueste Version des Pakets von GitHub und aktualisiert die Skripte,
die in dieser VM schon in C:\Scripts installiert sind. Es wird nichts neu
eingerichtet und keine Einrichtung erneut ausgefuehrt (setup-kid-vm.ps1 usw. bleiben unberuehrt).
Im Master kommt zusaetzlich library-queue.ps1 dazu (Spielebibliothek).

Erster Aufruf:
  irm https://raw.githubusercontent.com/Goeste/gaming-vm/main/update.ps1 | iex
Danach einfach:
  C:\Scripts\gaming-update.ps1

Das ganze Paket liegt danach in C:\GamingVM (fuer Einrichtungsskripte, Anleitung).
#>

$ErrorActionPreference = 'Stop'
$Repo      = 'Goeste/gaming-vm'
$Branch    = 'main'
$ScriptDir = 'C:\Scripts'
$PkgDir    = 'C:\GamingVM'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
         [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Bitte PowerShell als Administrator starten.' -ForegroundColor Red; return }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP ('gaming-vm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Write-Host "Lade $Repo ($Branch) von GitHub ..." -ForegroundColor Cyan
    $zip = Join-Path $tmp 'paket.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'master\master-update.ps1'))) { throw 'Download unvollstaendig' }
    Get-ChildItem -Path $src.FullName -Recurse -File | Unblock-File

    # Ganzes Paket nach C:\GamingVM
    if (Test-Path $PkgDir) { Remove-Item -Path $PkgDir -Recurse -Force }
    Move-Item -Path $src.FullName -Destination $PkgDir
    Write-Host "Paket liegt in $PkgDir"

    # Installierte Skripte aktualisieren
    New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
    $isMaster = Test-Path (Join-Path $ScriptDir 'master-update.ps1')
    $skip = @('setup-master.ps1', 'setup-kid-vm.ps1', 'setup-scan-task.ps1', 'init-z.ps1')
    $updated = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-ChildItem -Path (Join-Path $PkgDir 'master'), (Join-Path $PkgDir 'persist') -Filter '*.ps1') {
        if ($skip -contains $f.Name) { continue }
        $target = Join-Path $ScriptDir $f.Name
        $wanted = (Test-Path $target) -or ($isMaster -and $f.Name -eq 'library-queue.ps1')
        if ($wanted) { Copy-Item -Path $f.FullName -Destination $target -Force; $updated.Add($f.Name) }
    }
    Copy-Item -Path (Join-Path $PkgDir 'update.ps1') -Destination (Join-Path $ScriptDir 'gaming-update.ps1') -Force

    Write-Host ''
    Write-Host ("Rolle: " + $(if ($isMaster) { 'Master' } else { 'Kinder-VM' })) -ForegroundColor Cyan
    if ($updated.Count) { $updated | ForEach-Object { Write-Host "  aktualisiert: $ScriptDir\$_" } }
    else { Write-Host '  In C:\Scripts war noch nichts installiert - zuerst die Einrichtung laut Anleitung.' -ForegroundColor Yellow }
    Write-Host "  Naechstes Mal: $ScriptDir\gaming-update.ps1" -ForegroundColor Green
} catch {
    Write-Host "FEHLER: $_" -ForegroundColor Red
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
