<#
ensure-z-folders.ps1  -  laeuft automatisch in jeder VM (Aufgabe "Gaming Z-Ordner")

Liest D:\_persist\map.txt (wird im Master von redirect-to-z.ps1 gepflegt) und legt
fuer jede Umleitung den Zielordner auf Z: an. Gibt es dazu Startinhalte in
D:\_persist\seed\..., werden sie beim ersten Anlegen hineinkopiert.
Bestehende Daten auf Z: werden nie ueberschrieben.

Raeumt ausserdem leere Ordner mit zusammengeklebtem Namen auf Z: auf (Fehler aelterer
Versionen, z.B. ...\FSD\SavedSteamLibrary\...), auch bei Pfaden ueber 260 Zeichen.
Ordner mit Dateien werden nie geloescht.

Log: C:\ProgramData\GamingPersist\ensure.log
#>
param([string]$Letter = 'Z')

$LogDir = 'C:\ProgramData\GamingPersist'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'ensure.log'
function Write-Log([string]$m) { Add-Content -Path $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

$DRoot = 'D:\'
$ZRoot = "${Letter}:\Persist\D"
$map   = 'D:\_persist\map.txt'

# ============ gleiche Erkennung wie in redirect-to-z.ps1 ============

function Get-Roots {
    $r = @(Get-ChildItem -LiteralPath $DRoot -Directory -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notin @('_persist', '$RECYCLE.BIN', 'System Volume Information') } |
           ForEach-Object { $_.Name })
    return ,$r
}

function Get-GlueRoot([string]$segment, [string]$next, [string[]]$roots) {
    if (-not $next) { return $null }
    foreach ($r in $roots) {
        if ($segment.Length -gt $r.Length -and $segment.EndsWith($r, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath (Join-Path (Join-Path $DRoot $r) $next))) { return $r }
    }
    return $null
}

function Get-GlueRootOfDir([string]$dir, [string[]]$roots) {
    $name = Split-Path $dir -Leaf
    foreach ($c in Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue) {
        $g = Get-GlueRoot $name $c.Name $roots
        if ($g) { return $g }
    }
    return $null
}

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

# Zaehlt Dateien unterhalb eines Ordners, OHNE Verknuepfungen zu folgen (auch bei Pfaden ueber 260 Zeichen)
function Get-FileCount([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $out = robocopy $dir 'C:\__nichts__' /L /E /XJ /NJH /NJS /NDL /NC /NS /NP /FP /R:0 /W:0 2>$null
    return @($out | Where-Object { $_ -and $_.Trim() }).Count
}

# Loescht einen Ordner auch bei Pfaden ueber 260 Zeichen; rmdir folgt keinen Verknuepfungen
function Remove-DeepDir([string]$dir) {
    cmd /c rmdir /s /q "\\?\$dir" 2>$null | Out-Null
    if (Test-Path -LiteralPath $dir) {
        $empty = Join-Path $env:TEMP ('leer-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        robocopy $empty $dir /MIR /XJ /R:0 /W:0 /NJH /NJS /NDL /NFL /NP | Out-Null
        cmd /c rmdir /s /q "\\?\$dir" 2>$null | Out-Null
        cmd /c rmdir "$empty" 2>$null | Out-Null
    }
    return (-not (Test-Path -LiteralPath $dir))
}

function Find-GluedDirs([string]$base, [string[]]$roots) {
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $base)) { return ,$found }
    $stack = New-Object System.Collections.Stack
    $stack.Push($base)
    while ($stack.Count -gt 0) {
        foreach ($i in Get-ChildItem -LiteralPath $stack.Pop() -Directory -Force -ErrorAction SilentlyContinue) {
            if (Get-GlueRootOfDir $i.FullName $roots) { $found.Add($i.FullName); continue }
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($i.FullName)
        }
    }
    return ,$found
}

# ============ Ablauf ============

if (-not (Test-Path "${Letter}:\")) { Write-Log "Laufwerk ${Letter}: fehlt - init-z.ps1 ausfuehren!"; exit 1 }
$roots = Get-Roots

# 1. Muell aufraeumen (nur Ordner ohne eine einzige Datei)
foreach ($d in (Find-GluedDirs $ZRoot $roots)) {
    $files = Get-FileCount $d
    if ($files -gt 0) { Write-Log "NICHT aufgeraeumt (enthaelt $files Datei(en)): $d"; continue }
    if (Remove-DeepDir $d) { Write-Log "aufgeraeumt: $d" } else { Write-Log "konnte nicht vollstaendig geloescht werden: $d" }
}

# 2. Zielordner anlegen
if (-not (Test-Path $map)) { Write-Log "keine Umleitungen: $map fehlt (im Master noch nichts umgeleitet oder D: seitdem nicht neu verteilt)"; exit 0 }
$entries = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content -Path $map) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    foreach ($e in (Split-Entry $t $roots)) { if (-not $entries.Contains($e)) { $entries.Add($e) } }
}

$created = 0
foreach ($rel in $entries) {
    $target = "$ZRoot\$rel"
    if (Test-Path -LiteralPath $target) { continue }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $seed = "D:\_persist\seed\$rel"
    if (Test-Path -LiteralPath $seed) {
        robocopy $seed $target /E /XC /XN /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        Write-Log "angelegt (mit Startinhalt): $target"
    } else {
        Write-Log "angelegt: $target"
    }
    $created++
}
Write-Log "Pruefung fertig: $($entries.Count) Umleitung(en), $created Ordner neu angelegt"
if ($created -gt 0) {
    icacls "${Letter}:\Persist" /grant '*S-1-5-32-545:(OI)(CI)M' /T /C /Q | Out-Null
}
exit 0
