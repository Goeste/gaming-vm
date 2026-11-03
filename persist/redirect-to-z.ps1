<#
redirect-to-z.ps1  -  NUR IM MASTER als admin ausfuehren (Steam/Spiel vorher schliessen)

Leitet Ordner auf D: dauerhaft auf Z: um. Im Master wird der Ordner nach
Z:\Persist\D\<Pfad> verschoben und auf D: durch eine Verknuepfung (Junction)
ersetzt. Die Verknuepfung kommt mit der naechsten Verteilung in jede Kinder-VM
und zeigt dort auf deren eigenes Z:. Die Liste aller Umleitungen steht in
D:\_persist\map.txt.

Beispiele:
  .\redirect-to-z.ps1 'D:\SteamLibrary\steamapps\common\Spiel\Saves'
  .\redirect-to-z.ps1 'D:\...\Spiel\Saves','D:\...\Spiel\Mods'      # mehrere auf einmal
  .\redirect-to-z.ps1 'D:\SteamLibrary\steamapps\common\Spiel\Config' -Seed   # mit Startinhalt

  .\redirect-to-z.ps1 -List      # alle Umleitungen mit Status anzeigen
  .\redirect-to-z.ps1 -Repair    # pruefen, reparieren und aufraeumen (laeuft auch im Nachtlauf)
  .\redirect-to-z.ps1 '<Pfad>' -Remove      # Umleitung aufheben, Daten zurueck nach D:

-Repair erkennt auch zusammengeklebte Eintraege (Fehler aelterer Versionen, z.B.
"...\FSD\SavedSteamLibrary\..."), zerlegt sie wieder in die richtigen Eintraege und
entfernt die dabei entstandenen leeren Ordner auf D: und Z: - auch wenn die Pfade
laenger als 260 Zeichen sind. Ordner mit Dateien darin werden nie geloescht, nur gemeldet.
#>
#Requires -RunAsAdministrator
param(
    [string[]]$Path = @(),
    [switch]$Seed,
    [switch]$Remove,
    [switch]$Repair,
    [switch]$List,
    [string]$Letter = 'Z'
)
$ErrorActionPreference = 'Stop'
$PersistDir = 'D:\_persist'
$MapFile    = Join-Path $PersistDir 'map.txt'
$SeedDir    = Join-Path $PersistDir 'seed'
$ZRoot      = "${Letter}:\Persist\D"
$DRoot      = 'D:\'

# ======================= Liste und zusammengeklebte Eintraege =======================

# Namen der obersten Ordner auf D: (z.B. SteamLibrary, GOG Games) - jeder Eintrag beginnt mit einem davon
function Get-Roots {
    $r = @(Get-ChildItem -LiteralPath $DRoot -Directory -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notin @('_persist', '$RECYCLE.BIN', 'System Volume Information') } |
           ForEach-Object { $_.Name })
    return ,$r
}

# Ein Ordnername ist "zusammengeklebt", wenn er mit einem Wurzelnamen endet, aber laenger ist
# (z.B. SavedSteamLibrary) UND der naechste Ordner im Pfad unter dieser Wurzel auf D: wirklich existiert
# (z.B. D:\SteamLibrary\steamapps). So wird ein echter Ordner wie "SaveGames" nie verwechselt.
function Get-GlueRoot([string]$segment, [string]$next, [string[]]$roots) {
    if (-not $next) { return $null }
    foreach ($r in $roots) {
        if ($segment.Length -gt $r.Length -and $segment.EndsWith($r, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath (Join-Path (Join-Path $DRoot $r) $next))) { return $r }
    }
    return $null
}

# Wie oben, fuer einen vorhandenen Ordner: prueft dessen Unterordner als "naechsten" Pfadteil
function Get-GlueRootOfDir([string]$dir, [string[]]$roots) {
    $name = Split-Path $dir -Leaf
    foreach ($c in Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue) {
        $g = Get-GlueRoot $name $c.Name $roots
        if ($g) { return $g }
    }
    return $null
}

# Zerlegt einen Eintrag in die urspruenglichen Eintraege (bei sauberem Eintrag: genau einer)
function Split-Entry([string]$rel, [string[]]$roots) {
    $segs = @($rel -split '\\' | Where-Object { $_ })
    $out  = New-Object System.Collections.Generic.List[string]
    $cur  = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $g = $null
        if ($i -gt 0 -and $i -lt ($segs.Count - 1)) { $g = Get-GlueRoot $segs[$i] $segs[$i + 1] $roots }
        if ($g) {
            $cur.Add($segs[$i].Substring(0, $segs[$i].Length - $g.Length))
            $out.Add(($cur -join '\'))
            $cur.Clear(); $cur.Add($g)
        } else { $cur.Add($segs[$i]) }
    }
    if ($cur.Count -gt 1) { $out.Add(($cur -join '\')) }
    return ,$out.ToArray()
}

# Liest die Liste; zusammengeklebte Eintraege werden dabei schon zerlegt.
# Ergebnis ist immer eine echte Liste (List[string]) - auch bei 0 oder 1 Eintrag.
function Get-Map([string[]]$roots) {
    $list = New-Object System.Collections.Generic.List[string]
    if (Test-Path $MapFile) {
        foreach ($line in Get-Content $MapFile) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            foreach ($e in (Split-Entry $t $roots)) { if (-not $list.Contains($e)) { $list.Add($e) } }
        }
    }
    return ,$list
}

function Save-Map($entries) {
    New-Item -ItemType Directory -Force -Path $PersistDir | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Umleitungen von D: nach Z:\Persist\D\ - gepflegt von redirect-to-z.ps1 (ein Eintrag pro Zeile)')
    foreach ($e in ($entries | Sort-Object -Unique)) { if ($e) { $lines.Add($e) } }
    [IO.File]::WriteAllLines($MapFile, $lines.ToArray())
}

# ======================= Verknuepfungen und Ordner =======================

function Test-Junction([string]$p) {
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    return [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Get-JunctionTarget([string]$p) {
    try {
        $t = (Get-Item -LiteralPath $p -Force).Target
        if ($t) { return ([string]($t | Select-Object -First 1)).Replace('\??\', '') }
    } catch {}
    return $null
}

# Zaehlt Dateien unterhalb eines Ordners, OHNE Verknuepfungen zu folgen. robocopy im
# Nur-Auflisten-Modus (/L) kommt auch mit Pfaden ueber 260 Zeichen zurecht.
function Get-FileCount([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $out = robocopy $dir 'C:\__nichts__' /L /E /XJ /NJH /NJS /NDL /NC /NS /NP /FP /R:0 /W:0 2>$null
    return @($out | Where-Object { $_ -and $_.Trim() }).Count
}

# Loescht einen Ordner - auch bei Pfaden ueber 260 Zeichen.
# rmdir folgt keinen Verknuepfungen; \\?\ hebt die Laengenbegrenzung auf.
function Remove-DeepDir([string]$dir) {
    cmd /c rmdir /s /q "\\?\$dir" 2>$null | Out-Null
    if (Test-Path -LiteralPath $dir) {
        # Rueckfall: mit robocopy leeren (/XJ: Verknuepfungen weder verfolgen noch anfassen), dann nochmal rmdir
        $empty = Join-Path $env:TEMP ('leer-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        robocopy $empty $dir /MIR /XJ /R:0 /W:0 /NJH /NJS /NDL /NFL /NP | Out-Null
        cmd /c rmdir /s /q "\\?\$dir" 2>$null | Out-Null
        cmd /c rmdir "$empty" 2>$null | Out-Null
    }
    return (-not (Test-Path -LiteralPath $dir))
}

# Loescht einen Muell-Ordner nur, wenn keine einzige Datei darin liegt
function Remove-GarbageDir([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = Get-FileCount $dir
    if ($files -gt 0) { Write-Host "  NICHT geloescht (enthaelt $files Datei(en)), bitte selbst pruefen: $dir"; return }
    if (Remove-DeepDir $dir) { Write-Host "  aufgeraeumt: $dir" }
    else                     { Write-Host "  konnte nicht vollstaendig geloescht werden: $dir" }
}

# Sucht unterhalb von $base Ordner mit zusammengeklebtem Namen (folgt keinen Verknuepfungen)
function Find-GluedDirs([string]$base, [string[]]$roots) {
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $base)) { return ,$found }
    $stack = New-Object System.Collections.Stack
    $stack.Push($base)
    while ($stack.Count -gt 0) {
        foreach ($i in Get-ChildItem -LiteralPath $stack.Pop() -Directory -Force -ErrorAction SilentlyContinue) {
            if (Get-GlueRootOfDir $i.FullName $roots) { $found.Add($i.FullName); continue }   # ganzer Teilbaum ist Muell
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($i.FullName)
        }
    }
    return ,$found
}

function Restore-Target([string]$rel, [string]$target) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $s = Join-Path $SeedDir $rel
    if (Test-Path -LiteralPath $s) { robocopy $s $target /E /XC /XN /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null }
}

function Move-Content([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    robocopy $from $to /E /MOVE /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Kopieren von $from nach $to fehlgeschlagen (robocopy $LASTEXITCODE)" }
    if (Test-Path -LiteralPath $from) { [void](Remove-DeepDir $from) }
}

function Get-Rel([string]$p, [string[]]$roots) {
    $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
    if ($full -notmatch '^[Dd]:\\.+')    { throw "$full liegt nicht auf D:" }
    if ($full -match '^[Dd]:\\_persist') { throw "$full darf nicht umgeleitet werden" }
    $rel = $full.Substring(3)
    if ((Split-Entry $rel $roots).Count -ne 1) { throw "$full sieht wie ein zusammengeklebter Pfad aus - bitte pruefen" }
    return $rel
}

function Set-Redirect([string]$rel, [bool]$withSeed) {
    $src    = "D:\$rel"
    $target = "$ZRoot\$rel"
    if (Test-Junction $src) {
        $cur = Get-JunctionTarget $src
        if ($cur -and ($cur.TrimEnd('\') -ne $target.TrimEnd('\'))) {
            Write-Host "  Verknuepfung zeigte auf $cur - wird neu angelegt"
            cmd /c rmdir "$src" | Out-Null
        } elseif (-not (Test-Path -LiteralPath $target)) {
            Restore-Target $rel $target
            Write-Host "  Ziel fehlte, neu angelegt: $target"
            return
        } else {
            Write-Host "  bereits umgeleitet: $src"
            return
        }
    }
    if ($withSeed -and (Test-Path -LiteralPath $src)) {
        $s = Join-Path $SeedDir $rel
        New-Item -ItemType Directory -Force -Path $s | Out-Null
        robocopy $src $s /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Startinhalt fuer $src konnte nicht gesichert werden" }
    }
    if (Test-Path -LiteralPath $src) {
        Move-Content $src $target
    } else {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path $src) | Out-Null
    }
    cmd /c mklink /J "$src" "$target" | Out-Null
    if (-not (Test-Junction $src)) { throw "Verknuepfung $src konnte nicht angelegt werden" }
    Write-Host "  OK: $src  ->  $target"
}

# ======================= Hauptteil =======================
if (-not (Test-Path "${Letter}:\")) { throw "Laufwerk ${Letter}: fehlt - zuerst init-z.ps1 ausfuehren." }
$roots = Get-Roots
$map   = Get-Map $roots          # zusammengeklebte Eintraege sind hier schon zerlegt

if ($List) {
    if ($map.Count -eq 0) { Write-Host 'Keine Umleitungen.' }
    foreach ($rel in $map) {
        $src = "D:\$rel"; $target = "$ZRoot\$rel"
        if (-not (Test-Junction $src))                 { $state = 'DEFEKT     ' }
        elseif (-not (Test-Path -LiteralPath $target)) { $state = 'ZIEL FEHLT ' }
        else                                           { $state = 'OK         ' }
        Write-Host "$state $src"
    }
    $glued = @(Find-GluedDirs $ZRoot $roots)
    if ($glued.Count -gt 0) { Write-Host ''; Write-Host "$($glued.Count) Muell-Ordner auf ${Letter}: gefunden, z.B. $($glued[0])" }
    Write-Host ''
    Write-Host 'Reparieren und aufraeumen:  & C:\Scripts\redirect-to-z.ps1 -Repair'
    return
}

if ($Repair) {
    Write-Host 'Aufraeumen (zusammengeklebte Ordner auf D: und Z:) ...'
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Find-GluedDirs $ZRoot $roots)) { $dirs.Add($d) }
    foreach ($rel in $map) {                                   # auf D: nur neben den Eintraegen suchen (schnell)
        $parent = Split-Path "D:\$rel" -Parent
        foreach ($c in Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue) {
            if (Get-GlueRootOfDir $c.FullName $roots) { $dirs.Add($c.FullName) }
        }
    }
    foreach ($d in ($dirs | Sort-Object -Unique)) { Remove-GarbageDir $d }
    Write-Host 'Umleitungen pruefen ...'
    foreach ($rel in $map) { Set-Redirect $rel $false }
    Save-Map $map
    Write-Host 'Fertig.' -ForegroundColor Green
    return
}

if (-not $Path) { throw 'Bitte einen Pfad auf D: angeben (oder -List / -Repair).' }

foreach ($p in $Path) {
    $rel = Get-Rel $p $roots
    if ($Remove) {
        $src = "D:\$rel"; $target = "$ZRoot\$rel"
        if (Test-Junction $src) { cmd /c rmdir "$src" | Out-Null }
        if (Test-Path -LiteralPath $target) { Move-Content $target $src } else { New-Item -ItemType Directory -Force -Path $src | Out-Null }
        $s = Join-Path $SeedDir $rel
        if (Test-Path -LiteralPath $s) { [void](Remove-DeepDir $s) }
        [void]$map.Remove($rel)
        Write-Host "  aufgehoben: $src"
    } else {
        Set-Redirect $rel $Seed.IsPresent
        if (-not $map.Contains($rel)) { $map.Add($rel) }
    }
}
Save-Map $map
Write-Host ''
Write-Host 'Fertig. Die Kinder-VMs uebernehmen das nach der naechsten Verteilung (Nachtlauf oder game-disk-sync.sh).' -ForegroundColor Green
