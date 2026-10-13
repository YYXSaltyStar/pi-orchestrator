# Launch the orchestrator parent agent with hard-revoked execution ability,
# plus automatic retry when a run fails the tool-delivery check.
#
# The parent gets ONLY: read, grep, find, ls, subagent.
# It has no write, edit, bash, or powershell -- removed at assembly time, so the
# model never even sees those tool definitions in its context.
#
# WHY THE RETRY LOOP EXISTS
# -------------------------
# The tool set is intermittently not delivered to the model. Two observed shapes:
#   A. the model writes a tool call as plain text, so nothing executes
#   B. the model has no tools at all and says so
# Both exit 0 and look successful. In-process repair cannot fix B (the tools are
# genuinely absent for that process), so the only reliable remedy is a FRESH process.
# The guard extension reports the failure; this loop acts on it.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads .ps1 as ANSI.

param(
    [string]$Task = "",
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Prompt  = Join-Path $LabRoot "orchestrator.prompt.md"
$ToolSet = "read,grep,find,ls,subagent"

# Resolve Pi as `node <cli.js>`. The npm shims on PATH (pi, pi.cmd, pi.ps1) are shell
# scripts, not Win32 executables, so Start-Process cannot launch them directly.
$NodeExe = (Get-Command node -ErrorAction Stop).Source
$PiCli = Join-Path $env:APPDATA "npm\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js"
if (-not (Test-Path $PiCli)) {
    Write-Error "Pi CLI entry not found: $PiCli"
    exit 1
}

if (-not (Test-Path $Prompt)) {
    Write-Error "orchestrator prompt not found: $Prompt"
    exit 1
}

Set-Location $LabRoot

# Enable the guard in this process; child subagent processes inherit it.
$env:PI_LEAK_GUARD = "1"

# ---- interactive mode: hand over to Pi directly, no retry loop ----------------
if (-not $Task) {
    Write-Host ""
    Write-Host "  orchestrator launching (interactive)" -ForegroundColor Cyan
    Write-Host "  workspace : $LabRoot"
    Write-Host "  granted   : $ToolSet"
    Write-Host "  revoked   : write, edit, bash, powershell" -ForegroundColor Yellow
    Write-Host "  -> the parent cannot write files; it must delegate" -ForegroundColor DarkGray
    Write-Host ""
    & pi --tools $ToolSet --append-system-prompt $Prompt
    exit $LASTEXITCODE
}

# ---- print mode: run with retry on guard failure ------------------------------
function Test-GuardFailure([string[]]$Captured) {
    foreach ($line in $Captured) {
        if ($line -match 'pi-guard:\s*FAIL\s+(\S+)') {
            return $Matches[1]
        }
    }
    return $null
}

Write-Host ""
Write-Host "  orchestrator run (print mode)" -ForegroundColor Cyan
Write-Host "  granted : $ToolSet"
Write-Host "  revoked : write, edit, bash, powershell" -ForegroundColor Yellow
Write-Host "  retries : up to $MaxAttempts attempts on tool-delivery failure"
Write-Host ""

$finalOutput = $null
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "  [attempt $attempt/$MaxAttempts]" -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Capture stdout and stderr into temp FILES rather than merging streams with 2>&1.
    # PowerShell wraps native stderr lines as ErrorRecords, which corrupts the captured
    # text and makes a successful run look like a failure.
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $NodeExe `
            -ArgumentList @($PiCli, "--tools", $ToolSet, "--append-system-prompt", $Prompt, "-p", $Task) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = @(Get-Content -LiteralPath $outFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        $stderr = @(Get-Content -LiteralPath $errFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    $sw.Stop()

    $reason = Test-GuardFailure $stderr
    if (-not $reason) {
        Write-Host "  [ok] tool delivery healthy ($([math]::Round($sw.Elapsed.TotalSeconds))s)" -ForegroundColor Green
        $finalOutput = $stdout
        break
    }

    Write-Host "  [fail] $reason after $([math]::Round($sw.Elapsed.TotalSeconds))s" -ForegroundColor Red
    if ($attempt -eq $MaxAttempts) {
        Write-Host "  [give up] still failing after $MaxAttempts attempts" -ForegroundColor Red
        $finalOutput = $stdout
        break
    }
    Write-Host "  [retry] starting a fresh process" -ForegroundColor Yellow
}

$finalOutput | ForEach-Object { Write-Output $_ }

$env:PI_LEAK_GUARD = $null
