<#
library-queue.ps1  -  NUR IM MASTER; wird von master-update.ps1 aufgerufen

Verbindung zur Spielebibliothek (Home-Assistant-App). Auf der Netzwerkfreigabe liegt
  <Freigabe>\Bibliothek\auftrag.json   geschrieben von Home Assistant (Installieren/Entfernen, Sofort-Knopf)
  <Freigabe>\Bibliothek\status.json    geschrieben vom Master (installierte Spiele, freier Platz, Ergebnisse)

Von der Freigabe wird KEIN Code ausgefuehrt. Aus auftrag.json werden nur App-IDs und
Spielnamen gelesen und streng geprueft. Installieren = Steam-Manifest anlegen, damit Steam
das Spiel beim naechsten Start herunterlaedt. Entfernen = Manifest und Spielordner loeschen
(nur unter D:\SteamLibrary\steamapps\common, Umleitungen nach Z: bleiben unangetastet).

  -CheckNow   Exit 0, wenn der Knopf "Jetzt installieren und verteilen" gedrueckt wurde
              (Anforderung juenger als 3 Stunden und noch nicht erledigt), sonst Exit 3
  -Apply      Auftraege ausfuehren (Steam muss beendet sein)
  -Export     Liste der installierten Spiele + Ergebnisse nach status.json schreiben
  -WhatIf     mit -Apply: nur anzeigen
  -CheckStubs mit -Export (nur wenn Steam angemeldet war): von hier eingeplante Spiele, deren
              Download nicht einmal begonnen hat (keine Lizenz fuer dieses Konto, nicht fuer die
              Familie freigegeben), wieder austragen - sonst wartet jede Nacht auf sie

Einrichtung: setup-scan-task.ps1 -Master (Freigabe + Zugangsdaten), siehe Anleitung 13.
Log: C:\ProgramData\GamingMaster\library.log
#>
param(
    [switch]$CheckNow,
    [switch]$Apply,
    [switch]$Export,
    [switch]$WhatIf,
    [switch]$CheckStubs,                    # mit -Export: Steam war angemeldet -> nie gestartete Downloads aufraeumen
    [string]$Library     = 'D:\SteamLibrary',
    [string]$ConfigFile  = 'C:\ProgramData\GamingPersist\share.json',
    [string]$SubFolder   = 'Bibliothek',
    [string]$BibDir      = '',              # nur zum Testen: Ordner direkt angeben (ohne Freigabe)
    [string]$StateDir    = 'C:\ProgramData\GamingMaster',
    [int]$MaxRemove      = 10,              # Schutz: hoechstens so viele Spiele pro Lauf entfernen
    [int]$NowValidHours  = 3
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile     = Join-Path $StateDir 'library.log'
$ResultsFile = Join-Path $StateDir 'library-results.json'
$NowDoneFile = Join-Path $StateDir 'library-jetzt-erledigt.txt'
$CreatedFile = Join-Path $StateDir 'library-eingeplant.txt'   # App-IDs, deren Manifest von hier angelegt wurde
$SteamApps   = Join-Path $Library 'steamapps'
$Common      = Join-Path $SteamApps 'common'
$Utf8        = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $LogFile -Value $line
    Write-Host $m
}

# ---------------- Freigabe (gleiche Logik wie apply-redirects.ps1) ----------------
function Get-ShareRoot([string]$share) {
    $x = @($share -split '\\' | Where-Object { $_ })
    return "\\$($x[0])\$($x[1])"
}
function Get-ShareCred([string]$credFile) {
    if (-not (Test-Path $credFile)) { return $null }
    Add-Type -AssemblyName System.Security
    $j = Get-Content -Raw $credFile | ConvertFrom-Json
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($j.Password), $null,
             [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [pscustomobject]@{ User = $j.User; Password = [Text.Encoding]::UTF8.GetString($bytes) }
}
function Connect-Share([string]$share, [string]$credFile) {
    if (Test-Path $share) { return $true }
    $c = Get-ShareCred $credFile
    if (-not $c) { return $false }       # ohne Zugangsdaten kein "net use" (wuerde unsichtbar nach einem Passwort fragen)
    $null | net use (Get-ShareRoot $share) $c.Password /user:$($c.User) /persistent:no 2>&1 | Out-Null
    return (Test-Path $share)
}

# ---------------- Steam-Manifeste ----------------
function Get-VdfValue([string]$txt, [string]$key) {
    if ($txt -match ('"' + $key + '"\s+"([^"]*)"')) { return $Matches[1] }
    return $null
}
function Get-Installed {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -Path $SteamApps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
        $txt = Get-Content -Raw -Path $f.FullName -ErrorAction SilentlyContinue
        if (-not $txt) { continue }
        $id = Get-VdfValue $txt 'appid'
        if ($id -notmatch '^\d+$') { continue }
        $size = Get-VdfValue $txt 'SizeOnDisk'; if ($size -notmatch '^\d+$') { $size = '0' }
        $flags = Get-VdfValue $txt 'StateFlags'; if ($flags -notmatch '^\d+$') { $flags = '0' }
        $list.Add([pscustomobject]@{
            appid      = [int64]$id
            name       = (Get-VdfValue $txt 'name')
            installdir = (Get-VdfValue $txt 'installdir')
            state      = [int]$flags
            size       = [int64]$size
            buildid    = (Get-VdfValue $txt 'buildid')
        })
    }
    return ,$list
}

# Spielname -> Ordnername (nur erlaubte Zeichen)
function Get-SafeDirName([string]$name, [int64]$appid) {
    $n = ($name -replace '[\x00-\x1f<>:"/\\|?*]', '').Trim().TrimEnd('.').Trim()
    if ($n.Length -gt 100) { $n = $n.Substring(0, 100).Trim() }
    if (-not $n -or $n -eq '.' -or $n -eq '..') { $n = "app_$appid" }
    return $n
}

function Remove-DeepDir([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    if ($IsLinux -or $IsMacOS) { Remove-Item -LiteralPath $dir -Recurse -Force; return }   # nur fuer Tests
    # rmdir /s loescht Verknuepfungen (Junctions nach Z:), ohne hineinzugehen -> Daten auf Z: bleiben
    & cmd.exe /c "rmdir /s /q `"\\?\$dir`"" 2>&1 | Out-Null
}

function Install-Game([int64]$appid, [string]$name) {
    $manifest = Join-Path $SteamApps "appmanifest_$appid.acf"
    if (Test-Path -LiteralPath $manifest) { return @('vorhanden', 'bereits installiert bzw. schon eingeplant') }
    $dir = Get-SafeDirName $name $appid
    $vdfName = ($name -replace '[\x00-\x1f"\\]', '').Trim()
    if (-not $vdfName) { $vdfName = $dir }
    if ($WhatIf) { return @('wuerde', "wuerde Manifest anlegen ($dir)") }
    New-Item -ItemType Directory -Force -Path $SteamApps | Out-Null
    $t = "`t`t"
    $lines = @(
        '"AppState"', '{',
        "`t`"appid`"$t`"$appid`"",
        "`t`"Universe`"$t`"1`"",
        "`t`"name`"$t`"$vdfName`"",
        "`t`"StateFlags`"$t`"1026`"",
        "`t`"installdir`"$t`"$dir`"",
        "`t`"LastUpdated`"$t`"0`"",
        "`t`"SizeOnDisk`"$t`"0`"",
        "`t`"buildid`"$t`"0`"",
        "`t`"AutoUpdateBehavior`"$t`"2`"",
        '}'
    )
    [IO.File]::WriteAllText($manifest, (($lines -join "`n") + "`n"), $Utf8)
    Add-Content -Path $CreatedFile -Value "$appid"
    return @('eingeplant', "Steam laedt das Spiel beim naechsten Start ($dir)")
}

function Uninstall-Game([int64]$appid) {
    $manifest = Join-Path $SteamApps "appmanifest_$appid.acf"
    if (-not (Test-Path -LiteralPath $manifest)) { return @('nicht vorhanden', 'war nicht installiert') }
    $txt = Get-Content -Raw -LiteralPath $manifest
    $dir = Get-VdfValue $txt 'installdir'
    if ($dir -and ($dir -match '[\\/:]' -or $dir -match '^\.+$' -or $dir -match '[\x00-\x1f<>"|?*]')) {
        return @('abgelehnt', "unsicherer Ordnername im Manifest: $dir")
    }
    if ($WhatIf) { return @('wuerde', "wuerde $dir entfernen") }
    if ($dir) { Remove-DeepDir (Join-Path $Common $dir) }
    foreach ($extra in (Join-Path (Join-Path $SteamApps 'downloading') "$appid"),
                       (Join-Path (Join-Path $SteamApps 'shadercache') "$appid")) {
        Remove-DeepDir $extra
    }
    Remove-Item -LiteralPath $manifest -Force
    if ($dir -and (Test-Path -LiteralPath (Join-Path $Common $dir))) { return @('fehler', "Ordner $dir liess sich nicht ganz loeschen") }
    return @('entfernt', "$dir geloescht")
}

function Read-Order([string]$bib) {
    $f = Join-Path $bib 'auftrag.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $f -Encoding UTF8
        $o = $raw | ConvertFrom-Json
        # Zeitstempel als Originaltext (PowerShell 7 wuerde ihn sonst in ein lokales Datum umwandeln)
        $j = ''
        if ($raw -match '"jetzt"\s*:\s*"([^"]{1,40})"') { $j = $Matches[1] }
        $o | Add-Member -NotePropertyName jetztText -NotePropertyValue $j -Force
        return $o
    }
    catch { Write-Log "FEHLER: auftrag.json nicht lesbar: $_"; return $null }
}

function Write-JsonAtomic([string]$path, $obj) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 6), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ---------------- Ablauf ----------------
if (-not ($CheckNow -or $Apply -or $Export)) { Write-Host 'Bitte -CheckNow, -Apply oder -Export angeben.'; exit 1 }

$cfg = $null; $credFile = 'C:\ProgramData\GamingPersist\share-cred.json'
if ($BibDir) {
    $bib = $BibDir
} else {
    if (-not (Test-Path $ConfigFile)) { Write-Log "$ConfigFile fehlt - setup-scan-task.ps1 -Master ausfuehren"; exit 1 }
    $cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
    if (-not (Connect-Share $cfg.Share $credFile)) { Write-Log "FEHLER: Freigabe $($cfg.Share) nicht erreichbar"; exit 1 }
    $bib = Join-Path $cfg.Share $SubFolder
}

$code = 0
try {
    New-Item -ItemType Directory -Force -Path $bib | Out-Null
    $order = Read-Order $bib

    if ($CheckNow) {
        $code = 3
        if ($order -and $order.jetztText) {
            $req  = [string]$order.jetztText
            $done = ''
            if (Test-Path $NowDoneFile) { $done = (Get-Content -Raw $NowDoneFile).Trim() }
            $when = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($req, [ref]$when) -and $req -ne $done) {
                $age = ([DateTimeOffset]::UtcNow - $when).TotalHours
                if ($age -ge -0.5 -and $age -le $NowValidHours) {
                    Set-Content -Path $NowDoneFile -Value $req
                    Write-Log "Sofort-Auftrag aus der Spielebibliothek ($req)"
                    $code = 0
                }
            }
        }
    }

    if ($Apply) {
        if (Get-Process -Name steam -ErrorAction SilentlyContinue) { Write-Log 'FEHLER: Steam laeuft - Auftraege werden nicht ausgefuehrt'; exit 1 }
        $results = New-Object System.Collections.Generic.List[object]
        $items = @()
        if ($order -and $order.items) { $items = @($order.items) }
        Write-Log "=== Spielebibliothek: $($items.Count) Auftrag/Auftraege ==="
        $removed = 0; $seen = @{}
        foreach ($it in ($items | Select-Object -First 100)) {
            $platform = [string]$it.platform
            $action   = [string]$it.action
            $idText   = [string]$it.appid
            $name     = [string]$it.name
            $r = $null
            if ($idText -notmatch '^\d{1,10}$' -or [int64]$idText -le 0 -or [int64]$idText -gt 4294967295) {
                $r = @('abgelehnt', 'ungueltige App-ID')
            } elseif ($platform -and $platform -ne 'steam') {
                $r = @('abgelehnt', "Plattform '$platform' wird noch nicht unterstuetzt")
            } elseif ($seen.ContainsKey($idText)) {
                continue
            } elseif ($action -eq 'install') {
                $r = Install-Game ([int64]$idText) $name
            } elseif ($action -eq 'remove') {
                if ($removed -ge $MaxRemove) { $r = @('aufgeschoben', "hoechstens $MaxRemove Spiele pro Lauf entfernen") }
                else { $r = Uninstall-Game ([int64]$idText); if ($r[0] -eq 'entfernt') { $removed++ } }
            } else {
                $r = @('abgelehnt', "unbekannte Aktion '$action'")
            }
            $seen[$idText] = 1
            if ($name.Length -gt 100) { $name = $name.Substring(0, 100) }
            Write-Log ("  {0} {1} ({2}): {3} - {4}" -f $action, $name, $idText, $r[0], $r[1])
            $results.Add([pscustomobject]@{
                appid = [int64]$(if ($idText -match '^\d{1,10}$') { $idText } else { 0 })
                action = $action; result = $r[0]; message = $r[1]
                time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
        }
        if (-not $WhatIf) { Write-JsonAtomic $ResultsFile ([object[]]$results) }
    }

    if ($Export) {
        $results = New-Object System.Collections.Generic.List[object]
        if (Test-Path $ResultsFile) { try { foreach ($x in @(Get-Content -Raw $ResultsFile | ConvertFrom-Json)) { if ($x) { $results.Add($x) } } } catch {} }

        # Eingeplante Spiele, die Steam nicht laden wollte, wieder austragen
        if ($CheckStubs -and (Test-Path $CreatedFile)) {
            $keep = New-Object System.Collections.Generic.List[string]
            foreach ($id in @(Get-Content $CreatedFile | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique)) {
                $mf = Join-Path $SteamApps "appmanifest_$id.acf"
                if (-not (Test-Path -LiteralPath $mf)) { continue }
                $txt = Get-Content -Raw -LiteralPath $mf
                $flags = Get-VdfValue $txt 'StateFlags'; $size = Get-VdfValue $txt 'SizeOnDisk'
                $bytes = Get-VdfValue $txt 'BytesToDownload'; $build = Get-VdfValue $txt 'buildid'
                if ($flags -eq '4') { continue }
                $started = ($size -match '^\d+$' -and [int64]$size -gt 0) -or ($bytes -match '^\d+$' -and [int64]$bytes -gt 0) -or ($build -match '^\d+$' -and [int64]$build -gt 0)
                if ($started) { $keep.Add($id); continue }
                Remove-Item -LiteralPath $mf -Force
                $nm = Get-VdfValue $txt 'name'
                Write-Log "  $nm ($id): Steam hat den Download nicht begonnen - wieder ausgetragen"
                $results.Add([pscustomobject]@{ appid = [int64]$id; action = 'install'; result = 'fehler'
                    message = 'Steam hat den Download nicht begonnen - keine Lizenz fuer das Master-Konto bzw. nicht fuer die Familie freigegeben?'
                    time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
            }
            [IO.File]::WriteAllLines($CreatedFile, [string[]]$keep)
            Write-JsonAtomic $ResultsFile ([object[]]$results)
        }

        $installed = Get-Installed
        $free = $null; $total = $null
        try { $d = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path $Library).Path)); $free = $d.AvailableFreeSpace; $total = $d.TotalSize } catch {}
        $nowDone = ''
        if (Test-Path $NowDoneFile) { $nowDone = (Get-Content -Raw $NowDoneFile).Trim() }
        $status = [ordered]@{
            time          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            computer      = $env:COMPUTERNAME
            free_bytes    = $free
            total_bytes   = $total
            jetzt_erledigt = $nowDone
            installed     = [object[]]($installed | Sort-Object name)
            results       = [object[]]$results.ToArray()
        }
        Write-JsonAtomic (Join-Path $bib 'status.json') $status
        Write-Log "status.json geschrieben: $($installed.Count) Spiele"
    }
} finally {
    if ($cfg -and (Test-Path $credFile)) { net use (Get-ShareRoot $cfg.Share) /delete /y 2>&1 | Out-Null }
}
exit $code
