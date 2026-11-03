<#
scan-spielstaende.ps1  -  findet heraus, wo die installierten Spiele Spielstaende und Mods ablegen

Am besten in einer KINDER-VM als admin ausfuehren, nach einem Spielenachmittag und
VOR dem naechsten Nachtlauf. Dann sieht das Skript, was die Kinder heute geschrieben haben.

Geprueft werden Steam, GOG und Epic:
  - Schreibt das Spiel in seinen Installationsordner auf D:?  (Dateien, die seit dem Systemstart geaendert wurden)
  - Gibt es typische Spielstand-/Mod-Ordner im Installationsordner?
  - Gibt es Spielstaende auf C:?  (Steam Cloud, Dokumente, Gespeicherte Spiele, AppData)

Ergebnis (auf dem Desktop):
  spielstaende-bericht.txt    Bericht pro Spiel
  spielstaende.csv            dasselbe als Tabelle
  umleiten-vorschlaege.ps1    Befehle fuer redirect-to-z.ps1 - im MASTER ausfuehren
  umleiten.txt                nur die sicheren Faelle als Liste (liest apply-redirects.ps1 im Master)

Status:
  UMLEITEN    das Spiel hat heute in seinen Ordner auf D: geschrieben -> geht nachts verloren
  PRUEFEN     typischer Spielstand-/Mod-Ordner im Spielordner, aber heute nichts geschrieben
  OK (C:)     Spielstaende liegen auf C: oder in der Steam Cloud
  UMGELEITET  bereits nach Z: umgeleitet
  ZIEL FEHLT  umgeleitet, aber der Ordner auf Z: wurde geloescht - Spiel kann dort nicht speichern
  OK          nicht auf D: installiert - Daten bleiben ohnehin erhalten
  UNKLAR      keine Hinweise gefunden (noch nicht gespielt?) - nach einer Spielrunde erneut pruefen

Optionen:
  -Since '2026-10-26 06:00'   eigener Zeitpunkt statt Systemstart
  -NoDynamic                  nur Ordnernamen pruefen, keine Dateizeiten (schneller)
  -Rescue                     heutige Daten der sicheren Faelle schon nach Z:\Persist\D kopieren,
                              damit nach der Umleitung nichts fehlt (macht die taegliche Aufgabe)
#>
param(
    [string]$GamesRoot   = 'D:\',
    [datetime]$Since     = [datetime]::MinValue,
    [string]$ProfileRoot = 'C:\Users',
    [string]$SteamPath   = '',
    [string]$OutDir      = '',
    [switch]$NoDynamic,
    [switch]$Rescue,
    [string]$PersistRoot = 'Z:\Persist\D'
)
$ErrorActionPreference = 'Continue'

# ---------------- Grundeinstellungen ----------------
if ($Since -eq [datetime]::MinValue) {
    try   { $Since = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
    catch { $Since = (Get-Date).AddDays(-1) }
}
if (-not $OutDir) {
    $OutDir = [Environment]::GetFolderPath('Desktop')
    if (-not $OutDir) { $OutDir = (Get-Location).Path }
}
$StrongNames = @('saved','saves','save','savegames','savegame','savedata','savedgames','saveddata','profiles','profile','userdata','mods','mod')
$WeakNames   = @('config','configs','settings','cfg','logs','userconfig','screenshots')
# Nur Ordner mit diesen Namen werden automatisch umgeleitet (Rest nur als Vorschlag zum Pruefen)
$AutoNames   = $StrongNames + @('config','configs','settings','cfg','userconfig')
$SkipGames   = 'Steamworks Common Redistributables|Steam Linux Runtime|Proton |Proton$|SteamVR|Redistributable'

function Normalize([string]$s) { if (-not $s) { return '' }; return ($s -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
function Split-Rel([string]$rel) { return @($rel -split '[\\/]' | Where-Object { $_ }) }
function Join-Parts([string]$base, [string[]]$parts) { $p = $base; foreach ($x in $parts) { $p = Join-Path $p $x }; return $p }

# ---------------- Spiele finden ----------------
function Get-SteamRoot {
    if ($SteamPath) { return $SteamPath }
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKCU:\Software\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p.InstallPath) { return $p.InstallPath }
            if ($p.SteamPath)   { return ($p.SteamPath -replace '/', '\') }
        } catch {}
    }
    $d = 'C:\Program Files (x86)\Steam'
    if (Test-Path $d) { return $d }
    return $null
}

function Get-SteamGames([string]$steamRoot) {
    $libs = New-Object System.Collections.Generic.List[string]
    if ($steamRoot) { $libs.Add($steamRoot) }
    $vdf = Join-Parts $steamRoot @('steamapps', 'libraryfolders.vdf')
    if ($steamRoot -and (Test-Path $vdf)) {
        foreach ($m in [regex]::Matches((Get-Content -Raw $vdf), '"path"\s+"([^"]+)"')) {
            $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
        }
    }
    $seen = @{}
    foreach ($lib in $libs) {
        $key = $lib.TrimEnd('\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $sa = Join-Path $lib 'steamapps'
        foreach ($f in Get-ChildItem -Path $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $t    = Get-Content -Raw $f.FullName
            $id   = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
            $name = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
            $dir  = [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value
            $upd  = [regex]::Match($t, '"LastUpdated"\s+"(\d+)"').Groups[1].Value
            if (-not $dir -or $name -match $SkipGames) { continue }
            $updated = $null
            if ($upd) { $updated = [DateTimeOffset]::FromUnixTimeSeconds([int64]$upd).LocalDateTime }
            [pscustomobject]@{ Platform = 'Steam'; Name = $name; Id = $id
                               InstallDir = (Join-Parts $sa @('common', $dir)); LastUpdated = $updated }
        }
    }
}

function Get-GogGames {
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games') {
        foreach ($k in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.path) {
                [pscustomobject]@{ Platform = 'GOG'; Name = $p.gameName; Id = $p.gameID; InstallDir = $p.path; LastUpdated = $null }
            }
        }
    }
}

function Get-EpicGames {
    $dir = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    foreach ($f in Get-ChildItem -Path $dir -Filter '*.item' -ErrorAction SilentlyContinue) {
        try { $j = Get-Content -Raw $f.FullName | ConvertFrom-Json } catch { continue }
        if ($j.InstallLocation -and -not $j.bIsIncompleteInstall) {
            [pscustomobject]@{ Platform = 'Epic'; Name = $j.DisplayName; Id = $j.AppName; InstallDir = $j.InstallLocation; LastUpdated = $null }
        }
    }
}

# ---------------- Spielordner untersuchen ----------------
# Laeuft durch den Spielordner, ohne Verknuepfungen (Junctions) zu folgen.
function Get-FolderScan([string]$root) {
    $changed   = New-Object System.Collections.Generic.List[string]
    $junctions = New-Object System.Collections.Generic.List[string]
    $named     = New-Object System.Collections.Generic.List[string]
    $projects  = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($root, 0))
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop(); $dir = $entry[0]; $depth = $entry[1]
        foreach ($i in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { $junctions.Add($i.FullName); continue }   # auch verwaiste Verknuepfungen
            if ($i.PSIsContainer) {
                $n = $i.Name.ToLowerInvariant()
                if ($depth -lt 4 -and $StrongNames -contains $n) { $named.Add($i.FullName) }
                if ($depth -eq 0 -and (Test-Path (Join-Path $i.FullName 'Binaries'))) { $projects.Add($i.Name) }   # Unreal-Projekt (z.B. FSD)
                $stack.Push(@($i.FullName, ($depth + 1)))
            } elseif (-not $NoDynamic -and $i.LastWriteTime -gt $Since) {
                $changed.Add($i.FullName)
            }
        }
    }
    return [pscustomobject]@{ Changed = $changed; Junctions = $junctions; Named = $named; Projects = $projects }
}

# Prueft, ob der Ordner existiert, auf den eine Verknuepfung zeigt (nicht nur die Verknuepfung selbst)
function Test-LinkTarget([string]$link) {
    try {
        $t = (Get-Item -LiteralPath $link -Force -ErrorAction Stop).Target
        if (-not $t) { return $true }                       # Ziel nicht ermittelbar -> nicht als defekt melden
        $t = ([string]($t | Select-Object -First 1)).Replace('\??\', '')
        if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path $link -Parent) $t }
        return [IO.Directory]::Exists($t)
    } catch { return $false }
}

# Fasst geaenderte Dateien zu den Ordnern zusammen, die umgeleitet werden sollten
function Get-RedirectCandidates([string]$root, $files) {
    $result = @{}
    foreach ($f in $files) {
        $parts = Split-Rel ($f.Substring($root.Length))
        $dirParts = @($parts | Select-Object -First ($parts.Count - 1))
        $cut = -1
        for ($k = 0; $k -lt $dirParts.Count; $k++) {
            $n = $dirParts[$k].ToLowerInvariant()
            if ($StrongNames -contains $n -or $WeakNames -contains $n) { $cut = $k; break }
        }
        $auto = $false
        if ($cut -ge 0) { $target = Join-Parts $root @($dirParts[0..$cut]); $auto = ($AutoNames -contains $dirParts[$cut].ToLowerInvariant()) }
        elseif ($dirParts.Count -gt 0) { $target = Join-Parts $root $dirParts }
        else { $target = $root }
        if (-not $result.ContainsKey($target)) { $result[$target] = [pscustomobject]@{ Count = 0; Auto = $auto } }
        $result[$target].Count++
    }
    return $result
}

# ---------------- Hinweise auf C: ----------------
function Get-Profiles {
    Get-ChildItem -Path $ProfileRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users', 'Oeffentlich') }
}

function Test-NameMatch([string]$folderName, [string[]]$tokens) {
    $n = Normalize $folderName
    if ($n.Length -lt 3) { return $false }
    foreach ($t in $tokens) {
        if (-not $t) { continue }
        if ($n -eq $t) { return $true }
        if ($t.Length -ge 5 -and $n.Length -ge 5 -and ($n.Contains($t) -or $t.Contains($n))) { return $true }
    }
    return $false
}

function Get-CEvidence($game, [string[]]$tokens, [string]$steamRoot, $profiles) {
    $hits = New-Object System.Collections.Generic.List[string]
    if ($game.Platform -eq 'Steam' -and $steamRoot) {
        foreach ($u in Get-ChildItem -Path (Join-Path $steamRoot 'userdata') -Directory -ErrorAction SilentlyContinue) {
            $r = Join-Parts $u.FullName @($game.Id, 'remote')
            if (Test-Path $r) {
                $n = @(Get-ChildItem -Path $r -Recurse -File -ErrorAction SilentlyContinue).Count
                if ($n -gt 0) { $hits.Add("Steam Cloud: $n Datei(en) (Steam-Konto $($u.Name))") }
            }
        }
    }
    foreach ($prof in $profiles) {
        $base = $prof.FullName
        $parents = @(
            (Join-Parts $base @('Documents')), (Join-Parts $base @('Documents', 'My Games')),
            (Join-Parts $base @('OneDrive', 'Documents')), (Join-Parts $base @('OneDrive', 'Documents', 'My Games')),
            (Join-Parts $base @('Saved Games')),
            (Join-Parts $base @('AppData', 'Roaming')), (Join-Parts $base @('AppData', 'Local'))
        )
        foreach ($c in Get-ChildItem -Path (Join-Parts $base @('AppData', 'LocalLow')) -Directory -ErrorAction SilentlyContinue) { $parents += $c.FullName }   # Unity: LocalLow\Firma\Spiel
        foreach ($p in $parents) {
            foreach ($d in Get-ChildItem -Path $p -Directory -ErrorAction SilentlyContinue) {
                if (Test-NameMatch $d.Name $tokens) { $hits.Add($d.FullName) }
            }
        }
    }
    return $hits
}

# ---------------- Hauptteil ----------------
$steamRoot = Get-SteamRoot
$games = @()
$games += @(Get-SteamGames $steamRoot)
$games += @(Get-GogGames)
$games += @(Get-EpicGames)
$games = @($games | Where-Object { $_ } | Sort-Object Platform, Name)
$profiles = @(Get-Profiles)

Write-Host ("{0} Spiele gefunden (Steam: {1}). Pruefe Aenderungen seit {2:dd.MM.yyyy HH:mm} ..." -f $games.Count, $(if ($steamRoot) { $steamRoot } else { 'nicht gefunden' }), $Since) -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[object]
$idx = 0
foreach ($g in $games) {
    $idx++
    Write-Progress -Activity 'Spiele pruefen' -Status $g.Name -PercentComplete (100 * $idx / [math]::Max($games.Count, 1))
    $install = ([string]$g.InstallDir).TrimEnd('\', '/')
    $onGamesDrive = $install.ToLowerInvariant().StartsWith($GamesRoot.ToLowerInvariant().TrimEnd('\', '/'))
    $status = ''; $details = New-Object System.Collections.Generic.List[string]; $suggest = New-Object System.Collections.Generic.List[string]

    $tokens = @((Normalize $g.Name), (Normalize (Split-Path $install -Leaf)))
    $scan = $null
    if ((Test-Path -LiteralPath $install) -and $onGamesDrive) {
        $scan = Get-FolderScan $install
        $tokens += @($scan.Projects | ForEach-Object { Normalize $_ })
    }
    $cHits = @(Get-CEvidence $g $tokens $steamRoot $profiles)

    if (-not (Test-Path -LiteralPath $install)) {
        $status = 'FEHLT'; $details.Add("Spielordner nicht gefunden: $install")
    } elseif (-not $onGamesDrive) {
        $status = 'OK'; $details.Add("nicht auf $GamesRoot installiert ($install) - Daten bleiben erhalten")
    } else {
        $cand = @{}
        if ($scan.Changed.Count -gt 0) { $cand = Get-RedirectCandidates $install $scan.Changed }
        $updatedToday = ($g.LastUpdated -and $g.LastUpdated -gt $Since)
        $broken = @($scan.Junctions | Where-Object { -not (Test-LinkTarget $_) })
        foreach ($j in $scan.Junctions) {
            if ($broken -contains $j) { $details.Add("UMGELEITET, ABER ZIEL AUF Z: FEHLT: $j") }
            else                      { $details.Add("bereits umgeleitet: $j") }
        }

        if ($cand.Count -gt 0 -and -not $updatedToday) {
            $status = 'UMLEITEN'
            foreach ($k in ($cand.Keys | Sort-Object)) {
                if ($cand[$k].Auto) {
                    $details.Add("heute geschrieben: $k ($($cand[$k].Count) Datei(en))"); $suggest.Add($k)
                } else {
                    $details.Add("heute geschrieben, Ordnername unbekannt - pruefen: $k ($($cand[$k].Count) Datei(en))"); $suggest.Add("#$k")
                }
            }
        } elseif ($cand.Count -gt 0 -and $updatedToday) {
            $status = 'PRUEFEN'
            $details.Add('Spiel wurde heute von Steam aktualisiert - geaenderte Dateien koennen vom Update stammen')
            foreach ($k in ($cand.Keys | Sort-Object)) { $details.Add("geaendert: $k ($($cand[$k].Count) Datei(en))") }
        } elseif ($broken.Count -gt 0) {
            $status = 'ZIEL FEHLT'
            $details.Add("Reparieren: Start-ScheduledTask 'Gaming Z-Ordner' (Kinder-VM) bzw. redirect-to-z.ps1 -Repair (Master)")
        } elseif ($scan.Junctions.Count -gt 0) {
            $status = 'UMGELEITET'
        } elseif ($scan.Named.Count -gt 0 -and $cHits.Count -eq 0) {
            $status = 'PRUEFEN'
            foreach ($n in $scan.Named) { $details.Add("moeglicher Spielstand-/Mod-Ordner: $n"); $suggest.Add("#$n") }
        } elseif ($cHits.Count -gt 0) {
            $status = 'OK (C:)'
            foreach ($n in $scan.Named) { $details.Add("Hinweis, Ordner im Spielordner: $n") }
        } else {
            $status = 'UNKLAR'; $details.Add('keine Hinweise - nach einer Spielrunde erneut pruefen')
        }
    }
    foreach ($h in $cHits) { $details.Add("auf C:: $h") }

    $results.Add([pscustomobject]@{
        Status = $status; Plattform = $g.Platform; Spiel = $g.Name; Id = $g.Id; Spielordner = $install
        Details = ($details -join ' | '); Vorschlag = ($suggest -join ' | ')
    })
}
Write-Progress -Activity 'Spiele pruefen' -Completed

# ---------------- Ausgabe ----------------
$order = @{ 'ZIEL FEHLT' = -1; 'UMLEITEN' = 0; 'PRUEFEN' = 1; 'UNKLAR' = 2; 'FEHLT' = 3; 'UMGELEITET' = 4; 'OK (C:)' = 5; 'OK' = 6 }
$sorted = @($results | Sort-Object @{ Expression = { $order[$_.Status] } }, Spiel)

$csv = Join-Path $OutDir 'spielstaende.csv'
$sorted | Export-Csv -Path $csv -NoTypeInformation -Delimiter ';' -Encoding UTF8

$txt = Join-Path $OutDir 'spielstaende-bericht.txt'
$lines = @("Spielstand-Pruefung $(Get-Date -Format 'dd.MM.yyyy HH:mm') auf $env:COMPUTERNAME", "Aenderungen seit: $($Since.ToString('dd.MM.yyyy HH:mm'))", '')
foreach ($r in $sorted) {
    $lines += "[$($r.Status)] $($r.Spiel)  ($($r.Plattform) $($r.Id))"
    $lines += "    Spielordner: $($r.Spielordner)"
    foreach ($d in ($r.Details -split ' \| ')) { if ($d) { $lines += "    - $d" } }
    $lines += ''
}
[IO.File]::WriteAllLines($txt, [string[]]$lines)

$ps = Join-Path $OutDir 'umleiten-vorschlaege.ps1'
$out = @(
    '# Vorschlaege von scan-spielstaende.ps1 - IM MASTER als admin ausfuehren, Steam und Spiele geschlossen.',
    '# Aktive Zeilen: das Spiel hat heute in diesen Ordner geschrieben (Status UMLEITEN).',
    '# Auskommentierte Zeilen (#): nur ein Verdacht (Status PRUEFEN) - erst pruefen, dann das # entfernen.',
    '# Nur Ordner umleiten, die das Spiel selbst anlegt (Spielstaende, Einstellungen, Mods) - keine Spieldateien!',
    ''
)
foreach ($r in $sorted | Where-Object { $_.Vorschlag }) {
    $out += "# $($r.Spiel)  [$($r.Status)]"
    foreach ($s in ($r.Vorschlag -split ' \| ')) {
        if ($s.StartsWith('#')) { $out += "#& C:\Scripts\redirect-to-z.ps1 '$($s.Substring(1))'" }
        else                    { $out += "& C:\Scripts\redirect-to-z.ps1 '$s'" }
    }
    $out += ''
}
[IO.File]::WriteAllLines($ps, [string[]]$out)

# Liste der sicheren Faelle (nur Status UMLEITEN, nur bekannte Ordnernamen)
$auto = @()
foreach ($r in $sorted | Where-Object { $_.Status -eq 'UMLEITEN' -and $_.Vorschlag }) {
    foreach ($s in ($r.Vorschlag -split ' \| ')) { if ($s -and -not $s.StartsWith('#')) { $auto += $s } }
}
$auto = @($auto | Sort-Object -Unique)
$txtList = Join-Path $OutDir 'umleiten.txt'
[IO.File]::WriteAllLines($txtList, [string[]]$auto)

# Heutige Daten schon nach Z: kopieren, damit sie nach der Umleitung nicht fehlen
if ($Rescue -and $auto.Count -gt 0) {
    if (-not (Test-Path (Split-Path $PersistRoot -Parent))) {
        Write-Host "Rettung uebersprungen: $PersistRoot nicht vorhanden (init-z.ps1 ausfuehren)" -ForegroundColor Yellow
    } else {
        $rootLen = $GamesRoot.TrimEnd('\', '/').Length
        foreach ($src in $auto) {
            $rel = $src.Substring($rootLen).TrimStart('\', '/')
            $dst = Join-Parts $PersistRoot (Split-Rel $rel)
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            if (Get-Command robocopy -ErrorAction SilentlyContinue) {
                robocopy $src $dst /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            } else {
                Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
            }
            Write-Host "Gerettet nach Z: $src" -ForegroundColor Green
        }
    }
}

$table = $sorted | Select-Object Status, Plattform, Spiel |
    Format-Table -AutoSize | Out-String -Width 200
Write-Host $table
Write-Host "Bericht:     $txt" -ForegroundColor Green
Write-Host "Tabelle:     $csv" -ForegroundColor Green
Write-Host "Vorschlaege: $ps  (im Master ausfuehren)" -ForegroundColor Green
Write-Host "Liste:       $txtList  ($($auto.Count) sichere Faelle)" -ForegroundColor Green
