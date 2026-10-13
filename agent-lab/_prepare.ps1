# Recompute ground truth with an unambiguous definition.
#
# Two bugs in the first version of this script:
#   1. Lines were sliced from an array built by splitting on "\n", which over-counted
#      because the section files contain mixed CRLF/LF endings and a trailing newline.
#      ReadAllLines is the authoritative count.
#   2. `table_rows` counted every line starting with "|", including the HEADER row.
#      The counting rule says data rows only: exclude header AND separator.
#
# Keep ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.

$ErrorActionPreference = "Stop"

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path (Join-Path $root "sections\sec1.md"))) {
    Write-Host "sections/ not found." -ForegroundColor Yellow
    Write-Host "The four section files are excerpts of the course notes and are NOT"
    Write-Host "distributed with this repository. To recreate them, follow the"
    Write-Host "'Reproducing the test fixture' section of README.md, then re-run this script."
    exit 1
}

$truth = [ordered]@{}
foreach ($k in @("sec1", "sec2", "sec3", "sec4")) {
    $path = Join-Path $root "sections\$k.md"
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)

    # Count pipe-prefixed rows, then classify the first two as header/separator.
    $piped = @($lines | Where-Object { $_ -match '^\|' })
    $isSep = { param($s) $s -match '^\|[\s\-:|]+\|?\s*$' -and $s -match '-' }
    $header = if ($piped.Count -ge 1) { 1 } else { 0 }
    $sep = 0
    if ($piped.Count -ge 2 -and (& $isSep $piped[1])) { $sep = 1 }
    $dataRows = [Math]::Max(0, $piped.Count - $header - $sep)

    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $tick = ([regex]::Matches($text, '(?m)^```')).Count

    $truth[$k] = [ordered]@{
        lines        = $lines.Count
        nonblank     = @($lines | Where-Object { $_.Trim() -ne "" }).Count
        table_rows   = $dataRows
        pipe_rows    = $piped.Count
        code_blocks  = [math]::Floor($tick / 2)
        figure_refs  = ([regex]::Matches($text, 'assets/fig-\d+-')).Count
        figure_ids   = @([regex]::Matches($text, 'fig-(\d+)-') |
                        ForEach-Object { [int]$_.Groups[1].Value } |
                        Sort-Object -Unique |
                        ForEach-Object { "fig$($_.ToString('00'))" })
    }
}

$truth | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root\_ground_truth.json" -Encoding UTF8

"{0,-6}{1,8}{2,9}{3,7}{4,10}{5,8}{6,7}" -f "sec","lines","nonblank","tblrows","piperows","codblk","figrefs"
foreach ($k in $truth.Keys) {
    $v = $truth[$k]
    "{0,-6}{1,8}{2,9}{3,7}{4,10}{5,8}{6,7}   {7}" -f `
        $k, $v.lines, $v.nonblank, $v.table_rows, $v.pipe_rows, $v.code_blocks, $v.figure_refs, ($v.figure_ids -join " ")
}
