<#
update.ps1  -  Windows (Master und Kinder-VMs), PowerShell als Administrator

Holt die neueste Version des Pakets von GitHub und aktualisiert die Skripte,
die in dieser VM schon in C:\Scripts installiert sind. Es wird nichts neu
eingerichtet und keine Einrichtung erneut ausgefuehrt (setup-kid-vm.ps1 usw. bleiben unberuehrt).
Im Master kommt zusaetzlich library-queue.ps1 dazu (Spielebibliothek).

Richtet ausserdem die Aufgabe "Gaming Update" ein: Bei jedem Start der VM holt sie
als Systemkonto still die neueste Version (Log: C:\ProgramData\GamingVM\update.log).
Ohne Internet oder bei einem Fehler bleibt die bisherige Version.

Erster Aufruf:
  irm https://raw.githubusercontent.com/Goeste/gaming-vm/main/update.ps1 | iex
Danach von Hand:
  C:\Scripts\gaming-update.ps1
Automatik aus / wieder an:
  C:\Scripts\gaming-update.ps1 -AutoOff
  C:\Scripts\gaming-update.ps1 -AutoOn

Das ganze Paket liegt danach in C:\GamingVM (fuer Einrichtungsskripte, Anleitung).
#>
# Kein param()-Block: das Skript muss auch per "irm | iex" laufen. Schalter kommen ueber $args.

$Repo      = 'Goeste/gaming-vm'
$Branch    = 'main'
$ScriptDir = 'C:\Scripts'
$PkgDir    = 'C:\GamingVM'
$StateDir  = 'C:\ProgramData\GamingVM'
$TaskName  = 'Gaming Update'
$NoAuto    = Join-Path $StateDir 'no-auto-update'
$Auto      = $args -contains '-Auto'       # Aufruf durch die geplante Aufgabe beim Start
$AutoOff   = $args -contains '-AutoOff'
$AutoOn    = $args -contains '-AutoOn'

function Say([string]$m, [string]$color = 'Gray') {
    if ($Auto) {
        try {
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            Add-Content -Path (Join-Path $StateDir 'update.log') -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
        } catch {}
    } else { Write-Host $m -ForegroundColor $color }
}

# C:\Scripts und C:\GamingVM nur fuer Administratoren/System beschreibbar: Die Skripte dort laufen als
# Systemkonto - duerften die Kinder sie aendern, koennten sie damit Administratorrechte bekommen.
function Lock-Folder([string]$dir) {
    if (-not (Test-Path $dir)) { return }
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q 2>&1 | Out-Null
}

function Register-AutoUpdate {
    $script = Join-Path $ScriptDir 'gaming-update.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Auto"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'                 # eine Minute nach dem Start, wenn das Netzwerk steht
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -StartWhenAvailable `
                 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Holt beim Start die neuesten Gaming-Skripte von GitHub (gaming-update.ps1)' -Force | Out-Null
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
         [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Say 'Bitte PowerShell als Administrator starten.' 'Red'; return }
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# ---------------- Automatik an/aus ----------------
if ($AutoOff) {
    Set-Content -Path $NoAuto -Value (Get-Date -Format s)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Say "Automatisches Update beim Start ist AUS. Wieder an: $ScriptDir\gaming-update.ps1 -AutoOn" 'Yellow'
    return
}
if ($AutoOn) { Remove-Item -Path $NoAuto -Force -ErrorAction SilentlyContinue }

# ---------------- Herunterladen ----------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP ('gaming-vm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Say "Lade $Repo ($Branch) von GitHub ..." 'Cyan'
    $zip = Join-Path $tmp 'paket.zip'
    $tries = $(if ($Auto) { 10 } else { 1 })      # beim Start ggf. auf das Netzwerk warten
    for ($i = 1; $i -le $tries; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip -TimeoutSec 120
            break
        } catch {
            if ($i -eq $tries) { throw "Download fehlgeschlagen: $($_.Exception.Message)" }
            Start-Sleep -Seconds 30
        }
    }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'master\master-update.ps1'))) { throw 'Download unvollstaendig' }
    Get-ChildItem -Path $src.FullName -Recurse -File | Unblock-File

    # Ganzes Paket nach C:\GamingVM
    if (Test-Path $PkgDir) { Remove-Item -Path $PkgDir -Recurse -Force }
    Move-Item -Path $src.FullName -Destination $PkgDir
    Lock-Folder $PkgDir

    # Installierte Skripte aktualisieren
    New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
    $isMaster = Test-Path (Join-Path $ScriptDir 'master-update.ps1')
    $skip = @('setup-master.ps1', 'setup-kid-vm.ps1', 'setup-scan-task.ps1', 'init-z.ps1')
    $updated = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-ChildItem -Path (Join-Path $PkgDir 'master'), (Join-Path $PkgDir 'persist') -Filter '*.ps1') {
        if ($skip -contains $f.Name) { continue }
        $target = Join-Path $ScriptDir $f.Name
        $wanted = (Test-Path $target) -or ($isMaster -and $f.Name -eq 'library-queue.ps1')
        if (-not $wanted) { continue }
        $same = (Test-Path $target) -and ((Get-FileHash $target).Hash -eq (Get-FileHash $f.FullName).Hash)
        if (-not $same) { Copy-Item -Path $f.FullName -Destination $target -Force; $updated.Add($f.Name) }
    }
    Copy-Item -Path (Join-Path $PkgDir 'update.ps1') -Destination (Join-Path $ScriptDir 'gaming-update.ps1') -Force
    Lock-Folder $ScriptDir

    # Automatik einrichten (ausser sie wurde abgeschaltet)
    $autoState = 'aus (einschalten: -AutoOn)'
    if (-not (Test-Path $NoAuto)) { Register-AutoUpdate; $autoState = 'an (bei jedem Start)' }

    $role = $(if ($isMaster) { 'Master' } else { 'Kinder-VM' })
    if ($updated.Count) { Say "$role - aktualisiert: $($updated -join ', ')" 'Green' }
    else { Say "$role - alle Skripte waren schon aktuell" 'Green' }
    if (-not $Auto) {
        Write-Host "  Paket: $PkgDir   Automatisches Update: $autoState" -ForegroundColor Cyan
        Write-Host "  Von Hand: $ScriptDir\gaming-update.ps1" -ForegroundColor Cyan
    }
} catch {
    Say "FEHLER: $_ - die bisherige Version bleibt." 'Red'
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
