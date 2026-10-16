# Exact Windows file-timestamp capture and restoration (100-ns ticks), invoked explicitly from the WSL-side scripts
# through timestamps-capture.sh / timestamps-restore.sh. WSL's drvfs truncates timestamps to whole seconds on cp -p and
# touch; the original CreationTime and LastWriteTime of a file that an installation replaces can only be preserved
# from the Windows side. The manifest is a TSV: relative path, CreationTimeUtc ticks, LastWriteTimeUtc ticks,
# LastAccessTimeUtc ticks, length, SHA-256 (of the content at capture time).
#   -Mode capture -Root <dir> -Manifest <out.tsv> -Paths <rel>[,<rel>...]
#   -Mode restore -Root <dir> -Manifest <in.tsv>
# Every path must be relative, without '..' or wildcards, and must resolve under -Root. Restore sets a file's
# CreationTimeUtc and LastWriteTimeUtc ONLY after verifying that its current content hash equals the manifest's
# (the byte restoration must already have succeeded), then reads the timestamps back and fails on any mismatch.
# Nothing else is touched. Exit 0 only when every entry was captured / restored exactly.
param(
    [Parameter(Mandatory=$true)][ValidateSet('capture', 'restore')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Manifest,
    [string[]]$Paths = @()
)
$ErrorActionPreference = 'Stop'
function Fail($msg) { Write-Output ("win-timestamps: FAIL: " + $msg); exit 2 }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { Fail "root is not a directory: $Root" }
$rootFull = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $Root).FullName).TrimEnd('\') + '\'
function Resolve-Under-Root([string]$rel) {
    if ([string]::IsNullOrWhiteSpace($rel)) { Fail "empty path" }
    if ([System.IO.Path]::IsPathRooted($rel)) { Fail "absolute path refused: $rel" }
    if ($rel -match '(^|[\\/])\.\.([\\/]|$)') { Fail "parent reference refused: $rel" }
    if ($rel -match '[\*\?]') { Fail "wildcard refused: $rel" }
    $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $rel))
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { Fail "path escapes the root: $rel" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Fail "not an existing file: $rel" }
    return $full
}
function Hash-Of([string]$full) { return (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() }
if ($Mode -eq 'capture') {
    if ($Paths.Count -eq 0) { Fail "capture needs at least one path" }
    $lines = @()
    foreach ($rel in $Paths) {
        $full = Resolve-Under-Root $rel
        $f = Get-Item -LiteralPath $full
        $lines += ($rel + "`t" + $f.CreationTimeUtc.Ticks + "`t" + $f.LastWriteTimeUtc.Ticks + "`t" + $f.LastAccessTimeUtc.Ticks + "`t" + $f.Length + "`t" + (Hash-Of $full))
        Write-Output ("win-timestamps: captured " + $rel + " creation " + $f.CreationTimeUtc.ToString('o') + " lastwrite " + $f.LastWriteTimeUtc.ToString('o') + " sha256 " + (Hash-Of $full).Substring(0, 16) + "...")
    }
    [System.IO.File]::WriteAllText($Manifest, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ("win-timestamps: manifest written: " + $Manifest + " (" + $lines.Count + " entries)")
    exit 0
}
# restore
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Fail "manifest missing: $Manifest" }
$entries = Get-Content -LiteralPath $Manifest | Where-Object { $_.Trim() -ne '' }
if ($entries.Count -eq 0) { Fail "manifest empty: $Manifest" }
$failures = 0
foreach ($line in $entries) {
    $p = $line -split "`t"
    if ($p.Count -ne 6) { Fail "malformed manifest line: $line" }
    $rel = $p[0]; $cTicks = [int64]$p[1]; $wTicks = [int64]$p[2]; $len = [int64]$p[4]; $sha = $p[5].ToLowerInvariant()
    $full = Resolve-Under-Root $rel
    $f = Get-Item -LiteralPath $full
    if ($f.Length -ne $len -or (Hash-Of $full) -ne $sha) { Write-Output ("win-timestamps: FAIL: content of " + $rel + " is not the captured content (length " + $f.Length + " vs " + $len + "); timestamps NOT restored"); $failures++; continue }
    $f.CreationTimeUtc = [DateTime]::new($cTicks, [DateTimeKind]::Utc)
    $f.LastWriteTimeUtc = [DateTime]::new($wTicks, [DateTimeKind]::Utc)
    $g = Get-Item -LiteralPath $full
    if ($g.CreationTimeUtc.Ticks -ne $cTicks -or $g.LastWriteTimeUtc.Ticks -ne $wTicks) { Write-Output ("win-timestamps: FAIL: " + $rel + " read back creation " + $g.CreationTimeUtc.Ticks + " lastwrite " + $g.LastWriteTimeUtc.Ticks + " (wanted " + $cTicks + " / " + $wTicks + ")"); $failures++; continue }
    Write-Output ("win-timestamps: restored " + $rel + " creation " + $g.CreationTimeUtc.ToString('o') + " lastwrite " + $g.LastWriteTimeUtc.ToString('o') + " (EXACT)")
}
if ($failures -gt 0) { Write-Output ("win-timestamps: FAIL: " + $failures + " entr(y/ies) not restored"); exit 2 }
Write-Output ("win-timestamps: restored " + $entries.Count + " entr(y/ies) exactly")
exit 0
